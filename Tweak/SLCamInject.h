//
//  SLVCamInject.h
//  声临 · 虚拟摄像头 —— 注入层
//
//  挂点选择说明（和底包最初注释里的建议不同，是有意为之）：
//    底包建议 swizzle delegate 的 -captureOutput:didOutputSampleBuffer:fromConnection:。
//    实际改成 hook 更底层的 -[AVCaptureOutput _processSampleBuffer:]：
//      · 它在 AVCaptureOutput 基类上，一次 hook 同时覆盖视频和音频两条流；
//      · delegate 类往往是宿主 App 私有的、每次启动可能不同，还得处理 delegate 被替换；
//        而 _processSampleBuffer: 是 AVFoundation 内部方法，装一次永久有效；
//      · 不写死 selector —— 沿继承链扫描名字里带 processSampleBuffer 的方法，
//        系统改了方法名也还能命中。
//
//  时间戳策略：假帧的 PTS / duration 直接抄真帧的。时间轴由设备时钟驱动，
//  帧率、音画同步天然正确，不需要自己算。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 安装注入钩子。重复调用安全。
void SLVCamInstallHooks(void);

/// 现在是否处在「替换画面」状态（业务开 / 关时调，壳子据此切球色）
void SLVCamSetInjecting(BOOL injecting);

/// 当前是否在替换
BOOL SLVCamInjecting(void);

/// 钩子是否已经装过（装过不代表命中，看 SLVCamHookCount）
BOOL SLVCamHooksInstalled(void);

/// 实际命中的方法个数（0 = 这台系统上没找到 _processSampleBuffer:）
int SLVCamHookCount(void);

/// 宿主的音频是否确实从 AVCapture 走（见过 AVCapture 的音频采样缓冲）。
/// AudioUnit 那条链路据此让路，避免两条链路同时消费同一个 PCM 池。
BOOL SLVCamAVCaptureAudioSeen(void);

NS_ASSUME_NONNULL_END
