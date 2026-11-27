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
#import <objc/runtime.h>
#import <os/lock.h>
#import <dlfcn.h>
#import <string.h>

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
static int  sSLCamAVCaptureAudioFrames = 0;   // 0.3.55：走 AVCapture 音频链的帧数（体检用）
static int  sSLCamHookCount = 0;
static BOOL sLoggedMissingOrig = NO;
static BOOL sLoggedFirstVideo = NO;
static BOOL sLoggedFirstAudio = NO;
static int  sSLCamFailCount = 0;
static int  sSLCamAudioFailCount = 0;
static int  sSLCamBadPTS = 0;
static int  sSLCamOwnFmtLogged = 0;
static int  sSLCamDTSFixLogged = 0;
static int  sSLCamAttachLogged = 0;
static int  sSLCamSetAttachFailLogged = 0;
static int  sSLCamOwnFmtExtFailLogged = 0;
static int  sSLCamOwnFmtRejectedLogged = 0;

// ---- 0.3.61：按 output 分槽记上一帧 PTS，用来算真实帧间隔 ----
//
// 为什么不是一个全局变量：微信会同时挂预览/通话两路 AVCaptureVideoDataOutput，
// 两路 PTS 交错到达，用全局变量会把 66ms 的间隔算成 33ms —— 误报 30fps，
// 恰好又掉回这次「码率白抬」的同一个坑里。按 output 对象分槽，各算各的。
#define SLV_TS_SLOTS 4
static const void *sSLCamTSSelf[SLV_TS_SLOTS];
static CMTime      sSLCamTSPrev[SLV_TS_SLOTS];
static os_unfair_lock sSLCamTSLock = OS_UNFAIR_LOCK_INIT;
static double sSLCamDurLastMs = 0;      // 最近一帧填进去的间隔（心跳直接打这个）
static int    sSLCamDurFixLogged = 0;

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

/// 本帧与「同一 output 上一帧」的间隔（毫秒）。
/// 没有上一帧、或不属于同一路流、或时基不单调时返回 -1（调用方自己兜底）。
static double SLVCamFrameIntervalMs(const void *out, CMTime pts) {
    if (!out || !CMTIME_IS_VALID(pts)) return -1;

    double ms = -1;
    os_unfair_lock_lock(&sSLCamTSLock);
    int slot = -1, empty = -1;
    for (int i = 0; i < SLV_TS_SLOTS; i++) {
        if (sSLCamTSSelf[i] == out) { slot = i; break; }
        if (!sSLCamTSSelf[i] && empty < 0) empty = i;
    }
    if (slot < 0 && empty >= 0) {
        slot = empty;
        sSLCamTSSelf[slot] = out;
        sSLCamTSPrev[slot] = kCMTimeInvalid;
    }
    if (slot >= 0) {
        CMTime prev = sSLCamTSPrev[slot];
        if (CMTIME_IS_VALID(prev)) {
            CMTime d = CMTimeSubtract(pts, prev);
            if (CMTIME_IS_VALID(d) && CMTIME_IS_POSITIVE(d)) {
                ms = CMTimeGetSeconds(d) * 1000.0;
            }
        }
        sSLCamTSPrev[slot] = pts;
    }
    os_unfair_lock_unlock(&sSLCamTSLock);
    return ms;
}

// ---- 0.3.58：视频心跳 ----
//
// 0.3.57 的日志里音频有六七个指标，视频一个都没有 —— 所以「对面看着糊」只能靠猜。
// 这里补上最要紧的四个数：
//   · 宿主实际来要多少帧  → 采集帧率，Agora 编码的上限就是它
//   · 我们替换成功多少帧  → 少了说明打包失败或没数据，宿主拿到的是重复帧
//   · 每帧处理花多久      → 超 33ms 就掉到 30fps 以下
//   · 直出 / 渲染         → 直出 = 我们一个像素都没动，糊就怨不到这层
// 0.3.61 补第五个：帧间隔 —— 就是写进 duration 的那个值，也是码控摊预算的依据
static uint64_t sSLCamVideoAsked = 0;
static uint64_t sSLCamVideoServed = 0;
static uint64_t sSLCamVideoBypass = 0;
static double   sSLCamProcTotalMs = 0;
static double   sSLCamProcMaxMs = 0;
static CFAbsoluteTime sSLCamVideoBeatAt = 0;
static uint64_t sSLCamBeatAsked = 0;
static uint64_t sSLCamBeatServed = 0;
static uint64_t sSLCamBeatBypass = 0;
static double   sSLCamBeatTotalMs = 0;

static void SLVCamVideoBeat(CMFormatDescriptionRef fmt, double procMs, BOOL served) {
    sSLCamVideoAsked++;
    if (served) sSLCamVideoServed++; else sSLCamVideoBypass++;
    if (procMs > 0) {
        sSLCamProcTotalMs += procMs;
        if (procMs > sSLCamProcMaxMs) sSLCamProcMaxMs = procMs;
    }
    // 0.3.60：改成按时间触发（5 秒），不再按帧数。
    //
    // 之前是每 300 帧打一行 —— 15fps 下要 20 秒。陌陌的视频通话常常只有 15~20 秒，
    // 结果整场一次都没打出来（0.3.59 那两场就是），等于这段统计白做，
    // 连「帧率到底有没有变成 24」都看不到。
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (sSLCamVideoBeatAt <= 0) {
        // 首帧只立锚点。不然会打一行「0.0s / 0 帧 / 0.0fps」的噪音。
        sSLCamVideoBeatAt = now;
        sSLCamBeatAsked = sSLCamVideoAsked;
        sSLCamBeatServed = sSLCamVideoServed;
        sSLCamBeatBypass = sSLCamVideoBypass;
        sSLCamBeatTotalMs = sSLCamProcTotalMs;
        return;
    }
    if (now - sSLCamVideoBeatAt < 5.0) return;

    uint64_t asked = sSLCamVideoAsked - sSLCamBeatAsked;
    uint64_t servedN = sSLCamVideoServed - sSLCamBeatServed;
    uint64_t bypassN = sSLCamVideoBypass - sSLCamBeatBypass;
    double win = sSLCamVideoBeatAt > 0 ? (now - sSLCamVideoBeatAt) : 0;
    double avg = asked ? (sSLCamProcTotalMs - sSLCamBeatTotalMs) / (double)asked : 0;
    double fps = (win > 0.1) ? ((double)asked / win) : 0;

    NSUInteger direct = 0, render = 0;
    [[SLVCamFeed shared] videoPathCountsDirect:&direct render:&render];

    CMVideoDimensions d = fmt ? CMVideoFormatDescriptionGetDimensions(fmt) : (CMVideoDimensions){0, 0};
    OSType sub = fmt ? CMFormatDescriptionGetMediaSubType(fmt) : 0;
    SLVLog(@"视频: 心跳 %.1fs 宿主来要 %llu 帧（%.1ffps）· 帧间隔 %.1fms · 替换 %llu / 放行 %llu · 处理均 %.1fms 峰 %.1fms · 宿主 %dx%d %@ · 直出累计 %lu / 渲染累计 %lu",
          win, (unsigned long long)asked, fps, sSLCamDurLastMs,
          (unsigned long long)servedN, (unsigned long long)bypassN,
          avg, sSLCamProcMaxMs, d.width, d.height, SLVFourCC(sub),
          (unsigned long)direct, (unsigned long)render);

    sSLCamProcMaxMs = 0;   // 峰值按窗口算，否则整场都被开头几帧拖着
    sSLCamVideoBeatAt = now;
    sSLCamBeatAsked = sSLCamVideoAsked;
    sSLCamBeatServed = sSLCamVideoServed;
    sSLCamBeatBypass = sSLCamVideoBypass;
    sSLCamBeatTotalMs = sSLCamProcTotalMs;
}

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
        ((SLVProcessSampleBufferFn)orig)(self, _cmd, sbuf);
        return;
    }

    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sbuf);
    if (!fmt) { ((SLVProcessSampleBufferFn)orig)(self, _cmd, sbuf); return; }

    CMMediaType mediaType = CMFormatDescriptionGetMediaType(fmt);
    CMSampleBufferRef fake = NULL;
    double slvProcMs = 0;                // 0.3.58：这一帧的处理耗时（视频心跳用）

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

            // 0.3.61：duration 必须反映**真实帧间隔**，不能写死 1/30。
            //
            // 0.3.60 及之前这里一律填 1/30。后果：宿主按 15fps 送帧，我们却告诉下游
            // 「每帧 33.3ms」，等于宣称这是 30fps 的流。Agora 内部的码率控制是按
            // **声明帧率**摊每帧预算的 —— 声明 30fps，就按每帧 bitrate/30 发；实际只有
            // 一半的帧进来，总发出码率就只剩一半。设 4000kbps 实际跑出 ~2000，
            // 抬码率当然没感觉。
            // 更关键的是：这条错误信息连零拷贝直出也一起带着（直出只跳过像素，
            // 不跳过 timing），所以才会出现「像素一个字节没动，对面还是糊」。
            //
            // duration 还必须是「有效 + 非负」，否则 CMSampleBufferCreateReady 会以
            // kCMSampleBufferError_InvalidSampleTimingInfo 失败，表现和格式错一模一样。
            CMTime hostDur = timing.duration;
            if (CMTIME_IS_VALID(hostDur) && CMTimeCompare(hostDur, kCMTimeZero) > 0) {
                // 宿主给了合法时长，信它。
            } else {
                double gapMs = SLVCamFrameIntervalMs((__bridge void *)self,
                                                     timing.presentationTimeStamp);
                // 夹在 1/60 ~ 1/10：太小说明两路流混在了一起（会误报高帧率、
                // 把码率预算继续摊薄），太大说明中间断过流（按断档时长声明会让
                // 编码器以为帧率骤降，反手砍码率）。
                if (!(gapMs > 0)) gapMs = 66.7;     // 没有上一帧：按陌陌通话的 15fps 兜底
                if (gapMs < 16.7) gapMs = 16.7;
                if (gapMs > 100.0) gapMs = 100.0;
                timing.duration = CMTimeMakeWithSeconds(gapMs / 1000.0, 1000000);
                if (sSLCamDurFixLogged++ == 0) {
                    SLVLog(@"注入: duration 按真实帧间隔填 %.1fms（宿主原值 value=%lld scale=%d flags=%u，不再写死 1/30）",
                          gapMs, hostDur.value, hostDur.timescale, hostDur.flags);
                }
            }
            sSLCamDurLastMs = CMTimeGetSeconds(timing.duration) * 1000.0;
            if (!CMTIME_IS_VALID(timing.decodeTimeStamp)) {
                // 实时采集没有 B 帧，dts 本来就该等于 pts。留 invalid 会让部分链路
                // 自己按 duration 累加时间轴，又一次把错误的帧率坐实。
                if (sSLCamDTSFixLogged++ == 0) {
                    SLVLog(@"注入: 真帧 dts 非法（value=%lld scale=%d），已按 PTS 补齐",
                          timing.decodeTimeStamp.value, timing.decodeTimeStamp.timescale);
                }
                timing.decodeTimeStamp = timing.presentationTimeStamp;
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
            CFAbsoluteTime slvT0 = CFAbsoluteTimeGetCurrent();
            CVPixelBufferRef frame = [feed copyFrameForHostBuffer:img];
            slvProcMs = (CFAbsoluteTimeGetCurrent() - slvT0) * 1000.0;
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
        sSLCamAVCaptureAudioFrames++;

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

    if (fake) {
        if (mediaType == kCMMediaType_Video) SLVCamVideoBeat(fmt, slvProcMs, YES);
        ((SLVProcessSampleBufferFn)orig)(self, _cmd, fake);
        CFRelease(fake);
    } else {
        if (mediaType == kCMMediaType_Video) SLVCamVideoBeat(fmt, slvProcMs, NO);
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

#pragma mark - RTC 编码参数探针（0.3.58）

// 「对面看着糊」到底是编码档位低，还是美颜把细节磨掉了？
// 这两件事在我们这一层看不到 —— 只能问宿主：把 Agora 真正收到的参数打出来。
//
// 全部**只读**：拦下来打完日志，原样转发给原实现，宿主行为一个字节都不变。
// 之所以要单独做，是因为 0.3.57 的零拷贝对照场（素材 720x1280、和宿主格式完全一致、
// 我们一个像素没动）对面**照样糊** —— 那问题就只能在这条链的下游。
//
// 0.3.59 起唯一例外是 setVideoEncoderConfiguration：开关打开时会先改写档位再转发。

static NSString *SLVCamKV(id obj, NSString *key) {
    if (!obj) return @"-";
    @try {
        id v = [obj valueForKey:key];
        if (!v || v == [NSNull null]) return @"-";
        return [v description];
    } @catch (__unused NSException *e) {
        return @"?";
    }
}

/// dimension 是 CGSize，KVC 回来是 NSValue。日志里「1280x720」比「{1280, 720}」好认。
static NSString *SLVCamKVSize(id obj, NSString *key) {
    if (!obj) return @"-";
    @try {
        id v = [obj valueForKey:key];
        if (!v || v == [NSNull null]) return @"-";
        if ([v isKindOfClass:[NSValue class]]) {
            const char *t = [(NSValue *)v objCType];
            if (t && strcmp(t, @encode(CGSize)) == 0) {
                CGSize s = [(NSValue *)v CGSizeValue];
                return [NSString stringWithFormat:@"%.0fx%.0f", s.width, s.height];
            }
        }
        return [v description];
    } @catch (__unused NSException *e) {
        return @"?";
    }
}

#define SLV_MAX_RTC_HOOKS 8
static Method gSLRtcMethod[SLV_MAX_RTC_HOOKS];
static IMP    gSLRtcOrig[SLV_MAX_RTC_HOOKS];
static int    gSLRtcCount = 0;
static BOOL   sSLRtcLogged = NO;

/// 按 Method 指针存原实现：同一个 selector 在父类和子类上都可能被调用，
/// 存成「一个 selector 一份」会把子类那次转发到父类的实现上去。
static IMP SLVCamRtcOrigIMP(id self, SEL _cmd) {
    Method m = class_getInstanceMethod([self class], _cmd);
    for (int i = 0; i < gSLRtcCount; i++) {
        if (gSLRtcMethod[i] == m) return gSLRtcOrig[i];
    }
    return NULL;
}

static BOOL SLVCamRtcHook(Class cls, NSString *name, IMP imp) {
    if (!cls) return NO;
    SEL sel = NSSelectorFromString(name);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    for (int i = 0; i < gSLRtcCount; i++) if (gSLRtcMethod[i] == m) return YES;
    if (gSLRtcCount >= SLV_MAX_RTC_HOOKS) return NO;
    gSLRtcMethod[gSLRtcCount] = m;
    gSLRtcOrig[gSLRtcCount] = method_getImplementation(m);
    gSLRtcCount++;
    method_setImplementation(m, imp);
    SLVLog(@"RTC: 挂上 -[%s %s]", class_getName(cls), sel_getName(sel));
    return YES;
}

// 返回类型必须是 int：这几个 API 都返回错误码，宿主会拿它判断成败。
// 声明成 void 会丢返回值，轻则日志里一堆误判，重则宿主以为设置失败而重试。

// ---- 0.3.59：上行档位抬高（默认关） ----
//
// 0.3.58 的探针把「糊」定位成一条硬上限：陌陌交给 Agora 的是 fps=15 · bitrate=500。
// 500kbps ÷ 15fps ÷ 921600px ≈ 0.036 bit/像素 —— 这个密度下编码器必然降分辨率，
// 我们送 720x1280，对面拿到的只有 360p 级别。
//
// 同一个网络下安卓端看着明显更清楚，说明带宽不是瓶颈，是 iOS 端自己压得太狠。
// 所以这里做一件事：宿主把档位交给引擎之前，先抬上去再转发。
//
// 默认关 —— 高码率在弱网下会更卡、更耗电，得让用户自己决定要不要。
#define SLV_ENC_MIN_FPS       24
// 0.3.60 验证版：故意抬到 4000，不是最终值。
// 1600 那次对面看不出区别，只有两种可能 —— 要么码率没落地（被通后重置 / 被 SDK clamp），
// 要么落地了但 1600 对这个素材还不够。4000 拉到一个明显失衡的值，
// 就能一刀切开：有变化 = 链路通，没变化 = 根本没落地。
#define SLV_ENC_MIN_KBPS    4000
#define SLV_ENC_SHORT_SIDE    720    // 短边至少 720（竖屏 720x1280 / 横屏 1280x720）
#define SLV_ENC_LONG_MAX     1280    // 长边不再往上加，免得一路顶到 4K 白耗带宽

static BOOL SLVCamEncodeBoostOn(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:kSLCamEncodeBoostKey];
    return v ? [v boolValue] : NO;
}

/// 按候选键名依次取，第一个取到的就是它。Agora 各版本这个属性叫法不完全一样，
/// 0.3.58 只试了 dimension，日志里一直打「-」正是这个原因。
static id SLVCamKVFirst(id obj, NSArray<NSString *> *keys, NSString **hitKey) {
    if (!obj) return nil;
    for (NSString *k in keys) {
        @try {
            id v = [obj valueForKey:k];
            if (v && v != [NSNull null]) {
                if (hitKey) *hitKey = k;
                return v;
            }
        } @catch (__unused NSException *e) { }
    }
    return nil;
}

/// 把宿主给的档位抬到「看得清」的水平。返回 YES 表示真的动了。
/// 全部只改这份配置对象：宿主本来就是要把它交给引擎的，改它等于改了它的意图，
/// 但不会碰到引擎之外的任何状态。
static BOOL SLVCamRaiseEncoderConfig(id cfg, NSInteger *outFps, NSInteger *outKbps,
                                     CGSize *outDim, BOOL *hasDim,
                                     NSInteger *inFps, NSInteger *inKbps, CGSize *inDim) {
    if (!cfg) return NO;

    NSString *dimKey = nil;
    id dimVal = SLVCamKVFirst(cfg, @[@"dimension", @"videoDimension", @"size"], &dimKey);

    id fpsVal = SLVCamKVFirst(cfg, @[@"frameRate"], NULL);
    id kbpsVal = SLVCamKVFirst(cfg, @[@"bitrate"], NULL);
    NSInteger fps = fpsVal ? [fpsVal integerValue] : 0;
    NSInteger kbps = kbpsVal ? [kbpsVal integerValue] : 0;
    *inFps = fps;
    *inKbps = kbps;
    *inDim = CGSizeZero;
    *hasDim = NO;

    CGSize dim = CGSizeZero;
    if ([dimVal isKindOfClass:[NSValue class]]) {
        const char *t = [(NSValue *)dimVal objCType];
        if (t && strcmp(t, @encode(CGSize)) == 0) dim = [(NSValue *)dimVal CGSizeValue];
    }
    if (dim.width >= 2 && dim.height >= 2) {
        *hasDim = YES;
        *inDim = dim;
    }

    NSInteger tFps = MAX(fps, SLV_ENC_MIN_FPS);
    NSInteger tKbps = MAX(kbps, SLV_ENC_MIN_KBPS);
    CGSize tDim = dim;

    if (*hasDim) {
        CGFloat mn = MIN(dim.width, dim.height);
        CGFloat mx = MAX(dim.width, dim.height);
        CGFloat k = 1.0;
        if (mn < SLV_ENC_SHORT_SIDE) k = SLV_ENC_SHORT_SIDE / mn;
        if (mx * k > SLV_ENC_LONG_MAX) k = SLV_ENC_LONG_MAX / mx;
        if (k > 1.0) {
            // 编码器只吃偶数边长，差 1 像素会被拒
            tDim = CGSizeMake(round(dim.width * k / 2.0) * 2.0,
                              round(dim.height * k / 2.0) * 2.0);
        }
    }

    BOOL changed = NO;
    if (tFps != fps) {
        @try { [cfg setValue:@(tFps) forKey:@"frameRate"]; changed = YES; }
        @catch (__unused NSException *e) { }
    }
    if (tKbps != kbps) {
        @try { [cfg setValue:@(tKbps) forKey:@"bitrate"]; changed = YES; }
        @catch (__unused NSException *e) { }
    }
    if (*hasDim && !CGSizeEqualToSize(tDim, dim) && dimKey) {
        @try { [cfg setValue:[NSValue valueWithCGSize:tDim] forKey:dimKey]; changed = YES; }
        @catch (__unused NSException *e) { }
    }

    *outFps = tFps;
    *outKbps = tKbps;
    *outDim = tDim;
    return changed;
}

static int SLVCamRtcVideoConfig(id self, SEL _cmd, id cfg) {
    NSString *dimKey = nil;
    (void)SLVCamKVFirst(cfg, @[@"dimension", @"videoDimension", @"size"], &dimKey);
    NSString *dimText = dimKey ? SLVCamKVSize(cfg, dimKey) : @"-";

    if (!SLVCamEncodeBoostOn()) {
        SLVLog(@"RTC: 编码档位 dimension=%@ · fps=%@ · bitrate=%@ · orientation=%@ · degradation=%@ · mirror=%@",
              dimText, SLVCamKV(cfg, @"frameRate"), SLVCamKV(cfg, @"bitrate"),
              SLVCamKV(cfg, @"orientationMode"), SLVCamKV(cfg, @"degradationPreference"),
              SLVCamKV(cfg, @"mirrorMode"));
    } else {
        NSInteger iFps = 0, iKbps = 0, tFps = 0, tKbps = 0;
        CGSize iDim = CGSizeZero, tDim = CGSizeZero;
        BOOL hasDim = NO;
        BOOL changed = SLVCamRaiseEncoderConfig(cfg, &tFps, &tKbps, &tDim, &hasDim,
                                                &iFps, &iKbps, &iDim);
        NSString *dimFrom = hasDim ? [NSString stringWithFormat:@"%.0fx%.0f", iDim.width, iDim.height] : @"-";
        NSString *dimTo = hasDim ? [NSString stringWithFormat:@"%.0fx%.0f", tDim.width, tDim.height] : @"-";
        if (changed) {
            SLVLog(@"RTC: 编码档位 抬高 %ldfps/%ldkbps/%@ → %ldfps/%ldkbps/%@（已改写，再转发给引擎）",
                  (long)iFps, (long)iKbps, dimFrom, (long)tFps, (long)tKbps, dimTo);
        } else {
            SLVLog(@"RTC: 编码档位 %ldfps/%ldkbps/%@ —— 已经不低于目标，原样转发",
                  (long)iFps, (long)iKbps, dimFrom);
        }
    }

    IMP o = SLVCamRtcOrigIMP(self, _cmd);
    return o ? ((int (*)(id, SEL, id))o)(self, _cmd, cfg) : 0;
}

static int SLVCamRtcBeauty(id self, SEL _cmd, BOOL on, id opt) {
    SLVLog(@"RTC: 美颜 %@ · lightening=%@ smoothness=%@ redness=%@ sharpness=%@",
          on ? @"开" : @"关",
          SLVCamKV(opt, @"lighteningLevel"), SLVCamKV(opt, @"smoothnessLevel"),
          SLVCamKV(opt, @"rednessLevel"), SLVCamKV(opt, @"sharpnessLevel"));
    IMP o = SLVCamRtcOrigIMP(self, _cmd);
    return o ? ((int (*)(id, SEL, BOOL, id))o)(self, _cmd, on, opt) : 0;
}

static int SLVCamRtcVideoProfile(id self, SEL _cmd, NSInteger profile, BOOL swap) {
    SLVLog(@"RTC: 视频档位 profile=%ld · swapWH=%@（0=160x120 1=320x180 2=480x360 3=640x360 4=640x480 …）",
          (long)profile, swap ? @"Y" : @"N");
    IMP o = SLVCamRtcOrigIMP(self, _cmd);
    return o ? ((int (*)(id, SEL, NSInteger, BOOL))o)(self, _cmd, profile, swap) : 0;
}

static int SLVCamRtcCameraConfig(id self, SEL _cmd, id cfg) {
    SLVLog(@"RTC: 采集配置 %@", SLVCamKV(cfg, @"description") ?: @"-");
    IMP o = SLVCamRtcOrigIMP(self, _cmd);
    return o ? ((int (*)(id, SEL, id))o)(self, _cmd, cfg) : 0;
}

/// 4.x 进频道走的是这个。它本身不带分辨率，但能证明「探针确实活着」——
/// 如果它打了、编码档位那条一直不打，就说明陌陌没走标准 API，得换地方找。
static int SLVCamRtcChannelMedia(id self, SEL _cmd, id opt) {
    SLVLog(@"RTC: 频道媒体选项 publishCamera=%@ publishMic=%@ autoSubscribe=%@",
          SLVCamKV(opt, @"publishCameraTrack"),
          SLVCamKV(opt, @"publishMicrophoneTrack"),
          SLVCamKV(opt, @"autoSubscribeAudio"));
    IMP o = SLVCamRtcOrigIMP(self, _cmd);
    return o ? ((int (*)(id, SEL, id))o)(self, _cmd, opt) : 0;
}

/// RTC SDK 是懒加载的：首次扫描时可能还不存在。所以这个函数可以被反复调用，
/// 一旦类出现了就挂上，之后一直有效。
static void SLVCamInstallRtcProbes(void) {
    if (sSLRtcLogged) return;
    Class kit = objc_getClass("AgoraRtcEngineKit");
    if (!kit) return;

    SLVCamRtcHook(kit, @"setVideoEncoderConfiguration:", (IMP)SLVCamRtcVideoConfig);
    SLVCamRtcHook(kit, @"setBeautyEffectOptions:options:", (IMP)SLVCamRtcBeauty);
    SLVCamRtcHook(kit, @"setVideoProfile:swapWidthAndHeight:", (IMP)SLVCamRtcVideoProfile);
    SLVCamRtcHook(kit, @"setCameraCapturerConfiguration:", (IMP)SLVCamRtcCameraConfig);
    SLVCamRtcHook(kit, @"updateChannelWithMediaOptions:", (IMP)SLVCamRtcChannelMedia);

    // 一个都没命中 = 这个类不是 RTC 引擎（或者陌陌用的是别家 SDK）。
    // 不置标志，下次会话加输出时再试一遍 —— 总比一次没命中就永久放弃好。
    if (gSLRtcCount == 0) {
        SLVLog(@"RTC: AgoraRtcEngineKit 存在但 5 个方法全没命中，等下次会话再试");
        return;
    }
    sSLRtcLogged = YES;
    SLVLog(@"RTC: 编码/美颜探针已布点 %d 项（编码档位可改写，其余只读）", gSLRtcCount);
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
    // 会话开始装配输出，往往意味着 RTC / 录音 SDK 已经加载完了，
    // 这时候补扫一次符号，把刚才还不存在的镜像覆盖上
    SLVCamInstallAudioUnitHook();
    // 0.3.58：RTC 类多半也是这会儿才齐，编码/美颜探针在这里补挂一次
    SLVCamInstallRtcProbes();
}

static void SLVCamHookSessionOutputs(void) {
    Class cls = objc_getClass("AVCaptureSession");
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
// 0.3.56：两个新探针 —— 一个看「是不是往文件里直写」，一个看「音轨交给了谁」
static id (*gSLRecorderInitOrig)(id, SEL, NSURL *, NSDictionary *, NSError **);
static void (*gSLWriterAddInputOrig)(id, SEL, id);

static int sSLCamTapCount = 0;      // tap 收到过多少个 buffer（体检用）
static int sSLCamTapReplaced = 0;   // 其中成功换成素材音频的次数

int SLVCamAudioTapCount(void) { return sSLCamTapCount; }

typedef void (^SLVCamTapBlock)(AVAudioPCMBuffer *buffer, AVAudioTime *when);

/// AVAudioEngine tap 接管（0.3.56）。
///
/// 微信拍摄是唯一一个「四条入口全都不经过」的场景：AudioUnitRender 0 次、
/// AVCapture 音频 0 帧、AudioQueue 建了队列但一次回调都没有。这种情况下唯一
/// 还能碰到 PCM 的地方就是 inputNode 的 tap block —— buffer 是宿主给的可写内存，
/// 我们往里填素材音频，宿主读到的就是素材，时序和长度一点没变。
///
/// 以前这里只打一行日志就放行，等于眼睁睁看着一条能换的路不用。
static void SLVCamAudioTapProbe(id self, SEL _cmd, NSUInteger bus, AVAudioFrameCount frames,
                               AVAudioFormat *fmt, id block) {
    if (!gSLTapOrig) return;

    // 注意：**不能**在这里判断 SLVCamInjecting()。tap 只装一次，宿主一旦拿到的是
    // 我们的原封 block，之后用户再打开「替换」也换不进去了 —— 那样「先开相机、
    // 后开替换」就永远没声音。所以永远包一层，开关的判断挪进 block 里。
    if (!block || !fmt) {
        gSLTapOrig(self, _cmd, bus, frames, fmt, block);
        return;
    }

    AudioStreamBasicDescription a;
    memset(&a, 0, sizeof(a));
    if (fmt.streamDescription) a = *fmt.streamDescription;
    static BOOL logged = NO;
    if (!logged) {
        logged = YES;
        SLVLog(@"音频: 命中 AVAudioEngine tap bus=%lu %.0fHz %uch %uB/帧 交错=%@ · 已在 tap 里接管",
              (unsigned long)bus, a.mSampleRate, (unsigned)a.mChannelsPerFrame,
              (unsigned)a.mBytesPerFrame,
              (a.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? @"N" : @"Y");
    }

    SLVCamTapBlock orig = (SLVCamTapBlock)block;
    // __weak 是有意的：tap block 由 node 持有，block 里再强引用 node 就是环，
    // 通话结束引擎销毁了 node 也不会释放 —— 麦克风会一直开着。
    __weak id weakNode = self;
    SLVCamTapBlock wrapped = ^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
        sSLCamTapCount++;
        id node = weakNode;
        if (node && buf && buf.frameLength > 0 && SLVCamInjecting()) {
            if ([[SLVCamFeed shared] fillTapBuffer:buf consumer:(__bridge const void *)node]) {
                if (sSLCamTapReplaced++ == 0) {
                    SLVLog(@"音频: 已接管 AVAudioEngine tap 麦克风（%.0fHz %uch）",
                          buf.format.sampleRate, (unsigned)buf.format.channelCount);
                }
            }
        }
        if (orig) orig(buf, when);
    };
    gSLTapOrig(self, _cmd, bus, frames, fmt, (id)wrapped);
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
    }
    if (gSLMovieStartOrig) gSLMovieStartOrig(self, _cmd, url, delegate);
}

/// AVAudioRecorder 的**构造函数**（0.3.56）。
///
/// 之前只挂了 `-record`，看不到「它到底按什么格式往哪个文件写」。微信拍摄如果是
/// 这条路径，画面走 VideoDataOutput、声音直接进文件，我们连一次 PCM 都摸不到 ——
/// 那就只剩下「把 AVAudioRecorder 换掉」这一条路，代价完全不同，得先认出来。
static id SLVCamRecorderInitProbe(id self, SEL _cmd, NSURL *url, NSDictionary *settings, NSError **err) {
    static BOOL logged = NO;
    id obj = gSLRecorderInitOrig ? gSLRecorderInitOrig(self, _cmd, url, settings, err) : nil;
    if (!logged) {
        logged = YES;
        NSString *fmt = settings[AVFormatIDKey] ? [settings[AVFormatIDKey] description] : @"?";
        SLVLog(@"音频: 命中 AVAudioRecorder 建实例（%@ · fmt=%@ · %.0fHz %@ch · %@）· 声音直写文件，PCM 摸不到",
              url.lastPathComponent ?: @"?",
              fmt,
              [settings[AVSampleRateKey] doubleValue],
              settings[AVNumberOfChannelsKey] ?: @"?",
              obj ? @"创建成功" : @"创建失败");
    }
    return obj;
}

/// AVAssetWriter 加输入（0.3.56）：一句话区分「音轨是写文件那条」还是「就是采集那条」。
static void SLVCamWriterAddInputProbe(id self, SEL _cmd, id input) {
    static int logged = 0;
    if (logged < 4) {
        logged++;
        NSString *media = @"?";
        if ([input respondsToSelector:@selector(mediaType)]) media = [(AVAssetWriterInput *)input mediaType];
        SLVLog(@"音频: AVAssetWriter 加输入 #%d → %@", logged, media);
    }
    if (gSLWriterAddInputOrig) gSLWriterAddInputOrig(self, _cmd, input);
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
    SLVCamHookSel(rec, NSSelectorFromString(@"initWithURL:settings:error:"),
                 (IMP)SLVCamRecorderInitProbe, (IMP *)&gSLRecorderInitOrig);

    Class movie = objc_getClass("AVCaptureMovieFileOutput");
    SLVCamHookSel(movie, NSSelectorFromString(@"startRecordingToOutputFileURL:recordingDelegate:"),
                 (IMP)SLVCamMovieStartProbe, (IMP *)&gSLMovieStartOrig);

    // 0.3.56：微信拍摄如果真的「声音直写文件」，音轨会交给 AVAssetWriter。
    // 这一行日志就能把「到底谁在收音频」钉死，不用再猜。
    Class writer = objc_getClass("AVAssetWriter");
    SLVCamHookSel(writer, @selector(addInput:),
                 (IMP)SLVCamWriterAddInputProbe, (IMP *)&gSLWriterAddInputOrig);

    SLVLog(@"探测: 录制链路已布点 tap=%d recorder=%d movie=%d writer=%d",
          inputNode != nil, rec != nil, movie != nil, writer != nil);
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

/// 从素材取一帧、按当前旋转/镜像摆好、转成 JPEG。
/// 条件不满足返回 nil，调用方原样放行真照片。
static NSData *SLVCamPhotoJPEG(void) {
    if (!SLVCamInjecting() || !SLVCamArmed()) return nil;
    CVPixelBufferRef pb = [[SLVCamFeed shared]
        copyOrientedFrameForPixelFormat:kCVPixelFormatType_32BGRA size:CGSizeZero];
    if (!pb) return nil;
    NSData *jpeg = SLVCamJPEGFromPixelBuffer(pb, 0.92);
    CVPixelBufferRelease(pb);
    return jpeg.length ? jpeg : nil;
}

static void SLVCamPhotoLogOnce(void) {
    static BOOL logged = NO;
    if (logged) return;
    logged = YES;
    SLVLog(@"注入: 拍照已接管（AVCapturePhotoOutput）· 返回素材画面 %ld° / 镜像%@",
          (long)([SLVCamFeed shared].rotation % 360),
          [SLVCamFeed shared].mirrorEnabled ? @"开" : @"关");
}

static NSData *SLVCamPhotoFileData(id self, SEL _cmd) {
    NSData *fake = SLVCamPhotoJPEG();
    if (fake) { SLVCamPhotoLogOnce(); return fake; }
    return gSLPhotoDataOrig ? gSLPhotoDataOrig(self, _cmd) : nil;
}

static NSData *SLVCamPhotoFileDataCustom(id self, SEL _cmd, id customizer) {
    NSData *fake = SLVCamPhotoJPEG();
    if (fake) { SLVCamPhotoLogOnce(); return fake; }
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
// 视频输出那条路拿到的是**已经转过向**的缓冲（抖音是 1080x1920 竖屏），
// 而 AVCapturePhoto 给的是**传感器原始方向**（3840x2160 横屏）。两者差 90°。
// 不补这一下，素材就被塞进一个转了 90° 的框里 —— 预览正、拍出来歪。
//
// 补哪个方向由照片自己的 EXIF 方向决定：EXIF 说「要顺时针转 90° 才正」（=6），
// 我们就先逆时针转 90°（=270°），等宿主/系统把它转回来正好抵消。
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

    // 第三条：QQ 拍摄页录制走的第四条路 —— 先布点确认是哪条
    SLVCamInstallRecordingProbes();

    // 拍照（AVCaptureStillImageOutput）走的是另一条路，上面那套启发式挂不到
    SLVCamInstallStillImageHook();

    // 抖音拍照走 AVCapturePhotoOutput，又是另一条 —— 两条都要挂
    SLVCamInstallPhotoOutputHook();

    // 0.3.58：RTC 编码档位 / 美颜强度探针。类没加载的话会在会话加输出时补挂。
    SLVCamInstallRtcProbes();

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

int SLVCamAVCaptureAudioFrameCount(void) {
    return sSLCamAVCaptureAudioFrames;
}
