//
//  SLCodeWord.h
//  声临 · 虚拟摄像头 —— 口令（#vcam）
//
//  在任意输入框里打出 #vcam 之后**点发送**，才会隐藏 / 显示悬浮球。
//  只打出来不发送，什么都不会发生（也不会动输入框里的字）。
//
//  球被隐藏后主界面就没有入口了（设置页是从球点进去的），所以这条口令
//  同时也是唯一的回程票：再发一次就回来。
//

#import <Foundation/Foundation.h>

/// 口令原文（归一化后比较：去首尾空白、全角转半角、忽略大小写）
extern NSString *const SLVCodeWordText;

/// 装上口令监听。只装一次，重复调无副作用。
void SLVStartCodeWordWatcher(void);
