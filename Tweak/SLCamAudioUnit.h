//
//  SLVCamAudioUnit.h
//  声临 · 虚拟摄像头 —— 麦克风的第二条链路
//
//  背景（真机日志得出的结论）：
//    陌陌的采集会话里有 AVCaptureAudioDataOutput，音频走 AVCapture，
//    挂 _handleSampleBufferEventForSampleBuffer: 就能换掉。
//    但 QQ 的会话里只有 VideoDataOutput / StillImageOutput / MetadataOutput，
//    **根本没有 AudioDataOutput** —— 它的麦克风走自己的 AudioUnit，
//    AVCapture 那条链路永远收不到音频。
//
//  所以这里补一条 AudioUnitRender 的 C 函数 hook：
//    · 只处理「输入元素（bus 1）」且该单元确实开了麦克风输入的调用；
//    · 一旦发现宿主的音频已经在走 AVCapture（AVCaptureAudioSeen），立刻让路，
//      否则两条链路同时从同一个 PCM 池取数据，声音会被撕成两半。
//
//  第三条链路（0.2.8）：抖音拍短视频既不走 AVCapture 也不走 AudioUnitRender，
//  而是 AudioQueueNewInput + 回调。这里同时接管 AudioQueueNewInput，把宿主的
//  回调换成「先覆盖 buffer 再转交」的包装。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 安装 / 补装 AudioUnit 链路。重复调用安全：
/// 首次注册符号并全量扫描，之后每次调用只做补扫（后加载的 SDK 也能覆盖到）。
void SLVCamInstallAudioUnitHook(void);

/// 这条链路是否真的接管成功（找到 AudioUnitRender 的符号槽）
BOOL SLVCamAudioUnitHooked(void);

NS_ASSUME_NONNULL_END
