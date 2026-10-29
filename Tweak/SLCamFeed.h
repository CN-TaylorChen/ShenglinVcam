//
//  SLCamFeed.h
//  声临 · 虚拟摄像头 —— 帧源（业务插槽）
//
//  【底包留空】这里是「视频文件 → 一帧一帧的 CVPixelBuffer」。
//  骨架只保存路径、返回 NULL，编译通、逻辑不通 —— 填完这个类，
//  剩下的交给 SLCamInject 就能看到画面被替换。
//
//  推荐实现（约 120 行，底包没写）：
//    1. AVURLAsset + AVAssetReader，track 取 AVMediaTypeVideo；
//    2. AVAssetReaderTrackOutput 的 outputSettings 用
//       @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) }；
//    3. copyNextFrame 返回 copyNextSampleBuffer 里的 imageBuffer；
//    4. 读完（nil）就 seek 回 0 重新 startReading，做到「循环播放」；
//    5. 帧率对齐：胶囊按 30fps 取，视频是 24fps 就重复上一帧，别让时间戳乱跳。
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface SLCamFeed : NSObject

+ (instancetype)shared;

/// 当前视频文件路径（nil = 没有素材，注入层应当原样放行真实摄像头）
@property (nonatomic, copy, nullable) NSString *sourcePath;

/// 取下一帧。返回的 buffer 已 retain，调用方负责 CFRelease；没有可用帧返回 NULL。
- (nullable CVPixelBufferRef)copyNextFrame CF_RETURNS_RETAINED;

/// 回到第一帧（切换素材、重新打开相机时调）
- (void)rewind;

/// 视频原始分辨率；读不出来返回 CGSizeZero
- (CGSize)frameSize;

/// 已就绪：文件存在且能读出 track
- (BOOL)isReady;

@end

NS_ASSUME_NONNULL_END
