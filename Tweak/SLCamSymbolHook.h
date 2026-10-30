//
//  SLVCamSymbolHook.h
//  声临 · 虚拟摄像头 —— C 函数 hook
//
//  为什么自己写：自签注入的环境里没有 CydiaSubstrate，MSHookFunction 用不了；
//  而麦克风这条链路的入口（AudioUnitRender / AudioQueueNewInput）全是 C 函数，
//  靠 method_setImplementation 够不着。
//
//  原理和 fishhook 一样：App 调外部函数时，先走自己的 stub，再从
//  __la_symbol_ptr / __got 里取真实地址。dyld 完成 fixup 之后那一格里就是
//  真实地址，把它换成我们的实现就完成了重定向。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 把某个外部 C 函数的调用重定向到 replacement。
///
/// @param name        符号名，**不带**前导下划线，例如 "AudioUnitRender"
/// @param replacement 我们的实现，签名必须与原函数 ABI 完全一致
/// @param original    传出原函数地址；替换前就已写好，不会出现「已接管但拿不到原函数」的窗口
/// @return 命中的指针槽数（0 = 没找到，通常说明该符号不是经指针表调用，或镜像还没加载）
int SLVSymbolHook(const char *name, void *replacement, void * _Nullable * _Nullable original);

/// 重新扫一遍所有已加载镜像。App 内嵌的 SDK（比如 RTC 那套）往往是懒加载的，
/// 首次扫描时还不存在，需要在「会话开始加输出」这类时机补扫。
int SLVSymbolHookRescan(void);

/// 挂上 dyld 的「镜像加载」回调：之后再有 framework 被 dlopen，自动补扫一次。
/// 补扫在后台串行队列里做，不在 dyld 回调里做（那里还持着锁）。
void SLVSymbolHookInstallAutoRescan(void);

NS_ASSUME_NONNULL_END
