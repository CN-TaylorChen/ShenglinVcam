//
//  SLCodeWord.m
//  声临 · 虚拟摄像头 —— 口令（#vcam）
//
//  ── 语义：打出来就生效，不用发送 ──
//
//  输入框里的内容一变成 #vcam，立刻：切球 + 把口令从输入框里清掉。
//  清掉是为了不让它赖在输入框里（以前发出去以后字还在，导致反复触发、消息也照发）。
//
//  ── 0.3.45：只读不写宿主 ──
//
//  0.3.42 ~ 0.3.44 为了「程序性写入也能看见」，hook 了 UITextView / UITextField
//  以及输入框实际类的 -setText:。这在抖音上是致命的：
//
//    · 抖音评论区的输入框是 UITextView 的子类，它自己没实现 setText:，
//      于是消息进的是我们挂在 UITextView 上的钩子；钩子按 [self class] 找原实现，
//      找到的是子类名 —— 表里没有 → 原实现根本没被调用，setText: 静默失效；
//    · 宿主的 setText: 被吞掉之后，它按「写进去的长度」继续算 range，
//      拿到的却还是旧内容 → NSRange 越界 / TextKit 状态错乱 → 闪退。
//
//  而这条钩子本来就是多余的：手打、粘贴都会发 TextDidChange 通知。
//  所以 0.3.45 把它整块删掉，口令只管「听」，一个字都不往宿主输入框里塞 ——
//  除非确认命中了口令，那时才清空（这是口令本身的语义）。
//
//  ── 实现 ──
//
//    1. 文本通知（UITextField/UITextView TextDidChange）：手打、粘贴都能收到。
//    2. 命中后清字做了三层兜底（text / attributedText / textStorage），
//       并在 0.3 秒后复查一次，宿主塞回来就再清一次。
//    3. 0.6 秒内不重复触发，防止清字引发的连锁通知把球来回翻。
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

/// 超过这个长度直接不看了。口令只有 5 个字符，长文本连归一化都不必做 ——
/// 抖音评论区每敲一个字都会走到这里，能省一点是一点。
static const NSUInteger kSLCodeWordMaxScan = 32;

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
    if (t.length > kSLCodeWordMaxScan) return nil;   // 太长，肯定不是口令
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
    NSString *n = SLVCodeWordNormalize(text);
    return n != nil && [n isEqualToString:SLVCodeWordText];
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

#pragma mark - 状态机：文本变化

/// 文本一变成口令就干活。手打、粘贴都走这里。
///
/// 只读宿主输入框：除了命中口令时清一次字，其余情况连 text 都只是看一眼就走。
static void SLVCodeWordHandleText(UIView *input) {
    if (sSLCodeWordBusy || !input) return;

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

        SLVLog(@"SL-VCAM: 口令监听已装（输入 %@ 即生效，无需发送 · 只读宿主文本，不挂钩子）",
              SLVCodeWordText);
    });
}
