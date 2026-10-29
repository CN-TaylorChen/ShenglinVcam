//
//  SLCamInject.h
//  声临 · 虚拟摄像头 —— 注入层（业务插槽）
//
//  【底包留空】这里负责「把真实摄像头的帧换成 SLCamFeed 给的帧」。
//
//  推荐实现（底包没写）：
//    1. 目标进程里 hook -[AVCaptureVideoDataOutput setSampleBufferDelegate:queue:]，
//       记下 delegate 的类；对每个新出现的 delegate 类 swizzle
//       -captureOutput:didOutputSampleBuffer:fromConnection:；
//    2. swizzle 后的实现里：若 SLCamInjecting() 且有可用帧，
//       用 CMSampleBufferCreate + CMBlockBuffer（BGRA）把 SLCamFeed 的
//       CVPixelBuffer 包成新的 CMSampleBuffer，时间戳 / duration 抄原来的，
//       然后 %orig 传新 buffer；否则直接 %orig 原样放行；
//    3. 预览层（AVCaptureVideoPreviewLayer）走的是同一个 output，不必单独处理；
//    4. 想更稳就先只对指定 app 生效（SLTargetRegistry 已经在管这件事）。
//
//  注意：所有 hook 安装前都要校方法签名，签名不符就别装 —— 猜错就是崩。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 安装注入钩子。底包是空实现，重复调用安全。
void SLCamInstallHooks(void);

/// 现在是否处在「替换画面」状态（业务开 / 关时调，壳子据此切球色）
void SLCamSetInjecting(BOOL injecting);

/// 当前是否在替换
BOOL SLCamInjecting(void);

NS_ASSUME_NONNULL_END
