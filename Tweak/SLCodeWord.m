//
//  SLCodeWord.m
//  声临 · 虚拟摄像头 —— 口令（#vcam）
//
//  ── 语义：点发送才生效，而且那条口令不许发出去 ──
//
//  打出 #vcam 什么都不发生（字不动，可以继续编辑、可以删掉）；
//  点发送 → 吞掉这次点击（宿主收不到，消息发不出去）+ 清空输入框 + 切球。
//
//  ── 0.3.42 为什么没成 ──
//
//  日志只有两条「口令随输入清空，按已发送处理」，说明：
//    · 发送键那种点击根本没被认出来（一条「点中发送候选」都没有）——
//      候选判据太窄：要求 hitTest 命中的那个 view 自己就长得像发送键
//      （宽 ≤160）。陌陌实际命中的多半是输入条或更外层的容器，直接被尺寸条件否掉。
//    · 认出来也没用：0.3.42 清完字又把事件原样转给宿主，宿主照样把消息发走了。
//    · 于是球只是「发完之后」被动跟着清空翻了一下，消息已经出去了。
//
//  ── 0.3.43 的改法 ──
//
//    1. 判据放宽：命中 view 自己不算，就往上找 4 层父视图（跳过包含着输入框的那层）；
//       名字（类名 / accessibility / 标题）带 send·发送·提交 直接算；
//       再补一条纯位置判据：落点在输入框右边缘之外、同一水平带、且在最右侧窄条里。
//    2. 命中就**吞掉这次点击**：清字 + 切球 + 直接 return，不再转给宿主 ——
//       宿主压根收不到 touchesEnded，发送动作不会发生。
//    3. 一条口令只切一次：切完立刻解除武装，必须重新打一遍 #vcam 才会再次生效。
//       0.3.42 那两次「一隐一显」就是武装状态没清干净、隔 3 秒又触发了一次。
//    4. 清字做了三层兜底（text / attributedText / textStorage），并在 0.3 秒后复查一次，
//       防止陌陌的外壳（UIExpandingTextView）把文字又同步回来。
//    5. 兜底链保留：控件 target-action、UIApplication sendAction、setText:、0.4 秒轮询。
//       任一条走到都只切一次球。
//
//  剩下唯一的代价：如果以上判据在陌陌上都失手，口令还是会跟着消息发出去，
//  那条路只能靠轮询兜底把球切过去。日志里会打出「待发状态下点中 view=… 链=…」，
//  下一次就能照着真实类名精确拦截。
//

#import "SLCodeWord.h"
#import "SLFloatingBall.h"
#import "SLUtil.h"
#import "SLLog.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

NSString *const SLVCodeWordText = @"#vcam";

/// 打出口令之后，等发送的最长时间。超过就作废（草稿放一小时再发不该切球）。
static const CFTimeInterval kSLCodeWordPendingTTL = 120.0;
/// 两次切换的最小间隔，防多条路同时命中。
static const CFTimeInterval kSLCodeWordToggleGap = 0.8;

/// 当前「握着口令」的输入框（弱引用：输入框随面板销毁时自动变 nil）
static __weak UIView *sSLArmedInput = nil;
static CFAbsoluteTime sSLArmedAt = 0;
static CFAbsoluteTime sSLLastToggleAt = 0;
/// 自己清空输入框 / 切状态期间挡掉重入
static BOOL sSLCodeWordBusy = NO;
/// 轮询兜底
static dispatch_source_t sSLWatchTimer = NULL;
/// 链路日志只打一次，避免刷屏（两种：就位链路、待发点击链路）
static NSString *sSLArmedChainLogged = nil;
static NSString *sSLTouchChainLogged = nil;

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

static NSString *SLVCodeWordTextOf(UIView *input) {
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

static void SLVCodeWordStopWatch(void);

static void SLVCodeWordDisarm(void) {
    sSLArmedInput = nil;
    sSLArmedAt = 0;
    SLVCodeWordStopWatch();
}

/// 口令被消费掉了。一条口令只走一次：进来就先解除武装，后面任何一条路再来都无效。
/// why 只用于日志。
static void SLVCodeWordFire(UIView *input, NSString *why) {
    if (sSLCodeWordBusy) return;

    UIView *armed = sSLArmedInput;
    if (!armed) return;
    if (input && input != armed) return;
    if (sSLArmedAt <= 0 || CFAbsoluteTimeGetCurrent() - sSLArmedAt > kSLCodeWordPendingTTL) {
        SLVCodeWordDisarm();
        return;
    }

    SLVLog(@"SL-VCAM: 口令生效（%@）", why);
    SLVCodeWordDisarm();

    sSLCodeWordBusy = YES;
    SLVCodeWordForceClear(armed);
    sSLCodeWordBusy = NO;

    SLVCodeWordToggle();

    // 复查：宿主有可能把文字又塞回输入框（陌陌的 UIExpandingTextView 会同步内部状态）
    __weak UIView *weakInput = armed;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *v = weakInput;
        if (!v) return;
        if (!SLVCodeWordIsCode(SLVCodeWordTextOf(v))) return;
        sSLCodeWordBusy = YES;
        SLVCodeWordForceClear(v);
        sSLCodeWordBusy = NO;
        SLVLog(@"SL-VCAM: 口令被塞回来了，已再清一次（%@）", NSStringFromClass([v class]));
    });
}

#pragma mark - 轮询兜底

static void SLVCodeWordStopWatch(void) {
    if (sSLWatchTimer) {
        dispatch_source_cancel(sSLWatchTimer);
        sSLWatchTimer = NULL;
    }
}

static void SLVCodeWordStartWatch(void) {
    SLVCodeWordStopWatch();

    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                              (uint64_t)(0.4 * NSEC_PER_SEC),
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(t, ^{
        UIView *input = sSLArmedInput;
        if (!input) { SLVCodeWordStopWatch(); return; }

        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (sSLArmedAt <= 0 || now - sSLArmedAt > kSLCodeWordPendingTTL) {
            SLVCodeWordDisarm();
            return;
        }

        NSString *norm = SLVCodeWordNormalize(SLVCodeWordTextOf(input));
        if ([norm isEqualToString:SLVCodeWordText]) return;   // 还在，继续等

        if (norm.length == 0) {
            // 宿主自己把输入框清了 —— 多半是发送已经发生（我们没拦住）。
            // 球还是照切，至少语义对得上。
            SLVLog(@"SL-VCAM: 口令被宿主清空（轮询兜底）→ 按已发送处理");
            SLVCodeWordFire(input, @"轮询兜底");
        } else {
            SLVLog(@"SL-VCAM: 口令被改写，作废");
            SLVCodeWordDisarm();
        }
    });
    sSLWatchTimer = t;
    dispatch_resume(t);
}

#pragma mark - 发送键识别

/// 名字像不像「发送」：类名、accessibilityLabel / Identifier、按钮标题
static BOOL SLVCodeWordViewNamedSend(UIView *v) {
    if (!v) return NO;
    NSMutableString *hay = [NSMutableString string];
    if (v.accessibilityLabel.length) [hay appendString:v.accessibilityLabel];
    if (v.accessibilityIdentifier.length) [hay appendString:v.accessibilityIdentifier];
    if ([v isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)v;
        if (b.currentTitle.length) [hay appendString:b.currentTitle];
        NSString *t = [b titleForState:UIControlStateNormal];
        if (t.length) [hay appendString:t];
    }
    [hay appendString:NSStringFromClass([v class])];
    NSString *n = hay.lowercaseString;
    return [n containsString:@"send"] || [n containsString:@"发送"] ||
           [n containsString:@"submit"] || [n containsString:@"提交"];
}

/// 纯位置的「发送键」判据：落在输入框右边缘之外、同一水平带、且在最右边那条窄带里。
/// 陌陌输入条从右到左一般是 [发送][+][表情][输入框]，只取最右窄带能避开表情和 +。
static BOOL SLVCodeWordPointLooksLikeSend(CGPoint pt, UIView *input) {
    if (!input || !input.window) return NO;
    CGRect inR = [input convertRect:input.bounds toView:nil];
    if (CGRectIsEmpty(inR)) return NO;

    if (pt.x <= CGRectGetMaxX(inR) + 4.0) return NO;                 // 必须在输入框右侧
    if (fabs(pt.y - CGRectGetMidY(inR)) > 110.0) return NO;          // 同一水平带
    CGFloat w = input.window.bounds.size.width;
    if (w > 0 && pt.x < w - 110.0) return NO;                        // 只在最右窄带里算
    return YES;
}

#pragma mark - 主路 1：触摸派发前拦截（所有点击都绕不过 sendEvent:）

typedef void (*SLVWindowSendEventIMP)(id, SEL, UIEvent *);
static SLVWindowSendEventIMP sSLWindowSendEventOrig = NULL;

static void SLVWindowSendEvent(id self, SEL _cmd, UIEvent *event) {
    if (!sSLCodeWordBusy && sSLArmedInput && event && event.type == UIEventTypeTouches) {
        UIView *input = sSLArmedInput;
        UIWindow *win = (UIWindow *)self;

        for (UITouch *t in event.allTouches) {
            if (t.phase != UITouchPhaseEnded) continue;
            if (t.window != win) continue;
            // 到这一步文字已经被改了（用户删字 / 宿主清空）→ 不再是待发状态
            if (!SLVCodeWordIsCode(SLVCodeWordTextOf(input))) break;

            CGPoint pt = [t locationInView:win];
            UIView *hit = [win hitTest:pt withEvent:event];

            // 从命中的 view 往上找 4 层。跳过「包含着输入框」的那层 ——
            // 输入条本身包着输入框，不能算发送键。
            BOOL named = NO;
            UIView *v = hit;
            for (int i = 0; i < 5 && v; i++) {
                if (v == input || [input isDescendantOfView:v]) { v = v.superview; continue; }
                if (SLVCodeWordViewNamedSend(v)) { named = YES; break; }
                v = v.superview;
            }
            BOOL byPoint = SLVCodeWordPointLooksLikeSend(pt, input);

            // 诊断：每个「待发状态下被点中的 view」都记一次（同样的链路只记一次）
            NSString *chain = hit ? SLVCodeWordChain(hit) : @"(nil)";
            if (![chain isEqualToString:sSLTouchChainLogged]) {
                sSLTouchChainLogged = [chain copy];
                CGRect inR = [input convertRect:input.bounds toView:nil];
                SLVLog(@"SL-VCAM: 待发点击 view=%@ 点名=%@ 位置=%@ 输入框右缘=%.0f 判定=%@ 链=%@",
                      hit ? NSStringFromClass([hit class]) : @"nil",
                      named ? @"Y" : @"N",
                      NSStringFromCGPoint(pt),
                      CGRectGetMaxX(inR),
                      (named || byPoint) ? @"拦" : @"放",
                      chain);
            }

            if (!named && !byPoint) continue;

            SLVLog(@"SL-VCAM: 点中发送（%@）→ 吞掉这次点击", named ? @"名字" : @"位置");
            SLVCodeWordFire(input, named ? @"触摸拦截·名字" : @"触摸拦截·位置");
            return;   // 关键：不再转给宿主，touchesEnded 不会送到发送键，消息发不出去
        }
    }

    if (sSLWindowSendEventOrig) sSLWindowSendEventOrig(self, _cmd, event);
}

#pragma mark - 主路 2：控件 target-action（iOS 14 的 addAction: 不走 UIApplication）

typedef BOOL (*SLVControlSendActionIMP)(id, SEL, SEL, id, UIEvent *);
static SLVControlSendActionIMP sSLControlSendActionOrig = NULL;

static BOOL SLVControlSendAction(id self, SEL _cmd, SEL action, id target, UIEvent *event) {
    if (!sSLCodeWordBusy && sSLArmedInput && [self isKindOfClass:[UIControl class]]) {
        UIView *input = sSLArmedInput;
        if (SLVCodeWordIsCode(SLVCodeWordTextOf(input))) {
            NSString *sel = action ? NSStringFromSelector(action).lowercaseString : @"";
            BOOL named = SLVCodeWordViewNamedSend((UIView *)self) ||
                         [sel containsString:@"send"] ||
                         [sel containsString:@"submit"] ||
                         [sel containsString:@"publish"];
            if (named) {
                SLVLog(@"SL-VCAM: 控件发送 action=%@ class=%@ → 拦下",
                      action ? NSStringFromSelector(action) : @"?",
                      NSStringFromClass([self class]));
                SLVCodeWordFire(input, @"控件动作");
                return NO;   // action 不派发，消息发不出去
            }
        }
    }
    if (sSLControlSendActionOrig) return sSLControlSendActionOrig(self, _cmd, action, target, event);
    return NO;
}

#pragma mark - 主路 3：UIApplication sendAction（老式 target-action）

typedef BOOL (*SLVAppSendActionIMP)(id, SEL, SEL, id, id, UIEvent *);
static SLVAppSendActionIMP sSLAppSendActionOrig = NULL;

static BOOL SLVAppSendAction(id self, SEL _cmd, SEL action, id target, id sender, UIEvent *event) {
    if (!sSLCodeWordBusy && sSLArmedInput && [sender isKindOfClass:[UIControl class]]) {
        UIView *input = sSLArmedInput;
        if (SLVCodeWordIsCode(SLVCodeWordTextOf(input))) {
            NSString *sel = action ? NSStringFromSelector(action).lowercaseString : @"";
            BOOL named = SLVCodeWordViewNamedSend((UIView *)sender) ||
                         [sel containsString:@"send"] ||
                         [sel containsString:@"submit"] ||
                         [sel containsString:@"publish"];
            if (named) {
                SLVLog(@"SL-VCAM: sendAction action=%@ sender=%@ → 拦下",
                      action ? NSStringFromSelector(action) : @"?",
                      NSStringFromClass([sender class]));
                SLVCodeWordFire(input, @"sendAction");
                return NO;
            }
        }
    }
    if (sSLAppSendActionOrig) return sSLAppSendActionOrig(self, _cmd, action, target, sender, event);
    return NO;
}

#pragma mark - 主路 4：程序性清空（setText:）

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

static void SLVTextViewSetText(id self, SEL _cmd, NSString *text) {
    UIView *input = (UIView *)self;
    NSString *old = SLVCodeWordTextOf(input);

    IMP orig = SLVCodeWordOrigForClass([self class]);
    if (orig) ((SLVSetTextIMP)orig)(self, _cmd, text);

    if (sSLCodeWordBusy) return;
    if (sSLArmedInput != input) return;
    if (!SLVCodeWordIsCode(old)) return;
    NSString *now = SLVCodeWordTextOf(input);
    if (now.length > 0) return;   // 改成别的了，说明用户在继续编辑

    SLVLog(@"SL-VCAM: 宿主 setText: 清空了口令（%@）", NSStringFromClass([input class]));
    SLVCodeWordFire(input, @"setText");
}

/// 给某个类挂 setText:。只在该类**自己**实现了这个方法时才挂，
/// 否则会和父类的钩子重复，一次赋值走两遍。
static BOOL SLVCodeWordHookSetTextClass(Class cls) {
    if (!cls || sSLSTCount >= SLV_MAX_SETTEXT_HOOKS) return NO;
    for (int i = 0; i < sSLSTCount; i++) {
        if (sSLSTClasses[i] == cls) return YES;   // 挂过了
    }

    SEL sel = NSSelectorFromString(@"setText:");
    unsigned int n = 0;
    Method *list = class_copyMethodList(cls, &n);
    BOOL own = NO;
    for (unsigned int i = 0; i < n; i++) {
        if (method_getName(list[i]) == sel) { own = YES; break; }
    }
    if (list) free(list);
    if (!own) return NO;   // 继承父类的实现，父类钩子已经能覆盖

    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;

    IMP prev = method_setImplementation(m, (IMP)SLVTextViewSetText);
    sSLSTClasses[sSLSTCount] = cls;
    sSLSTOrigs[sSLSTCount] = prev;
    sSLSTCount++;

    SLVLog(@"SL-VCAM: 给 %@ 补挂了 setText:", NSStringFromClass(cls));
    return YES;
}

#pragma mark - 状态机：文本变化

static void SLVCodeWordArm(UIView *input) {
    sSLArmedInput = input;
    sSLArmedAt = CFAbsoluteTimeGetCurrent();
    SLVCodeWordStartWatch();

    // 输入框的实际类如果是自绘的（陌陌是 UIExpandingTextViewInternal），
    // 它自己实现了 setText: 的话，父类的钩子会被绕过 —— 到这一步才认得出类名，就这儿补挂。
    SLVCodeWordHookSetTextClass([input class]);

    NSString *chain = SLVCodeWordChain(input);
    if (![chain isEqualToString:sSLArmedChainLogged]) {
        sSLArmedChainLogged = [chain copy];
        SLVLog(@"SL-VCAM: 口令已就位，等发送（%@）", chain);
    }
}

static void SLVCodeWordHandleChange(UIView *input) {
    if (sSLCodeWordBusy || !input) return;

    NSString *norm = SLVCodeWordNormalize(SLVCodeWordTextOf(input));

    // 1) 正好打成了口令 —— 只记住，不动手
    if ([norm isEqualToString:SLVCodeWordText]) {
        SLVCodeWordArm(input);
        return;
    }

    // 2) 变空了 —— 只认「刚刚握过口令的同一个输入框」
    if (norm.length == 0) {
        if (sSLArmedInput != input) return;
        SLVLog(@"SL-VCAM: 口令随输入清空，按已发送处理");
        SLVCodeWordFire(input, @"输入通知");
        return;
    }

    // 3) 改成别的了 —— 作废
    if (sSLArmedInput == input) {
        SLVLog(@"SL-VCAM: 口令被改成别的了，作废");
        SLVCodeWordDisarm();
    }
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

        // 主路 3：所有 target-action 的总出口
        Method appSelM = class_getInstanceMethod([UIApplication class],
                                                 NSSelectorFromString(@"sendAction:to:from:forEvent:"));
        if (appSelM) {
            sSLAppSendActionOrig = (SLVAppSendActionIMP)method_setImplementation(appSelM, (IMP)SLVAppSendAction);
        }

        // 主路 2：控件自己的 sendAction:（iOS 14 的 addAction:forControlEvents: 只走这里）
        Method ctlM = class_getInstanceMethod([UIControl class],
                                              NSSelectorFromString(@"sendAction:to:forEvent:"));
        if (ctlM) {
            sSLControlSendActionOrig = (SLVControlSendActionIMP)method_setImplementation(ctlM, (IMP)SLVControlSendAction);
        }

        // 主路 4：程序性清空（宿主发送后自己把 text 置空，这条不发系统通知）
        SLVCodeWordHookSetTextClass([UITextView class]);
        SLVCodeWordHookSetTextClass([UITextField class]);

        // 主路 1：所有点击的必经之路，比宿主的点击处理更早
        Method seM = class_getInstanceMethod([UIWindow class], NSSelectorFromString(@"sendEvent:"));
        if (seM) {
            sSLWindowSendEventOrig = (SLVWindowSendEventIMP)method_setImplementation(seM, (IMP)SLVWindowSendEvent);
        }

        SLVLog(@"SL-VCAM: 口令监听已装（发送 %@ 生效 · 触摸前=%@ · 控件动作=%@ · 应用动作=%@ · 清空钩子=%d 个类）",
              SLVCodeWordText,
              sSLWindowSendEventOrig ? @"开" : @"关",
              sSLControlSendActionOrig ? @"开" : @"关",
              sSLAppSendActionOrig ? @"开" : @"关",
              sSLSTCount);
    });
}
