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
                    SLVLog(@"录制: VideoDataOutput 连接 旋转=%ld 镜像=%@",
                           (long)SLVCamPreviewRotationDeg(c), c.isVideoMirrored ? @"Y" : @"N");
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

#pragma mark - 竖采集（0.3.28）

// Swiftgram 的视频消息是 **400x400 正方形**。正方形上挂 90° 旋转矩阵，
// 转了跟没转在取景上完全一样，只有内容朝向差 90° —— 而它的播放端不认
// track transform（0.3.27 的日志已经把 transform 写进文件了，成品照样歪）。
//
// 所以 transform 这条路对视频消息是死路。唯一能治本的办法：
// **让采集连接直接交出竖的 buffer**，像素本身是正的，transform 保持 identity。
//
// 代价是预览层的 connection 还停在 90°（那个我们不动，宿主自己在用），
// 所以「预览层角度」要减掉这 90°，才等于现在这一帧真实的摆法。
static NSInteger const SLVPortraitDeg = 90;

/// 只有 Swiftgram 走这条。别的 App（抖音 / 陌陌 / QQ / Turrit）现在都是好的，
/// 不能因为一个 App 的问题把它们的采集管线一起改了。
static BOOL SLVCamPortraitCapture(void) {
    static BOOL on = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        on = [bid isEqualToString:@"app.swiftgram.ios"];
    });
    return on;
}

/// 这条连接是不是视频数据输出。预览层的 connection `output` 是 nil，
/// 拍照输出是 AVCapturePhotoOutput —— 后者绝对不能碰，照片方向现在是对的。
static BOOL SLVCamIsVideoDataConnection(AVCaptureConnection *conn) {
    if (!conn) return NO;
    id out = nil;
    @try { out = conn.output; } @catch (NSException *e) { }
    return [out isKindOfClass:[AVCaptureVideoDataOutput class]];
}

/// 把一条视频数据输出连接掰成竖的。已经是竖的就什么都不做。
static void SLVCamForcePortraitConnection(AVCaptureConnection *conn, const char *why) {
    if (!conn || !SLVCamIsVideoDataConnection(conn)) return;

    if (@available(iOS 17.0, *)) {
        if (fabs(conn.videoRotationAngle - (double)SLVPortraitDeg) < 0.5) return;
        conn.videoRotationAngle = (CGFloat)SLVPortraitDeg;
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (conn.videoOrientation == AVCaptureVideoOrientationPortrait) return;
        conn.videoOrientation = AVCaptureVideoOrientationPortrait;
#pragma clang diagnostic pop
    }
    SLVLog(@"竖采集: %s → 视频输出连接改成 %ld°（让 buffer 本身就是竖的）",
           why ? why : "?", (long)SLVPortraitDeg);
}

/// 宿主自己会设 0°，设完我们的就没了 —— 所以把 setter 也接住。
typedef void (*SLVSetRotAngleFn)(id, SEL, CGFloat);
static SLVSetRotAngleFn gSLSetRotAngleOrig = NULL;

static void SLVCamSetVideoRotationAngle(id self, SEL _cmd, CGFloat angle) {
    CGFloat use = angle;
    if (SLVCamPortraitCapture() && SLVCamIsVideoDataConnection((AVCaptureConnection *)self)) {
        use = (CGFloat)SLVPortraitDeg;
    }
    if (gSLSetRotAngleOrig) gSLSetRotAngleOrig(self, _cmd, use);
}

typedef void (*SLVSetOrientationFn)(id, SEL, NSInteger);
static SLVSetOrientationFn gSLSetOrientationOrig = NULL;

static void SLVCamSetVideoOrientation(id self, SEL _cmd, NSInteger orientation) {
    NSInteger use = orientation;
    if (SLVCamPortraitCapture() && SLVCamIsVideoDataConnection((AVCaptureConnection *)self)) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        use = AVCaptureVideoOrientationPortrait;
#pragma clang diagnostic pop
    }
    if (gSLSetOrientationOrig) gSLSetOrientationOrig(self, _cmd, use);
}

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

    // 0.3.28：刚加进来的视频输出立刻掰成竖的，别等第一帧。
    // 晚一步的代价是第一帧还是横的，宿主的 writer 可能就按横的定下来了。
    if (output && SLVCamPortraitCapture() &&
        [output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
        @try {
            AVCaptureConnection *c =
                [(AVCaptureOutput *)output connectionWithMediaType:AVMediaTypeVideo];
            SLVCamForcePortraitConnection(c, "addOutput");
        } @catch (NSException *e) { }
    }

    // 会话开始装配输出，往往意味着 RTC / 录音 SDK 已经加载完了，
    // 这时候补扫一次符号，把刚才还不存在的镜像覆盖上
    SLVCamInstallAudioUnitHook();
}

static void SLVCamHookSessionOutputs(void) {
    Class cls = objc_getClass("AVCaptureSession");

    // 0.3.28：连接的旋转角 setter 先接住 —— 宿主每次设 0° 都会走到这里，
    // 我们在它落地之前换回竖的。放在下面的 return 之前，免得早退漏挂。
    Class connCls = objc_getClass("AVCaptureConnection");
    if (connCls && SLVCamPortraitCapture()) {
        Method mAngle = class_getInstanceMethod(connCls, NSSelectorFromString(@"setVideoRotationAngle:"));
        if (mAngle && !gSLSetRotAngleOrig) {
            gSLSetRotAngleOrig = (SLVSetRotAngleFn)method_getImplementation(mAngle);
            method_setImplementation(mAngle, (IMP)SLVCamSetVideoRotationAngle);
        }
        Method mOrient = class_getInstanceMethod(connCls, NSSelectorFromString(@"setVideoOrientation:"));
        if (mOrient && !gSLSetOrientationOrig) {
            gSLSetOrientationOrig = (SLVSetOrientationFn)method_getImplementation(mOrient);
            method_setImplementation(mOrient, (IMP)SLVCamSetVideoOrientation);
        }
    }

    if (!cls) return;
    Method m = class_getInstanceMethod(cls, @selector(addOutput:));
    if (!m) return;
    if (gSLAddOutputOrig) return;
    gSLAddOutputOrig = method_getImplementation(m);
    method_setImplementation(m, (IMP)SLVCamAddOutput);
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
static void (*gSLMovieStartOrig)(id, SEL, NSURL *, id);

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

static void SLVCamMovieStartProbe(id self, SEL _cmd, NSURL *url, id delegate) {
    static BOOL logged = NO;
    if (!logged) {
        logged = YES;
        SLVLog(@"音频: 命中 AVCaptureMovieFileOutput 录制（%@）· 画面会绕过 VideoDataOutput",
              url.lastPathComponent ?: @"?");

        // 0.3.23：把这条 connection 的旋转角打出来。
        // 「预览是正的、文件是歪的」只可能有两种原因：这条 connection 的角度跟
        // 预览层不一致，或者宿主根本没把角度写进文件。先把这个数拿到手。
        @try {
            AVCaptureConnection *c =
                [(AVCaptureMovieFileOutput *)self connectionWithMediaType:AVMediaTypeVideo];
            if (c) {
                SLVLog(@"录制: MovieFileOutput 连接 旋转=%ld 镜像=%@",
                       (long)SLVCamPreviewRotationDeg(c), c.isVideoMirrored ? @"Y" : @"N");
            } else {
                SLVLog(@"录制: MovieFileOutput 拿不到 video 连接");
            }
        } @catch (NSException *e) {
            SLVLog(@"录制: MovieFileOutput 读连接失败（%@）", e.reason ?: @"?");
        }
    }
    if (gSLMovieStartOrig) gSLMovieStartOrig(self, _cmd, url, delegate);
}

// 0.3.24：AVAssetWriter 这条路写文件时的 transform。
//
// 宿主如果在这里设了旋转，文件播放时就会转；设成 identity 就不转 ——
// 我们塞进去的「躺着」的像素会原样播出来，也就是「发送后歪 90°」。
//
// Swiftgram 的实测（13:18~13:19 两段日志）：
//   13:19:01 transform = [a=0 b=1 c=-1 d=0]   ← 90°，这条是对的
//   13:19:40 transform = [a=1 b=0 c=0 d=1]    ← identity，这条就是「视频消息发送后歪」
//
// 同一个 App 两条录制链路给的值不一样，说明它按场景自己算，而视频消息那条算漏了
// （或者它以为 buffer 已经是竖的 —— 但 `VideoDataOutput 连接 旋转=0` 证明不是，
// 1920x1440 横着进来的）。
//
// 所以：宿主设 identity 时，只要「宿主帧是横的」就补一个 90°。
// 不判断屏幕方向，只看 buffer 本身 —— 横 buffer + 不转 = 文件一定躺。
static void (*gSLWriterTransformOrig)(id, SEL, CGAffineTransform);
static int sSLWriterTransformCalls = 0;

static void SLVCamWriterSetTransform(id self, SEL _cmd, CGAffineTransform t) {
    CGAffineTransform use = t;
    BOOL weFix = NO;

    BOOL isIdentity = (fabs(t.a - 1.0) < 0.01 && fabs(t.b) < 0.01 &&
                       fabs(t.c) < 0.01 && fabs(t.d - 1.0) < 0.01);

    if (SLVCamPortraitCapture()) {
        // 0.3.28：竖采集模式下 buffer 已经是竖的了。
        // 宿主这时候再设 90°（普通视频录制会这么设），文件反而会被转歪；
        // 设 identity 才是对的。所以这一路**一律**按 identity 交上去。
        use = CGAffineTransformIdentity;
        weFix = !isIdentity;
    } else if (isIdentity && SLVCamInjecting()) {
        CGSize hs = [[SLVCamFeed shared] latestHostFrameSize];
        if (hs.width > hs.height) {
            use = CGAffineTransformMakeRotation(M_PI_2);
            weFix = YES;
        }
    }

    // 0.3.25：每次调用都记（前 8 次 + 之后每 20 次）。
    // 0.3.24 只在第一次打，结果日志里「补完 90° 转头 startWriting 又读到 identity」，
    // 看不出到底是另一个 input 还是被宿主覆盖了。现在每次都给宿主值 → 实际值。
    sSLWriterTransformCalls++;
    if (sSLWriterTransformCalls <= 8 || sSLWriterTransformCalls % 20 == 0) {
        SLVLog(@"录制: setTransform #%d 宿主=[%.2f %.2f %.2f %.2f] → 实际=[%.2f %.2f %.2f %.2f]%@",
               sSLWriterTransformCalls,
               t.a, t.b, t.c, t.d, use.a, use.b, use.c, use.d,
               weFix ? (SLVCamPortraitCapture() ? @" （竖采集：压成 identity）" : @" （补 90°）") : @"");
    }

    if (gSLWriterTransformOrig) gSLWriterTransformOrig(self, _cmd, use);
}

// 0.3.25：写完的那一刻读回 transform。
// 如果这里还是 identity，说明我们的设置被宿主覆盖了 —— 那 transform 这条路就没救，
// 得改成「让 buffer 本身是竖的」（动 AVCaptureConnection）。
static void (*gSLWriterMarkFinishedOrig)(id, SEL);

static void SLVCamWriterMarkFinished(id self, SEL _cmd) {
    @try {
        AVAssetWriterInput *vi = (AVAssetWriterInput *)self;
        if ([vi.mediaType isEqualToString:AVMediaTypeVideo]) {
            CGAffineTransform t = vi.transform;
            BOOL idt = (fabs(t.a - 1.0) < 0.01 && fabs(t.b) < 0.01 &&
                        fabs(t.c) < 0.01 && fabs(t.d - 1.0) < 0.01);
            SLVLog(@"录制: markAsFinished 时 video transform = [%.2f %.2f %.2f %.2f]%@",
                   t.a, t.b, t.c, t.d, idt ? @" （还是 identity！）" : @"");
        }
    } @catch (NSException *e) { }
    if (gSLWriterMarkFinishedOrig) gSLWriterMarkFinishedOrig(self, _cmd);
}

// 0.3.24：兜底。有些宿主压根不调 `setTransform:`，默认就是 identity ——
// 那样上面那个 hook 一次都不会进。开始写之前扫一遍 inputs 补上。
static void (*gSLWriterStartOrig)(id, SEL);

static void SLVCamWriterStartWriting(id self, SEL _cmd) {
    // 0.3.28：竖采集模式下 buffer 本身是竖的，identity 就是对的。
    // 这里再补 90° 反而会把文件转歪，所以整段跳过。
    if (SLVCamInjecting() && !SLVCamPortraitCapture()) {
        @try {
            CGSize hs = [[SLVCamFeed shared] latestHostFrameSize];
            if (hs.width > hs.height && hs.width > 1.0) {
                NSArray *inputs = [(AVAssetWriter *)self inputs];
                for (id inp in inputs) {
                    if (![inp respondsToSelector:@selector(transform)] ||
                        ![inp respondsToSelector:@selector(setTransform:)] ||
                        ![inp respondsToSelector:@selector(mediaType)]) continue;

                    AVAssetWriterInput *vi = (AVAssetWriterInput *)inp;
                    if (![vi.mediaType isEqualToString:AVMediaTypeVideo]) continue;

                    CGAffineTransform t = vi.transform;
                    BOOL idt = (fabs(t.a - 1.0) < 0.01 && fabs(t.b) < 0.01 &&
                                fabs(t.c) < 0.01 && fabs(t.d - 1.0) < 0.01);
                    if (idt) {
                        vi.transform = CGAffineTransformMakeRotation(M_PI_2);
                        SLVLog(@"录制: startWriting 兜底 · 给 video input 补 90°（宿主帧 %.0fx%.0f）",
                               hs.width, hs.height);
                    }
                }
            }
        } @catch (NSException *e) {
            SLVLog(@"录制: startWriting 兜底失败（%@）", e.reason ?: @"?");
        }
    }
    if (gSLWriterStartOrig) gSLWriterStartOrig(self, _cmd);
}

// 0.3.27：写完把成品读回来，看 transform 到底有没有写进文件。
//
// 0.3.26 的日志已经证明「设置留住了」：setTransform 补了 90°，
// startWriting 兜底一次都没触发（说明读回来就是 90°）。
// 但文件还是歪，那就只剩两种可能：
//   A. transform 压根没进文件的 tkhd matrix —— 那 setTransform 时机不对
//   B. 进了，但 Telegram 转码时丢了 —— 那 transform 这条路彻底无效，
//      只能让 buffer 本身变竖（动 AVCaptureConnection）
//
// 这条日志一次就能分开。

// 把文件里视频轨的 transform 打出来。异步加载 tracks，最多等 2 秒。
// 只做「读 + 打日志」，任何异常都咽掉 —— 这是探针，绝不能影响宿主写文件。
static void SLVLogTrackTransformNow(NSURL *url, NSString *tag) {
    if (!url) return;
    @try {
        AVURLAsset *a = [AVURLAsset URLAssetWithURL:url options:nil];

        // tracks 在新系统上是异步加载的，同步读会拿到空数组 —— 等它加载完
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [a loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^{
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
                                                   (int64_t)(2 * NSEC_PER_SEC)));

        NSArray *tracks = [a tracksWithMediaType:AVMediaTypeVideo];
        if (tracks.count == 0) {
            SLVLog(@"录制: %@ %@ 读不到视频轨（可能已删除）", tag, url.lastPathComponent);
            return;
        }
        for (AVAssetTrack *t in tracks) {
            CGAffineTransform tr = t.preferredTransform;
            CGSize ns = t.naturalSize;
            BOOL idt = (fabs(tr.a - 1.0) < 0.01 && fabs(tr.b) < 0.01 &&
                        fabs(tr.c) < 0.01 && fabs(tr.d - 1.0) < 0.01);
            SLVLog(@"录制: %@ %@ 视频 %.0fx%.0f transform=[%.2f %.2f %.2f %.2f]%@",
                   tag, url.lastPathComponent, ns.width, ns.height,
                   tr.a, tr.b, tr.c, tr.d,
                   idt ? @" （identity）" : @"");
        }
    } @catch (NSException *e) {
        SLVLog(@"录制: %@ 读失败（%@）", tag, e.reason ?: @"?");
    }
}

// 上面那个函数里有个 2 秒的信号量。宿主调 finishWriting / export 很可能在**主线程**，
// 直接跑会把界面卡住 —— 主线程上就丢后台队列（日志晚几十毫秒无所谓），
// 已经在别的线程就当场跑，省得文件被宿主删掉之后再读不到。
static void SLVLogTrackTransform(NSURL *url, NSString *tag) {
    if (!url) return;
    if ([NSThread isMainThread]) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            SLVLogTrackTransformNow(url, tag);
        });
    } else {
        SLVLogTrackTransformNow(url, tag);
    }
}

static void (*gSLWriterFinishOrig)(id, SEL, void (^)(void));

static void SLVCamWriterFinishWriting(id self, SEL _cmd, void (^handler)(void)) {
    AVAssetWriter *w = (AVAssetWriter *)self;
    NSURL *url = w.outputURL;

    void (^wrapped)(void) = [^{
        if (handler) handler();
        SLVLogTrackTransform(url, @"成品");
    } copy];

    if (gSLWriterFinishOrig) gSLWriterFinishOrig(self, _cmd, wrapped);
}

// 0.3.27：Telegram 发视频消息时，会不会把刚录的文件再导一遍？
// 如果会，transform 就算进了原文件，也可能在这一步丢掉 —— 那 transform 这条路就废了，
// 只能改成「让 buffer 本身就是竖的」。
// initWithAsset:presetName: 返回的是 instancetype，原始实现必须声明成返回 id。
// 写成 void 会在 `self = ...` 那一行报 "assigning to '__strong id' from incompatible type 'void'"。
static id (*gSLExportInitOrig)(id, SEL, id, id);

static id SLVCamExportInit(id self, SEL _cmd, id asset, id preset) {
    if (gSLExportInitOrig) self = gSLExportInitOrig(self, _cmd, asset, preset);
    @try {
        if ([asset isKindOfClass:[AVURLAsset class]]) {
            NSURL *u = [(AVURLAsset *)asset URL];
            SLVLog(@"录制: Telegram 开始导出 %@（preset=%@）", u.lastPathComponent, preset ?: @"?");
            SLVLogTrackTransform(u, @"导出前");
        }
    } @catch (NSException *e) { }
    return self;
}

static void (*gSLExportRunOrig)(id, SEL, void (^)(void));

static void SLVCamExportRun(id self, SEL _cmd, void (^handler)(void)) {
    NSURL *out = nil;
    @try { out = [(AVAssetExportSession *)self outputURL]; } @catch (NSException *e) { }

    void (^wrapped)(void) = [^{
        if (handler) handler();
        SLVLogTrackTransform(out, @"导出后");
    } copy];

    if (gSLExportRunOrig) gSLExportRunOrig(self, _cmd, wrapped);
}

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

    Class movie = objc_getClass("AVCaptureMovieFileOutput");
    SLVCamHookSel(movie, NSSelectorFromString(@"startRecordingToOutputFileURL:recordingDelegate:"),
                 (IMP)SLVCamMovieStartProbe, (IMP *)&gSLMovieStartOrig);

    // 0.3.23：录制文件的朝向探针
    Class writerInput = SLVCamLoadClass("AVAssetWriterInput", "/System/Library/Frameworks/AVFoundation.framework/AVFoundation");
    SLVCamHookSel(writerInput, NSSelectorFromString(@"setTransform:"),
                 (IMP)SLVCamWriterSetTransform, (IMP *)&gSLWriterTransformOrig);
    // 0.3.25：写完时读回 transform，判断我们的设置有没有被覆盖
    SLVCamHookSel(writerInput, NSSelectorFromString(@"markAsFinished"),
                 (IMP)SLVCamWriterMarkFinished, (IMP *)&gSLWriterMarkFinishedOrig);

    // 0.3.24：宿主不调 setTransform 时的兜底
    Class writer = SLVCamLoadClass("AVAssetWriter", "/System/Library/Frameworks/AVFoundation.framework/AVFoundation");
    SLVCamHookSel(writer, NSSelectorFromString(@"startWriting"),
                 (IMP)SLVCamWriterStartWriting, (IMP *)&gSLWriterStartOrig);

    // 0.3.27：写完把成品读回来，看 transform 到底有没有进文件
    SLVCamHookSel(writer, NSSelectorFromString(@"finishWritingWithCompletionHandler:"),
                 (IMP)SLVCamWriterFinishWriting, (IMP *)&gSLWriterFinishOrig);

    // 0.3.27：Telegram 会不会拿这个文件再导一遍
    Class exporter = SLVCamLoadClass("AVAssetExportSession",
                                     "/System/Library/Frameworks/AVFoundation.framework/AVFoundation");
    SLVCamHookSel(exporter, NSSelectorFromString(@"initWithAsset:presetName:"),
                 (IMP)SLVCamExportInit, (IMP *)&gSLExportInitOrig);
    SLVCamHookSel(exporter, NSSelectorFromString(@"exportAsynchronouslyWithCompletionHandler:"),
                 (IMP)SLVCamExportRun, (IMP *)&gSLExportRunOrig);

    SLVLog(@"探测: 录制链路已布点 tap=%d recorder=%d movie=%d writerInput=%d writer=%d export=%d",
          inputNode != nil, rec != nil, movie != nil, writerInput != nil, writer != nil,
          exporter != nil);
}

#pragma mark - 拍照接管（0.2.15）

// 拍照是另一条完全独立的路径。
//
// 我们的注入是按「类名里凡是名字带 samplebuffer 且签名是单指针参数的方法」挂的，
// 而 -[AVCaptureStillImageOutput captureStillImageAsynchronouslyFromConnection:completionHandler:]
// 是「对象 + block」两个参数，被那条规则直接跳过 —— 所以拍照出来永远是真实画面。
// QQ 的日志里明确有「会话加输出: AVCaptureStillImageOutput」，就是它。
//
// 接法：把 completionHandler 包一层，收到真 buffer 后不往下传，改传我们自己的
// 假 JPEG。CMSampleBuffer 是只读的，替换只能新建一个 —— 拿素材当前帧转 JPEG，
// 再按 JPEG 的宽高建 format description + block buffer 拼出来。
static void (*gSLStillOrig)(id, SEL, id, id);

static NSData *SLVCamJPEGFromPixelBuffer(CVPixelBufferRef pb, CGFloat quality) {
    if (!pb) return nil;
    CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
    if (!ci) return nil;
    static CIContext *ctx = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ctx = [CIContext contextWithOptions:nil]; });
    CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent];
    if (!cg) return nil;
    UIImage *img = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return UIImageJPEGRepresentation(img, quality);
}

static CMSampleBufferRef SLVCamJPEGSampleBuffer(CVPixelBufferRef pb) {
    NSData *jpeg = SLVCamJPEGFromPixelBuffer(pb, 0.92);
    if (!jpeg.length) return NULL;

    size_t len = jpeg.length;
    CMBlockBufferRef block = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, len, kCFAllocatorDefault,
                                           NULL, 0, len, kCMBlockBufferAssureMemoryNowFlag,
                                           &block) != kCMBlockBufferNoErr || !block) {
        return NULL;
    }
    if (CMBlockBufferReplaceDataBytes(jpeg.bytes, block, 0, len) != kCMBlockBufferNoErr) {
        CFRelease(block);
        return NULL;
    }

    // 宽高必须跟 JPEG 本身一致 —— QQ 是按 format description 摆图的，
    // 尺寸对不上会拉伸变形。
    CMVideoFormatDescriptionRef fmt = NULL;
    OSStatus st = CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_JPEG,
                                                 (int32_t)CVPixelBufferGetWidth(pb),
                                                 (int32_t)CVPixelBufferGetHeight(pb),
                                                 NULL, &fmt);
    if (st != noErr || !fmt) {
        CFRelease(block);
        return NULL;
    }

    CMSampleTimingInfo timing = { CMTimeMake(1, 30), kCMTimeZero, kCMTimeInvalid };
    size_t sizes[1] = { len };
    CMSampleBufferRef sbuf = NULL;
    st = CMSampleBufferCreateReady(kCFAllocatorDefault, block, fmt, 1, 1, &timing, 1, sizes, &sbuf);
    CFRelease(fmt);
    CFRelease(block);
    return (st == noErr) ? sbuf : NULL;
}

static void SLVCamCaptureStill(id self, SEL _cmd, id connection,
                              void (^handler)(CMSampleBufferRef, NSError *)) {
    if (!gSLStillOrig) return;
    if (!SLVCamInjecting() || !SLVCamArmed() || ![[SLVCamFeed shared] isReady]) {
        // block 本身就是对象，直接当 id 传，不要加 __bridge ——
        // 对 block 类型做 __bridge 转 id 是编译错误（clang 会直接 segfault）。
        gSLStillOrig(self, _cmd, connection, handler);
        return;
    }

    void (^wrapped)(CMSampleBufferRef, NSError *) = ^(CMSampleBufferRef buf, NSError *err) {
        if (!handler) return;
        // 0.2.16：这里原来用 copyNextFrame，拿的是解码器吐的**原始帧** ——
        // 既没转角度也没镜像，所以预览里画面已经转正了，拍出来还是歪的。
        // 改用拍照专用出帧：按当前旋转/镜像摆好，但不碰预览管线。
        CVPixelBufferRef pb = [[SLVCamFeed shared]
            copyOrientedFrameForPixelFormat:kCVPixelFormatType_32BGRA size:CGSizeZero];
        CMSampleBufferRef fake = pb ? SLVCamJPEGSampleBuffer(pb) : NULL;
        if (pb) CVPixelBufferRelease(pb);
        if (fake) {
            static BOOL logged = NO;
            if (!logged) {
                logged = YES;
                SLVLog(@"注入: 拍照已接管 · 返回素材画面（已按 %ld° / 镜像%@）",
                      (long)([SLVCamFeed shared].rotation % 360),
                      [SLVCamFeed shared].mirrorEnabled ? @"开" : @"关");
            }
            handler(fake, err);
            CFRelease(fake);
        } else {
            handler(buf, err);   // 素材这一帧没解出来，宁可给真画面也不给黑图
        }
    };
    gSLStillOrig(self, _cmd, connection, [wrapped copy]);
}

static void SLVCamInstallStillImageHook(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    Class cls = objc_getClass("AVCaptureStillImageOutput");
    if (!cls) {
        SLVLog(@"注入: AVCaptureStillImageOutput 不存在，拍照跳过");
        return;
    }
    SLVCamHookSel(cls, NSSelectorFromString(@"captureStillImageAsynchronouslyFromConnection:completionHandler:"),
                 (IMP)SLVCamCaptureStill, (IMP *)&gSLStillOrig);
    SLVLog(@"注入: 拍照链路已布点 still=%d", gSLStillOrig != nil);
}

#pragma mark - 拍照接管之二：AVCapturePhotoOutput（抖音走这条）

// QQ 用 AVCaptureStillImageOutput，抖音用 AVCapturePhotoOutput —— 两条完全独立的路径。
// 抖音日志里那句「会话加输出: AVCapturePhotoOutput」就是它，只挂 StillImageOutput
// 对它一点作用都没有，所以拍出来还是真实画面。
//
// 接法不走 delegate：delegate 是宿主私有类，每次启动可能不同，还得处理中途被替换。
// 改成直接挂在 -[AVCapturePhoto fileDataRepresentation] 上 —— 宿主不管怎么拍、
// 委托给谁、要 HEIC 还是 JPEG，最后总得向 AVCapturePhoto 要字节，那一刻换成我们的。
// 一个方法覆盖所有调用方式，也不用管它内部编码格式。

static NSData *(*gSLPhotoDataOrig)(id, SEL);
static NSData *(*gSLPhotoDataCustomOrig)(id, SEL, id);
static void   (*gSLPhotoCaptureOrig)(id, SEL, id, id);
static CVPixelBufferRef (*gSLPhotoPBOrig)(id, SEL);

// 0.3.23：拍照要「摆正」，需要两个数 —— 转多少度、最终多大。
//
// 为什么补的角度要跟用户设的旋转**相加**：
//   用户设的 rotation 是**对着预览调**出来的 —— 他转到「预览看着正」为止。
//   而预览正不正，是「素材转 userRot」再叠上「预览层转 connection」的结果。
//   所以素材本身的朝向偏差 = -(userRot + connection)。
//   拍照要把它摆回正，就得转 +(userRot + connection)。
//
// 竖拍后摄：EXIF 6（要顺时针 90 才正），预览层 connection 通常也是 90，
// 用户把 rotation 调到 270 → 270 + 90 = 360 = 0 → 素材原样输出，正好是正的。
// 这就是日志里「返回素材画面 270°」那个值的真正含义。
//
// 尺寸同样要摆正：`AVCapturePhoto` 的 buffer 是传感器原始方向（4032x3024 横），
// 摆正之后是 3024x4032 竖，宽高必须跟着换 —— 否则出来的是张横图。
static NSInteger SLVCamPhotoUprightRotation(id photo, CGSize rawSize, CGSize *outSize) {
    NSInteger cw = 90;   // 拿不到 EXIF 就按最常见的竖拍后摄（EXIF 6）处理
    @try {
        NSDictionary *meta = [(AVCapturePhoto *)photo metadata];
        NSNumber *v = meta[(NSString *)kCGImagePropertyOrientation];
        switch (v ? v.integerValue : 6) {
            case 1: case 2: cw = 0;   break;
            case 3: case 4: cw = 180; break;
            case 5: case 7: cw = 90;  break;   // 带镜像的那几个按旋转部分算
            case 6:         cw = 90;  break;
            case 8:         cw = 270; break;
            default:        cw = 90;  break;
        }
    } @catch (NSException *e) { }

    if (outSize) {
        if ((cw == 90 || cw == 270) && rawSize.width >= 1 && rawSize.height >= 1) {
            *outSize = CGSizeMake(rawSize.height, rawSize.width);
        } else {
            *outSize = rawSize;
        }
    }
    return cw;
}

/// 从素材取一帧、按当前旋转/镜像摆好、转成 JPEG。
/// 条件不满足返回 nil，调用方原样放行真照片。
static void SLVCamPhotoLogOnce(CGSize raw, CGSize out, NSInteger cw);

static NSData *SLVCamPhotoJPEG(id photo) {
    if (!SLVCamInjecting() || !SLVCamArmed()) return nil;

    // 0.3.23：尺寸必须跟**真照片**走。
    //
    // 原来传的是 CGSizeZero，输出尺寸就取「素材旋转后的尺寸」—— 素材 1080x1920
    // 转 270 变成 1920x1080，于是照片是 16:9 横图，而预览是 4:3 竖屏。
    // 一个横一个竖，这就是「拍照和录制方向不一样」的直接原因。
    CGSize raw = CGSizeZero;
    if (gSLPhotoPBOrig) {
        CVPixelBufferRef real = gSLPhotoPBOrig(photo, NSSelectorFromString(@"pixelBuffer"));
        if (real) raw = CGSizeMake(CVPixelBufferGetWidth(real), CVPixelBufferGetHeight(real));
    }

    CGSize outSize = CGSizeZero;
    NSInteger cw = SLVCamPhotoUprightRotation(photo, raw, &outSize);

    CVPixelBufferRef pb = [[SLVCamFeed shared]
        copyOrientedFrameForPixelFormat:kCVPixelFormatType_32BGRA
                                   size:outSize
                          extraRotation:cw];
    if (!pb) return nil;
    NSData *jpeg = SLVCamJPEGFromPixelBuffer(pb, 0.92);
    CVPixelBufferRelease(pb);
    if (jpeg.length) SLVCamPhotoLogOnce(raw, outSize, cw);
    return jpeg.length ? jpeg : nil;
}

static void SLVCamPhotoLogOnce(CGSize raw, CGSize out, NSInteger cw) {
    static BOOL logged = NO;
    if (logged) return;
    logged = YES;
    SLVLog(@"注入: 拍照已接管（AVCapturePhotoOutput）· 照片 %.0fx%.0f → 摆正 %.0fx%.0f · "
          @"设置 %ld° + 补偿 %ld° = %ld° / 镜像%@",
          raw.width, raw.height, out.width, out.height,
          (long)([SLVCamFeed shared].rotation % 360), (long)cw,
          (long)((([SLVCamFeed shared].rotation % 360) + cw) % 360),
          [SLVCamFeed shared].mirrorEnabled ? @"开" : @"关");
}

static NSData *SLVCamPhotoFileData(id self, SEL _cmd) {
    NSData *fake = SLVCamPhotoJPEG(self);
    if (fake) return fake;
    return gSLPhotoDataOrig ? gSLPhotoDataOrig(self, _cmd) : nil;
}

static NSData *SLVCamPhotoFileDataCustom(id self, SEL _cmd, id customizer) {
    NSData *fake = SLVCamPhotoJPEG(self);
    if (fake) return fake;
    return gSLPhotoDataCustomOrig ? gSLPhotoDataCustomOrig(self, _cmd, customizer) : nil;
}

// 只做一次探针：记录宿主到底调不调 capturePhotoWithSettings:delegate:，
// 以及 delegate 是什么类。下次再出「拍了没换」的日志，一眼就知道走到哪一步了。
static void SLVCamPhotoCapture(id self, SEL _cmd, id settings, id delegate) {
    static BOOL logged = NO;
    if (!logged) {
        logged = YES;
        SLVLog(@"注入: 命中 AVCapturePhotoOutput 拍照 · delegate=%@",
              delegate ? NSStringFromClass([delegate class]) : @"(nil)");
    }
    if (gSLPhotoCaptureOrig) gSLPhotoCaptureOrig(self, _cmd, settings, delegate);
}

// 照片缓冲的「方向类别」可能跟预览缓冲不一样：
// 视频输出那条路拿到的缓冲已经带上了 connection 的朝向（Swiftgram 日志里是
// 1920x1440 横的，Turrit 是 1712x1284 横的），而 AVCapturePhoto 给的是
// **传感器原始方向**，两者可能差 90°。
// 不补这一下，素材就被塞进一个转了 90° 的框里 —— 预览正、拍出来歪。
//
// 补哪个方向由照片自己的 EXIF 方向决定：EXIF 说「要顺时针转 90° 才正」（=6），
// 我们就先逆时针转 90°（=270°），等宿主/系统把它转回来正好抵消。
//
// 0.3.23 备注：这条路（`-[AVCapturePhoto pixelBuffer]`）只有抖音在走，
// Swiftgram 走的是 `fileDataRepresentation`，用的是另一套（见
// SLVCamPhotoUprightRotation）。两套不能合并 —— pixelBuffer 那条路是
// **原地改写宿主的原始 buffer**，尺寸动不了，只能靠角度补偿；JPEG 那条路
// 是我们自己出图，尺寸和角度都能自己定。
static NSInteger SLVCamPhotoExtraRotation(id photo, CGSize dstSize) {
    CGSize vs = [[SLVCamFeed shared] latestFrameSize];
    if (vs.width < 1 || vs.height < 1 || dstSize.width < 1 || dstSize.height < 1) return 0;

    BOOL videoPortrait = vs.height > vs.width;
    BOOL photoPortrait = dstSize.height > dstSize.width;
    if (videoPortrait == photoPortrait) return 0;   // 方向类别一致，不用补

    NSInteger cw = 90;   // 拿不到 EXIF 就按最常见的竖拍后摄（EXIF 6）处理
    @try {
        NSDictionary *meta = [(AVCapturePhoto *)photo metadata];
        NSNumber *v = meta[(NSString *)kCGImagePropertyOrientation];
        switch (v ? v.integerValue : 6) {
            case 1: case 2: cw = 0;   break;
            case 3: case 4: cw = 180; break;
            case 5: case 7: cw = 90;  break;   // 带镜像的那几个按旋转部分算
            case 6:         cw = 90;  break;
            case 8:         cw = 270; break;
            default:        cw = 90;  break;
        }
    } @catch (NSException *e) { }
    return (360 - cw) % 360;
}

// 抖音（IESMMCaptureKit）读的是 -[AVCapturePhoto pixelBuffer]，不是
// fileDataRepresentation —— 0.2.16 的日志里「命中 AVCapturePhotoOutput 拍照」有了，
// 「拍照已接管（AVCapturePhotoOutput）」一行没有，就是证据：它压根没来要文件字节。
//
// 这条路上不能返回我们自己 new 的 buffer：
//   · pixelBuffer 返回的是**借用**引用，调用方不会 CFRelease → 每次拍照泄 8MB；
//   · 尺寸/格式跟真照片对不上，宿主按 resolvedSettings 算出的宽高会跟 buffer 打架。
// 所以改成「拿宿主那个 buffer，把素材帧原地画进去」—— 指针、尺寸、格式全是它熟悉的。
static CVPixelBufferRef SLVCamPhotoPixelBuffer(id self, SEL _cmd) {
    CVPixelBufferRef real = gSLPhotoPBOrig ? gSLPhotoPBOrig(self, _cmd) : NULL;
    if (!real) return real;
    if (!SLVCamInjecting() || !SLVCamArmed()) return real;

    CGSize sz = CGSizeMake(CVPixelBufferGetWidth(real), CVPixelBufferGetHeight(real));
    NSInteger extra = SLVCamPhotoExtraRotation(self, sz);
    if (![[SLVCamFeed shared] renderIntoPixelBuffer:real extraRotation:extra]) return real;

    static BOOL logged = NO;
    if (!logged) {
        logged = YES;
        CGSize vs = [[SLVCamFeed shared] latestFrameSize];
        SLVLog(@"注入: 拍照已接管（pixelBuffer 原地改写）· 照片 %zux%zu / 预览 %zux%zu · "
              @"设置 %ld° + 补偿 %ld° / 镜像%@",
              CVPixelBufferGetWidth(real), CVPixelBufferGetHeight(real),
              (size_t)vs.width, (size_t)vs.height,
              (long)([SLVCamFeed shared].rotation % 360), (long)extra,
              [SLVCamFeed shared].mirrorEnabled ? @"开" : @"关");
    }
    return real;
}

static void SLVCamInstallPhotoOutputHook(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;

    Class photo = objc_getClass("AVCapturePhoto");
    Class output = objc_getClass("AVCapturePhotoOutput");
    if (!photo || !output) {
        SLVLog(@"注入: AVCapturePhoto/PhotoOutput 不存在，拍照跳过 photo=%d output=%d",
              photo != nil, output != nil);
        return;
    }

    SLVCamHookSel(photo, NSSelectorFromString(@"fileDataRepresentation"),
                 (IMP)SLVCamPhotoFileData, (IMP *)&gSLPhotoDataOrig);
    SLVCamHookSel(photo, NSSelectorFromString(@"fileDataRepresentationWithCustomizer:"),
                 (IMP)SLVCamPhotoFileDataCustom, (IMP *)&gSLPhotoDataCustomOrig);
    SLVCamHookSel(photo, NSSelectorFromString(@"pixelBuffer"),
                 (IMP)SLVCamPhotoPixelBuffer, (IMP *)&gSLPhotoPBOrig);
    SLVCamHookSel(output, NSSelectorFromString(@"capturePhotoWithSettings:delegate:"),
                 (IMP)SLVCamPhotoCapture, (IMP *)&gSLPhotoCaptureOrig);

    SLVLog(@"注入: 拍照链路已布点 photo=%d custom=%d pb=%d capture=%d",
          gSLPhotoDataOrig != nil, gSLPhotoDataCustomOrig != nil,
          gSLPhotoPBOrig != nil, gSLPhotoCaptureOrig != nil);
}

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

// 0.3.28：竖采集模式下，采集连接被我们掰成了竖的（+90°），
// 而预览层的 connection 还停在宿主自己的角度上（没动它）。
// 所以「这一帧真实的摆法」= 预览层角度 - 90°。
//
// 举例：预览层 90°、采集 90° → 实际 0°，显示层不用转，竖帧直接铺满竖窗口。
static NSInteger SLVCamEffectivePreviewDeg(AVCaptureConnection *conn) {
    NSInteger deg = SLVCamPreviewRotationDeg(conn);
    if (SLVCamPortraitCapture()) {
        deg = (deg - SLVPortraitDeg) % 360;
        if (deg < 0) deg += 360;
    }
    return deg;
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
        if (big || connGone || SLVCamPreviewSizeStable(pl, lw, lh)) {
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

    // 0.3.28：这里要用「有效角度」。竖采集模式下帧本身已经是竖的，
    // 预览层 connection 那个 90° 不再代表真实摆法 —— 拿它去换宽高会把比例算反。
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
        if (wantSync) {
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

    // 0.3.28：竖采集开关。只有 Swiftgram 会打开 —— 它的视频消息是 400x400 正方形，
    // transform 那条路走不通，只能让采集连接直接交竖 buffer。
    if (SLVCamPortraitCapture()) {
        SLVLog(@"竖采集: 已开启（视频输出连接强制 %ld°，writer transform 一律 identity）",
               (long)SLVPortraitDeg);
    }

    // 第二条链路：不经过 AVCapture 的麦克风（QQ 这类自建音频栈的 App）
    SLVCamInstallAudioUnitHook();

    // 第三条：QQ 拍摄页录制走的第四条路 —— 先布点确认是哪条
    SLVCamInstallRecordingProbes();

    // 拍照（AVCaptureStillImageOutput）走的是另一条路，上面那套启发式挂不到
    SLVCamInstallStillImageHook();

    // 抖音拍照走 AVCapturePhotoOutput，又是另一条 —— 两条都要挂
    SLVCamInstallPhotoOutputHook();

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
