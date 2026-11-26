//
//  SLCodeWord.m
//  声临 · 虚拟摄像头 —— 口令（#vcam）
//
//  ── 为什么是「发送」而不是「输入」 ──
//
//  输入即触发的问题：中文输入法下打 #vcam 要经过中间态（#、#v、#vc……），
//  只要中间态碰巧被切到，球就闪了一下；而且字被吃掉，用户以为自己打错了。
//  但「发送」就一个明确动作，跟人按发送键的直觉一致。
//
//  ── 怎么抓到「发送」──
//
//  只在文本变化里猜是不够的（那分不清「点发送」和「全选删除」）。所以分两路：
//
//   主路：hook -[UIApplication sendAction:to:from:forEvent:]，这是所有
//         target-action 的唯一出口。文本正好是口令 + 这次点击是发送键 → 直接
//         吞掉这个动作，消息不会发出去，输入框清空，球跟着切。
//   兜底：有些宿主的发送键是自绘视图加手势，根本不走 target-action。那就看
//         「上一条快照正好是口令、下一条直接变成空」—— 逐字删除会有中间态，
//         一步到空只可能是宿主在发送后自己清的空。
//
//  两路共用同一个 pending 输入框 + 时间窗，谁先到谁触发，触发时立刻作废，
//  不会因为拦下来之后又收到一条清空通知而切两次。
//

#import "SLCodeWord.h"
#import "SLFloatingBall.h"
#import "SLUtil.h"
#import "SLLog.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

NSString *const SLVCodeWordText = @"#vcam";

/// 打出口令之后，等发送的最长时间。超过就作废（草稿留一小时再发不该切球）。
static const CFTimeInterval kSLCodeWordPendingTTL = 30.0;

/// 两次切换的最小间隔，防重入 / 防两路同时命中。
static const CFTimeInterval kSLCodeWordToggleGap = 1.0;

/// 待发送的输入框（弱引用：输入框随面板销毁时自动变 nil，不用管）
static __weak UIView *sSLPendingInput = nil;
/// 上一次「正好是口令」的快照，兜底判定用
static __weak UIView *sSLLastCodeWordInput = nil;
static CFAbsoluteTime sSLPendingAt = 0;
static CFAbsoluteTime sSLLastToggleAt = 0;
/// 自己清空输入框 / 切状态期间挡掉重入
static BOOL sSLCodeWordBusy = NO;

#pragma mark - 基础

// 归一化：去首尾空白 → 全角转半角 → 小写。
// 中文输入法在英文状态下很容易打出「＃ｖｃａｍ」，原样比较会认不出来。
static NSString *SLVCodeWordNormalize(NSString *_Nullable text) {
    if (text.length == 0) return @"";
    NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableString *out = [NSMutableString stringWithCapacity:t.length];
    for (NSUInteger i = 0; i < t.length; i++) {
        unichar c = [t characterAtIndex:i];
        // 全角 ASCII 落在 0xFF01–0xFF5E，整体减 0xFEE0 回到半角
        if (c >= 0xFF01 && c <= 0xFF5E) c = (unichar)(c - 0xFEE0);
        [out appendString:[NSString stringWithCharacters:&c length:1]];
    }
    return [out lowercaseString];
}

static NSString *SLVCodeWordTextOf(UIView *input) {
    if ([input isKindOfClass:[UITextField class]]) return ((UITextField *)input).text;
    if ([input isKindOfClass:[UITextView class]]) return ((UITextView *)input).text;
    return nil;
}

// 清掉输入框里的口令。
// 只写 text 属性：宿主自己的 placeholder / 发送键可用状态都挂在这上面，
// 补一个 editingChanged（文本框）或 TextDidChange（文本视图）能让它们的 binding 跟上，
// 不至于留一行看不见的文字在草稿里。
static void SLVCodeWordClearInput(UIView *input) {
    if ([input isKindOfClass:[UITextField class]]) {
        UITextField *tf = (UITextField *)input;
        tf.text = @"";
        [tf sendActionsForControlEvents:UIControlEventEditingChanged];
    } else if ([input isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView *)input;
        tv.text = @"";
        [[NSNotificationCenter defaultCenter] postNotificationName:UITextViewTextDidChangeNotification
                                                            object:tv];
    }
}

#pragma mark - 切换

static void SLVCodeWordToggle(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (sSLLastToggleAt > 0 && now - sSLLastToggleAt < kSLCodeWordToggleGap) return;
    sSLLastToggleAt = now;

    BOOL hide = !SLVFloatBallHidden();

    sSLCodeWordBusy = YES;
    SLVSetFloatBallHidden(hide);
    sSLCodeWordBusy = NO;

    SLVToast(hide ? @"悬浮球已隐藏 · 发送 #vcam 可恢复" : @"悬浮球已显示");
    SLVLog(@"SL-VCAM: 口令 %@ → 悬浮球%@", SLVCodeWordText, hide ? @"隐藏" : @"显示");
}

#pragma mark - 发送键识别

// 这次点击是不是「发送」。两种特征，命中任一即算：
//   1) 名字里带「发送 / send」（accessibilityLabel、标题、identifier）
//   2) 陌陌这类自绘发送键没有名字，就按位置判断：在输入框右侧、同一水平带、个头不大
static BOOL SLVCodeWordLooksLikeSend(id sender, UIView *input) {
    if (![sender isKindOfClass:[UIControl class]]) return NO;

    UIControl *c = (UIControl *)sender;
    if (c == input) return NO;
    if (input && [input isDescendantOfView:c]) return NO;

    NSMutableString *hay = [NSMutableString string];
    if (c.accessibilityLabel.length) [hay appendString:c.accessibilityLabel];
    if (c.accessibilityIdentifier.length) [hay appendString:c.accessibilityIdentifier];
    if ([c isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)c;
        if (b.currentTitle.length) [hay appendString:b.currentTitle];
        NSString *t = [b titleForState:UIControlStateNormal];
        if (t.length) [hay appendString:t];
    }
    NSString *name = [hay lowercaseString];
    if ([name containsString:@"发送"] || [name containsString:@"send"]) return YES;

    // 位置兜底
    if (!input || !input.window || !c.window) return NO;
    CGRect inR = [input convertRect:input.bounds toView:nil];
    CGRect bR = [c convertRect:c.bounds toView:nil];
    if (CGRectIsEmpty(bR) || CGRectIsEmpty(inR)) return NO;

    CGFloat dy = fabs(CGRectGetMidY(bR) - CGRectGetMidY(inR));
    CGFloat band = MAX(90.0, CGRectGetHeight(inR) * 0.8 + 40.0);
    BOOL rightSide = CGRectGetMidX(bR) > CGRectGetMidX(inR);
    BOOL bandOK = dy < band;
    BOOL sizeOK = bR.size.width <= 140.0 && bR.size.height <= 140.0 && bR.size.width >= 8.0;
    return (rightSide && bandOK && sizeOK);
}

#pragma mark - 主路：拦发送动作

/// 返回 YES 表示这次动作被我们吃掉了（不再往下派发，消息发不出去）
static BOOL SLVCodeWordConsumeSend(id sender) {
    if (sSLCodeWordBusy) return NO;

    UIView *input = sSLPendingInput;
    if (!input) return NO;
    if (sSLPendingAt <= 0 || CFAbsoluteTimeGetCurrent() - sSLPendingAt > kSLCodeWordPendingTTL) {
        sSLPendingInput = nil;
        return NO;
    }

    NSString *raw = SLVCodeWordTextOf(input);
    if (![SLVCodeWordNormalize(raw) isEqualToString:SLVCodeWordText]) {
        sSLPendingInput = nil;
        return NO;
    }

    if (!SLVCodeWordLooksLikeSend(sender, input)) return NO;

    NSString *label = nil;
    if ([sender isKindOfClass:[UIControl class]]) {
        label = [(UIControl *)sender accessibilityLabel];
        if (!label.length && [sender isKindOfClass:[UIButton class]]) {
            label = [(UIButton *)sender currentTitle];
        }
    }
    SLVLog(@"SL-VCAM: 口令发送被拦下 sender=%@ label=%@",
          NSStringFromClass([sender class]), label.length ? label : @"-");

    sSLPendingInput = nil;
    sSLLastCodeWordInput = nil;

    sSLCodeWordBusy = YES;
    SLVCodeWordClearInput(input);   // 字清掉，宿主那边也不会再拿它当草稿
    sSLCodeWordBusy = NO;

    SLVCodeWordToggle();
    return YES;
}

typedef BOOL (*SLVAppSendActionIMP)(id, SEL, SEL, id, id, UIEvent *);
static SLVAppSendActionIMP sSLAppSendActionOrig = NULL;

static BOOL SLVAppSendAction(id self, SEL _cmd, SEL action, id target, id sender, UIEvent *event) {
    if (SLVCodeWordConsumeSend(sender)) return NO;
    if (sSLAppSendActionOrig) return sSLAppSendActionOrig(self, _cmd, action, target, sender, event);
    return NO;
}

#pragma mark - 兜底 / 状态机：文本变化

static void SLVCodeWordHandleChange(UIView *input) {
    if (sSLCodeWordBusy || !input) return;

    NSString *norm = SLVCodeWordNormalize(SLVCodeWordTextOf(input));

    // 1) 正好打成了口令 —— 只记住，不动手
    if ([norm isEqualToString:SLVCodeWordText]) {
        sSLPendingInput = input;
        sSLLastCodeWordInput = input;
        sSLPendingAt = CFAbsoluteTimeGetCurrent();
        SLVLog(@"SL-VCAM: 口令已就位，等发送（%@）", NSStringFromClass([input class]));
        return;
    }

    // 2) 一步变空 —— 宿主发完自己清的空（逐字删除会有中间态，走不到这里）
    if (norm.length == 0) {
        BOOL wasCodeWord = (sSLLastCodeWordInput == input);
        sSLLastCodeWordInput = nil;
        if (!wasCodeWord) return;
        if (sSLPendingAt <= 0 || CFAbsoluteTimeGetCurrent() - sSLPendingAt > kSLCodeWordPendingTTL) {
            sSLPendingInput = nil;
            return;
        }
        sSLPendingInput = nil;
        SLVLog(@"SL-VCAM: 口令随发送清空，按已发送处理");
        SLVCodeWordToggle();
        return;
    }

    // 3) 改成别的了 —— 作废
    if (sSLLastCodeWordInput == input) sSLLastCodeWordInput = nil;
    if (sSLPendingInput == input) sSLPendingInput = nil;
}

#pragma mark - 装监听

void SLVStartCodeWordWatcher(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

        [nc addObserverForName:UITextFieldTextDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n) {
            id obj = n.object;
            if ([obj isKindOfClass:[UITextField class]]) SLVCodeWordHandleChange(obj);
        }];

        [nc addObserverForName:UITextViewTextDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n) {
            id obj = n.object;
            if ([obj isKindOfClass:[UITextView class]]) SLVCodeWordHandleChange(obj);
        }];

        // 主路：所有 target-action 的总出口
        SEL sel = NSSelectorFromString(@"sendAction:to:from:forEvent:");
        Method m = class_getInstanceMethod([UIApplication class], sel);
        if (m) {
            sSLAppSendActionOrig = (SLVAppSendActionIMP)method_setImplementation(m, (IMP)SLVAppSendAction);
        }

        SLVLog(@"SL-VCAM: 口令监听已装（发送 %@ 生效 · 拦发送=%@）",
              SLVCodeWordText, sSLAppSendActionOrig ? @"开" : @"关");
    });
}
