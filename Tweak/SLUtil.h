//
//  SLUtil.h
//  声临 · 虚拟摄像头 —— 底包通用小工具
//
//  底包里所有「和业务无关的小事」都收在这里：沙盒路径、toast、顶层控制器、圆形裁图。
//  套用新插件时这个文件基本不用动。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// App 沙盒 Documents
NSString *SLDocumentsPath(void);

/// 本插件的专属目录（Documents/ShenglinVcam），不存在会建
NSString *SLStoreDir(void);

/// 专属目录下的某个文件名（不做存在性检查）
NSString *SLStorePath(NSString *name);

/// 轻提示（1.6s）
void SLToast(NSString *message);

/// 长一点的提示（2.4s）
void SLToastLong(NSString *message);

/// 当前最顶层的控制器（考虑 presentedViewController 链）
UIViewController *_Nullable SLTopViewController(void);

/// 屏幕矩形，origin 恒为 (0,0)。
/// 插件注入后所有「尺寸」都必须走这里，不要用 superview.bounds / self.view.bounds ——
/// SLKeyWindow() 挑的是 windowLevel 最高的窗口，那个窗口常常只是屏幕的一块局部区域
/// （QQRTCWindow、键盘窗、Alert 窗），拿它的 bounds 当屏幕会让扇缩水、面板变形。
CGRect SLScreenRect(void);

/// SLScreenRect().size
CGSize SLScreenSize(void);

/// 居中裁成正方形后再切圆角。用于自定义图标 / 素材封面。
UIImage *_Nullable SLRoundedImage(UIImage *_Nullable src, CGFloat side);

NS_ASSUME_NONNULL_END
