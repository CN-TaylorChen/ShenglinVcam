//
//  SLCodeWord.m
//  声临 · 虚拟摄像头 —— 口令（#vcam）
//
//  ── 语义：发送才生效 ──
//
//  打出 #vcam 什么都不发生（字也不动，可以继续编辑、可以删掉）；点了发送才切球。
//
//  ── 为什么这么绕 ──
//
//  0.3.41 只挂了两条路，在陌陌上双双落空（日志只剩 `口令已就位`）：
//
//    · 主路 hook -[UIApplication sendAction:to:from:forEvent:]，等发送键来。没等到。
//    · 兜底看「文本一步变空」。也没等到 —— 因为 UITextView 的 text 被程序改写
//      （宿主发送后自己清空）**不会**发 UITextViewTextDidChangeNotification，
//      只有用户敲键盘才发。这条只在用户手打时成立。
//
//  所以 0.3.42 补三处，任何一处命中都能把球切过去：
//
//    1. sendAction 判定放宽 + 逐次打日志（action 方法名带 send 直接算）
//    2. hook -[UITextView setText:] / -[UITextField setText:]：程序清空也能看见，
//       并打调用栈 —— 下次日志能直接读出陌陌是哪个方法在清空输入框
//    3. 0.4 秒轮询兜底：pending 期间盯着文本，从口令变空就按已发送处理。
//       覆盖「既不走 target-action、也不是 setText」的一切未知路径
//
//  代价说清楚：1 能拦下发送（消息发不出去），2 和 3 拦不住 —— 那时宿主已经在
//  消费这条口令了，球照样切，但聊天里会多一条 #vcam。
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
/// 两次切换的最小间隔，防重入 / 防多条路同时命中。
static const CFTimeInterval kSLCodeWordToggleGap = 1.0;

/// 待发送的输入框（弱引用：输入框随面板销毁时自动变 nil，不用管）
static __weak UIView *sSLPendingInput = nil;
/// 上一次「正好是口令」的快照，兜底判定用
static __weak UIView *sSLLastCodeWordInput = nil;
static CFAbsoluteTime sSLPendingAt = 0;
static CFAbsoluteTime sSLLastToggleAt = 0;
/// 自己清空输入框 / 切状态期间挡掉重入
static BOOL sSLCodeWordBusy = NO;
/// 轮询兜底
static dispatch_source_t sSLWatchTimer = NULL;
/// 链路只打一次，避免刷屏
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

static BOOL SLVCodeWordIsCode(NSString *text) {
    return [SLVCodeWordNormalize(text) isEqualToString:SLVCodeWordText];
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
        UIView *input = sSLPendingInput;
        if (!input) { SLVCodeWordStopWatch(); return; }

        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (sSLPendingAt <= 0 || now - sSLPendingAt > kSLCodeWordPendingTTL) {
            sSLPendingInput = nil;
            sSLLastCodeWordInput = nil;
            SLVCodeWordStopWatch();
            return;
        }

        NSString *norm = SLVCodeWordNormalize(SLVCodeWordTextOf(input));
        if ([norm isEqualToString:SLVCodeWordText]) return;   // 还在，继续等

        sSLPendingInput = nil;
        sSLLastCodeWordInput = nil;
        SLVCodeWordStopWatch();

        if (norm.length == 0) {
            SLVLog(@"SL-VCAM: 口令消失（轮询兜底）→ 按已发送处理");
            SLVCodeWordToggle();
        } else {
            SLVLog(@"SL-VCAM: 口令被改写，作废");
        }
    });
    sSLWatchTimer = t;
    dispatch_resume(t);
}

#pragma mark - 发送键识别

// 纯位置判断：这块东西像不像「输入框右边的发送键」。
// 从 UIControl 和从 hitTest 拿到的任意 view 都走这一套，保证两路判据一致。
static BOOL SLVCodeWordRectLooksLikeSendButton(UIView *v, UIView *input) {
    if (!v || !input || !v.window || !input.window) return NO;
    if (v == input || [v isDescendantOfView:input]) return NO;

    CGRect inR = [input convertRect:input.bounds toView:nil];
    CGRect bR = [v convertRect:v.bounds toView:nil];
    if (CGRectIsEmpty(bR) || CGRectIsEmpty(inR)) return NO;

    CGFloat dy = fabs(CGRectGetMidY(bR) - CGRectGetMidY(inR));
    BOOL rightSide = CGRectGetMidX(bR) > CGRectGetMidX(inR);
    BOOL sizeOK = bR.size.width >= 8.0 && bR.size.width <= 160.0 && bR.size.height <= 160.0;
    return (rightSide && dy < 200.0 && sizeOK);
}

// 这次点击是不是「发送」。按可靠性从高到低三种特征，命中任一即算：
//   1) action 方法名里带 send / submit / publish（陌陌这类自研发送键最常见）
//   2) 名字里带「发送 / send」（accessibilityLabel、标题、identifier）
//   3) 位置：在输入框右侧、同一水平带、个头不大
static BOOL SLVCodeWordLooksLikeSend(id sender, SEL action, UIView *input) {
    if (![sender isKindOfClass:[UIControl class]]) return NO;

    UIControl *c = (UIControl *)sender;
    if (c == input || [input isDescendantOfView:c]) return NO;

    NSString *sel = action ? NSStringFromSelector(action) : @"";
    NSString *selL = sel.lowercaseString;
    if ([selL containsString:@"send"] || [selL containsString:@"submit"] || [selL containsString:@"publish"]) {
        return YES;
    }

    NSMutableString *hay = [NSMutableString string];
    if (c.accessibilityLabel.length) [hay appendString:c.accessibilityLabel];
    if (c.accessibilityIdentifier.length) [hay appendString:c.accessibilityIdentifier];
    if ([c isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)c;
        if (b.currentTitle.length) [hay appendString:b.currentTitle];
        NSString *t = [b titleForState:UIControlStateNormal];
        if (t.length) [hay appendString:t];
    }
    NSString *name = hay.lowercaseString;
    if ([name containsString:@"发送"] || [name containsString:@"send"]) return YES;

    return SLVCodeWordRectLooksLikeSendButton(c, input);
}

static NSString *SLVCodeWordSenderLabel(id sender) {
    if (![sender isKindOfClass:[UIControl class]]) return @"-";
    UIControl *c = (UIControl *)sender;
    if (c.accessibilityLabel.length) return c.accessibilityLabel;
    if ([c isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)c;
        if (b.currentTitle.length) return b.currentTitle;
    }
    return @"-";
}

#pragma mark - 主路：拦发送动作

/// 返回 YES 表示这次动作被我们吃掉了（不再往下派发，消息发不出去）
static BOOL SLVCodeWordConsumeSend(id sender, SEL action) {
    if (sSLCodeWordBusy) return NO;

    UIView *input = sSLPendingInput;
    if (!input) return NO;
    if (sSLPendingAt <= 0 || CFAbsoluteTimeGetCurrent() - sSLPendingAt > kSLCodeWordPendingTTL) {
        sSLPendingInput = nil;
        return NO;
    }

    // 宿主可能已经把文本改掉了（发送流程里先清空再派发），那就交给兜底
    if (!SLVCodeWordIsCode(SLVCodeWordTextOf(input))) return NO;

    BOOL hit = SLVCodeWordLooksLikeSend(sender, action, input);
    SLVLog(@"SL-VCAM: sendAction sender=%@ action=%@ label=%@ 判定=%@",
          sender ? NSStringFromClass([sender class]) : @"nil",
          action ? NSStringFromSelector(action) : @"?",
          SLVCodeWordSenderLabel(sender),
          hit ? @"拦" : @"放");
    if (!hit) return NO;

    sSLPendingInput = nil;
    sSLLastCodeWordInput = nil;
    SLVCodeWordStopWatch();

    sSLCodeWordBusy = YES;
    SLVCodeWordClearInput(input);   // 字清掉，宿主那边也不会再拿它当草稿
    sSLCodeWordBusy = NO;

    SLVCodeWordToggle();
    return YES;
}

typedef BOOL (*SLVAppSendActionIMP)(id, SEL, SEL, id, id, UIEvent *);
static SLVAppSendActionIMP sSLAppSendActionOrig = NULL;

static BOOL SLVAppSendAction(id self, SEL _cmd, SEL action, id target, id sender, UIEvent *event) {
    if (SLVCodeWordConsumeSend(sender, action)) return NO;
    if (sSLAppSendActionOrig) return sSLAppSendActionOrig(self, _cmd, action, target, sender, event);
    return NO;
}

#pragma mark - 第三路：触摸派发前抢先清空

// 陌陌的发送键既不走 target-action（sendAction 一次没来过），也不是 setText:
// 清的空。那就只剩一个所有点击都绕不过去的点：UIWindow 的 sendEvent:。
//
// 它比宿主自己的点击处理更早，此时 hitTest 能拿到真正被点的那个 view ——
// 不管它是 UIButton、自绘 view 还是加在手势上的容器。判出来是「输入框右边的
// 小块」就当场把口令清掉：宿主随后读到的是空串，消息发不出去。
typedef void (*SLVWindowSendEventIMP)(id, SEL, UIEvent *);
static SLVWindowSendEventIMP sSLWindowSendEventOrig = NULL;

static void SLVWindowSendEvent(id self, SEL _cmd, UIEvent *event) {
    if (!sSLCodeWordBusy && sSLPendingInput && event && event.type == UIEventTypeTouches) {
        UIView *input = sSLPendingInput;
        BOOL consumed = NO;

        for (UITouch *t in event.allTouches) {
            if (consumed) break;
            if (t.phase != UITouchPhaseEnded) continue;
            if (t.window != (UIWindow *)self) continue;
            if (!SLVCodeWordIsCode(SLVCodeWordTextOf(input))) continue;

            UIView *hit = [(UIWindow *)self hitTest:[t locationInWindow] withEvent:event];
            if (!hit) continue;
            if (!SLVCodeWordRectLooksLikeSendButton(hit, input)) {
                continue;
            }

            SLVLog(@"SL-VCAM: 点中发送候选 view=%@ → 抢先清空口令", NSStringFromClass([hit class]));

            sSLPendingInput = nil;
            sSLLastCodeWordInput = nil;
            SLVCodeWordStopWatch();

            sSLCodeWordBusy = YES;
            SLVCodeWordClearInput(input);
            sSLCodeWordBusy = NO;

            SLVCodeWordToggle();
            consumed = YES;
        }
    }

    if (sSLWindowSendEventOrig) sSLWindowSendEventOrig(self, _cmd, event);
}

#pragma mark - 第二路：程序性清空（setText:）

/// 宿主要改输入框内容了。oldText 是改之前的值。
/// 只有「改之前正好是口令、改之后是空」才算用掉了这条口令 —— 改成别的说明用户在继续编辑。
static void SLVCodeWordNoteSetText(UIView *input, NSString *oldText) {
    if (sSLCodeWordBusy || !input) return;
    if (sSLPendingInput != input) return;
    if (!SLVCodeWordIsCode(oldText)) return;

    NSString *now = SLVCodeWordTextOf(input);
    if (now.length > 0) return;   // 改成别的了，不算发送

    sSLPendingInput = nil;
    sSLLastCodeWordInput = nil;
    SLVCodeWordStopWatch();

    SLVLog(@"SL-VCAM: 宿主清空了口令（setText:%@）→ 已发送", NSStringFromClass([input class]));

    // 调用栈：陌陌这条链路不打这一手，永远只能靠猜。只打前 14 帧。
    NSArray *stack = [NSThread callStackSymbols];
    NSUInteger n = MIN(stack.count, (NSUInteger)14);
    for (NSUInteger i = 1; i < n; i++) SLVLog(@"    ↳ %@", stack[i]);

    SLVCodeWordToggle();
}

typedef void (*SLVSetTextIMP)(id, SEL, NSString *);

// 每个类单独存一份原 IMP。
// 不能用一个全局变量：UITextView 和它的子类（陌陌的 UIExpandingTextViewInternal）
// 如果都实现了 setText:，两份原 IMP 不是同一个，混用就会调错实现。
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

static NSString *SLVCodeWordTextOfObject(id o) {
    if ([o isKindOfClass:[UITextField class]]) return ((UITextField *)o).text;
    if ([o isKindOfClass:[UITextView class]]) return ((UITextView *)o).text;
    return nil;
}

static void SLVTextViewSetText(id self, SEL _cmd, NSString *text) {
    NSString *old = SLVCodeWordTextOfObject(self);
    IMP orig = SLVCodeWordOrigForClass([self class]);
    if (orig) ((SLVSetTextIMP)orig)(self, _cmd, text);
    SLVCodeWordNoteSetText(self, old);
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

static void SLVCodeWordHandleChange(UIView *input) {
    if (sSLCodeWordBusy || !input) return;

    NSString *norm = SLVCodeWordNormalize(SLVCodeWordTextOf(input));

    // 1) 正好打成了口令 —— 只记住，不动手
    if ([norm isEqualToString:SLVCodeWordText]) {
        sSLPendingInput = input;
        sSLLastCodeWordInput = input;
        sSLPendingAt = CFAbsoluteTimeGetCurrent();
        SLVCodeWordStartWatch();

        // 输入框的实际类如果是自绘的（陌陌是 UIExpandingTextViewInternal），
        // 它自己实现了 setText: 的话，父类的钩子会被绕过 —— 到这一步才认得出类名，就这儿补挂。
        SLVCodeWordHookSetTextClass([input class]);

        NSString *chain = SLVCodeWordChain(input);
        if (![chain isEqualToString:sSLLastChainLogged]) {
            sSLLastChainLogged = [chain copy];
            SLVLog(@"SL-VCAM: 口令已就位，等发送（%@）", chain);
        }
        return;
    }

    // 2) 一步变空 —— 用户手打时宿主清空会走到这里（程序清空走 setText 钩子）
    if (norm.length == 0) {
        BOOL wasCodeWord = (sSLLastCodeWordInput == input);
        sSLLastCodeWordInput = nil;
        if (!wasCodeWord) return;
        if (sSLPendingAt <= 0 || CFAbsoluteTimeGetCurrent() - sSLPendingAt > kSLCodeWordPendingTTL) {
            sSLPendingInput = nil;
            return;
        }
        sSLPendingInput = nil;
        SLVCodeWordStopWatch();
        SLVLog(@"SL-VCAM: 口令随输入清空，按已发送处理");
        SLVCodeWordToggle();
        return;
    }

    // 3) 改成别的了 —— 作废
    if (sSLLastCodeWordInput == input) sSLLastCodeWordInput = nil;
    if (sSLPendingInput == input) {
        sSLPendingInput = nil;
        SLVCodeWordStopWatch();
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

        // 主路：所有 target-action 的总出口
        SEL sendSel = NSSelectorFromString(@"sendAction:to:from:forEvent:");
        Method sendM = class_getInstanceMethod([UIApplication class], sendSel);
        if (sendM) {
            sSLAppSendActionOrig = (SLVAppSendActionIMP)method_setImplementation(sendM, (IMP)SLVAppSendAction);
        }

        // 第二路：程序性清空（宿主发送后自己把 text 置空，这条不发系统通知）
        SLVCodeWordHookSetTextClass([UITextView class]);
        SLVCodeWordHookSetTextClass([UITextField class]);

        // 第三路：所有点击的必经之路，比宿主的点击处理更早
        Method seM = class_getInstanceMethod([UIWindow class], NSSelectorFromString(@"sendEvent:"));
        if (seM) {
            sSLWindowSendEventOrig = (SLVWindowSendEventIMP)method_setImplementation(seM, (IMP)SLVWindowSendEvent);
        }

        SLVLog(@"SL-VCAM: 口令监听已装（发送 %@ 生效 · 拦动作=%@ · 触摸前=%@ · 清空钩子=%d 个类）",
              SLVCodeWordText,
              sSLAppSendActionOrig ? @"开" : @"关",
              sSLWindowSendEventOrig ? @"开" : @"关",
              sSLSTCount);
    });
}
