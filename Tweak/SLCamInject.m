//
//  SLCamInject.m
//  声临 · 虚拟摄像头 —— 注入层实现
//

#import "SLCamInject.h"
#import "SLCamFeed.h"
#import "SLLog.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>

typedef void (*SLProcessSampleBufferFn)(id, SEL, CMSampleBufferRef);

// 原始 IMP 用固定数组存，按 Method 指针线性比对。
//
// 别用 NSMapTable + NSPointerFunctionsOpaqueMemory 存这个：那套 key 语义是「裸指针」，
// 每次查询都新建一个 NSValue 对象、地址不同，永远查不到 —— 查不到就会把原始实现整个
// 跳过，表现为「Hook 装上了、日志也对、但摄像头全黑」。Method 数量个位数，线性扫足够。
#define SL_MAX_HOOKS 8
static Method gSLHookMethods[SL_MAX_HOOKS];
static IMP    gSLHookIMPs[SL_MAX_HOOKS];

static BOOL sSLCamInjecting = NO;
static BOOL sSLCamHooksInstalled = NO;
static int  sSLCamHookCount = 0;
static BOOL sLoggedMissingOrig = NO;
static BOOL sLoggedFirstVideo = NO;
static BOOL sLoggedFirstAudio = NO;

/// 音视频输出可能各自重写了 _processSampleBuffer:，必须按 Method 分别保存原始 IMP，
/// 否则音频会走到视频的原始实现上去（表现为只有画面变、声音还在）。
static IMP SLCamOriginalIMP(id self, SEL _cmd) {
    Method m = class_getInstanceMethod([self class], _cmd);
    if (!m) return NULL;
    for (int i = 0; i < sSLCamHookCount; i++) {
        if (gSLHookMethods[i] == m) return gSLHookIMPs[i];
    }
    if (!sLoggedMissingOrig) {
        sLoggedMissingOrig = YES;
        SLLog(@"注入: 找不到 %s 的原始 IMP，将原样放行", sel_getName(_cmd));
    }
    return NULL;
}

static void SLCamProcessSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sbuf) {
    IMP orig = SLCamOriginalIMP(self, _cmd);

    // 拿不到原始实现只能放弃（SLCamOriginalIMP 里已记日志）。这种情况只会在
    // hook 表被破坏时出现 —— 正常情况下查表是纯指针比对，不会失手。
    if (!orig) return;

    SLCamFeed *feed = [SLCamFeed shared];

    if (!sbuf || !sSLCamInjecting || ![feed isReady]) {
        ((SLProcessSampleBufferFn)orig)(self, _cmd, sbuf);
        return;
    }

    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sbuf);
    if (!fmt) { ((SLProcessSampleBufferFn)orig)(self, _cmd, sbuf); return; }

    CMMediaType mediaType = CMFormatDescriptionGetMediaType(fmt);
    CMSampleBufferRef fake = NULL;

    if (mediaType == kCMMediaType_Video) {
        CVImageBufferRef img = CMSampleBufferGetImageBuffer(sbuf);
        if (img) {
            OSType pf = CVPixelBufferGetPixelFormatType(img);
            CGSize size = CGSizeMake((CGFloat)CVPixelBufferGetWidth(img),
                                     (CGFloat)CVPixelBufferGetHeight(img));

            if (!sLoggedFirstVideo) {
                sLoggedFirstVideo = YES;
                SLLog(@"首帧 视频 %zux%zu pf=%u", (size_t)size.width, (size_t)size.height, (unsigned)pf);
            }

            CMSampleTimingInfo timing = {0};
            timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sbuf);
            timing.decodeTimeStamp       = CMSampleBufferGetDecodeTimeStamp(sbuf);
            timing.duration              = CMSampleBufferGetDuration(sbuf);
            if (CMTIME_IS_INVALID(timing.duration)) timing.duration = CMTimeMake(1, 30);

            CVPixelBufferRef frame = [feed copyFrameForPixelFormat:pf size:size];
            if (frame) {
                if (CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, frame, fmt, &timing, &fake) != noErr) {
                    SLLog(@"注入: CMSampleBuffer 构造失败（fmt 与帧不匹配）");
                    fake = NULL;
                }
                CVPixelBufferRelease(frame);
            }
        }
    } else if (mediaType == kCMMediaType_Audio) {
        // 只处理未压缩 PCM；AAC 之类的压缩音频直接放行，避免格式错乱
        if (CMFormatDescriptionGetMediaSubType(fmt) == kAudioFormatLinearPCM) {
            const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
            CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sbuf);
            size_t len = bb ? CMBlockBufferGetDataLength(bb) : 0;

            if (!sLoggedFirstAudio) {
                sLoggedFirstAudio = YES;
                SLLog(@"首帧 音频 %.0fHz %uch %uB/帧 len=%zu",
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

                        if (CMSampleBufferCreate(kCFAllocatorDefault, newBB, true, NULL, NULL, fmt,
                                                 frames, 1, &t, 0, NULL, &fake) != noErr) {
                            fake = NULL;
                        }
                        CFRelease(newBB);
                    }
                }
            }
        }
    }

    if (fake) {
        ((SLProcessSampleBufferFn)orig)(self, _cmd, fake);
        CFRelease(fake);
    } else {
        ((SLProcessSampleBufferFn)orig)(self, _cmd, sbuf);   // 拿不到假帧就放真帧，绝不黑屏
    }
}

static void SLCamHookMethod(Class owner, Method m) {
    if (!m) return;
    if (sSLCamHookCount >= SL_MAX_HOOKS) return;

    for (int i = 0; i < sSLCamHookCount; i++) {
        if (gSLHookMethods[i] == m) return;              // 已经 hook 过
    }

    IMP old = method_getImplementation(m);
    if (old == (IMP)SLCamProcessSampleBuffer) return;

    gSLHookMethods[sSLCamHookCount] = m;
    gSLHookIMPs[sSLCamHookCount] = old;
    sSLCamHookCount++;

    SLLog(@"hook -[%s %s] types=%s", class_getName(owner),
          sel_getName(method_getName(m)), method_getTypeEncoding(m));

    method_setImplementation(m, (IMP)SLCamProcessSampleBuffer);
}

void SLCamInstallHooks(void) {
    if (sSLCamHooksInstalled) return;
    sSLCamHooksInstalled = YES;

    // 不写死 selector：这几个类及其父类上凡是名字带 processSampleBuffer 的都挂上
    NSArray<NSString *> *classNames = @[
        @"AVCaptureVideoDataOutput",
        @"AVCaptureAudioDataOutput",
        @"AVCaptureMovieFileOutput",
        @"AVCapturePhotoOutput",
        @"AVCaptureOutput",
    ];

    for (NSString *cn in classNames) {
        Class cls = objc_getClass(cn.UTF8String);
        if (!cls) continue;
        for (Class c = cls; c; c = class_getSuperclass(c)) {
            unsigned int n = 0;
            Method *list = class_copyMethodList(c, &n);
            for (unsigned i = 0; i < n; i++) {
                NSString *name = @(sel_getName(method_getName(list[i])));
                if (![name containsString:@"processSampleBuffer"]) continue;
                SLCamHookMethod(c, list[i]);
            }
            free(list);
        }
    }

    if (sSLCamHookCount == 0) {
        SLLog(@"注入: 没找到 _processSampleBuffer: —— 该系统版本可能改了私有 API，"
              @"可用日志页确认后换挂点");
    } else {
        SLLog(@"注入: 共 hook %d 个方法", sSLCamHookCount);
    }
}

void SLCamSetInjecting(BOOL injecting) {
    if (sSLCamInjecting == injecting) return;
    sSLCamInjecting = injecting;
    SLLog(@"injecting = %@", injecting ? @"YES" : @"NO");
}

BOOL SLCamInjecting(void) {
    return sSLCamInjecting;
}

BOOL SLCamHooksInstalled(void) {
    return sSLCamHooksInstalled;
}

int SLCamHookCount(void) {
    return sSLCamHookCount;
}
