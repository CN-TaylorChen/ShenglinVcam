//
//  SLCamFeed.h
//  声临 · 虚拟摄像头 —— 帧源
//
//  职责只有一件：把「一个视频文件」变成「一帧帧符合宿主要求的画面 + 一段段 PCM」。
//  不碰 UI、不碰 hook，只管解码、循环、缩放、格式对齐。
//
//  调用顺序（注入层负责）：
//    第一次拿到真帧 → 把它的像素格式和尺寸喂给 copyFrameForPixelFormat:size:
//    → 本类据此重建解码管线 → 之后每帧都返回同格式的假画面。
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

@interface SLCamFeed : NSObject

+ (instancetype)shared;

/// 当前视频文件路径（nil = 没有素材，注入层应当原样放行真实摄像头）
@property (nonatomic, copy, nullable) NSString *sourcePath;

/// 播完回到第一帧（默认 YES）
@property (nonatomic, assign) BOOL loopEnabled;

/// 水平镜像（默认 NO）
@property (nonatomic, assign) BOOL mirrorEnabled;

/// 画面旋转角度，顺时针，只认 0 / 90 / 180 / 270（默认 0）。
/// 旋转后按「铺满目标框 + 居中裁切」缩放，不会把人脸拉扁。
@property (nonatomic, assign) NSInteger rotation;

/// 是否用素材音频替换麦克风（默认 YES）。
/// NO 时输出**静音**而不是放行真实麦克风 —— 虚拟摄像头场景下关声音就是要静音，
/// 放行麦克风会把环境声录进去。
@property (nonatomic, assign) BOOL audioReplaceEnabled;

/// 取下一帧（原始尺寸）。返回 +1 的 buffer，调用方负责 CFRelease；没有可用帧返回 NULL。
- (nullable CVPixelBufferRef)copyNextFrame CF_RETURNS_RETAINED;

/// 按宿主真实帧的像素格式和尺寸取一帧。返回 +1，调用方 CFRelease。
///
/// 第一次被调用（或宿主换了相机 / 分辨率导致格式变化）时会记下目标格式并重建
/// 解码管线，**这一帧返回 NULL**，注入层据此放行真帧。宁可漏一两帧真画面，
/// 也不要在采集线程上阻塞等解码 —— 那是黑屏和掉帧的根源。
- (nullable CVPixelBufferRef)copyFrameForPixelFormat:(OSType)pixelFormat
                                                size:(CGSize)size
    CF_RETURNS_RETAINED;

/// 按宿主音频格式取一段 PCM（素材音频不够长时尾部补静音）。
/// 没有音频轨、或还没解出数据时返回 nil，注入层放行真实麦克风。
- (nullable NSData *)audioForFormat:(const AudioStreamBasicDescription *)asbd
                           numBytes:(size_t)numBytes;

/// 只登记宿主音频格式，不取数据。
///
/// AudioQueue 那条链路（抖音拍摄）拿到格式的时刻远早于第一次回调，提前登记
/// 才能让解码线程把音轨挂上 —— 否则开头一两百毫秒只能出静音。
- (void)primeAudioFormat:(const AudioStreamBasicDescription *)asbd;

/// 回到第一帧（切换素材、重新打开相机时调）
- (void)rewind;

/// 视频原始分辨率；读不出来返回 CGSizeZero
- (CGSize)frameSize;

/// 素材可用：路径非空且文件存在
- (BOOL)isReady;

/// 解码管线已经按宿主格式跑起来了（至少出过一帧）
- (BOOL)isPipelineReady;

@end

NS_ASSUME_NONNULL_END
