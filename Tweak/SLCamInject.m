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

            CVPixelBufferRef frame = [feed copyFrameForPixelFormat:pf size:size];
            if (frame) {
                // 优先沿用宿主的 fmt（下游的编码器/写入器都按它配置，换了会出岔子）。
                // 只有当假帧确实与它不匹配时，才退而求其次自建一个 —— 自建的那个
                // 必须把宿主的 extensions 带过去，否则宿主读扩展拿到 NULL 会崩。
                CMVideoFormatDescriptionRef useFmt = (CMVideoFormatDescriptionRef)fmt;
                CMVideoFormatDescriptionRef ownFmt = NULL;
                if (!CMVideoFormatDescriptionMatchesImageBuffer((CMVideoFormatDescriptionRef)fmt, frame)) {
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

    if (fake) {
        ((SLVProcessSampleBufferFn)orig)(self, _cmd, fake);
        CFRelease(fake);
    } else {
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
    }
    if (gSLMovieStartOrig) gSLMovieStartOrig(self, _cmd, url, delegate);
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

    SLVLog(@"探测: 录制链路已布点 tap=%d recorder=%d movie=%d",
          inputNode != nil, rec != nil, movie != nil);
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
