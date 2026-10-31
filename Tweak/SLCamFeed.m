//
//  SLVCamFeed.m
//  声临 · 虚拟摄像头 —— 帧源实现
//
//  并发模型（重要）：
//    · 解码跑在独立 NSThread 上，长循环不占任何 dispatch queue
//    · _lock 只保护「跨线程共享的状态」：最新帧、音频池、目标格式
//    · AVAssetReader 及其 output 由解码线程独占，别处不碰
//

#import "SLCamFeed.h"
#import "SLUtil.h"
#import "SLLog.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <Accelerate/Accelerate.h>
#import <unistd.h>

#pragma mark - 渲染到 YUV 的正确姿势（0.3.5）

// 背景：宿主要的是 420f / 420v 双平面（NV12），而 CoreImage 的默认 CIContext 是
// Metal 的 —— 往这种双平面 buffer 上 render，**亮度平面写对了、色度平面写错了**。
// 症状是白底 + 亮绿的人形轮廓（色度里混进了亮度信息），只在「必须过 CoreImage」
// 的两条路上出现：图片素材、以及开了旋转 / 镜像的视频。
//
// 视频不旋转不镜像时走解码器直出（AVAssetReaderTrackOutput 直接吐 420f），
// 压根不碰 CoreImage，所以一直是正常的 —— 这也是「视频好、图片绿」的原因。
//
// 修法分两条，最后都收敛到同一段「BGRA → vImage 转 NV12」：
//   · 图片：一辈子只渲染一次，本来可以直接换 CPU 渲染；但既然视频那条路已经写好了，
//     就统一走 BGRA + vImage，少一条路径少一个坑
//   · 视频每帧：CPU 渲染扛不住 30fps，而 CI 对 BGRA 100% 可靠，转 YUV 交给 Accelerate
//     （平面偏移 / stride / 色彩矩阵全由它算，不用自己搬字节）

/// 把 BGRA 的内容搬进**已经存在**的 NV12 buffer 的两个平面。
/// dst 必须是 420v / 420f，宽高是偶数。dst 比 src 小的话只取左上角那块。
static BOOL SLVBlitBGRAtoNV12(CVPixelBufferRef src, CVPixelBufferRef dst) {
    if (!src || !dst) return NO;

    OSType df = CVPixelBufferGetPixelFormatType(dst);
    BOOL full = (df == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
    if (!full && df != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) return NO;

    size_t w = CVPixelBufferGetWidth(dst);
    size_t h = CVPixelBufferGetHeight(dst);
    // 420 是 2x2 下采样，宽高必须偶数；奇数会少一行 / 一列，边缘出现斜纹
    w &= ~(size_t)1;
    h &= ~(size_t)1;
    if (w < 2 || h < 2) return NO;
    if (CVPixelBufferGetWidth(src) < w || CVPixelBufferGetHeight(src) < h) return NO;

    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dst, 0);

    BOOL ok = YES;
    void *yBase = CVPixelBufferGetBaseAddressOfPlane(dst, 0);
    void *uvBase = CVPixelBufferGetBaseAddressOfPlane(dst, 1);
    void *sBase = CVPixelBufferGetBaseAddress(src);
    if (!yBase || !uvBase || !sBase) ok = NO;

    if (ok) {
        vImage_Buffer s = { .data = sBase,
                            .height = (vImagePixelCount)h,
                            .width  = (vImagePixelCount)w,
                            .rowBytes = CVPixelBufferGetBytesPerRow(src) };
        vImage_Buffer y = { .data = yBase,
                            .height = (vImagePixelCount)h,
                            .width  = (vImagePixelCount)w,
                            .rowBytes = CVPixelBufferGetBytesPerRowOfPlane(dst, 0) };
        // 色度平面只有一半宽高；一个 CbCr 交织像素 = 2 字节，所以 rowBytes 天然是 w
        vImage_Buffer uv = { .data = uvBase,
                             .height = (vImagePixelCount)(h / 2),
                             .width  = (vImagePixelCount)(w / 2),
                             .rowBytes = CVPixelBufferGetBytesPerRowOfPlane(dst, 1) };

        // 数字视频（16-235）还是全范围（0-255），跟宿主声明的格式一致，
        // 不然暗部会发灰、高光会过曝。
        vImage_YpCbCrPixelRange range = full
            ? (vImage_YpCbCrPixelRange){ 0, 128, 255, 255, 255, 0, 255, 0 }
            : (vImage_YpCbCrPixelRange){ 16, 128, 235, 240, 235, 16, 240, 16 };

        vImage_ARGBToYpCbCr info;
        // 苹果相机管线一律 BT.709；BGRA 在小端机上的内存布局就是 B,G,R,A，
        // 正好对上 kvImageARGB8888。
        // 注意 range 是在 GenerateConversion 里用掉的，转换函数本身不吃它 ——
        // 第 5 个参数是 permuteMap（通道重排表），不重排就是 0,1,2,3。
        const uint8_t permute[4] = { 0, 1, 2, 3 };
        if (vImageConvert_ARGBToYpCbCr_GenerateConversion(
                kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2, &range,
                &info, kvImageARGB8888, kvImage420Yp8_CbCr8, kvImageNoFlags) != kvImageNoError) {
            ok = NO;
        } else if (vImageConvert_ARGB8888To420Yp8_CbCr8(
                       &s, &y, &uv, &info, permute, kvImageNoFlags) != kvImageNoError) {
            ok = NO;
        }
    }

    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    return ok;
}

/// 给自建的 BGRA 帧补上色彩附件。
///
/// 日志里能直接看出差别：解码器给的视频帧带 9 项扩展，我们自建的图片帧只有 2 项
/// （Version、CVBytesPerRow）。
///
/// 注意这里**不设 YCbCrMatrix** —— BGRA 是 RGB 格式，没有 YUV 平面，
/// 给它标一个 BT.709 的 YCbCr 矩阵在语义上是错的，下游万一照这个做 RGB→YUV
/// 的反向换算，颜色就全歪了。RGB 帧只需要 primaries + transfer function。
static void SLVTagBGRAFrame(CVPixelBufferRef pb) {
    if (!pb) return;
    NSDictionary *atts = @{
        (id)kCVImageBufferColorPrimariesKey: (id)kCVImageBufferColorPrimaries_ITU_R_709_2,
        // sRGB 的伽马，不是 BT.709 的视频伽马（那个约 1.9，会把对比度压扁）
        (id)kCVImageBufferTransferFunctionKey: CFSTR("IEC_sRGB"),
    };
    CVBufferSetAttachments(pb, (__bridge CFDictionaryRef)atts, kCVAttachmentMode_ShouldPropagate);
}

/// 把一帧中心像素的 BGRA 打出来。
///
/// 这是为了分清「我们渲错了」和「宿主解释错了」：
///   · 中心像素是正常的白 / 正常颜色 → 帧本身没问题，绿是下游解释出来的
///   · 中心像素就已经是绿的值（G 高、R/B 低）→ CI 渲染这一步就错了
static void SLVLogCenterPixel(CVPixelBufferRef pb, NSString *tag) {
    if (!pb) return;
    OSType pf = CVPixelBufferGetPixelFormatType(pb);
    size_t w = CVPixelBufferGetWidth(pb);
    size_t h = CVPixelBufferGetHeight(pb);
    if (pf != kCVPixelFormatType_32BGRA || w < 2 || h < 2) {
        SLVLog(@"%@ 中心像素跳过（pf=%u %zux%zu）", tag, (unsigned)pf, w, h);
        return;
    }
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
    size_t rb = CVPixelBufferGetBytesPerRow(pb);
    if (base) {
        uint8_t *p = base + (h / 2) * rb + (w / 2) * 4;
        SLVLog(@"%@ 中心像素 B=%u G=%u R=%u A=%u（%zux%zu）",
               tag, p[0], p[1], p[2], p[3], w, h);
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
}

/// 把一张 BGRA 的 CVPixelBuffer 转成新建的 420v / 420f 双平面。
/// 失败返回 NULL。目标格式不是 NV12 时也返回 NULL。
static CVPixelBufferRef SLVConvertBGRAtoNV12(CVPixelBufferRef src, OSType dstFmt) {
    if (!src) return NULL;
    if (dstFmt != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
        dstFmt != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) return NULL;

    size_t w = CVPixelBufferGetWidth(src) & ~(size_t)1;
    size_t h = CVPixelBufferGetHeight(src) & ~(size_t)1;
    if (w < 2 || h < 2) return NULL;

    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey : @{} };
    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, dstFmt,
                            (__bridge CFDictionaryRef)attrs, &dst) != kCVReturnSuccess) return NULL;

    if (!SLVBlitBGRAtoNV12(src, dst)) {
        CVPixelBufferRelease(dst);
        return NULL;
    }
    return dst;
}

// 音频水位（单位：秒）。
//
// 音频消费是硬实时的：AudioUnitRender 每 20ms 就要 320 帧（16k 单声道 = 1280 字节），
// 一秒 64000 字节，一字节都不能少、也不能晚。而生产端是解码线程，速度取决于
// 解码耗时和视频帧率 —— 两者不可能天然相等。
//
// 不钉水位就会漂：
//   · 生产快于消费 → 缓冲一路涨（以前上限是 2 秒）→ 声音越来越滞后 = 不同步
//   · 生产慢于消费 → 缓冲抽干 → 补零 → 声音断续
//
// 所以生产端补到 HIGH 就停手，消费端只在「明显出事」时才丢 —— 两者必须贴得很近。
// 0.2.8 的教训：HIGH 设成 0.35s 而 TARGET 只有 0.10s，于是解码线程每次都把
// 缓冲填到 350ms，消费端下一次回调就一口气砍掉 250ms，稳态下每 270ms 只播
// 20ms，听感就是「没声音」。水位控制的前提是生产端不许越过目标太多。
//
// 0.2.9 的教训：光把阈值压低还不够，**任何在稳态下会成立的丢包条件都不行**。
// 那次加了一条「超过 target + 4 包就以 2× 速度追」，结果稳态水位本来就长期
// 停在 target 之上（生产端按 HIGH 补），这条分支每次回调都成立，每 20ms 丢一包
// 20ms，内容以 2 倍速前进 —— 听感就是「声音加速」。
// 所以现在只剩一条硬切：0.6 秒。它离稳态水位有 5 倍余量，正常永远够不着，
// 只有切素材、重建管线这种真卡顿才会踩到。
//
//   生产端高水位 120ms  —— 稳态水位就在这附近，A/V 延迟也靠它压住
//   消费端只在超过 600ms 时一刀砍回 100ms，其余情况一律不丢
#define SLV_AUDIO_TARGET_SEC 0.10
#define SLV_AUDIO_HIGH_SEC   0.12
#define SLV_AUDIO_HARD_SEC   0.60

@interface SLVCamFeed () {
    NSLock *_lock;

    // ---- 跨线程共享（受 _lock 保护）----
    CVPixelBufferRef _latestVideo;
    NSString *_pipelineKey;              // "875704422:1920x1080"，变了就要重建 reader
    BOOL _reconfigRequested;
    NSMutableData *_audioPCM;
    NSUInteger _audioReadCursor;
    AudioStreamBasicDescription _audioDstASBD;
    BOOL _hasAudioDstASBD;
    AVAudioConverter *_audioConverter;
    NSUInteger _audioBytesPerSecond;
    BOOL _assetHasAudio;                 // 素材本身有没有音轨：决定「没数据」时是静音还是放行真麦克风
    NSUInteger _audioDropped;            // 累计丢弃字节（诊断用）
    BOOL _audioDropLogged;
    BOOL _audioPassLogged;               // 「放行真麦克风」只打一次，诊断用
    NSUInteger _audioCalls;              // 消费端被调用次数（水位心跳用）
    CGSize _naturalSize;

    // ---- 解码线程独占 ----
    AVAssetReader *_reader;
    AVAssetReaderTrackOutput *_videoOut;
    AVAssetReaderTrackOutput *_audioOut;
    AudioStreamBasicDescription _audioSrcASBD;
    double _frameInterval;               // 秒/帧，按素材自身帧率算，用来给解码线程节流
    int _idleRounds;                     // 连续空转次数，用来区分「读完了」和「音频池满了」

    CIContext *_ciContext;
    NSUInteger _generation;
    BOOL _running;

    // ---- 图片素材（0.2.20）----
    // 图片没有「下一帧」，解一次就够。解完塞进 _latestVideo，
    // 下游三条出图路径（预览 / 拍照 / 抖音 pixelBuffer）读的都是它，一行都不用改。
    BOOL _isImage;
    BOOL _stillLoaded;
    NSString *_stillKey;                 // 这张静态图是按哪个 "格式:宽x高" 渲染的
}

- (void)sl_restart;
+ (BOOL)sl_isImagePath:(NSString *)p;
- (void)sl_loadStillImage;
- (void)sl_decodeLoopWithGeneration:(NSUInteger)gen;
- (void)sl_buildReaderForKey:(NSString *)key;
- (BOOL)sl_pumpAudio;
- (BOOL)sl_audioBelowHighWater;
- (NSData *)sl_audioLocked:(const AudioStreamBasicDescription *)asbd numBytes:(size_t)numBytes configure:(BOOL)configure;
- (NSData *)sl_convertAudio:(NSData *)input;
- (NSInteger)sl_normalizedRotation;
- (nullable CIImage *)sl_image:(CIImage *)img
                       toWidth:(size_t)w
                        height:(size_t)h
                        mirror:(BOOL)mirror
                      rotation:(NSInteger)rotation;
- (CVPixelBufferRef)sl_render:(CVPixelBufferRef)src
                      toWidth:(size_t)w
                       height:(size_t)h
                       format:(OSType)pf
                       mirror:(BOOL)mirror
                     rotation:(NSInteger)rotation CF_RETURNS_RETAINED;

@end

@implementation SLVCamFeed

+ (instancetype)shared {
    static SLVCamFeed *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[SLVCamFeed alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSLock new];
        _audioPCM = [NSMutableData data];
        // 0.3.6：整个 CIContext 改成 CPU 渲染。
        //
        // 日志证明宿主抖音要的是 BGRA（pf=1111970369），所以绿屏跟 YUV 无关 ——
        // 问题出在「Metal 版 CIContext 渲染进我们自己造的 CVPixelBuffer」这一步。
        // 视频帧是解码器分配的（自带 Metal 兼容 + 完整色彩附件）一直正常，
        // 图片帧和镜像帧是我们自己建 buffer 再渲，就绿了。
        //
        // 图片只渲一次、镜像/拍照是低频，CPU 渲染慢几十毫秒完全能接受，
        // 但它是软件直接写内存，不依赖 Metal 兼容性，结果一定对。
        // 不旋转不镜像的视频走解码器直出，压根不经过这里，性能不受影响。
        _ciContext = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer : @YES }];
        _loopEnabled = YES;
        _mirrorEnabled = NO;
        _rotation = 0;
        _audioReplaceEnabled = YES;
    }
    return self;
}

#pragma mark - 对外属性

- (void)setSourcePath:(NSString *)sourcePath {
    NSString *p = [sourcePath copy];
    [_lock lock];
    _sourcePath = p;
    _naturalSize = CGSizeZero;
    _isImage = [SLVCamFeed sl_isImagePath:p];
    _stillLoaded = NO;
    [_lock unlock];
    [self sl_restart];
    SLVLog(@"feed source -> %@%@", p.lastPathComponent ?: @"(nil)",
          [SLVCamFeed sl_isImagePath:p] ? @"（图片）" : @"");
}

/// 按扩展名判断是不是图片素材
+ (BOOL)sl_isImagePath:(NSString *)p {
    if (!p.length) return NO;
    NSString *e = p.pathExtension.lowercaseString;
    return [@[@"png", @"jpg", @"jpeg", @"heic", @"heif", @"webp", @"bmp", @"tif", @"tiff"]
            containsObject:e];
}

- (CGSize)frameSize {
    [_lock lock];
    CGSize s = _naturalSize;
    [_lock unlock];
    return s;
}

- (BOOL)isReady {
    [_lock lock];
    NSString *p = _sourcePath;
    [_lock unlock];
    return p.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:p];
}

- (BOOL)isPipelineReady {
    [_lock lock];
    BOOL r = (_latestVideo != NULL);
    [_lock unlock];
    return r;
}

#pragma mark - 重启解码

- (void)sl_restart {
    NSUInteger gen;
    [_lock lock];
    gen = ++_generation;
    _reconfigRequested = YES;
    _pipelineKey = nil;
    _stillLoaded = NO;
    _stillKey = nil;
    if (_latestVideo) { CVPixelBufferRelease(_latestVideo); _latestVideo = NULL; }
    [_audioPCM setLength:0];
    _audioReadCursor = 0;
    _running = (_sourcePath.length > 0);
    BOOL run = _running;
    [_lock unlock];

    if (run) {
        [NSThread detachNewThreadWithBlock:^{
            [self sl_decodeLoopWithGeneration:gen];
        }];
    }
}

- (void)rewind {
    [self sl_restart];
}

#pragma mark - 图片素材

// 把一张图片变成一帧 CVPixelBuffer，塞进 _latestVideo。
//
// 只做一次。之后所有出图路径（预览的 copyFrameForPixelFormat:、拍照的
// copyOrientedFrameForPixelFormat:、抖音的 renderIntoPixelBuffer:）读的都是
// 这同一个 buffer，缩放 / 旋转 / 镜像全由它们原有的逻辑处理，这里不用重复实现。
- (void)sl_loadStillImage {
    NSString *path = nil;
    NSString *key = nil;
    NSUInteger gen = 0;
    [_lock lock];
    path = _sourcePath;
    key = _pipelineKey;
    gen = _generation;
    [_lock unlock];
    if (!path.length) return;

    CIImage *img = [CIImage imageWithContentsOfURL:[NSURL fileURLWithPath:path] options:nil];
    if (!img) {
        SLVLog(@"feed 图片解码失败 %@", path.lastPathComponent);
        return;
    }

    // 竖着拍的照片像素本身是躺的，靠 EXIF 方向摆正。
    // 不套这一下，选一张手机拍的竖图进去，画面会横过来。
    NSNumber *ori = nil;
    @try {
        ori = img.properties[(NSString *)kCGImagePropertyOrientation];
    } @catch (NSException *e) { }
    NSInteger o = ori.integerValue;
    if (o >= 2 && o <= 8) img = [img imageByApplyingOrientation:(int)o];

    CGRect ext = img.extent;
    if (ext.size.width < 1 || ext.size.height < 1) return;

    // 目标尺寸：宿主已经告诉我们格式就按它来（这样 copyFrameForPixelFormat:
    // 能走零转换直出），还没告诉就按原图（长边封顶 2048）。
    OSType pf = kCVPixelFormatType_32BGRA;
    size_t w = 0, h = 0;
    if (key.length) {
        NSArray<NSString *> *parts = [key componentsSeparatedByString:@":"];
        if (parts.count == 2) {
            OSType kpf = (OSType)(uint32_t)[parts[0] intValue];
            NSArray<NSString *> *wh = [parts[1] componentsSeparatedByString:@"x"];
            if (wh.count == 2 && kpf) {
                pf = kpf;
                w = (size_t)[wh[0] integerValue];
                h = (size_t)[wh[1] integerValue];
            }
        }
    }
    if (w < 1 || h < 1) {
        CGFloat cap = 2048.0;
        CGFloat scale = MIN(1.0, cap / MAX(ext.size.width, ext.size.height));
        w = (size_t)lround(ext.size.width * scale);
        h = (size_t)lround(ext.size.height * scale);
    }
    if (w < 1 || h < 1) return;

    // 缩放交给公共那套「铺满 + 居中裁切」，跟视频走完全一样的数学；
    // 旋转 / 镜像**不在这里做** —— 那是每帧按设置实时变的，由下游负责。
    CIImage *scaled = [self sl_image:img toWidth:w height:h mirror:NO rotation:0];
    if (!scaled) return;

    // 0.3.6：用 CPU 渲染，并给帧补上色彩附件。
    //
    // 日志（12:10:34）证明宿主抖音要的是 **BGRA**（pf=1111970369），不是 420f ——
    // 所以 0.3.5 那条 vImage 转换对图片路径根本没执行，绿屏跟 YUV 毫无关系。
    //
    // 真正可疑的是「Metal 版 CIContext 渲染进我们自己 CVPixelBufferCreate 的 buffer」。
    // 视频帧是解码器分配的，自带 Metal 兼容 + 完整色彩附件，一直正常；
    // 图片帧是我们造的（只有 IOSurfaceProperties），渲出来就不对。
    // 图片只渲一次，直接走 CPU 最稳，顺便把色彩附件补齐。
    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey : @{} };
    CVPixelBufferRef bgra = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &bgra) != kCVReturnSuccess) {
        return;
    }

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    [_ciContext render:scaled toCVPixelBuffer:bgra
                       bounds:CGRectMake(0, 0, (CGFloat)w, (CGFloat)h) colorSpace:cs];
    CGColorSpaceRelease(cs);
    SLVTagBGRAFrame(bgra);
    SLVLogCenterPixel(bgra, @"feed 图片渲染");

    CVPixelBufferRef pb = NULL;
    if (pf == kCVPixelFormatType_32BGRA) {
        pb = bgra;                       // 宿主本来就要 BGRA，不用转
    } else {
        pb = SLVConvertBGRAtoNV12(bgra, pf);
        CVPixelBufferRelease(bgra);
        if (!pb) {
            // 既不是 BGRA 也不是 NV12（422 / 10bit 这类）。这种格式极少见，
            // 退回老路径让 CI 直接渲染 —— 可能仍然偏色，但至少不是黑屏。
            if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, pf,
                                    (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess) return;
            CGColorSpaceRef cs2 = CGColorSpaceCreateDeviceRGB();
            [_ciContext render:scaled toCVPixelBuffer:pb
                               bounds:CGRectMake(0, 0, (CGFloat)w, (CGFloat)h) colorSpace:cs2];
            CGColorSpaceRelease(cs2);
        }
    }
    SLVLogCenterPixel(pb, @"feed 图片出帧");

    BOOL stale = NO;
    [_lock lock];
    if (gen != _generation) {
        stale = YES;
    } else {
        CVPixelBufferRef old = _latestVideo;
        _latestVideo = pb;
        _stillLoaded = YES;
        _stillKey = [key copy];
        _naturalSize = CGSizeMake((CGFloat)w, (CGFloat)h);
        if (old) CVPixelBufferRelease(old);
    }
    [_lock unlock];

    if (stale) { CVPixelBufferRelease(pb); return; }
    SLVLog(@"feed 管线就绪 图片 %zux%zu（原始 %.0fx%.0f）",
          w, h, ext.size.width, ext.size.height);
}

#pragma mark - 解码线程

- (void)sl_decodeLoopWithGeneration:(NSUInteger)gen {
    @autoreleasepool {
        [NSThread currentThread].name = @"slcam.decode";
        [NSThread currentThread].qualityOfService = NSQualityOfServiceUserInitiated;
    }

    while (YES) {
        @autoreleasepool {
            [_lock lock];
            BOOL alive = (gen == _generation) && _running;
            BOOL reconfig = _reconfigRequested;
            _reconfigRequested = NO;
            NSString *key = _pipelineKey;
            BOOL loop = _loopEnabled;
            BOOL isImage = _isImage;
            [_lock unlock];
            if (!alive) break;

            // ---- 图片素材：解一次就够，之后一直挂着同一帧 ----
            // 不建 reader（图片没有视频轨，建了也是空的），也不节流到帧率 ——
            // 直接睡到下一轮，等 generation 变了自然退出。
            if (isImage) {
                NSString *skey;
                BOOL loaded;
                [_lock lock];
                loaded = _stillLoaded;
                skey = _stillKey;
                [_lock unlock];
                // 宿主换了分辨率 / 像素格式 → 这张图得按新目标重渲一次，
                // 否则 copyFrameForPixelFormat: 每帧都要现场做一次 CI 缩放，
                // 30fps 下等于白烧一整个核。
                BOOL same = (skey == nil && key == nil) || [skey isEqualToString:key];
                if (!loaded || !same) [self sl_loadStillImage];
                usleep(200 * 1000);
                continue;
            }

            if (reconfig || !_reader) {
                [self sl_buildReaderForKey:key];
                if (!_reader) { usleep(30 * 1000); continue; }
            }

            BOOL gotAny = NO;
            BOOL videoEnded = NO;

            if (_videoOut) {
                CMSampleBufferRef sb = [_videoOut copyNextSampleBuffer];
                if (sb) {
                    gotAny = YES;
                    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
                    if (pb) {
                        CVPixelBufferRetain(pb);
                        [_lock lock];
                        CVPixelBufferRef old = _latestVideo;
                        _latestVideo = pb;
                        [_lock unlock];
                        if (old) CVPixelBufferRelease(old);
                    }
                    CFRelease(sb);
                    // 按素材自身帧率节流：不节流会全速解码，画面变成快进
                    if (_frameInterval > 0) {
                        usleep((useconds_t)(_frameInterval * 1000000.0));
                    }
                } else {
                    videoEnded = YES;
                }
            }

            // 一个视频帧周期里音频往往不止需要一包（一包 AAC 通常只有 23ms，
            // 而 30fps 一帧是 33ms），以前「一帧只补一包」会让缓冲长期处于抽干状态。
            // 现在按水位补，最多补 8 包，避免一次把解码线程卡太久。
            if (_audioOut) {
                for (int i = 0; i < 8; i++) {
                    if (![self sl_pumpAudio]) break;
                    gotAny = YES;
                    if (![self sl_audioBelowHighWater]) break;
                }
            }

            // 视频读完了就算「这一轮结束」，哪怕音轨还有剩。
            // 以前只看 gotAny，音轨比视频长一点点时画面会永远停在最后一帧 ——
            // 从外面看就是「卡死」，而且是随素材概率出现的。
            if (gotAny && !videoEnded) {
                _idleRounds = 0;
            } else {
                // 连续空转才认为是真读完了；音频池满也会空转，别把那种当结尾
                _idleRounds++;
                if (_idleRounds < 3) {
                    usleep(15 * 1000);
                    continue;
                }
                _idleRounds = 0;
                if (loop) {
                    // 一轮播完 —— 重建 reader 实现循环播放
                    [self sl_buildReaderForKey:key];
                    if (!_reader) usleep(50 * 1000);
                } else {
                    usleep(120 * 1000);
                }
            }
        }
    }
}

/// 缓冲还没到高水位，可以继续补
- (BOOL)sl_audioBelowHighWater {
    [_lock lock];
    NSUInteger buffered = _audioPCM.length - _audioReadCursor;
    NSUInteger rate = _audioBytesPerSecond;
    [_lock unlock];
    if (rate == 0) return YES;      // 目标格式还没确定，先别停
    return buffered < (NSUInteger)(rate * SLV_AUDIO_HIGH_SEC);
}

/// 解码线程内调用：音频池没到高水位才继续解
- (BOOL)sl_pumpAudio {
    [_lock lock];
    NSUInteger buffered = _audioPCM.length - _audioReadCursor;
    NSUInteger limit = (NSUInteger)(_audioBytesPerSecond * SLV_AUDIO_HIGH_SEC);
    [_lock unlock];
    if (limit && buffered >= limit) return NO;

    CMSampleBufferRef sb = [_audioOut copyNextSampleBuffer];
    if (!sb) return NO;

    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    size_t len = bb ? CMBlockBufferGetDataLength(bb) : 0;
    if (len > 0) {
        NSMutableData *raw = [NSMutableData dataWithLength:len];
        CMBlockBufferCopyDataBytes(bb, 0, len, raw.mutableBytes);
        NSData *converted = [self sl_convertAudio:raw];
        if (converted.length) {
            [_lock lock];
            [_audioPCM appendData:converted];
            [_lock unlock];
        }
    }
    CFRelease(sb);
    return YES;
}

- (NSData *)sl_convertAudio:(NSData *)input {
    AVAudioConverter *conv;
    AudioStreamBasicDescription dst;
    [_lock lock];
    conv = _audioConverter;
    dst = _audioDstASBD;
    BOOL hasDst = _hasAudioDstASBD;
    AudioStreamBasicDescription src = _audioSrcASBD;
    [_lock unlock];
    if (!hasDst) return nil;
    if (!conv) return input;   // 格式已经一致，直接透传

    AVAudioFormat *srcFmt = [[AVAudioFormat alloc] initWithStreamDescription:&src];
    AVAudioFormat *dstFmt = [[AVAudioFormat alloc] initWithStreamDescription:&dst];
    if (!srcFmt || !dstFmt) return nil;

    AVAudioFrameCount frames = (AVAudioFrameCount)(input.length / srcFmt.streamDescription->mBytesPerFrame);
    if (frames == 0) return nil;

    AVAudioPCMBuffer *inBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:srcFmt frameCapacity:frames];
    if (!inBuf) return nil;
    inBuf.frameLength = frames;
    memcpy(inBuf.mutableAudioBufferList->mBuffers[0].mData, input.bytes, input.length);

    AVAudioFrameCount cap = (AVAudioFrameCount)((double)frames * dstFmt.sampleRate / srcFmt.sampleRate) + 128;
    AVAudioPCMBuffer *outBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:dstFmt frameCapacity:cap];
    if (!outBuf) return nil;

    __block BOOL supplied = NO;
    NSError *err = nil;
    AVAudioConverterOutputStatus st = [conv convertToBuffer:outBuf error:&err
        withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount n, AVAudioConverterInputStatus *status) {
            if (supplied) { *status = AVAudioConverterInputStatus_NoDataNow; return nil; }
            supplied = YES;
            *status = AVAudioConverterInputStatus_HaveData;
            return inBuf;
        }];
    if (st == AVAudioConverterOutputStatus_Error || outBuf.frameLength == 0) return nil;

    const AudioBufferList *abl = outBuf.audioBufferList;
    if (abl->mNumberBuffers == 1) {
        return [NSData dataWithBytes:abl->mBuffers[0].mData length:abl->mBuffers[0].mDataByteSize];
    }
    // 非交错多声道：拼成一块，配合 mFormatFlags 里的 NonInterleaved 由下游按 plane 读
    NSMutableData *out = [NSMutableData data];
    for (UInt32 i = 0; i < abl->mNumberBuffers; i++) {
        [out appendBytes:abl->mBuffers[i].mData length:abl->mBuffers[i].mDataByteSize];
    }
    return out;
}

#pragma mark - Reader 构建（只在解码线程调用）

- (void)sl_buildReaderForKey:(NSString *)key {
    [_reader cancelReading];
    _reader = nil;
    _videoOut = nil;
    _audioOut = nil;
    _idleRounds = 0;

    NSString *path;
    [_lock lock];
    path = _sourcePath;
    [_lock unlock];
    if (!path.length) return;

    OSType pf = kCVPixelFormatType_32BGRA;
    if (key.length) {
        NSString *head = [key componentsSeparatedByString:@":"].firstObject;
        if (head.length) pf = (OSType)strtoul(head.UTF8String, NULL, 0);
    }

    NSURL *url = [NSURL fileURLWithPath:path];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    NSError *err = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
    if (!reader) {
        SLVLog(@"feed reader 创建失败: %@", err.localizedDescription ?: @"?");
        return;
    }

    BOOL wantAudio;
    [_lock lock];
    wantAudio = _hasAudioDstASBD;
    [_lock unlock];

    // 素材到底有没有音轨，每次都记下来。这不只是日志：
    // 音频池暂时没数据时，靠它决定是「输出静音」还是「放行真实麦克风」。
    AVAssetTrack *audioTrack = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    [_lock lock];
    _assetHasAudio = (audioTrack != nil);
    [_lock unlock];

    // 每次换素材探一次音轨，单独打一行。
    // 不这样的话，日志里 `(video=Y audio=N)` 会有歧义 —— 那个 N 只表示
    // 「宿主还没来要音频」，跟素材有没有音轨是两回事。
    static NSString *sLastAudioProbePath = nil;
    if (![sLastAudioProbePath isEqualToString:path]) {
        sLastAudioProbePath = path;
        // 顺手把音轨编码打出来。之前只打「有/无」，遇到「明明有音轨却没声音」时
        // 完全看不出是编码解不动还是别的原因（Opus / AC-3 这类在 mp4 里很常见）。
        NSString *codec = @"-", *detail = @"-";
        if (audioTrack) {
            CMFormatDescriptionRef fd =
                (__bridge CMFormatDescriptionRef)audioTrack.formatDescriptions.firstObject;
            if (fd) {
                FourCharCode fc = CMFormatDescriptionGetMediaSubType(fd);
                codec = [NSString stringWithFormat:@"%c%c%c%c",
                         (char)(fc >> 24), (char)(fc >> 16), (char)(fc >> 8), (char)fc];
                const AudioStreamBasicDescription *a =
                    CMAudioFormatDescriptionGetStreamBasicDescription(fd);
                if (a) detail = [NSString stringWithFormat:@"%.0fHz %uch",
                                 a->mSampleRate, (unsigned)a->mChannelsPerFrame];
            }
        }
        SLVLog(@"feed 素材音轨: %@ · %@ · %@（%@）", audioTrack ? @"有" : @"无",
              codec, detail, path.lastPathComponent);
    }

    AVAssetTrack *vt = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (vt) {
        NSDictionary *settings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(pf) };
        AVAssetReaderTrackOutput *o = [[AVAssetReaderTrackOutput alloc] initWithTrack:vt outputSettings:settings];
        o.alwaysCopiesSampleData = NO;
        if ([reader canAddOutput:o]) {
            [reader addOutput:o];
            _videoOut = o;
        } else {
            // 目标格式解码器不认，退回 BGRA，交给 CoreImage 转
            NSDictionary *bg = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
            AVAssetReaderTrackOutput *o2 = [[AVAssetReaderTrackOutput alloc] initWithTrack:vt outputSettings:bg];
            o2.alwaysCopiesSampleData = NO;
            if ([reader canAddOutput:o2]) { [reader addOutput:o2]; _videoOut = o2; }
        }
        CGSize ns = vt.naturalSize;
        float fps = vt.nominalFrameRate;
        if (fps < 1.0f || fps > 240.0f) fps = 30.0f;
        _frameInterval = 1.0 / (double)fps;
        [_lock lock];
        _naturalSize = ns;
        [_lock unlock];
    }

    if (wantAudio && audioTrack) {
        AVAssetTrack *at = audioTrack;
        if (at) {
            // 统一解成 float32 / 单声道 / 非交错 / 44.1k，再由 AVAudioConverter 转成宿主格式
            AudioStreamBasicDescription src;
            memset(&src, 0, sizeof(src));
            src.mSampleRate = 44100;
            src.mFormatID = kAudioFormatLinearPCM;
            src.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
            src.mChannelsPerFrame = 1;
            src.mBitsPerChannel = 32;
            src.mBytesPerFrame = 4;
            src.mBytesPerPacket = 4;
            src.mFramesPerPacket = 1;

            NSDictionary *settings = @{
                AVFormatIDKey: @(kAudioFormatLinearPCM),
                AVSampleRateKey: @44100.0,
                AVNumberOfChannelsKey: @1,
                AVLinearPCMBitDepthKey: @32,
                AVLinearPCMIsFloatKey: @YES,
                AVLinearPCMIsBigEndianKey: @NO,
                AVLinearPCMIsNonInterleaved: @YES,
            };
            AVAssetReaderTrackOutput *o = [[AVAssetReaderTrackOutput alloc] initWithTrack:at outputSettings:settings];
            o.alwaysCopiesSampleData = NO;
            if ([reader canAddOutput:o]) {
                [reader addOutput:o];
                _audioOut = o;
                [_lock lock];
                _audioSrcASBD = src;
                [_lock unlock];
            } else {
                // 音轨在，但解不成 float32 / 单声道。表现就是「有音轨却全程静音」，
                // 必须留一行，否则只能靠猜。
                SLVLog(@"feed 音轨解不成 PCM（编码不支持），这条素材只能静音");
            }
        }
    }

    if (![reader startReading]) {
        SLVLog(@"feed startReading 失败: %@", reader.error.localizedDescription ?: @"?");
        return;
    }
    _reader = reader;

    // 循环播放每轮都要重建 reader，每 11 秒刷一行会把日志淹掉。
    // 只在「首次 / 目标格式变了 / 每 20 轮」打一次 —— 真出问题时也还看得到心跳。
    static NSString *sLastLoggedKey = nil;
    static int sLoopRounds = 0;
    sLoopRounds++;
    BOOL keyChanged = ![sLastLoggedKey isEqualToString:key ?: @""];
    if (keyChanged || sLoopRounds % 20 == 0) {
        sLastLoggedKey = key ?: @"";
        SLVLog(@"feed 管线就绪 %@ (video=%@ audio=%@)%@", key ?: @"(nil)",
              _videoOut ? @"Y" : @"N", _audioOut ? @"Y" : @"N",
              keyChanged ? @"" : [NSString stringWithFormat:@" · 第 %d 轮", sLoopRounds]);
    }
}

#pragma mark - 出帧

- (CGSize)latestFrameSize {
    [_lock lock];
    CVPixelBufferRef pb = _latestVideo;
    CGSize s = pb ? CGSizeMake(CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb)) : CGSizeZero;
    [_lock unlock];
    return s;
}

- (CVPixelBufferRef)copyNextFrame {
    [_lock lock];
    CVPixelBufferRef pb = _latestVideo ? (CVPixelBufferRef)CVPixelBufferRetain(_latestVideo) : NULL;
    [_lock unlock];
    return pb;
}

- (CVPixelBufferRef)copyFrameForPixelFormat:(OSType)pixelFormat size:(CGSize)size {
    if (pixelFormat == 0 || size.width < 1 || size.height < 1) return NULL;
    size_t w = (size_t)size.width;
    size_t h = (size_t)size.height;

    NSString *key = [NSString stringWithFormat:@"%u:%zux%zu", (unsigned)pixelFormat, w, h];
    [_lock lock];
    BOOL changed = ![_pipelineKey isEqualToString:key];
    if (changed) { _pipelineKey = key; _reconfigRequested = YES; }
    BOOL hasFrame = (_latestVideo != NULL);
    [_lock unlock];

    // 目标格式刚变、手里还没有任何帧：放行这一帧真画面，让解码线程按新格式重建
    if (changed && !hasFrame) return NULL;

    [_lock lock];
    CVPixelBufferRef pb = _latestVideo ? (CVPixelBufferRef)CVPixelBufferRetain(_latestVideo) : NULL;
    [_lock unlock];
    if (!pb) return NULL;

    size_t sw = CVPixelBufferGetWidth(pb);
    size_t sh = CVPixelBufferGetHeight(pb);
    OSType spf = CVPixelBufferGetPixelFormatType(pb);
    NSInteger rot = [self sl_normalizedRotation];

    // 尺寸、格式都对上、又没开镜像/旋转，才能零转换直出
    if (sw == w && sh == h && spf == pixelFormat && !self.mirrorEnabled && rot == 0) {
        return pb;
    }

    CVPixelBufferRef out = [self sl_render:pb
                                   toWidth:w
                                    height:h
                                    format:pixelFormat
                                    mirror:self.mirrorEnabled
                                  rotation:rot];
    CVPixelBufferRelease(pb);
    return out;
}

/// 角度只认 0/90/180/270，其余一律当 0（脏数据不该让画面整个歪掉）
- (NSInteger)sl_normalizedRotation {
    NSInteger r = self.rotation % 360;
    if (r < 0) r += 360;
    if (r == 90 || r == 180 || r == 270) return r;
    return 0;
}

// 拍照专用出帧。跟 copyFrameForPixelFormat:size: 的区别只有一点：
// **不动 _pipelineKey / _reconfigRequested**，所以预览管线一根手指都不碰。
//
// 代价是每次拍照都要现场做一次 CI 渲染（约十几毫秒），但拍照是低频操作，
// 拿这点开销换「预览不闪一下真摄像头」完全值得。
- (CVPixelBufferRef)copyOrientedFrameForPixelFormat:(OSType)pixelFormat size:(CGSize)size {
    if (pixelFormat == 0) return NULL;

    [_lock lock];
    CVPixelBufferRef pb = _latestVideo ? (CVPixelBufferRef)CVPixelBufferRetain(_latestVideo) : NULL;
    [_lock unlock];
    if (!pb) return NULL;

    size_t sw = CVPixelBufferGetWidth(pb);
    size_t sh = CVPixelBufferGetHeight(pb);
    if (sw < 1 || sh < 1) { CVPixelBufferRelease(pb); return NULL; }

    NSInteger rot = [self sl_normalizedRotation];
    BOOL mirror = self.mirrorEnabled;

    size_t w, h;
    if (size.width >= 1 && size.height >= 1) {
        w = (size_t)size.width;
        h = (size_t)size.height;
    } else if (rot == 90 || rot == 270) {
        w = sh;   // 转 90/270 之后宽高互换
        h = sw;
    } else {
        w = sw;
        h = sh;
    }

    // 格式、尺寸都对上又没开镜像/旋转 → 原样直出，省一次渲染
    if (rot == 0 && !mirror && CVPixelBufferGetPixelFormatType(pb) == pixelFormat
        && sw == w && sh == h) {
        return pb;
    }

    CVPixelBufferRef out = [self sl_render:pb
                                   toWidth:w
                                    height:h
                                    format:pixelFormat
                                    mirror:mirror
                                  rotation:rot];
    CVPixelBufferRelease(pb);
    return out;
}

- (CVPixelBufferRef)sl_render:(CVPixelBufferRef)src
                      toWidth:(size_t)w
                       height:(size_t)h
                       format:(OSType)pf
                       mirror:(BOOL)mirror
                     rotation:(NSInteger)rotation {
    size_t sw = CVPixelBufferGetWidth(src);
    size_t sh = CVPixelBufferGetHeight(src);
    if (sw < 1 || sh < 1 || w < 1 || h < 1) return NULL;

    CIImage *img = [self sl_image:[CIImage imageWithCVPixelBuffer:src]
                          toWidth:w
                           height:h
                           mirror:mirror
                         rotation:rotation];
    if (!img) return NULL;

    // 0.3.5：先渲染成 BGRA，再按目标格式转。
    //
    // 原来直接把结果往 pf 上渲染。宿主要 420f/420v（NV12 双平面）时，
    // Metal 版 CIContext 写出来的色度平面是错的 —— 亮度进去了、色度没进去，
    // 解出来就是「白底 + 亮绿人形轮廓」。开镜像 / 旋转的视频和所有图片都中招，
    // 不旋转不镜像的视频走解码器直出，所以一直正常。
    //
    // BGRA 是 CI 最可靠的输出格式，转 NV12 交给 vImage（平面偏移和 stride 它自己算）。
    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey : @{} };
    CVPixelBufferRef bgra = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &bgra) != kCVReturnSuccess) return NULL;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    [_ciContext render:img
       toCVPixelBuffer:bgra
                bounds:CGRectMake(0, 0, (CGFloat)w, (CGFloat)h)
            colorSpace:cs];
    CGColorSpaceRelease(cs);

    CVPixelBufferRef dst = NULL;
    if (pf == kCVPixelFormatType_32BGRA) {
        dst = bgra;                       // 宿主本来就要 BGRA，不用再转
        bgra = NULL;
    } else {
        dst = SLVConvertBGRAtoNV12(bgra, pf);
        CVPixelBufferRelease(bgra);
        if (!dst) {
            // 既不是 BGRA 也不是 NV12（422 / 10bit 这类，极少见）。
            // 退回老路径让 CI 直接渲染 —— 可能仍然偏色，但总比黑屏强。
            if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, pf,
                                    (__bridge CFDictionaryRef)attrs, &dst) != kCVReturnSuccess) return NULL;
            CGColorSpaceRef cs2 = CGColorSpaceCreateDeviceRGB();
            [_ciContext render:img
               toCVPixelBuffer:dst
                        bounds:CGRectMake(0, 0, (CGFloat)w, (CGFloat)h)
                    colorSpace:cs2];
            CGColorSpaceRelease(cs2);
        }
    }
    if (!dst) return NULL;

    // 把源帧的色彩附件带到目标帧上。
    //
    // CVPixelBufferCreate 造出来的是「干净」的缓冲，色彩空间 / YCbCr 矩阵这些
    // 附件一个都没有。下游（尤其抖音）会去读这些 key，拿不到 NULL 之后有些
    // 地方是不判空直接 CFRelease 的 —— 那就是崩溃。
    // 顺带也让色彩转换更准：解码器给的矩阵本来就是对的。
    CFDictionaryRef srcAtts = CVBufferCopyAttachments(src, kCVAttachmentMode_ShouldPropagate);
    if (srcAtts) {
        CVBufferSetAttachments(dst, srcAtts, kCVAttachmentMode_ShouldPropagate);
        CFRelease(srcAtts);
    }
    return dst;
}

/// 旋转 + 铺满裁切 + 镜像，全部在 CI 坐标系里做完，返回摆好姿势的图。
/// `sl_render:`（自己建 buffer）和 `renderIntoPixelBuffer:`（改写宿主 buffer）
/// 共用这一份数学 —— 两处各写一遍迟早会不一致。
- (CIImage *)sl_image:(CIImage *)img
              toWidth:(size_t)w
               height:(size_t)h
               mirror:(BOOL)mirror
             rotation:(NSInteger)rotation {
    if (!img) return nil;

    // 1) 旋转。CI 是 y 轴向上的坐标系，视觉上的「顺时针」要取负角度。
    //    旋转后 extent 会跑到负象限，必须平移回 (0,0)，否则后面缩放会按错的框算。
    if (rotation != 0) {
        img = [img imageByApplyingTransform:CGAffineTransformMakeRotation(-rotation * M_PI / 180.0)];
        CGRect e = img.extent;
        img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(-e.origin.x, -e.origin.y)];
    }

    // 2) 铺满目标框再居中裁切（aspect-fill）。直接拉伸会把人脸拉扁，
    //    竖屏素材塞进横屏预览时尤其明显。
    CGRect re = img.extent;
    if (re.size.width < 1 || re.size.height < 1) return nil;
    CGFloat s = MAX((CGFloat)w / re.size.width, (CGFloat)h / re.size.height);
    img = [img imageByApplyingTransform:CGAffineTransformMakeScale(s, s)];

    CGRect se = img.extent;
    img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(
        ((CGFloat)w - se.size.width) / 2.0,
        ((CGFloat)h - se.size.height) / 2.0)];

    // 3) 镜像：在目标坐标系里水平翻转，翻转后再平移回 (0,0)
    if (mirror) {
        img = [img imageByApplyingTransform:CGAffineTransformConcat(
            CGAffineTransformMakeScale(-1, 1),
            CGAffineTransformMakeTranslation((CGFloat)w, 0))];
    }
    return img;
}

/// 把当前素材帧画进**调用方给的** buffer，原地改写内容，不换指针、不改所有权。
///
/// 为什么要这个方法：`-[AVCapturePhoto pixelBuffer]` 返回的 buffer 归 AVCapturePhoto
/// 自己所有，调用方拿到的是借用引用。如果我们返回自己 new 出来的 buffer，
/// 一是调用方不会 CFRelease（每次拍照泄 8MB），二是尺寸/格式跟真照片对不上，
/// 宿主按 resolvedSettings 算出来的宽高会跟 buffer 打架。
/// 原地画进去两个问题都不存在：指针、尺寸、格式全是宿主熟悉的那个。
- (BOOL)renderIntoPixelBuffer:(CVPixelBufferRef)dst extraRotation:(NSInteger)extraRotation {
    if (!dst) return NO;
    size_t w = CVPixelBufferGetWidth(dst);
    size_t h = CVPixelBufferGetHeight(dst);
    if (w < 1 || h < 1) return NO;

    [_lock lock];
    CVPixelBufferRef src = _latestVideo ? (CVPixelBufferRef)CVPixelBufferRetain(_latestVideo) : NULL;
    [_lock unlock];
    if (!src) return NO;

    // 用户设的旋转 + 拍照补偿角，归一成 0/90/180/270
    NSInteger rot = ([self sl_normalizedRotation] + extraRotation) % 360;
    if (rot < 0) rot += 360;
    if (rot != 90 && rot != 180 && rot != 270) rot = 0;

    CIImage *img = [self sl_image:[CIImage imageWithCVPixelBuffer:src]
                          toWidth:w
                           height:h
                           mirror:self.mirrorEnabled
                         rotation:rot];
    CVPixelBufferRelease(src);
    if (!img) return NO;

    // 0.3.5：跟 sl_render: 一样的道理 —— 不能直接往宿主的 NV12 buffer 上 render，
    // 色度平面会写错，拍出来的照片就是绿轮廓。先渲 BGRA，再让 vImage 写平面。
    OSType dpf = CVPixelBufferGetPixelFormatType(dst);
    BOOL isNV12 = (dpf == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                   dpf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);

    if (!isNV12) {
        // BGRA（或其它单平面格式）：CI 直接写就行
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        [_ciContext render:img
           toCVPixelBuffer:dst
                    bounds:CGRectMake(0, 0, (CGFloat)w, (CGFloat)h)
                colorSpace:cs];
        CGColorSpaceRelease(cs);
        return YES;
    }

    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey : @{} };
    CVPixelBufferRef bgra = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &bgra) != kCVReturnSuccess) return NO;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    [_ciContext render:img
       toCVPixelBuffer:bgra
                bounds:CGRectMake(0, 0, (CGFloat)w, (CGFloat)h)
            colorSpace:cs];
    CGColorSpaceRelease(cs);

    BOOL ok = SLVBlitBGRAtoNV12(bgra, dst);
    CVPixelBufferRelease(bgra);
    return ok;
}

#pragma mark - 出音频

/// 登记宿主音频格式并建好转换器。调用方必须已持有 _lock。
/// 返回 YES 表示格式是新的（或变了），解码管线需要重建。
- (BOOL)sl_configureAudioLocked:(const AudioStreamBasicDescription *)asbd {
    if (!asbd || asbd->mBytesPerFrame == 0 || asbd->mSampleRate == 0) return NO;
    if (_hasAudioDstASBD && memcmp(asbd, &_audioDstASBD, sizeof(*asbd)) == 0) return NO;

    _audioDstASBD = *asbd;
    _hasAudioDstASBD = YES;
    _audioBytesPerSecond = (NSUInteger)(asbd->mSampleRate * asbd->mBytesPerFrame);

    // 解码侧固定 float32 / 单声道 / 非交错 / 44.1k，这里就地推导源格式，
    // 不依赖解码线程，避免首次请求时 converter 拿到全零 ASBD
    AudioStreamBasicDescription src = *asbd;
    src.mSampleRate = 44100;
    src.mFormatID = kAudioFormatLinearPCM;
    src.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    src.mChannelsPerFrame = 1;
    src.mBitsPerChannel = 32;
    src.mBytesPerFrame = 4;
    src.mBytesPerPacket = 4;
    src.mFramesPerPacket = 1;
    _audioSrcASBD = src;

    _audioConverter = nil;
    BOOL needConvert = !(asbd->mFormatFlags & kAudioFormatFlagIsFloat)
                    || !(asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved)
                    || asbd->mChannelsPerFrame != 1
                    || asbd->mSampleRate != 44100;
    if (needConvert) {
        AVAudioFormat *sf = [[AVAudioFormat alloc] initWithStreamDescription:&src];
        AVAudioFormat *df = [[AVAudioFormat alloc] initWithStreamDescription:&_audioDstASBD];
        if (sf && df) {
            _audioConverter = [[AVAudioConverter alloc] initFromFormat:sf toFormat:df];
            if (!_audioConverter) SLVLog(@"音频转换器创建失败，将只换画面");
        }
    }
    _reconfigRequested = YES;   // 让解码线程把音频轨挂上
    SLVLog(@"audio 目标 %.0fHz %uch %uB/帧 转码=%@", asbd->mSampleRate,
          (unsigned)asbd->mChannelsPerFrame, (unsigned)asbd->mBytesPerFrame,
          needConvert ? @"Y" : @"N");
    return YES;
}

- (void)primeAudioFormat:(const AudioStreamBasicDescription *)asbd {
    if (!asbd) return;
    [_lock lock];
    [self sl_configureAudioLocked:asbd];
    [_lock unlock];
}

/// 取一包 PCM。调用方必须已持有 _lock。
- (NSData *)sl_audioLocked:(const AudioStreamBasicDescription *)asbd numBytes:(size_t)numBytes configure:(BOOL)configure {
    if (!asbd || asbd->mBytesPerFrame == 0 || numBytes == 0) return nil;

    // 关掉「替换音频」= 静音。这里必须返回全零的 PCM，不能返回 nil：
    // 返回 nil 会让注入层放行真实麦克风，把环境声原样录进去。
    // 走这条分支也就不需要素材有音轨，无声视频同样能静音。
    if (!self.audioReplaceEnabled) {
        return [NSMutableData dataWithLength:numBytes];
    }

    if (configure) {
        [self sl_configureAudioLocked:asbd];
    } else if (!_hasAudioDstASBD) {
        // 实时线程不建转换器 —— 那是几十毫秒的活，让 primeAudioFormat: 去做。
        // 但这条路以前是静默返回 nil 的，而 nil 在三条注入链路里都等于
        // 「放行真麦克风」。所以「录制时音频没被替换」在日志上完全看不见，
        // 现在第一次撞上就留一行痕。
        if (!_audioPassLogged) {
            _audioPassLogged = YES;
            SLVLog(@"音频: 放行真麦克风 —— 目标格式还没配置（素材 %.0fHz %uch，宿主未登记）",
                  asbd->mSampleRate, (unsigned)asbd->mChannelsPerFrame);
        }
        return nil;
    }

    NSMutableData *chunk = [NSMutableData dataWithLength:numBytes];
    NSUInteger got = 0;
    NSUInteger avail = _audioPCM.length - _audioReadCursor;

    // 水位控制。
    //
    // 只有一条规则：缓冲撑到 0.6 秒以上就一刀砍回目标水位。正常运行时一次都
    // 不该触发 —— 生产端高水位只有 120ms，离 600ms 差着 5 倍。
    //
    // 0.2.9 在这里还有一条「avail > target + 4 包就以 2× 速度追」的分支，
    // 想法是「一次最多丢一包，人耳听不出来」。但稳态水位本来就长期高于 target
    // （生产端按 HIGH 补，HIGH 必然大于 TARGET），于是那条分支每次回调都成立：
    // 每 20ms 丢一包 20ms，内容以 40ms/20ms 前进 = 2 倍速，听感就是「声音加速」。
    //
    // 「追赶」只有在能判断出「确实落后」时才有意义，而这里根本没有可靠的落后
    // 判据 —— 水位高不等于延迟大，正常稳态水位同样高。所以整条删掉，
    // 不再有任何在稳态下会触发的丢包路径。
    if (_audioBytesPerSecond > 0) {
        NSUInteger target = (NSUInteger)(_audioBytesPerSecond * SLV_AUDIO_TARGET_SEC);
        if (target < numBytes) target = numBytes;
        NSUInteger hard = (NSUInteger)(_audioBytesPerSecond * SLV_AUDIO_HARD_SEC);

        if (avail > hard) {
            NSUInteger drop = avail - target;
            _audioReadCursor += drop;
            avail -= drop;
            _audioDropped += drop;
            if (!_audioDropLogged) {
                _audioDropLogged = YES;
                SLVLog(@"音频: 缓冲 %lums 严重偏高（卡顿后遗留），硬切 %lu 字节回 %lums",
                      (unsigned long)((avail + drop) * 1000 / _audioBytesPerSecond),
                      (unsigned long)drop,
                      (unsigned long)(target * 1000 / _audioBytesPerSecond));
            }
        }
    }

    if (avail > 0) {
        got = MIN(avail, numBytes);
        memcpy(chunk.mutableBytes, (uint8_t *)_audioPCM.bytes + _audioReadCursor, got);
        _audioReadCursor += got;
        NSUInteger trimAt = _audioBytesPerSecond ? _audioBytesPerSecond * 2 : (44100 * 32);
        if (_audioReadCursor > trimAt) {
            [_audioPCM replaceBytesInRange:NSMakeRange(0, _audioReadCursor) withBytes:NULL length:0];
            _audioReadCursor = 0;
        }
    }

    // 心跳：每 3000 包打一次水位，下次再出问题不用靠推算
    _audioCalls++;
    if (_audioCalls % 3000 == 0 && _audioBytesPerSecond > 0) {
        SLVLog(@"音频: 水位 %lums · 丢 %lu 字节 · 第 %lu 包",
              (unsigned long)((_audioPCM.length - _audioReadCursor) * 1000 / _audioBytesPerSecond),
              (unsigned long)_audioDropped, (unsigned long)_audioCalls);
    }

    BOOL hasAudio = _assetHasAudio;
    (void)hasAudio;

    if (got == 0) {
        // 素材没有音轨 —— **输出静音**，不再放行真实麦克风。
        //
        // 以前这里返回 nil，让真麦克风原样穿过去，本意是「只换画面、保留原声」。
        // 但实际用起来是反的：打开了「替换音频」，结果录进去的是房间里的声音，
        // 用户看到的就是「替换没生效 / 这个视频没声音」。图片素材走的也是这条
        //（图片天然没有音轨），所以选一张图进去同样是环境声。
        //
        // 虚拟摄像头的前提是「别把真实环境录进去」，所以这里改成静音。
        if (!hasAudio && !_audioPassLogged) {
            _audioPassLogged = YES;
            SLVLog(@"音频: 素材没有音轨，输出静音（不放行真麦克风）");
        }
        // 有音轨但还没解出数据 —— 必须输出静音。
        // 返回 nil 会让注入层放行真麦克风，把环境声原样录进去，
        // 通话刚接通那 1 秒最明显。
        return chunk;   // dataWithLength 出来就是全零
    }
    if (got < numBytes) memset((uint8_t *)chunk.mutableBytes + got, 0, numBytes - got);  // 不够补静音
    return chunk;
}

- (NSData *)audioForFormat:(const AudioStreamBasicDescription *)asbd numBytes:(size_t)numBytes {
    [_lock lock];
    NSData *d = [self sl_audioLocked:asbd numBytes:numBytes configure:YES];
    [_lock unlock];
    return d;
}

- (NSData *)tryAudioForFormat:(const AudioStreamBasicDescription *)asbd numBytes:(size_t)numBytes {
    // 实时音频线程专用：拿不到锁就放行这一包真麦克风，绝不阻塞宿主。
    // 锁只在解码线程 append 那一瞬间被持有，正常几乎不会撞上；
    // 一旦撞上，说明解码线程正在干重活，这时候卡住宿主才是灾难。
    if (![_lock tryLock]) return nil;
    NSData *d = [self sl_audioLocked:asbd numBytes:numBytes configure:NO];
    [_lock unlock];
    return d;
}

@end
