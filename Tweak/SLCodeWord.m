//
//  SLCodeWord.m
//  声临 · 虚拟摄像头 —— 口令（#vcam）
//
//  输入框里打「#vcam」→ 清掉这行字 → 悬浮球隐藏 / 显示。
//  球被隐藏后主界面就再没有入口了（设置页是从球点进去的），所以这条口令
//  同时也是唯一的回程票：再打一次就回来。
//

#import "SLCodeWord.h"
#import "SLFloatingBall.h"
#import "SLUtil.h"
#import "SLLog.h"

#import <UIKit/UIKit.h>

NSString *const SLVCodeWordText = @"#vcam";

// 清空输入框会再触发一次编辑通知，挡掉重入（否则一次输入会连开两遍开关）
static BOOL sSLCodeWordBusy = NO;

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

static void SLVCodeWordToggle(void) {
    BOOL hide = !SLVFloatBallHidden();
    SLVSetFloatBallHidden(hide);
    SLVToast(hide ? @"悬浮球已关闭 · 再打一次 #vcam 打开" : @"悬浮球已打开");
    SLVLog(@"SL-VCAM: 口令 %@ → 悬浮球%@", SLVCodeWordText, hide ? @"隐藏" : @"显示");
}

static void SLVCodeWordHandleInput(UIView *input) {
    if (sSLCodeWordBusy || !input) return;

    NSString *raw = SLVCodeWordTextOf(input);
    if (raw.length == 0) return;

    // 要求「整行就是口令」，不是「包含口令」——
    // 用户正常评论里写到 #vcam 时不该把球弄没了。
    if (![SLVCodeWordNormalize(raw) isEqualToString:SLVCodeWordText]) return;

    sSLCodeWordBusy = YES;
    SLVCodeWordClearInput(input);
    sSLCodeWordBusy = NO;

    SLVCodeWordToggle();
}

void SLVStartCodeWordWatcher(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

        [nc addObserverForName:UITextFieldTextDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n) {
            id obj = n.object;
            if ([obj isKindOfClass:[UITextField class]]) SLVCodeWordHandleInput(obj);
        }];

        [nc addObserverForName:UITextViewTextDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n) {
            id obj = n.object;
            if ([obj isKindOfClass:[UITextView class]]) SLVCodeWordHandleInput(obj);
        }];

        SLVLog(@"SL-VCAM: 口令监听已装（%@）", SLVCodeWordText);
    });
}
