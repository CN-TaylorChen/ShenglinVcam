//
//  SLVCamFeed.h
//  声临 · 虚拟摄像头 —— 帧源
//
//  职责只有一件：把「一个视频文件」变成「一帧帧符合宿主要求的画面 + 一段段 PCM」。
//  不碰 UI、不碰 hook，只管解码、循环、缩放、格式对齐。
//
//  调用顺序（注入层负责）：
//    第一次拿到真帧 → 把宿主那个 buffer 交给 copyFrameForHostBuffer:
//    → 本类据此重建解码管线，并把素材原地写进宿主的 buffer → 之后每帧都一样。
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

@interface SLVCamFeed : NSObject

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

/// 注入专用：把宿主**自己的**真帧 buffer 交进来，返回一帧可以直接交给宿主的画面。
///
/// 关键点是**不再自己造 buffer**。三轮日志已经证明：子类型、尺寸、行跨度全都一致，
/// 宿主那边照样是绿的 —— 差别只剩「buffer 是谁造的」。真帧是摄像头采集的 IOSurface，
/// 我们 `CVPixelBufferCreate` 出来的是另一种内存排布，宿主按自己的方式读就串了色。
///
/// 所以这里原地改写宿主给的这个 buffer：指针、格式、IOSurface 属性全是它熟悉的，
/// `CMVideoFormatDescriptionMatchesImageBuffer` 天然为真，自建 fmt 那套兜底用不上。
///
/// 返回 +1，调用方负责 CFRelease：
///   · 返回值 == host 的 retain 版 → 内容已改写，直接拿去打包
///   · 返回其它 buffer → 素材帧本身就是对的，零拷贝直出（视频不旋转不镜像走这条）
///   · NULL → 这一帧放行真画面
- (nullable CVPixelBufferRef)copyFrameForHostBuffer:(CVPixelBufferRef)host
    CF_RETURNS_RETAINED;

/// 拍照专用：按当前「旋转 / 镜像」设置摆好，但**不重建解码管线**地取一帧。
///
/// 为什么不能直接用 copyFrameForHostBuffer:：那个方法会记下目标格式并让
/// 解码线程按它重建管线。拍一张照片就把预览管线换掉，代价是紧接着的几帧预览
/// 取不到数据（返回 NULL → 放行真画面），画面上会闪一下真实摄像头。
///
/// size 传 CGSizeZero 表示按素材自身尺寸（旋转 90/270 时宽高互换），
/// 此时是 1:1 直出，不做铺满裁切，拍出来的就是素材原始分辨率。
- (nullable CVPixelBufferRef)copyOrientedFrameForPixelFormat:(OSType)pixelFormat
                                                        size:(CGSize)size
    CF_RETURNS_RETAINED;

/// 把当前素材帧画进**调用方给的** buffer，原地改写内容，不换指针、不改所有权。
///
/// 给 `-[AVCapturePhoto pixelBuffer]` 这类「buffer 归宿主所有、只能改内容」的场景用。
/// 返回自己 new 的 buffer 是不行的：调用方不会 CFRelease（每次拍照泄 8MB），
/// 而且尺寸/格式跟真照片对不上，宿主按 resolvedSettings 算出的宽高会跟 buffer 打架。
///
/// `extraRotation` 是「在用户设的旋转之外再补多少度」。拍照需要它：
/// 视频输出那条路拿到的是已经转过向的缓冲（1080x1920 竖屏），
/// 而 AVCapturePhoto 给的是传感器原始方向（3840x2160 横屏），两者差 90°。
/// 不补的话素材会被塞进一个转了 90° 的框里，拍出来就是歪的。
- (BOOL)renderIntoPixelBuffer:(CVPixelBufferRef)dst extraRotation:(NSInteger)extraRotation;

/// 按宿主音频格式取一段 PCM（素材音频不够长时尾部补静音）。
/// 没有音频轨、或还没解出数据时返回 nil，注入层放行真实麦克风。
- (nullable NSData *)audioForFormat:(const AudioStreamBasicDescription *)asbd
                           numBytes:(size_t)numBytes;

/// 只登记宿主音频格式，不取数据。
///
/// AudioQueue 那条链路（抖音拍摄）拿到格式的时刻远早于第一次回调，提前登记
/// 才能让解码线程把音轨挂上 —— 否则开头一两百毫秒只能出静音。
- (void)primeAudioFormat:(const AudioStreamBasicDescription *)asbd;

/// 实时音频线程专用：和 `audioForFormat:numBytes:` 一样，但**绝不阻塞**。
/// 拿不到锁、或格式还没登记，就立刻返回 nil（注入层据此放行真麦克风）。
/// 在宿主的音频回调里只能用它 —— 宁可漏一包，也不能把音频线程卡住。
- (nullable NSData *)tryAudioForFormat:(const AudioStreamBasicDescription *)asbd
                              numBytes:(size_t)numBytes;

/// 回到第一帧（切换素材、重新打开相机时调）
- (void)rewind;

/// 视频原始分辨率；读不出来返回 CGSizeZero
- (CGSize)frameSize;

/// 当前预览缓冲的尺寸 —— 宿主真正在用的那个（1080x1920 之类），不是素材的。
/// 拍照要拿它判断「预览是竖屏还是横屏」，从而决定补多少度。没有帧返回 CGSizeZero。
- (CGSize)latestFrameSize;

/// 素材可用：路径非空且文件存在
- (BOOL)isReady;

/// 解码管线已经按宿主格式跑起来了（至少出过一帧）
- (BOOL)isPipelineReady;

@end

NS_ASSUME_NONNULL_END
