//
//  SLCodeWord.m
//  声临 · 虚拟摄像头 —— 口令（#vcam）
//
//  ── 语义：打出来就生效，不用发送 ──
//
//  输入框里的内容一变成 #vcam，立刻：切球 + 把口令从输入框里清掉。
//  清掉是为了不让它赖在输入框里（以前发出去以后字还在，导致反复触发、消息也照发）。
//
//  ── 为什么不再等「发送」 ──
//
//  0.3.41 ~ 0.3.43 一直在追发送那一下，结论是追不到：
//
//    · 陌陌的发送键既不走 target-action，也不是 setText: 清空；
//    · 0.3.43 的日志证明整轮操作里没有一次点击落在输入条右侧 ——
//      发送极可能是用键盘上的「发送」键完成的，那个触摸在 UIRemoteKeyboardWindow 里，
//      而这类系统窗口自己重写了 sendEvent:，挂在 -[UIWindow sendEvent:] 上的钩子对它无效。
//
//  与其继续猜发送键长什么样，不如把触发点挪到「文本本身」：
//  文本变成口令 = 用户就是想执行口令，这个信号不需要识别任何按钮。
//
//  ── 实现 ──
//
//    1. 文本通知（UITextField/UITextView TextDidChange）：手打、粘贴都能收到。
//    2. 顺带 hook 输入框实际类的 -setText:：程序性写入（草稿恢复、快捷输入）也看得见。
//       只在该类自己实现了 setText: 时才挂，避免和父类钩子重复触发。
//    3. 命中后清字做了三层兜底（text / attributedText / textStorage），
//       并在 0.3 秒后复查一次，宿主塞回来就再清一次。
//    4. 0.6 秒内不重复触发，防止清字引发的连锁通知把球来回翻。
//

#import "SLCodeWord.h"
#import "SLFloatingBall.h"
#import "SLUtil.h"
#import "SLLog.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

NSString *const SLVCodeWordText = @"#vcam";

/// 两次触发的最小间隔：清字本身会引发一串文本通知，别让它把球翻回去
static const CFTimeInterval kSLCodeWordGap = 0.6;

/// 自己清字期间挡掉重入
static BOOL sSLCodeWordBusy = NO;
static CFAbsoluteTime sSLLastFireAt = 0;
/// 就位链路只打一次，避免刷屏
static NSString *sSLLastChainLogged = nil;

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

static BOOL SLVCodeWordIsCode(NSString *_Nullable text) {
    return [SLVCodeWordNormalize(text) isEqualToString:SLVCodeWordText];
}

static NSString *SLVCodeWordTextOf(id input) {
    if ([input isKindOfClass:[UITextField class]]) return ((UITextField *)input).text;
    if ([input isKindOfClass:[UITextView class]]) return ((UITextView *)input).text;
    return nil;
}

// 清掉输入框里的口令。
// 三层兜底：text 属性（宿主自己的 placeholder / 发送键可用状态都挂在这上面）、
// attributedText、textStorage。陌陌的输入框是 UIExpandingTextView 外壳 + 内部
// textView，只改 text 有可能被外壳同步回来，所以能改的层都改一遍。
static void SLVCodeWordForceClear(UIView *input) {
    if ([input isKindOfClass:[UITextField class]]) {
        UITextField *tf = (UITextField *)input;
        if (tf.text.length) tf.text = @"";
        [tf sendActionsForControlEvents:UIControlEventEditingChanged];
        return;
    }
    if (![input isKindOfClass:[UITextView class]]) return;

    UITextView *tv = (UITextView *)input;
    if (tv.text.length) tv.text = @"";
    if (tv.attributedText.length) {
        tv.attributedText = [[NSAttributedString alloc] initWithString:@""];
    }
    if (tv.textStorage.length) {
        [tv.textStorage replaceCharactersInRange:NSMakeRange(0, tv.textStorage.length)
                                      withString:@""];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:UITextViewTextDidChangeNotification
                                                        object:tv];
}

/// 输入框 → 向上 12 层 responder 的类名，用来认「这块输入属于谁」
static NSString *SLVCodeWordChain(UIView *v) {
    NSMutableArray *a = [NSMutableArray array];
    id cur = v;
    for (int i = 0; i < 12 && cur; i++) {
        [a addObject:NSStringFromClass([cur class])];
        cur = [cur nextResponder];
    }
    return [a componentsJoinedByString:@" > "];
}

#pragma mark - 切换

static void SLVCodeWordToggle(void) {
    BOOL hide = !SLVFloatBallHidden();

    SLVSetFloatBallHidden(hide);

    SLVToast(hide ? @"悬浮球已隐藏 · 再打一次 #vcam 可恢复" : @"悬浮球已显示");
    SLVLog(@"SL-VCAM: 口令 %@ → 悬浮球%@", SLVCodeWordText, hide ? @"隐藏" : @"显示");
}

#pragma mark - 隐藏 setText:（程序性写入也能看见）

typedef void (*SLVSetTextIMP)(id, SEL, NSString *);

// 每个类单独存一份原 IMP。
// 不能用一个全局变量：UITextView 和它的子类如果都实现了 setText:，
// 两份原 IMP 不是同一个，混用就会调错实现。
#define SLV_MAX_SETTEXT_HOOKS 8
static Class sSLSTClasses[SLV_MAX_SETTEXT_HOOKS];
static IMP sSLSTOrigs[SLV_MAX_SETTEXT_HOOKS];
static int sSLSTCount = 0;

static IMP SLVCodeWordOrigForClass(Class cls) {
    for (int i = sSLSTCount - 1; i >= 0; i--) {
        if (sSLSTClasses[i] == cls) return sSLSTOrigs[i];
    }
    return NULL;
}

static void SLVCodeWordHandleText(UIView *input);

static void SLVTextViewSetText(id self, SEL _cmd, NSString *text) {
    IMP orig = SLVCodeWordOrigForClass([self class]);
    if (orig) ((SLVSetTextIMP)orig)(self, _cmd, text);

    if (!sSLCodeWordBusy && [self isKindOfClass:[UIView class]]) {
        SLVCodeWordHandleText((UIView *)self);
    }
}

/// 给某个类挂 setText:。只在该类**自己**实现了这个方法时才挂，
/// 否则会和父类的钩子重复，一次赋值走两遍。
static void SLVCodeWordHookSetTextClass(Class cls) {
    if (!cls || sSLSTCount >= SLV_MAX_SETTEXT_HOOKS) return;
    for (int i = 0; i < sSLSTCount; i++) {
        if (sSLSTClasses[i] == cls) return;   // 挂过了
    }

    SEL sel = NSSelectorFromString(@"setText:");
    unsigned int n = 0;
    Method *list = class_copyMethodList(cls, &n);
    BOOL own = NO;
    for (unsigned int i = 0; i < n; i++) {
        if (method_getName(list[i]) == sel) { own = YES; break; }
    }
    if (list) free(list);
    if (!own) return;   // 继承父类的实现，父类钩子已经能覆盖

    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    IMP prev = method_setImplementation(m, (IMP)SLVTextViewSetText);
    sSLSTClasses[sSLSTCount] = cls;
    sSLSTOrigs[sSLSTCount] = prev;
    sSLSTCount++;

    SLVLog(@"SL-VCAM: 给 %@ 补挂了 setText:", NSStringFromClass(cls));
}

#pragma mark - 状态机：文本变化

/// 文本一变成口令就干活。手打、粘贴、程序写入都走这里。
static void SLVCodeWordHandleText(UIView *input) {
    if (sSLCodeWordBusy || !input) return;

    // 顺手把输入框实际类的 setText: 挂上（陌陌是 UIExpandingTextViewInternal），
    // 这样它自己重写 setText: 时也绕不过我们。挂过的类内部会直接返回。
    SLVCodeWordHookSetTextClass([input class]);

    NSString *text = SLVCodeWordTextOf(input);
    if (!SLVCodeWordIsCode(text)) return;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (sSLLastFireAt > 0 && now - sSLLastFireAt < kSLCodeWordGap) return;
    sSLLastFireAt = now;

    SLVLog(@"SL-VCAM: 输入框里出现口令「%@」（%@）→ 生效", text, NSStringFromClass([input class]));

    sSLCodeWordBusy = YES;
    SLVCodeWordForceClear(input);
    sSLCodeWordBusy = NO;

    SLVCodeWordToggle();

    NSString *chain = SLVCodeWordChain(input);
    if (![chain isEqualToString:sSLLastChainLogged]) {
        sSLLastChainLogged = [chain copy];
        SLVLog(@"SL-VCAM: 口令来源链路 %@", chain);
    }

    // 复查：陌陌的 UIExpandingTextView 外壳可能把文字又同步回来
    __weak UIView *weakInput = input;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *v = weakInput;
        if (!v) return;
        if (!SLVCodeWordIsCode(SLVCodeWordTextOf(v))) return;
        sSLCodeWordBusy = YES;
        SLVCodeWordForceClear(v);
        sSLCodeWordBusy = NO;
        SLVLog(@"SL-VCAM: 口令被塞回来了，已再清一次");
    });
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
            if ([obj isKindOfClass:[UITextField class]]) SLVCodeWordHandleText(obj);
        }];

        [nc addObserverForName:UITextViewTextDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n) {
            id obj = n.object;
            if ([obj isKindOfClass:[UITextView class]]) SLVCodeWordHandleText(obj);
        }];

        // 程序性写入：宿主自己把 text 置成口令（草稿恢复、快捷输入）也认
        SLVCodeWordHookSetTextClass([UITextView class]);
        SLVCodeWordHookSetTextClass([UITextField class]);

        SLVLog(@"SL-VCAM: 口令监听已装（输入 %@ 即生效，无需发送 · 清空钩子=%d 个类）",
              SLVCodeWordText, sSLSTCount);
    });
}
