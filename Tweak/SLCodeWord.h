//
//  SLCodeWord.h
//  声临 · 虚拟摄像头 —— 口令（#vcam）
//
//  宿主 App 里任意输入框（评论、私信、搜索都算）打出 #vcam，这行字会被当场吃掉，
//  悬浮球同时切到「隐藏 / 显示」的另一半。
//
//  为什么走通知而不是 hook 输入框类：抖音、陌陌各有一套自绘输入组件，
//  按类名 hook 既脆又漏；系统每次编辑后都会发 UITextFieldTextDidChange / UITextViewTextDidChange，
//  挂一次就全覆盖，也不碰宿主自己的编辑状态。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 口令原文（比较时忽略前后空白、全角半角、大小写）
extern NSString *const SLVCodeWordText;

/// 装上口令监听。进程内只装一次，重复调用无害。
void SLVStartCodeWordWatcher(void);

NS_ASSUME_NONNULL_END
