//
//  SLVCamInject.m
//  声临 · 虚拟摄像头 —— 注入层实现
//

#import "SLCamInject.h"
#import "SLCamFeed.h"
#import "SLCamAudioUnit.h"
#import "SLCamBridge.h"
#import "SLLog.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>   // 0.3.21：预览层接管里的 CATransform3D
#import <Accelerate/Accelerate.h>  // 0.3.32：写文件时把像素转 90°（vImageRotate90）
#import <objc/runtime.h>
#import <os/lock.h>
#import <dlfcn.h>
#include <math.h>   // 0.3.21：预览层接管里用 fabs / M_PI

typedef void (*SLVProcessSampleBufferFn)(id, SEL, CMSampleBufferRef);

// 原始 IMP 用固定数组存，按 Method 指针线性比对。
//
// 别用 NSMapTable + NSPointerFunctionsOpaqueMemory 存这个：那套 key 语义是「裸指针」，
// 每次查询都新建一个 NSValue 对象、地址不同，永远查不到 —— 查不到就会把原始实现整个
// 跳过，表现为「Hook 装上了、日志也对、但摄像头全黑」。Method 数量个位数，线性扫足够。
#define SLV_MAX_HOOKS 8
static Method gSLHookMethods[SLV_MAX_HOOKS];
static IMP    gSLHookIMPs[SLV_MAX_HOOKS];

static BOOL sSLCamInjecting = NO;
static BOOL sSLCamHooksInstalled = NO;
static BOOL sSLCamAVCaptureAudioSeen = NO;
static int  sSLCamHookCount = 0;
static BOOL sLoggedMissingOrig = NO;
static BOOL sLoggedFirstVideo = NO;
static BOOL sLoggedFirstAudio = NO;
static int  sSLCamFailCount = 0;
static int  sSLCamAudioFailCount = 0;
static int  sSLCamBadPTS = 0;
static int  sSLCamTimingFixLogged = 0;
static int  sSLCamOwnFmtLogged = 0;
static int  sSLCamDTSFixLogged = 0;
static int  sSLCamAttachLogged = 0;
static int  sSLCamSetAttachFailLogged = 0;
static int  sSLCamOwnFmtExtFailLogged = 0;
static int  sSLCamOwnFmtRejectedLogged = 0;

/// 四字符码转可读串（'BGRA' / '420f'），日志里比裸数字好认
static NSString *SLVFourCC(OSType v) {
    char c[5] = {
        (char)((v >> 24) & 0xff), (char)((v >> 16) & 0xff),
        (char)((v >> 8) & 0xff),  (char)(v & 0xff), 0
    };
    for (int i = 0; i < 4; i++) {
        if (c[i] < 32 || c[i] > 126) c[i] = '?';
    }
    return @(c);
}

/// 0.3.21：预览层接管。定义在文件后半段，这里先声明 —— 注入主流程要用。
static void SLVCamFeedPreview(CMSampleBufferRef sb);
static void SLVCamTeardownPreview(void);
static void SLVCamTeardownPreviewIfStale(void);
static NSInteger SLVCamPreviewRotationDeg(AVCaptureConnection *conn);

/// 音视频输出可能各自重写了 _processSampleBuffer:，必须按 Method 分别保存原始 IMP，
/// 否则音频会走到视频的原始实现上去（表现为只有画面变、声音还在）。
static IMP SLVCamOriginalIMP(id self, SEL _cmd) {
    Method m = class_getInstanceMethod([self class], _cmd);
    if (!m) return NULL;
    for (int i = 0; i < sSLCamHookCount; i++) {
        if (gSLHookMethods[i] == m) return gSLHookIMPs[i];
    }
    if (!sLoggedMissingOrig) {
        sLoggedMissingOrig = YES;
        SLVLog(@"注入: 找不到 %s 的原始 IMP，将原样放行", sel_getName(_cmd));
    }
    return NULL;
}

/// 自建 fmt 的缓存。
///
/// 为什么需要：`CMVideoFormatDescriptionMatchesImageBuffer(宿主 fmt, 假帧)` 每帧都为假
/// —— 宿主 fmt 带着自己的 CVBytesPerRow，和我们的帧天生对不上。所以每帧都会走进自建
/// 分支。不缓存的话 30fps 下每秒白建 60 个 fmt，而且是在采集队列上。
///
/// 自建 fmt 只跟「子类型 + 宽 + 高 + 帧的色彩矩阵」有关，这四样不变就一直复用。
/// 把色彩矩阵也算进 key 是因为自建 fmt 的扩展是从帧的附件反推的 —— 换素材后色彩
/// 矩阵可能变，复用旧 fmt 会让色彩偏一点。
#define SLV_FMT_CACHE 4

typedef struct {
    OSType subType;
    int32_t width;
    int32_t height;
    uintptr_t colorHash;
    CMVideoFormatDescriptionRef fmt;      // 缓存自己持有一份引用
} SLVFmtCacheEntry;

static SLVFmtCacheEntry gSLFmtCache[SLV_FMT_CACHE];
static int gSLFmtCacheCount = 0;
static int gSLFmtCacheNext = 0;           // 满了就轮换覆盖
static os_unfair_lock gSLFmtCacheLock = OS_UNFAIR_LOCK_INIT;

/// 帧的色彩矩阵哈希，用来区分「同一尺寸但色彩标注不同」的帧
static uintptr_t SLVCamFrameColorHash(CVPixelBufferRef frame) {
    CFTypeRef m = CVBufferGetAttachment(frame, kCVImageBufferYCbCrMatrixKey, NULL);
    return m ? (uintptr_t)CFHash(m) : 0;
}

static CMVideoFormatDescriptionRef SLVCamCachedFormat(OSType subType, int32_t w, int32_t h,
                                                     uintptr_t colorHash) {
    CMVideoFormatDescriptionRef hit = NULL;
    os_unfair_lock_lock(&gSLFmtCacheLock);
    for (int i = 0; i < gSLFmtCacheCount; i++) {
        if (gSLFmtCache[i].subType == subType && gSLFmtCache[i].width == w
            && gSLFmtCache[i].height == h && gSLFmtCache[i].colorHash == colorHash) {
            hit = (CMVideoFormatDescriptionRef)CFRetain(gSLFmtCache[i].fmt);
            break;
        }
    }
    os_unfair_lock_unlock(&gSLFmtCacheLock);
    return hit;
}

static void SLVCamStoreFormat(OSType subType, int32_t w, int32_t h,
                             uintptr_t colorHash, CMVideoFormatDescriptionRef fmt) {
    if (!fmt) return;
    os_unfair_lock_lock(&gSLFmtCacheLock);
    int slot;
    if (gSLFmtCacheCount < SLV_FMT_CACHE) {
        slot = gSLFmtCacheCount++;
    } else {
        slot = gSLFmtCacheNext;
        gSLFmtCacheNext = (gSLFmtCacheNext + 1) % SLV_FMT_CACHE;
        if (gSLFmtCache[slot].fmt) CFRelease(gSLFmtCache[slot].fmt);
    }
    gSLFmtCache[slot].subType = subType;
    gSLFmtCache[slot].width = w;
    gSLFmtCache[slot].height = h;
    gSLFmtCache[slot].colorHash = colorHash;
    gSLFmtCache[slot].fmt = (CMVideoFormatDescriptionRef)CFRetain(fmt);
    os_unfair_lock_unlock(&gSLFmtCacheLock);
}

/// 从宿主 extensions 里剔除「描述内存布局」的 key，只留色彩类。
///
/// CVBytesPerRow / CVFieldCount 描述的是缓冲区**怎么摆放**，必须由帧自己决定。
/// 从宿主 fmt 抄过来就会和我们的帧对不上，于是
/// CMSampleBufferCreateReadyWithImageBuffer 直接返回
/// kCMSampleBufferError_InvalidMediaFormat(-12743)，整帧打包失败 → 画面不被替换。
///
/// 0.2.10 就是整包抄了扩展，三个 App 全挂在 -12743。当时日志里真帧是「自洽=Y」，
/// 而假帧尺寸、子类型都和宿主 fmt 一样却仍判不匹配 —— 差异只在 bytesPerRow，
/// 这也是 CMVideoFormatDescriptionMatchesImageBuffer 会比的唯一一项。
static CFDictionaryRef SLVCamColorExtensions(CFDictionaryRef hostExt) {
    if (!hostExt) return NULL;
    // 用可变类型接着：CFDictionaryRemoveValue 要的是 CFMutableDictionaryRef，
    // 声明成 CFDictionaryRef 再传进去会丢 const，-Werror 下直接编译失败。
    CFMutableDictionaryRef out = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, hostExt);
    if (!out) return NULL;
    CFDictionaryRemoveValue(out, CFSTR("CVBytesPerRow"));
    CFDictionaryRemoveValue(out, CFSTR("CVFieldCount"));
    return out;
}

/// 自建一个「和假帧自洽、又尽量保留宿主扩展」的 fmt。
///
/// 为什么不能只用 CMVideoFormatDescriptionCreateForImageBuffer：它是从像素缓冲区
/// 反推 extensions 的，反推出来往往只有寥寥几项。宿主（抖音尤其）会去
/// CMFormatDescriptionGetExtension 取相机内参、色彩矩阵这类 key，拿到 NULL 之后
/// 是不判空直接 CFRelease 的 —— CoreFoundation 对 CFRelease(NULL) 是硬断言。
/// 0.2.9「点开录制就闪退」的栈就是：假帧 → _processSampleBuffer: →
/// AwemeCore 代理 → CFRelease(NULL)。
///
/// 但也不能像 0.2.10 那样整包抄 —— 布局 key 会让 fmt 和帧对不上（-12743）。
///
/// 所以：先用「宿主扩展去掉布局 key」建一个，**建完立刻自检**，和帧自洽才用；
/// 不自洽就退回帧反推。有了这道自检，任何扩展组合导致的 -12743 都不可能漏出去。
static CMVideoFormatDescriptionRef SLVCamMakeFormatDescription(CMFormatDescriptionRef hostFmt,
                                                              CVPixelBufferRef frame) {
    if (!hostFmt || !frame) return NULL;

    OSType subType = CMFormatDescriptionGetMediaSubType(hostFmt);
    if (subType == 0) subType = CVPixelBufferGetPixelFormatType(frame);

    int32_t w = (int32_t)CVPixelBufferGetWidth(frame);
    int32_t h = (int32_t)CVPixelBufferGetHeight(frame);
    uintptr_t colorHash = SLVCamFrameColorHash(frame);

    // 命中缓存就直接返回（返回的是 CFRetain 过的，调用方照常 CFRelease）
    CMVideoFormatDescriptionRef cached = SLVCamCachedFormat(subType, w, h, colorHash);
    if (cached) return cached;

    CFDictionaryRef ext = SLVCamColorExtensions(CMFormatDescriptionGetExtensions(hostFmt));
    CMVideoFormatDescriptionRef out = NULL;
    OSStatus st = CMVideoFormatDescriptionCreate(kCFAllocatorDefault, subType, w, h, ext, &out);
    if (ext) CFRelease(ext);

    if (st == noErr && out) {
        if (CMVideoFormatDescriptionMatchesImageBuffer(out, frame)) {
            SLVCamStoreFormat(subType, w, h, colorHash, out);
            return out;
        }
        CFRelease(out);                       // 和帧对不上，宁可不要
        out = NULL;
    }

    // 退回帧反推：extensions 少一些，但一定自洽
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, frame, &out) != noErr) {
        return NULL;
    }
    if (sSLCamOwnFmtExtFailLogged++ == 0) {
        SLVLog(@"注入: 带宿主扩展建 fmt 不自洽 st=%d，已退回帧反推（宿主可能取不到内参）", (int)st);
    }
    SLVCamStoreFormat(subType, w, h, colorHash, out);
    return out;
}

/// 把真帧上的附件整套搬到假帧上。
///
/// CMSampleBufferCreateReadyWithImageBuffer 只传播「像素缓冲区上」的附件，而真帧
/// sample buffer 自己带的那些（相机内参、时间戳对齐信息等）一条都继承不过来。
/// 宿主用 CMGetAttachment / CMCopyDictionaryOfAttachments 去取，就会拿到 NULL。
static void SLVCamCopySampleAttachments(CMSampleBufferRef from, CMSampleBufferRef to) {
    if (!from || !to) return;
    CFDictionaryRef atts = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, from,
                                                         kCMAttachmentMode_ShouldPropagate);
    if (!atts) return;

    // CMSetAttachments 返回 void，失败是静默的 —— 只能写完再读回来确认。
    // 这一步每个进程只做一次，开销可以忽略。
    CMSetAttachments(to, atts, kCMAttachmentMode_ShouldPropagate);
    CFRelease(atts);

    if (sSLCamSetAttachFailLogged++ > 0) return;
    CFDictionaryRef check = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, to,
                                                          kCMAttachmentMode_ShouldPropagate);
    CFIndex got = check ? CFDictionaryGetCount(check) : 0;
    if (got == 0) SLVLog(@"注入: 附件回填后仍为空 —— 宿主可能取不到内参");
    if (check) CFRelease(check);
}

/// 首次注入时把两边的 key 列表打出来。
/// 万一以后还崩在这个位置，这一行就能直接指出宿主缺哪个 key，不用再猜。
static void SLVCamLogAttachmentKeys(CMSampleBufferRef sbuf, CMFormatDescriptionRef fmt) {
    if (sSLCamAttachLogged++ > 0) return;

    CFDictionaryRef atts = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, sbuf,
                                                         kCMAttachmentMode_ShouldPropagate);
    NSArray *attKeys = atts ? [(__bridge NSDictionary *)atts allKeys] : @[];
    CFDictionaryRef ext = fmt ? CMFormatDescriptionGetExtensions(fmt) : NULL;
    NSArray *extKeys = ext ? [(__bridge NSDictionary *)ext allKeys] : @[];

    SLVLog(@"注入: 真帧附件 %lu 项 %@ · 宿主 fmt 扩展 %lu 项 %@",
          (unsigned long)attKeys.count, attKeys,
          (unsigned long)extKeys.count, extKeys);
    if (atts) CFRelease(atts);
}

static void SLVCamProcessSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sbuf) {
    IMP orig = SLVCamOriginalIMP(self, _cmd);

    // 拿不到原始实现只能放弃（SLVCamOriginalIMP 里已记日志）。这种情况只会在
    // hook 表被破坏时出现 —— 正常情况下查表是纯指针比对，不会失手。
    if (!orig) return;

    SLVCamFeed *feed = [SLVCamFeed shared];

    if (!sbuf || !sSLCamInjecting || ![feed isReady]) {
        // 0.3.21：替换没开（或还没就绪）时，预览层那边也必须退回原生画面，
        // 否则会一直停在我们喂的最后一帧上 —— 看起来就是「相机卡死了」。
        SLVCamTeardownPreview();
        ((SLVProcessSampleBufferFn)orig)(self, _cmd, sbuf);
        return;
    }

    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sbuf);
    if (!fmt) { ((SLVProcessSampleBufferFn)orig)(self, _cmd, sbuf); return; }

    CMMediaType mediaType = CMFormatDescriptionGetMediaType(fmt);
    CMSampleBufferRef fake = NULL;

    if (mediaType == kCMMediaType_Video) {
        CVImageBufferRef img = CMSampleBufferGetImageBuffer(sbuf);
        if (img) {
            OSType pf = CVPixelBufferGetPixelFormatType(img);
            CGSize size = CGSizeMake((CGFloat)CVPixelBufferGetWidth(img),
                                     (CGFloat)CVPixelBufferGetHeight(img));

            // 宿主自己的 fmt 和它自己的 buffer 是否自洽？
            // iOS 17 起 AVCaptureConnection 的旋转会直接作用到 VideoDataOutput 的 buffer 上：
            // buffer 变成竖的（1080x1920），而 fmt 还留着传感器尺寸（1920x1080）。
            // 这种 fmt 拿来做 CMSampleBufferCreateReadyWithImageBuffer 的校验必然不过。
            BOOL fmtMatchesReal = CMVideoFormatDescriptionMatchesImageBuffer(
                (CMVideoFormatDescriptionRef)fmt, img);

            if (!sLoggedFirstVideo) {
                sLoggedFirstVideo = YES;
                CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions((CMVideoFormatDescriptionRef)fmt);
                SLVLog(@"首帧 视频 %zux%zu pf=%u(%@) · fmt %dx%d %@ · 自洽=%@",
                      (size_t)size.width, (size_t)size.height, (unsigned)pf, SLVFourCC(pf),
                      d.width, d.height,
                      SLVFourCC(CMFormatDescriptionGetMediaSubType(fmt)),
                      fmtMatchesReal ? @"Y" : @"N");
                // 宿主到底从帧上取了哪些 key，一次看清 —— 以后崩在这个位置能直接定位
                SLVCamLogAttachmentKeys(sbuf, fmt);
            }

            CMSampleTimingInfo timing = {0};
            timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sbuf);
            timing.decodeTimeStamp       = CMSampleBufferGetDecodeTimeStamp(sbuf);
            timing.duration              = CMSampleBufferGetDuration(sbuf);

            // duration 必须是「有效 + 非负」，否则 CMSampleBufferCreateReady 会以
            // kCMSampleBufferError_InvalidSampleTimingInfo 失败 —— 这个错跟格式无关，
            // 但表现和格式错一模一样（每帧都失败）。采集帧的 duration 经常是 indefinite，
            // 光判 CMTIME_IS_INVALID 拦不住。
            if (!CMTIME_IS_VALID(timing.duration) || CMTimeCompare(timing.duration, kCMTimeZero) < 0) {
                if (sSLCamTimingFixLogged++ == 0) {
                    SLVLog(@"注入: 真帧 duration 非法（value=%lld scale=%d flags=%u），已归一成 1/30",
                          timing.duration.value, timing.duration.timescale, timing.duration.flags);
                }
                timing.duration = CMTimeMake(1, 30);
            }
            if (!CMTIME_IS_VALID(timing.decodeTimeStamp)) {
                if (sSLCamDTSFixLogged++ == 0) {
                    SLVLog(@"注入: 真帧 dts 非法（value=%lld scale=%d flags=%u），已置为 invalid",
                          timing.decodeTimeStamp.value, timing.decodeTimeStamp.timescale,
                          timing.decodeTimeStamp.flags);
                }
                timing.decodeTimeStamp = kCMTimeInvalid;
            }
            if (!CMTIME_IS_VALID(timing.presentationTimeStamp)) {
                // 没有有效的 PTS 就没法接进宿主的时间轴，硬塞一个反而会把下游时序搞乱。
                // 这一帧直接放行真画面，下一帧再说。
                if (sSLCamBadPTS++ == 0) SLVLog(@"注入: 真帧没有有效 PTS，跳过替换");
                ((SLVProcessSampleBufferFn)orig)(self, _cmd, sbuf);
                return;
            }

            // 0.3.8：不再要「自己造的假帧」，而是把宿主这一帧**原地改写**。
            //
            // 前三轮都在猜「我们造的 buffer 缺了哪个属性」，三次全被日志推翻
            // （要的不是 YUV、中心像素正常、行跨度也一致）。真正的问题不是缺属性，
            // 是「buffer 是谁造的」本身：宿主把 IOSurface 拿去建 Metal 纹理，
            // 我们 CVPixelBufferCreate 出来的那种排布它读不出正确内容，画出来就是绿的。
            // 现在直接写进宿主自己的 buffer，指针 / 格式 / 属性全是它熟悉的那个。
            CVPixelBufferRef frame = [feed copyFrameForHostBuffer:img];
            if (frame) {
                // 优先沿用宿主的 fmt（下游的编码器/写入器都按它配置，换了会出岔子）。
                // 只有当假帧确实与它不匹配时，才退而求其次自建一个 —— 自建的那个
                // 必须把宿主的 extensions 带过去，否则宿主读扩展拿到 NULL 会崩。
                //
                // 0.3.8 起这段基本走不到了：frame 通常就是 img 本身，天然匹配。
                CMVideoFormatDescriptionRef useFmt = (CMVideoFormatDescriptionRef)fmt;
                CMVideoFormatDescriptionRef ownFmt = NULL;
                if (!CMVideoFormatDescriptionMatchesImageBuffer((CMVideoFormatDescriptionRef)fmt, frame)) {
                    // 0.3.7：把「为什么判不匹配」摊开打出来。
                    //
                    // MatchesImageBuffer 只比三项：子类型、尺寸、bytesPerRow。
                    // 日志里假帧和宿主 fmt 的子类型（BGRA）、尺寸（1080x1920）都一样，
                    // 那就只可能差在行跨度上 —— 我们的帧是 CVPixelBufferCreate 直出的，
                    // 宿主的是 pixelBufferPool 分配的，两者对齐策略不一定相同。
                    if (sSLCamOwnFmtLogged++ == 0) {
                        CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions((CMVideoFormatDescriptionRef)fmt);
                        CFTypeRef rbv = CMFormatDescriptionGetExtension((CMFormatDescriptionRef)fmt,
                                                                        CFSTR("CVBytesPerRow"));
                        long hostRB = 0;
                        if (rbv && CFGetTypeID(rbv) == CFNumberGetTypeID()) {
                            CFNumberGetValue((CFNumberRef)rbv, kCFNumberLongType, &hostRB);
                        }
                        size_t frameRB = CVPixelBufferGetBytesPerRow(frame);
                        size_t realRB = CVPixelBufferGetBytesPerRow(img);
                        SLVLog(@"注入: 假帧不匹配 · fmt %dx%d %@ 跨度=%ld · 假帧 %zux%zu %@ 跨度=%zu · 真帧跨度=%zu%@",
                              d.width, d.height, SLVFourCC(CMFormatDescriptionGetMediaSubType(fmt)),
                              hostRB,
                              CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame),
                              SLVFourCC(CVPixelBufferGetPixelFormatType(frame)), frameRB,
                              realRB,
                              (hostRB > 0 && (size_t)hostRB != frameRB) ? @" ← 跨度不一致" : @"");
                    }
                    ownFmt = SLVCamMakeFormatDescription(fmt, frame);
                    if (ownFmt) {
                        useFmt = ownFmt;
                        if (sSLCamOwnFmtLogged++ == 0) {
                            CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions((CMVideoFormatDescriptionRef)fmt);
                            // 把自建 fmt 的扩展 key 也打出来 —— 万一抖音那边还崩，
                            // 这一行能直接看出它到底能不能取到内参/色彩矩阵
                            CFDictionaryRef oe = CMFormatDescriptionGetExtensions(ownFmt);
                            NSArray *okeys = oe ? [(__bridge NSDictionary *)oe allKeys] : @[];
                            SLVLog(@"注入: 假帧与宿主 fmt 不匹配，已自建 fmt（帧 %ux%u %@ / fmt %dx%d %@）· 自建扩展 %lu 项 %@",
                                  (unsigned)CVPixelBufferGetWidth(frame),
                                  (unsigned)CVPixelBufferGetHeight(frame),
                                  SLVFourCC(CVPixelBufferGetPixelFormatType(frame)),
                                  d.width, d.height, SLVFourCC(CMFormatDescriptionGetMediaSubType(fmt)),
                                  (unsigned long)okeys.count, okeys);
                        }
                    }
                }

                OSStatus st = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, frame, useFmt,
                                                                       &timing, &fake);
                if (st != noErr && ownFmt) {
                    // 自建 fmt 被拒（-12743 = InvalidMediaFormat 之类）—— 换成「完全从帧
                    // 反推」的 fmt 再试一次。宁可丢扩展，也不能让整帧打包失败：
                    // 打包失败 = 假帧交不出去 = 画面完全不被替换，这是最坏的降级。
                    CMVideoFormatDescriptionRef rawFmt = NULL;
                    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, frame, &rawFmt) == noErr
                        && rawFmt) {
                        OSStatus st2 = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, frame, rawFmt,
                                                                               &timing, &fake);
                        if (st2 == noErr) {
                            if (sSLCamOwnFmtRejectedLogged++ == 0) {
                                SLVLog(@"注入: 自建 fmt 被拒 st=%d，换帧反推 fmt 重试成功", (int)st);
                            }
                            st = noErr;
                        } else {
                            st = st2;
                        }
                        CFRelease(rawFmt);
                    }
                }
                if (st != noErr) {
                    fake = NULL;
                    sSLCamFailCount++;
                    // 前 3 次 + 之后每 120 帧打一条，既能看到细节又不会把日志刷爆
                    if (sSLCamFailCount <= 3 || sSLCamFailCount % 120 == 0) {
                        CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions((CMVideoFormatDescriptionRef)fmt);
                        SLVLog(@"注入: 打包失败 #%d st=%d · fmt %dx%d %@ · 帧 %ux%u %@ · 自洽=%@ · 兜底fmt=%@",
                              sSLCamFailCount, (int)st,
                              d.width, d.height, SLVFourCC(CMFormatDescriptionGetMediaSubType(fmt)),
                              (unsigned)CVPixelBufferGetWidth(frame),
                              (unsigned)CVPixelBufferGetHeight(frame),
                              SLVFourCC(CVPixelBufferGetPixelFormatType(frame)),
                              fmtMatchesReal ? @"Y" : @"N",
                              ownFmt ? @"Y" : @"N");
                    }
                } else {
                    if (sSLCamFailCount > 0) {
                        SLVLog(@"注入: 打包恢复正常（累计失败 %d 次）", sSLCamFailCount);
                        sSLCamFailCount = 0;
                    }
                    // 真帧的附件必须搬到假帧上：宿主那边 CMGetAttachment /
                    // CMCopyDictionaryOfAttachments 拿不到东西，是不判空就 CFRelease 的
                    SLVCamCopySampleAttachments(sbuf, fake);
                }
                if (ownFmt) CFRelease(ownFmt);
                CVPixelBufferRelease(frame);
            }
        }
    } else if (mediaType == kCMMediaType_Audio) {
        // 只要这里有音频流过，就说明宿主的采集音频是走 AVCapture 的，
        // AudioUnit 那条链路必须让路（否则同一个 PCM 池被两处消费，声音会碎）
        sSLCamAVCaptureAudioSeen = YES;

        // 只处理未压缩 PCM；AAC 之类的压缩音频直接放行，避免格式错乱
        if (CMFormatDescriptionGetMediaSubType(fmt) == kAudioFormatLinearPCM) {
            const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
            CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sbuf);
            size_t len = bb ? CMBlockBufferGetDataLength(bb) : 0;

            if (!sLoggedFirstAudio) {
                sLoggedFirstAudio = YES;
                SLVLog(@"首帧 音频 %.0fHz %uch %uB/帧 len=%zu",
                      asbd ? asbd->mSampleRate : 0,
                      asbd ? (unsigned)asbd->mChannelsPerFrame : 0,
                      asbd ? (unsigned)asbd->mBytesPerFrame : 0, len);
            }
            if (asbd && asbd->mBytesPerFrame > 0 && len > 0) {
                NSData *pcm = [feed audioForFormat:asbd numBytes:len];
                if (pcm.length == len) {
                    CMBlockBufferRef newBB = NULL;
                    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, len, kCFAllocatorDefault,
                                                           NULL, 0, len, kCMBlockBufferAssureMemoryNowFlag,
                                                           &newBB) == kCMBlockBufferNoErr) {
                        CMBlockBufferReplaceDataBytes(pcm.bytes, newBB, 0, len);

                        CMSampleTimingInfo t = {0};
                        t.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sbuf);
                        t.duration = CMTimeMake(1, (int32_t)asbd->mSampleRate);
                        CMItemCount frames = (CMItemCount)(len / asbd->mBytesPerFrame);

                        OSStatus ast = CMSampleBufferCreate(kCFAllocatorDefault, newBB, true, NULL, NULL, fmt,
                                                            frames, 1, &t, 0, NULL, &fake);
                        if (ast != noErr) {
                            fake = NULL;
                            sSLCamAudioFailCount++;
                            if (sSLCamAudioFailCount <= 3 || sSLCamAudioFailCount % 300 == 0) {
                                SLVLog(@"注入: 音频打包失败 #%d st=%d · %u 帧 · %zu 字节",
                                      sSLCamAudioFailCount, (int)ast, (unsigned)frames, len);
                            }
                        } else {
                            // 音频帧同样要把宿主的附件带过去，理由和视频一样
                            SLVCamCopySampleAttachments(sbuf, fake);
                        }
                        CFRelease(newBB);
                    }
                }
            }
        }
    }

    // 0.3.23：一次性把「这条 video data output 的 connection」打出来。
    // 宿主写文件时会不会再转一次，取决于它自己的 connection 角度 ——
    // 这个数跟预览层的角度一对比，就知道「文件歪」是不是差在这里。
    if (mediaType == kCMMediaType_Video) {
        static BOOL sLoggedOutConn = NO;
        if (!sLoggedOutConn) {
            sLoggedOutConn = YES;
            @try {
                AVCaptureConnection *c =
                    [(AVCaptureVideoDataOutput *)self connectionWithMediaType:AVMediaTypeVideo];
                if (c) {
                    CVImageBufferRef first = CMSampleBufferGetImageBuffer(sbuf);
                    SLVLog(@"录制: VideoDataOutput 连接 旋转=%ld 镜像=%@ 帧=%zux%zu",
                           (long)SLVCamPreviewRotationDeg(c), c.isVideoMirrored ? @"Y" : @"N",
                           first ? (size_t)CVPixelBufferGetWidth(first) : 0,
                           first ? (size_t)CVPixelBufferGetHeight(first) : 0);
                } else {
                    SLVLog(@"录制: VideoDataOutput 拿不到 video 连接");
                }
            } @catch (NSException *e) {
                SLVLog(@"录制: VideoDataOutput 读连接失败（%@）", e.reason ?: @"?");
            }
        }
    }

    if (fake) {
        // 0.3.21：同一帧也喂给预览层。
        // Turrit 的预览是 AVCaptureVideoPreviewLayer，直连采集设备、不读 data output ——
        // 只改上面那一帧的话，录制是对的、预览还是真实摄像头。
        SLVCamFeedPreview(fake);
        ((SLVProcessSampleBufferFn)orig)(self, _cmd, fake);
        CFRelease(fake);
    } else {
        // 0.3.22：这一帧拿不到假帧，不等于「替换停了」。
        //
        // 音频帧、解码偶尔跟不上、宿主临时换格式，都会走到这里。0.3.21 是一帧
        // 就拆一次显示层，结果预览在「素材 ↔ 真实摄像头」之间一秒闪三次 ——
        // Swiftgram 的「乱闪」就是这么来的。
        // 改成：只有连续两秒都没喂出去帧，才认为替换真的停了。
        if (mediaType == kCMMediaType_Video) SLVCamTeardownPreviewIfStale();
        ((SLVProcessSampleBufferFn)orig)(self, _cmd, sbuf);   // 拿不到假帧就放真帧，绝不黑屏
    }
}

static void SLVCamHookMethod(Class owner, Method m) {
    if (!m) return;
    if (sSLCamHookCount >= SLV_MAX_HOOKS) return;

    for (int i = 0; i < sSLCamHookCount; i++) {
        if (gSLHookMethods[i] == m) return;              // 已经 hook 过
    }

    IMP old = method_getImplementation(m);
    if (old == (IMP)SLVCamProcessSampleBuffer) return;

    gSLHookMethods[sSLCamHookCount] = m;
    gSLHookIMPs[sSLCamHookCount] = old;
    sSLCamHookCount++;

    SLVLog(@"hook -[%s %s] types=%s", class_getName(owner),
          sel_getName(method_getName(m)), method_getTypeEncoding(m));

    method_setImplementation(m, (IMP)SLVCamProcessSampleBuffer);
}

/// 只挂「void + 一个指针参数」的方法。
///
/// 名字带 SampleBuffer 不代表签名就是 (self, _cmd, CMSampleBufferRef)，
/// 万一挂到带 connection 之类的多参方法上，我们的实现会把后面的参数整个丢掉，
/// 宿主当场行为异常。宁可漏挂，不可挂错。
static BOOL SLVCamIsSinglePointerArgMethod(Method m) {
    if (method_getNumberOfArguments(m) != 3) return NO;

    char ret[16] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    if (ret[0] != 'v') return NO;

    char arg[16] = {0};
    method_getArgumentType(m, 2, arg, sizeof(arg));
    return arg[0] == '^';
}

/// 把某个类（含父类）上「像采样缓冲」的方法名列出来，只记日志不挂。
/// 音频输出在各系统版本上的私有方法名不一样，靠这个先看清再动手。
static void SLVCamDumpCandidates(const char *className) {
    Class cls = objc_getClass(className);
    if (!cls) {
        SLVLog(@"探测: %s 不存在", className);
        return;
    }
    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        unsigned int n = 0;
        Method *list = class_copyMethodList(c, &n);
        for (unsigned i = 0; i < n; i++) {
            NSString *name = @(sel_getName(method_getName(list[i])));
            NSString *low = name.lowercaseString;
            if (![low containsString:@"sample"] && ![low containsString:@"buffer"]) continue;
            [hits addObject:[NSString stringWithFormat:@"%s.%@", class_getName(c), name]];
        }
        free(list);
    }
    SLVLog(@"探测: %s → %@", className,
          hits.count ? [hits componentsJoinedByString:@", "] : @"(无)");
}

#pragma mark - 竖采集（0.3.28 引入，0.3.31 彻底移除）

// 这条路的完整经过，留给以后别再试：
//
// Swiftgram 的视频消息是 **400x400 正方形**。正方形上挂 90° 旋转矩阵，
// 转了跟没转在取景上完全一样，只有内容朝向差 90° —— 而它的播放端不认
// track transform（0.3.27 的日志已经把 transform 写进文件了，成品照样歪）。
//
// 于是想：让采集连接直接交出竖的 buffer，像素本身是正的，transform 保持 identity。
//
// **0.3.30 实测结论：这条路不能走。**
//   - 视频消息的方向**还是不对**（buffer 已经变竖 1080x1920、transform 已经是
//     identity，发出去照样歪）；
//   - 更糟的是把**拍照和普通视频录制一起带坏了** —— 整条采集链路的基准都变了。
//
// 收益为零、代价是整个采集管线。0.3.31 起代码整体删除，不再留开关。
//
// 真要再试，只能换成「只在写文件前转帧」（挂 appendSampleBuffer:），
// 绝不能再动 AVCaptureSession。

#pragma mark - 会话输出探测

// App 到底往会话里加了哪些输出？音频是不是走 AVCaptureAudioDataOutput，
// 直接看这个就知道，比猜私有方法名靠谱。
typedef void (*SLVAddOutputFn)(id, SEL, id);
static IMP gSLAddOutputOrig = NULL;

static void SLVCamAddOutput(id self, SEL _cmd, id output) {
    if (output) {
        SLVLog(@"会话加输出: %s", class_getName([output class]));
    }
    if (gSLAddOutputOrig) {
        ((SLVAddOutputFn)gSLAddOutputOrig)(self, _cmd, output);
    }

    // 会话开始装配输出，往往意味着 RTC / 录音 SDK 已经加载完了，
    // 这时候补扫一次符号，把刚才还不存在的镜像覆盖上
    SLVCamInstallAudioUnitHook();
}

// 0.3.29：`addOutput:` 不是唯一的加输出方式。
//
// 0.3.28 的日志里，Swiftgram 的视频消息会话**只有** `会话加输出: AVCaptureAudioDataOutput`
// 这一行 —— 视频输出压根没走 addOutput:，可帧照样在流
// （`录制: VideoDataOutput 连接 旋转=0` 就是它）。所以那一路的连接我们没接住，
// 竖采集对它等于没开。
//
// AVFoundation 里还有另一条公开路径：`addOutputWithNoConnections:` + `addConnection:`。
// 两个都挂上。
static IMP gSLAddOutputNoConnOrig = NULL;

static void SLVCamAddOutputNoConnections(id self, SEL _cmd, id output) {
    if (output) {
        SLVLog(@"会话加输出(手工连线): %s", class_getName([output class]));
    }
    if (gSLAddOutputNoConnOrig) {
        ((SLVAddOutputFn)gSLAddOutputNoConnOrig)(self, _cmd, output);
    }
    // 这条路径下 output 还没有任何连接，真正要等 addConnection: —— 见下面。
    SLVCamInstallAudioUnitHook();
}

static void SLVCamHookSessionOutputs(void) {
    Class cls = objc_getClass("AVCaptureSession");
    if (!cls) return;

    Method m = class_getInstanceMethod(cls, @selector(addOutput:));
    if (m && !gSLAddOutputOrig) {
        gSLAddOutputOrig = method_getImplementation(m);
        method_setImplementation(m, (IMP)SLVCamAddOutput);
    }

    // `addOutput:` 不是唯一的加输出方式：Swiftgram 的视频消息会话走的是
    // `addOutputWithNoConnections:`，日志里只有 `会话加输出(手工连线)` 那一行。
    // 两条都接住，只为了把「会话加了什么」打全 —— 注入本身不依赖它。
    Method mNoConn = class_getInstanceMethod(cls, NSSelectorFromString(@"addOutputWithNoConnections:"));
    if (mNoConn && !gSLAddOutputNoConnOrig) {
        gSLAddOutputNoConnOrig = method_getImplementation(mNoConn);
        method_setImplementation(mNoConn, (IMP)SLVCamAddOutputNoConnections);
    }
}

#pragma mark - 录制音频链路探测（0.2.15）

// 我们目前接了三条音频链路：AudioUnitRender(bus=1)、AVCaptureAudioDataOutput、
// AudioQueueNewInput。QQ 的「拍摄页录制」三条全都没走到 —— 0.2.14 的日志里
// 连新加的「放行真麦克风」一行都没打，说明 audioForFormat: 根本没被调用；
// 而同一个会话只加了 VideoDataOutput / StillImageOutput / MetadataOutput，
// 没有 AudioDataOutput，所以声音是从 capture session 外面进来的。
//
// 下面三条是最可能的入口。这一版**只打日志、不接管**：
// AVAudioEngine 的 tap 能直接改 PCM buffer，AVAudioRecorder 是往文件里写，
// 两套接管方式完全不同 —— 没确认走哪条就写，大概率白做。
static void (*gSLTapOrig)(id, SEL, NSUInteger, AVAudioFrameCount, AVAudioFormat *, id);
static BOOL (*gSLRecorderOrig)(id, SEL);

static void SLVCamAudioTapProbe(id self, SEL _cmd, NSUInteger bus, AVAudioFrameCount frames,
                               AVAudioFormat *fmt, id block) {
    static BOOL logged = NO;
    if (!logged) {
        logged = YES;
        AudioStreamBasicDescription a;
        memset(&a, 0, sizeof(a));
        if (fmt && fmt.streamDescription) a = *fmt.streamDescription;
        SLVLog(@"音频: 命中 AVAudioEngine tap bus=%lu %.0fHz %uch %uB/帧 · 录制走这条",
              (unsigned long)bus, a.mSampleRate,
              (unsigned)a.mChannelsPerFrame, (unsigned)a.mBytesPerFrame);
    }
    if (gSLTapOrig) gSLTapOrig(self, _cmd, bus, frames, fmt, block);
}

static BOOL SLVCamRecorderProbe(id self, SEL _cmd) {
    static BOOL logged = NO;
    if (!logged) {
        logged = YES;
        SLVLog(@"音频: 命中 AVAudioRecorder -record · 录制走写文件路径");
    }
    return gSLRecorderOrig ? gSLRecorderOrig(self, _cmd) : NO;
}

// 0.3.31：录制方向的三条路（setTransform / markAsFinished / startWriting 兜底）
// 和成品 transform 探针全部移除，原因写在 docs/RELEASE_NOTES.md 的 0.3.31 一节：
//
//   · 0.3.27 的探针已经证明 transform 确实进了文件的 tkhd，播放端就是不认；
//   · 0.3.29 的竖采集证明「让 buffer 变竖」也没用，而且会带坏拍照和普通录制。
//
// 结论：这两条路对「视频消息」都是死的。0.3.31 起不再碰 AVAssetWriter，
// 录制完全交回宿主，本 tweak 只负责把采集帧换成素材。


// AVFAudio 是 iOS 14 起独立出来的框架，宿主不一定会主动加载。
// objc_getClass 拿不到就 dlopen 一次再取。
static Class SLVCamLoadClass(const char *name, const char *framework) {
    Class c = objc_getClass(name);
    if (c || !framework) return c;
    if (dlopen(framework, RTLD_LAZY)) return objc_getClass(name);
    return nil;
}

static void SLVCamHookSel(Class cls, SEL sel, IMP imp, IMP *origOut) {
    if (!cls || !sel) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    if (origOut) *origOut = method_getImplementation(m);
    method_setImplementation(m, imp);
}

// 0.3.31：只剩音频探针。
//
// 原来这里还挂着 AVAssetWriterInput / AVAssetWriter / AVAssetExportSession 和
// AVCaptureMovieFileOutput 的录制探针 —— 那是 0.3.23~0.3.27 为了查「录制方向」
// 布的。方向问题两条路都证伪了，探针也跟着一起撤掉：少挂几个类，少一分风险。
//
// 音频这两条留着，麦克风替换出问题时还靠它们定位走的是哪条链路。
static void SLVCamInstallRecordingProbes(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;

    const char *avf = "/System/Library/Frameworks/AVFAudio.framework/AVFAudio";
    Class inputNode = SLVCamLoadClass("AVAudioInputNode", avf);
    SLVCamHookSel(inputNode, NSSelectorFromString(@"installTapOnBus:bufferSize:format:block:"),
                 (IMP)SLVCamAudioTapProbe, (IMP *)&gSLTapOrig);

    Class rec = SLVCamLoadClass("AVAudioRecorder", avf);
    SLVCamHookSel(rec, @selector(record), (IMP)SLVCamRecorderProbe, (IMP *)&gSLRecorderOrig);

    SLVLog(@"探测: 音频链路已布点 tap=%d recorder=%d", inputNode != nil, rec != nil);
}

#pragma mark - 视频消息方向（0.3.32）

// 这一版只做一件事：**在写文件的那一刻把像素转过来**。
//
// 为什么只剩这一条路 —— 前面两条都实测证伪了：
//
//   1. track transform（0.3.27）
//      transform 确实写进了文件的 tkhd matrix（探针读回来了），播放端就是不认。
//      400x400 的正方形视频，转了跟没转在几何上完全等价，转码器很可能直接丢掉。
//
//   2. 让采集连接交出竖 buffer（0.3.28 / 0.3.29）
//      buffer 变成 1080x1920、transform 变成 identity，发出去还是歪。
//      而且改的是整条采集链路的基准，把拍照和普通录制一起带坏了。
//
// 所以这一条：采集一个字节不碰，transform 一个字节不设，
// 只在宿主往 writer 里 append 的那一帧上，把像素顺时针转 90°。
//
// ## 为什么不会误伤普通视频录制
//
// 宿主自己会转的场景（普通视频录制），它会给 `AVAssetWriterInput` 设一个 90° 的
// transform，那种情况我们**一律不动**。
//
// 只有 transform 是 identity 的时候（视频消息就是这样，0.3.30 的日志：
// `录制: setTransform 宿主=[1.00 0.00 -0.00 1.00]`），才说明宿主打算原样写，
// 而我们的假帧是横的 —— 这一帧必须由我们转正。
//
// ## 尺寸安全
//
// append 的 buffer 尺寸一旦跟 writer 期望的对不上，writer 会直接进 failed 状态，
// 整段录制就废了。所以转之前先算：
//
//   · writer 指定了输出尺寸（outputSettings 里有宽高）→ 只有「转完正好等于它」才转；
//   · writer 没指定尺寸（passthrough）→ 尺寸自由，直接转。

static BOOL (*gSLAppendOrig)(id, SEL, CMSampleBufferRef);
static int sSLAppendRotated = 0;
static int sSLAppendSkippedFit = 0;

/// 把一帧 32BGRA 的图像顺时针转 90°，返回新的 sample buffer（调用方负责 CFRelease）。
/// 任何一步不满足都返回 NULL —— 调用方拿到 NULL 就原样 append，绝不能影响录制。
static CMSampleBufferRef SLVCamRotate90SampleBuffer(CMSampleBufferRef src) {
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(src);
    if (!pb) return NULL;

    OSType pf = CVPixelBufferGetPixelFormatType(pb);
    if (pf != kCVPixelFormatType_32BGRA) return NULL;   // vImage 这条路只认 32 位

    size_t w = CVPixelBufferGetWidth(pb);
    size_t h = CVPixelBufferGetHeight(pb);
    if (w < 2 || h < 2) return NULL;

    if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return NULL;
    }

    CVPixelBufferRef dst = NULL;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    if (CVPixelBufferCreate(kCFAllocatorDefault, h, w, pf,
                            (__bridge CFDictionaryRef)attrs, &dst) != kCVReturnSuccess || !dst) {
        CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
        return NULL;
    }

    if (CVPixelBufferLockBaseAddress(dst, 0) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(dst);
        return NULL;
    }

    vImage_Buffer sv = {
        .data     = CVPixelBufferGetBaseAddress(pb),
        .height   = (vImagePixelCount)h,
        .width    = (vImagePixelCount)w,
        .rowBytes = CVPixelBufferGetBytesPerRow(pb),
    };
    vImage_Buffer dv = {
        .data     = CVPixelBufferGetBaseAddress(dst),
        .height   = (vImagePixelCount)w,
        .width    = (vImagePixelCount)h,
        .rowBytes = CVPixelBufferGetBytesPerRow(dst),
    };
    uint8_t back[4] = { 0, 0, 0, 0 };
    // 注意常量名：vImage 这套用的是 kRotate90DegreesClockwise（值 1），
    // 不是别的库里的 kRotateClockwise —— 写错会直接编译不过。
    vImage_Error err = vImageRotate90_ARGB8888(&sv, &dv, kRotate90DegreesClockwise,
                                               back, kvImageNoFlags);

    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);

    if (err != kvImageNoError) {
        CVPixelBufferRelease(dst);
        return NULL;
    }

    CMFormatDescriptionRef newFmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, dst, &newFmt) != noErr
        || !newFmt) {
        CVPixelBufferRelease(dst);
        return NULL;
    }

    // 时间戳必须原样带过去 —— 丢了它 writer 会按 0 写，整段视频时长就乱了。
    // 拿不到就干脆不转，交给宿主原帧（宁可歪，也不能把文件写坏）。
    CMSampleTimingInfo timing;
    if (CMSampleBufferGetSampleTimingInfo(src, 0, &timing) != noErr) {
        CFRelease(newFmt);
        CVPixelBufferRelease(dst);
        return NULL;
    }

    CMSampleBufferRef out = NULL;
    OSStatus st = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, dst, newFmt,
                                                           &timing, &out);
    CFRelease(newFmt);
    CVPixelBufferRelease(dst);
    if (st != noErr || !out) return NULL;
    return out;
}

static BOOL SLVCamAppendSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sb) {
    if (!gSLAppendOrig) return NO;
    if (!sb) return gSLAppendOrig(self, _cmd, sb);

    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sb);
    if (!fmt || CMFormatDescriptionGetMediaType(fmt) != kCMMediaType_Video) {
        return gSLAppendOrig(self, _cmd, sb);
    }

    // 没在替换、或者素材没就绪 —— 这一帧是宿主的真实画面，绝不能转。
    if (!SLVCamInjecting() || !SLVCamArmed()) {
        return gSLAppendOrig(self, _cmd, sb);
    }

    AVAssetWriterInput *inp = (AVAssetWriterInput *)self;
    CGAffineTransform t = CGAffineTransformIdentity;
    NSDictionary *settings = nil;
    @try {
        t = inp.transform;
        settings = inp.outputSettings;
    } @catch (NSException *e) { }

    // 宿主自己会转（普通视频录制）—— 不动。
    BOOL identity = (fabs(t.a - 1.0) < 0.01 && fabs(t.b) < 0.01 &&
                     fabs(t.c) < 0.01 && fabs(t.d - 1.0) < 0.01);
    if (!identity) {
        return gSLAppendOrig(self, _cmd, sb);
    }

    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) return gSLAppendOrig(self, _cmd, sb);
    size_t w = CVPixelBufferGetWidth(pb);
    size_t h = CVPixelBufferGetHeight(pb);

    // 尺寸安全闸：writer 指定了尺寸就必须「转完正好等于它」。
    if (settings) {
        NSNumber *sw = settings[AVVideoWidthKey];
        NSNumber *sh = settings[AVVideoHeightKey];
        NSInteger tw = sw ? sw.integerValue : 0;
        NSInteger th = sh ? sh.integerValue : 0;
        if (tw > 0 && th > 0 && ((size_t)tw != h || (size_t)th != w)) {
            sSLAppendSkippedFit++;
            if (sSLAppendSkippedFit <= 3) {
                SLVLog(@"方向: 跳过转帧 · buffer %zux%zu / writer 目标 %ldx%ld（转完 %zux%zu 对不上）",
                       w, h, (long)tw, (long)th, h, w);
            }
            return gSLAppendOrig(self, _cmd, sb);
        }
    }

    CMSampleBufferRef rotated = SLVCamRotate90SampleBuffer(sb);
    if (!rotated) {
        static BOOL loggedFail = NO;
        if (!loggedFail) {
            loggedFail = YES;
            SLVLog(@"方向: 转帧失败（buffer %zux%zu），本帧原样写", w, h);
        }
        return gSLAppendOrig(self, _cmd, sb);
    }

    sSLAppendRotated++;
    if (sSLAppendRotated == 1 || sSLAppendRotated % 90 == 0) {
        SLVLog(@"方向: 第 %d 帧顺时针转 90° · %zux%zu → %zux%zu（writer transform=identity）",
               sSLAppendRotated, w, h, h, w);
    }

    BOOL ok = gSLAppendOrig(self, _cmd, rotated);
    CFRelease(rotated);
    return ok;
}

static void SLVCamInstallVideoMessageFix(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;

    Class cls = SLVCamLoadClass("AVAssetWriterInput",
                                "/System/Library/Frameworks/AVFoundation.framework/AVFoundation");
    if (!cls) {
        SLVLog(@"方向: AVAssetWriterInput 不存在，跳过");
        return;
    }
    SLVCamHookSel(cls, NSSelectorFromString(@"appendSampleBuffer:"),
                  (IMP)SLVCamAppendSampleBuffer, (IMP *)&gSLAppendOrig);
    SLVLog(@"方向: 写文件转帧已布点 append=%d", gSLAppendOrig != nil);
}

#pragma mark - 拍照接管（0.2.15 引入，0.3.31 移除）

// 这里原来有两条拍照链路：
//   · AVCaptureStillImageOutput 的 captureStillImageAsynchronouslyFromConnection:
//     （QQ 走这条）—— 把 completionHandler 包一层，改传素材转出来的假 JPEG；
//   · AVCapturePhoto 的 fileDataRepresentation / pixelBuffer
//     （抖音 IESMMCaptureKit 走这条）—— 把素材帧原地画进宿主那个 buffer。
//
// 0.3.31 起整体移除：拍照不再是本 tweak 的目标功能，
// 用户明确说「拍摄功能不需要了，只要虚拟摄像头对视频消息替换」。
//
// 移除的收益不只是少两块代码 —— 这两条链路跟录制方向修复搅在一起过
// （0.3.28 的竖采集把拍照方向一起带歪），拆掉之后采集链路回到最朴素的状态：
// 只改 _processSampleBuffer: 交出去的那一帧。

#pragma mark - 预览层接管（0.3.21）

// 为什么需要这一层：
//
// Turrit（Telegram 魔改，com.seastar.turrit）的相机预览是 AVCaptureVideoPreviewLayer，
// 它直连 AVCaptureSession，从**采集设备**直接取画面 —— 完全不经过 AVCaptureVideoDataOutput。
// 所以会出现「录出来的视频是替换素材、预览还是真实摄像头」这种一半生效的怪现象：
// 我们改的是交给 delegate 的那一帧，录制读它，预览层不读。
//
// 预览层没有任何「喂帧」接口，改不了它显示什么。唯一的路是盖住它：
// 在它上面挂一个 AVSampleBufferDisplayLayer，把我们每一帧 enqueue 进去。
//
// 几何不自己算，全部照抄预览层自己的 connection（videoRotationAngle / isVideoMirrored）——
// 猜错一次就是整幅画面歪 90° 或左右反，而这种错在日志里看不出来，只能靠试。

static char kSLPreviewDisplayKey;

// 0.3.28：最后一次拿到的「有效角度」。connection 变 nil 时靠它继续摆几何。
static char kSLPreviewDegKey;

static NSHashTable *gSLPreviewLayers = nil;   // 弱引用：预览层归 App 持有，我们不延长它的命
static os_unfair_lock gSLPreviewLock = OS_UNFAIR_LOCK_INIT;   // 建层在主线程、喂帧在采集线程
static IMP gSLPreviewInitOrig = NULL;
static IMP gSLPreviewSetSessionOrig = NULL;
static BOOL gSLPreviewMounted = NO;
static BOOL gSLPreviewFedLogged = NO;
static CFAbsoluteTime gSLPreviewLastSync = 0.0;
static CFAbsoluteTime gSLPreviewLastFed = 0.0;   // 最后一次成功喂帧的时刻，用来判「替换是不是真停了」

static void SLVCamRegisterPreviewLayer(id layer);

/// App 建预览层只有两个入口：initWithSession: 和 setSession:。
/// 两个都挂 —— 有的版本先 init 空会话、拿到设备后再 setSession:。
static id SLVCamPreviewInitWithSession(id self, SEL _cmd, AVCaptureSession *session) {
    id (*fn)(id, SEL, id) = (id (*)(id, SEL, id))gSLPreviewInitOrig;
    id r = fn ? fn(self, _cmd, session) : nil;
    if (r) SLVCamRegisterPreviewLayer(r);
    return r;
}

static void SLVCamPreviewSetSession(id self, SEL _cmd, AVCaptureSession *session) {
    void (*fn)(id, SEL, AVCaptureSession *) =
        (void (*)(id, SEL, AVCaptureSession *))gSLPreviewSetSessionOrig;
    if (fn) fn(self, _cmd, session);
    SLVCamRegisterPreviewLayer(self);
}

static void SLVCamRegisterPreviewLayer(id layer) {
    if (![layer isKindOfClass:[AVCaptureVideoPreviewLayer class]]) return;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gSLPreviewLayers = [NSHashTable weakObjectsHashTable];
    });

    BOOL added = NO;
    os_unfair_lock_lock(&gSLPreviewLock);
    if (![gSLPreviewLayers containsObject:layer]) {
        [gSLPreviewLayers addObject:layer];
        added = YES;
    }
    os_unfair_lock_unlock(&gSLPreviewLock);
    if (!added) return;

    AVCaptureVideoPreviewLayer *pl = (AVCaptureVideoPreviewLayer *)layer;
    SLVLog(@"预览: 抓到 AVCaptureVideoPreviewLayer 尺寸=%.0fx%.0f 会话=%@",
           pl.bounds.size.width, pl.bounds.size.height,
           pl.session ? @"有" : @"无");
}

/// 取一份预览层的快照。弱表会在对象释放时自动剔除，但读的时候要加锁。
static NSArray *SLVCamPreviewLayerSnapshot(void) {
    if (!gSLPreviewLayers) return @[];
    os_unfair_lock_lock(&gSLPreviewLock);
    NSArray *snap = gSLPreviewLayers.allObjects;
    os_unfair_lock_unlock(&gSLPreviewLock);
    return snap ?: @[];
}

/// 预览层怎么转，我们就怎么转。
/// 一律读它自己的 connection，不按「竖屏应该转 90」这类经验猜。
static NSInteger SLVCamPreviewRotationDeg(AVCaptureConnection *conn) {
    if (!conn) return 0;
    NSInteger deg = 0;
    if (@available(iOS 17.0, *)) {
        deg = (NSInteger)(conn.videoRotationAngle + 0.5);
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        switch (conn.videoOrientation) {
            case AVCaptureVideoOrientationPortrait:           deg = 90;  break;
            case AVCaptureVideoOrientationPortraitUpsideDown: deg = 270; break;
            case AVCaptureVideoOrientationLandscapeRight:     deg = 180; break;
            case AVCaptureVideoOrientationLandscapeLeft:      deg = 0;   break;
            default:                                          deg = 0;   break;
        }
#pragma clang diagnostic pop
    }
    return ((deg % 360) + 360) % 360;
}

// 0.3.31：这个包装函数只剩一句了。
//
// 0.3.28/0.3.29 时它还要处理「竖采集模式下角度要减 90°」—— 竖采集整体移除后，
// 预览层的 connection 角度就是唯一真相，直接用它。
// 保留函数名是为了让下面的调用点读起来还有「有效角度」这层意思。
static NSInteger SLVCamEffectivePreviewDeg(AVCaptureConnection *conn) {
    return SLVCamPreviewRotationDeg(conn);
}

// 0.3.23：这个预览层现在真的在屏幕上吗？
//
// Swiftgram 一次会话里同时挂着两个预览层（4:3 前置 369x492 镜像=Y、
// 16:9 后置 369x656 镜像=N）。切换摄像头时它不是销毁旧的，而是把旧的藏起来。
// 0.3.22 只判断了 superlayer，藏起来的那个照样每帧喂帧 —— 它的 bounds 一变，
// ResizeAspectFill 就重算一次裁切，屏幕上看到的就是「录制过程中画面突然放大一下」。
//
// CALayer 的 hidden / opacity 不会往下传，所以要顺着 superlayer 一路查上去。
static BOOL SLVCamPreviewLayerVisible(AVCaptureVideoPreviewLayer *pl) {
    if (!pl) return NO;
    if (pl.isHidden) return NO;
    if (pl.opacity < 0.01f) return NO;
    if (pl.bounds.size.width < 8.0 || pl.bounds.size.height < 8.0) return NO;

    // 预览层的 delegate 通常是承载它的 UIView，能借此判断「还在不在窗口里」
    id d = pl.delegate;
    if ([d isKindOfClass:[UIView class]]) {
        if (!((UIView *)d).window) return NO;
    }

    CALayer *p = pl.superlayer;
    int guard = 0;
    while (p && guard++ < 16) {
        if (p.hidden) return NO;
        if (p.opacity < 0.01f) return NO;
        p = p.superlayer;
    }
    return YES;
}

// 0.3.23：bounds 变化要「连续两次读到同一个新值」才应用。
//
// 布局动画、键盘弹出、切换摄像头时的过渡，都会让 pl.bounds 连续几帧微调。
// 原来每 0.25 秒对一次、差 0.5px 就改，于是裁切跟着一格一格重算 —— 录屏里
// 4.79 秒那一下「人物突然放大 8%」就是这么来的。
//
// 但大幅度变化（换方向、换层、从 0x0 变成有尺寸）必须立刻生效，否则会一直卡在旧尺寸。
static char kSLPreviewPendingSizeKey;

// 0.3.29：预览层自己的尺寸变没变。
//
// 原来几何同步固定 0.25 秒一次 —— 录制一开始取景框要长到全屏，那是段动画，
// 每帧尺寸都不一样，0.25 秒只跟得上四步，剩下的时间覆盖层比取景框小，
// 底下就是真实摄像头。现在只要尺寸变了就立刻对一次。
static char kSLPreviewSeenSizeKey;
static char kSLPreviewUrgentKey;

static BOOL SLVCamPreviewSizeChanged(AVCaptureVideoPreviewLayer *pl) {
    CGRect b = pl.bounds;
    NSString *cur = [NSString stringWithFormat:@"%.1fx%.1f", b.size.width, b.size.height];
    NSString *last = objc_getAssociatedObject(pl, &kSLPreviewSeenSizeKey);
    if ([last isEqualToString:cur]) return NO;
    objc_setAssociatedObject(pl, &kSLPreviewSeenSizeKey, cur, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // 顺带告诉几何同步：这一次别走「两次确认」，直接跟。
    objc_setAssociatedObject(pl, &kSLPreviewUrgentKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

static BOOL SLVCamPreviewSizeStable(AVCaptureVideoPreviewLayer *pl, CGFloat lw, CGFloat lh) {
    NSString *cur = [NSString stringWithFormat:@"%.1fx%.1f", lw, lh];
    NSString *last = objc_getAssociatedObject(pl, &kSLPreviewPendingSizeKey);
    if (last) {
        NSArray *parts = [last componentsSeparatedByString:@"|"];
        NSString *lastSize = parts.count > 0 ? parts[0] : @"";
        int n = parts.count > 1 ? [parts[1] intValue] : 0;
        if ([lastSize isEqualToString:cur]) {
            n++;
            objc_setAssociatedObject(pl, &kSLPreviewPendingSizeKey,
                [NSString stringWithFormat:@"%@|%d", cur, n], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return n >= 2;
        }
    }
    objc_setAssociatedObject(pl, &kSLPreviewPendingSizeKey,
        [NSString stringWithFormat:@"%@|1", cur], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return NO;
}

/// 把显示层的几何对齐到预览层。
///
/// 90/270 度时把显示层的 bounds 宽高互换：内容先按「横过来的那个矩形」排版，
/// 再由 transform 整体转 90° —— 转完正好铺满预览层的竖屏矩形。
/// 直接拿竖屏矩形去排版会让 4:3 的画面被当成 3:4 来裁，人脸直接出画。
static void SLVCamSyncPreviewGeometry(AVCaptureVideoPreviewLayer *pl) {
    AVSampleBufferDisplayLayer *dl = objc_getAssociatedObject(pl, &kSLPreviewDisplayKey);
    if (!dl) return;

    CGRect pb = pl.bounds;
    CGFloat pw = pb.size.width, ph = pb.size.height;
    if (pw < 8.0 || ph < 8.0) return;

    // 0.3.29：取景框这一帧刚变过尺寸 → 别走「两次确认」，立刻跟。
    BOOL urgent = [objc_getAssociatedObject(pl, &kSLPreviewUrgentKey) boolValue];
    if (urgent) {
        objc_setAssociatedObject(pl, &kSLPreviewUrgentKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    AVCaptureConnection *conn = pl.connection;
    BOOL connGone = (conn == nil);
    NSInteger deg = 0;

    if (!connGone) {
        deg = SLVCamEffectivePreviewDeg(conn);
        // 记下最后一次拿到的角度。会话重配时 connection 会短暂变 nil，
        // 那时候就用这个缓存值继续摆 —— 角度没变，画面不会歪。
        objc_setAssociatedObject(pl, &kSLPreviewDegKey, @(deg), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        // 0.3.28：**不再直接 return**。
        //
        // 0.3.22 当初这么写是为了避免「当成 0 度去改几何，画面歪一下」，
        // 但代价是：一开始录制 connection 就变 nil，几何同步整段停摆 ——
        // 取景框在长大，显示层钉在原地，下面露出真实摄像头。
        // 14:12 那段录屏里录制全程底下漏着真实画面，就是这么来的。
        //
        // 现在改成：用缓存角度继续同步 bounds 和 position，角度不猜、不变，
        // 只是让覆盖层跟着取景框走。
        NSNumber *cached = objc_getAssociatedObject(pl, &kSLPreviewDegKey);
        if (!cached) {
            // 一次都没拿到过角度 —— 那就先按面积铺满，等 connection 回来再摆正。
            dl.bounds = CGRectMake(0.0, 0.0, pw, ph);
            dl.position = CGPointMake(CGRectGetMidX(pb), CGRectGetMidY(pb));
            return;
        }
        deg = cached.integerValue;
    }

    BOOL swap = (deg == 90 || deg == 270);
    CGFloat lw = swap ? ph : pw;
    CGFloat lh = swap ? pw : ph;

    if (fabs(dl.bounds.size.width - lw) > 0.5 || fabs(dl.bounds.size.height - lh) > 0.5) {
        // 0.3.23：小幅度抖动要两次确认，大幅度变化立刻生效。
        // 0.3.28：connection 掉了的时候不做「两次确认」—— 这时候取景框多半在动画里，
        // 每一帧尺寸都不一样，等它稳定下来就是永远等不到，只能每帧立刻跟。
        CGFloat cw0 = dl.bounds.size.width, ch0 = dl.bounds.size.height;
        BOOL big = (cw0 < 1.0 || ch0 < 1.0)
                || (fabs(cw0 - lw) / MAX(lw, 1.0) > 0.15)
                || (fabs(ch0 - lh) / MAX(lh, 1.0) > 0.15);
        if (big || urgent || connGone || SLVCamPreviewSizeStable(pl, lw, lh)) {
            dl.bounds = CGRectMake(0.0, 0.0, lw, lh);
        }
    }
    CGPoint pos = CGPointMake(CGRectGetMidX(pb), CGRectGetMidY(pb));
    if (!CGPointEqualToPoint(dl.position, pos)) dl.position = pos;

    CATransform3D t = CATransform3DMakeRotation(deg * M_PI / 180.0, 0.0, 0.0, 1.0);

    // 0.3.26：**不再**叠 connection 的镜像。
    //
    // 喂进来的 fake 帧是我们按「用户设置」渲染出来的**最终画面** —— 用户要镜像的话
    // `sl_image:` 里已经翻过一道了。这里再按 `conn.isVideoMirrored` 翻一次，
    // 预览就比文件多翻一道，表现就是「录制时预览和发送后方向对不上」。
    //
    // Swiftgram 的实测：4:3 前置层是 `镜像=Y`，而文件那边的 transform 只有旋转
    // （`[a=0 b=1 c=-1 d=0]`，没有 -1 的缩放分量），两边正好差一个水平翻转。
    // 旋转 90° 叠上镜像，视觉上就成了「歪向另一边」，比单纯镜像更迷惑人。
    //
    // 预览层和文件现在用同一套几何：只转，不翻。要镜像就改设置里的开关，
    // 那一条路会在渲染时生效，预览和文件同时变。
    dl.transform = t;

    static BOOL sLoggedGeom = NO;
    if (!sLoggedGeom) {
        sLoggedGeom = YES;
        SLVLog(@"预览: 几何 预览=%.0fx%.0f 旋转=%ld 显示层=%.0fx%.0f 镜像=不叠（fake 帧已定）",
               pw, ph, (long)deg, lw, lh);
    }
}

/// 挂载 + 对齐几何。**必须在主线程**：CALayer 的属性改动不能从采集线程直接来。
static void SLVCamMountPreviewDisplay(AVCaptureVideoPreviewLayer *pl) {
    if (!pl || !pl.superlayer) return;

    // 0.3.22：尺寸还没定下来（0x0）就别挂。Swiftgram 的日志里就有
    // 「挂上显示层 预览=0x0 会话=有」—— 一块零面积的层，白建一套渲染面。
    // 等它有了尺寸，下一帧自然会再进来一次。
    if (pl.bounds.size.width < 8.0 || pl.bounds.size.height < 8.0) return;

    // 0.3.23：藏起来的预览层不挂。挂着它就会跟着喂帧，bounds 一变就重算裁切。
    if (!SLVCamPreviewLayerVisible(pl)) return;

    AVSampleBufferDisplayLayer *dl = objc_getAssociatedObject(pl, &kSLPreviewDisplayKey);
    if (!dl) {
        dl = [[AVSampleBufferDisplayLayer alloc] init];
        dl.videoGravity = AVLayerVideoGravityResizeAspectFill;
        dl.masksToBounds = YES;
        dl.backgroundColor = [UIColor blackColor].CGColor;
        [pl addSublayer:dl];
        objc_setAssociatedObject(pl, &kSLPreviewDisplayKey, dl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        gSLPreviewMounted = YES;
        // 刚挂上就起算「两秒宽限」：否则第一帧要是恰好没出图，
        // 时间戳还停在 0，会被立刻判成「替换停了」而拆掉。
        gSLPreviewLastFed = CFAbsoluteTimeGetCurrent();

        AVCaptureConnection *conn = pl.connection;
        SLVLog(@"预览: 挂上显示层 预览=%.0fx%.0f 会话=%@ 连接=%@ 旋转=%ld 镜像=%@",
               pl.bounds.size.width, pl.bounds.size.height,
               pl.session ? @"有" : @"无",
               conn ? @"有" : @"无",
               (long)SLVCamPreviewRotationDeg(conn),
               (conn && conn.isVideoMirrored) ? @"Y" : @"N");
    }
    SLVCamSyncPreviewGeometry(pl);
}

/// 复制一份 sample buffer 给显示层用。
///
/// 不复用原帧直接 enqueue 是有意的：显示层会一直持有那个 buffer 直到画完，
/// 而原帧是宿主采集池里的 —— 池子通常只有三五个，被我们扣住一个，
/// 采集管线就可能开始丢帧。复制的是元数据、像素仍是共享的，代价可以忽略。
static CMSampleBufferRef SLVCamMakeDisplayBuffer(CMSampleBufferRef src) {
    CMSampleBufferRef out = NULL;
    if (CMSampleBufferCreateCopy(kCFAllocatorDefault, src, &out) != noErr || !out) return NULL;

    // 显示层默认按 PTS 排期。相机帧的 PTS 是真实时间，通常没问题；
    // 但一切换前后摄、一重开会话，PTS 就可能跳一大截，画面会卡在上一帧干等。
    // 加这一条让它「拿到就画」。
    CMSetAttachment(out, kCMSampleAttachmentKey_DisplayImmediately,
                    kCFBooleanTrue, kCMAttachmentMode_ShouldPropagate);
    return out;
}

// 0.3.25：帧要喂给「比例对得上」的那个预览层。
//
// Swiftgram 同时挂两路 video data output 和两个预览层：
//   1920x1440（4:3）  ↔ 369x492（4:3）
//   1920x1080（16:9） ↔ 369x656（16:9）
//
// 0.3.22~0.3.24 是每一帧广播给**所有**层。于是 4:3 的帧被喂进 16:9 的层、
// 16:9 的帧被喂进 4:3 的层，ResizeAspectFill 只能大幅裁切；两路交替喂，
// 画面就在两种裁切之间来回跳 —— 这才是「录制时还在闪」真正剩下的那一半。
//
// 判据：把帧按 connection 的角度转正之后，宽高比跟预览层差 12% 以内算匹配。
// 12% 是留给 428x571 / 1440x1920 这种「同一比例但取整不同」的余量。
static BOOL SLVCamFrameFitsLayer(CMSampleBufferRef sb, AVCaptureVideoPreviewLayer *pl) {
    CVImageBufferRef img = CMSampleBufferGetImageBuffer(sb);
    if (!img) return NO;

    CGFloat fw = (CGFloat)CVPixelBufferGetWidth(img);
    CGFloat fh = (CGFloat)CVPixelBufferGetHeight(img);
    if (fw < 1.0 || fh < 1.0) return NO;

    // 角度直接用预览层 connection 自己的值 —— 竖采集移除后没有第二套角度了。
    NSInteger deg = SLVCamEffectivePreviewDeg(pl.connection);
    if (deg == 90 || deg == 270) { CGFloat t = fw; fw = fh; fh = t; }

    CGRect b = pl.bounds;
    if (b.size.width < 1.0 || b.size.height < 1.0) return NO;

    CGFloat fr = fw / fh;
    CGFloat lr = b.size.width / b.size.height;
    return fabs(fr - lr) / MAX(lr, 0.0001) < 0.12;
}

/// 把这一帧也喂给预览层（如果有的话）。采集线程调用。
static void SLVCamFeedPreview(CMSampleBufferRef sb) {
    if (!gSLPreviewLayers) return;
    if (!sb) return;
    if (!CMSampleBufferGetImageBuffer(sb)) return;   // 音频帧直接跳过

    NSArray *layers = SLVCamPreviewLayerSnapshot();
    if (layers.count == 0) return;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL wantSync = (now - gSLPreviewLastSync) > 0.25;   // 几何变化（转屏 / 换布局）不需要每帧对
    if (wantSync) gSLPreviewLastSync = now;

    // 0.3.25：先数一遍「有几层比例对得上」。一个都没有就不做过滤，退回「全喂」——
    // 否则只挂一层、但比例特殊的 App（抖音的 9:16 预览之类）会一帧都收不到。
    NSUInteger fitCount = 0;
    for (AVCaptureVideoPreviewLayer *pl in layers) {
        if (![pl isKindOfClass:[AVCaptureVideoPreviewLayer class]]) continue;
        if (!SLVCamPreviewLayerVisible(pl)) continue;
        if (SLVCamFrameFitsLayer(sb, pl)) fitCount++;
    }
    BOOL filterByRatio = (fitCount > 0);

    // 0.3.22：一帧只复制一次，几个预览层共用。
    // 原来是在循环里各复制一份，两个预览层就多一次 3MB 的元数据拷贝 + 一次 retain。
    CMSampleBufferRef disp = NULL;

    for (AVCaptureVideoPreviewLayer *pl in layers) {
        if (![pl isKindOfClass:[AVCaptureVideoPreviewLayer class]]) continue;
        // 0.3.23：藏起来 / 透明的预览层一律跳过。
        // 原来只判 superlayer，Swiftgram 那两层里被藏起来的那一层照样每帧喂，
        // 它的 bounds 一变，屏幕上正在显示的那层就跟着「放大一下」。
        if (!SLVCamPreviewLayerVisible(pl)) continue;
        // 0.3.25：比例对不上的层也跳过（只在有匹配层时才过滤）
        if (filterByRatio && !SLVCamFrameFitsLayer(sb, pl)) continue;

        AVSampleBufferDisplayLayer *dl = objc_getAssociatedObject(pl, &kSLPreviewDisplayKey);
        if (!dl) {
            // 挂载动作丢到主线程，这一帧先跳过 —— 下一帧就能接上
            dispatch_async(dispatch_get_main_queue(), ^{
                SLVCamMountPreviewDisplay(pl);
            });
            continue;
        }
        if (wantSync || SLVCamPreviewSizeChanged(pl)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                SLVCamSyncPreviewGeometry(pl);
            });
        }

        if (!disp) disp = SLVCamMakeDisplayBuffer(sb);
        if (!disp) break;

        if (dl.status == AVQueuedSampleBufferRenderingStatusFailed) {
            // 显示层一旦进入 failed 就再也不出画面，必须 flush 才能恢复
            if (!gSLPreviewFedLogged) {
                SLVLog(@"预览: 显示层失败（%@），已 flush 重来",
                       dl.error.localizedDescription ?: @"?");
            }
            [dl flush];
        } else if (!dl.isReadyForMoreMediaData) {
            // 0.3.22：显示层还没画完上一帧就别再塞 —— 让它自己追上，
            // 否则队列越积越长，画面延迟越来越大，采集池也会被扣住。
            continue;
        }
        [dl enqueueSampleBuffer:disp];
        gSLPreviewLastFed = now;

        if (!gSLPreviewFedLogged) {
            gSLPreviewFedLogged = YES;
            CVImageBufferRef img = CMSampleBufferGetImageBuffer(sb);
            SLVLog(@"预览: 开始喂帧 帧=%zux%zu 预览=%.0fx%.0f 状态=%ld",
                   (size_t)CVPixelBufferGetWidth(img), (size_t)CVPixelBufferGetHeight(img),
                   pl.bounds.size.width, pl.bounds.size.height, (long)dl.status);
        }
    }
    if (disp) CFRelease(disp);
}

/// 0.3.22：只有「连续两秒都没喂出去帧」才认为替换真的停了。
///
/// 0.3.21 是「这一帧拿不到假帧就拆」，结果音频帧、解码偶尔跟不上都会触发，
/// 预览就在「素材 ↔ 真实摄像头」之间一秒闪三次。拿不到帧不等于停了。
static void SLVCamTeardownPreviewIfStale(void) {
    if (!gSLPreviewMounted) return;
    if (CFAbsoluteTimeGetCurrent() - gSLPreviewLastFed < 2.0) return;
    SLVCamTeardownPreview();
}

/// 撤掉显示层，恢复原生预览。替换关掉、或这一帧拿不到假帧时调用。
static void SLVCamTeardownPreview(void) {
    if (!gSLPreviewMounted || !gSLPreviewLayers) return;
    gSLPreviewMounted = NO;

    NSArray *layers = SLVCamPreviewLayerSnapshot();
    for (AVCaptureVideoPreviewLayer *pl in layers) {
        if (![pl isKindOfClass:[AVCaptureVideoPreviewLayer class]]) continue;
        AVSampleBufferDisplayLayer *dl = objc_getAssociatedObject(pl, &kSLPreviewDisplayKey);
        if (!dl) continue;
        objc_setAssociatedObject(pl, &kSLPreviewDisplayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_async(dispatch_get_main_queue(), ^{
            [dl removeFromSuperlayer];
        });
    }
    gSLPreviewFedLogged = NO;
    SLVLog(@"预览: 撤掉显示层，恢复原生预览");
}

static void SLVCamInstallPreviewLayerHook(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;

    Class cls = objc_getClass("AVCaptureVideoPreviewLayer");
    if (!cls) {
        SLVLog(@"预览: AVCaptureVideoPreviewLayer 不存在，跳过");
        return;
    }
    SLVCamHookSel(cls, NSSelectorFromString(@"initWithSession:"),
                  (IMP)SLVCamPreviewInitWithSession, &gSLPreviewInitOrig);
    SLVCamHookSel(cls, NSSelectorFromString(@"setSession:"),
                  (IMP)SLVCamPreviewSetSession, &gSLPreviewSetSessionOrig);
    SLVLog(@"预览: 预览层接管已布点 init=%d setSession=%d",
          gSLPreviewInitOrig != nil, gSLPreviewSetSessionOrig != nil);
}

void SLVCamInstallHooks(void) {
    if (sSLCamHooksInstalled) return;
    sSLCamHooksInstalled = YES;

    // 不写死 selector：这几个类及其父类上凡是名字带 samplebuffer 的都挂上
    NSArray<NSString *> *classNames = @[
        @"AVCaptureVideoDataOutput",
        @"AVCaptureAudioDataOutput",
        @"AVCaptureMovieFileOutput",
        @"AVCapturePhotoOutput",
        @"AVCaptureOutput",
    ];

    // 跳过的这些方法每次启动都是固定的那几条，逐条打会把日志顶满。
    // 攒起来合成一行 —— 信息一条不少，占用从 6 行变 1 行。
    NSMutableArray<NSString *> *skipped = [NSMutableArray array];

    for (NSString *cn in classNames) {
        Class cls = objc_getClass(cn.UTF8String);
        if (!cls) continue;
        for (Class c = cls; c; c = class_getSuperclass(c)) {
            unsigned int n = 0;
            Method *list = class_copyMethodList(c, &n);
            for (unsigned i = 0; i < n; i++) {
                NSString *name = @(sel_getName(method_getName(list[i]))).lowercaseString;
                if (![name containsString:@"samplebuffer"]) continue;
                if (!SLVCamIsSinglePointerArgMethod(list[i])) {
                    [skipped addObject:[NSString stringWithFormat:@"-[%s %s]",
                                        class_getName(c), sel_getName(method_getName(list[i]))]];
                    continue;
                }
                SLVCamHookMethod(c, list[i]);
            }
            free(list);
        }
    }

    if (skipped.count) {
        SLVLog(@"注入: 跳过 %lu 个方法（签名不是单指针参数，挂了会丢参）: %@",
              (unsigned long)skipped.count, [skipped componentsJoinedByString:@", "]);
    }

    // 音频在各系统版本上未必走 AVCaptureAudioDataOutput，先把候选方法名和
    // 会话里实际加了哪些输出打出来，下次日志就能定位
    SLVCamDumpCandidates("AVCaptureAudioDataOutput");
    SLVCamDumpCandidates("AVCaptureAudioPreviewOutput");
    SLVCamHookSessionOutputs();

    // 第二条链路：不经过 AVCapture 的麦克风（QQ 这类自建音频栈的 App）
    SLVCamInstallAudioUnitHook();

    // 音频探针（AVAudioEngine tap / AVAudioRecorder）
    SLVCamInstallRecordingProbes();

    // 0.3.32：视频消息的方向 —— 只在写文件那一刻转帧，别的一概不碰
    SLVCamInstallVideoMessageFix();

    // 第四条：预览层。Turrit 这类 App 的预览直连采集设备，不走任何 data output，
    // 上面几条全都碰不到它。
    SLVCamInstallPreviewLayerHook();

    if (sSLCamHookCount == 0) {
        SLVLog(@"注入: 没找到 _processSampleBuffer: —— 该系统版本可能改了私有 API，"
              @"可用日志页确认后换挂点");
    } else {
        SLVLog(@"注入: 共 hook %d 个方法", sSLCamHookCount);
    }
}

void SLVCamSetInjecting(BOOL injecting) {
    if (sSLCamInjecting == injecting) return;
    sSLCamInjecting = injecting;
    SLVLog(@"injecting = %@", injecting ? @"YES" : @"NO");
}

BOOL SLVCamInjecting(void) {
    return sSLCamInjecting;
}

BOOL SLVCamHooksInstalled(void) {
    return sSLCamHooksInstalled;
}

int SLVCamHookCount(void) {
    return sSLCamHookCount;
}

BOOL SLVCamAVCaptureAudioSeen(void) {
    return sSLCamAVCaptureAudioSeen;
}
