//
//  SLCamInject.m
//  声临 · 虚拟摄像头 —— 注入层实现
//

#import "SLCamInject.h"
#import "SLCamFeed.h"
#import "SLCamAudioUnit.h"
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

/// 四字符码转可读串（'BGRA' / '420f'），日志里比裸数字好认
static NSString *SLFourCC(OSType v) {
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

/// 自建一个「和假帧自洽、又保留宿主 extensions」的 fmt。
///
/// 这里绝对不能用 CMVideoFormatDescriptionCreateForImageBuffer：它是从像素缓冲区
/// 反推 extensions 的，而我们手上的帧是 CVPixelBufferCreate 干净造出来的，
/// 反推出来就是空字典。宿主（抖音尤其）会去 CMFormatDescriptionGetExtension
/// 取相机内参、色彩矩阵这类 key，拿到 NULL 之后是不判空直接 CFRelease 的 ——
/// CoreFoundation 对 CFRelease(NULL) 是硬断言，当场 SIGTRAP。
/// 0.2.9「点开录制就闪退」的栈就是：我们的假帧 → _processSampleBuffer: →
/// AwemeCore 代理 → CFRelease(NULL)。所以必须把宿主 fmt 的 extensions 整包搬过去。
///
/// 尺寸用假帧自己的，这样 CMVideoFormatDescriptionMatchesImageBuffer 才过。
static CMVideoFormatDescriptionRef SLCamMakeFormatDescription(CMFormatDescriptionRef hostFmt,
                                                              CVPixelBufferRef frame) {
    if (!hostFmt || !frame) return NULL;

    OSType subType = CMFormatDescriptionGetMediaSubType(hostFmt);
    if (subType == 0) subType = CVPixelBufferGetPixelFormatType(frame);

    CMVideoFormatDescriptionRef out = NULL;
    OSStatus st = CMVideoFormatDescriptionCreate(kCFAllocatorDefault, subType,
                                                 (int32_t)CVPixelBufferGetWidth(frame),
                                                 (int32_t)CVPixelBufferGetHeight(frame),
                                                 CMFormatDescriptionGetExtensions(hostFmt),
                                                 &out);
    if (st == noErr && out) return out;

    // 带着宿主 extensions 造不出来（个别 key 和尺寸不自洽），退回系统那套：
    // extensions 是空的，但至少 fmt 和帧自洽，画面不会黑。
    out = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, frame, &out) != noErr) {
        return NULL;
    }
    if (sSLCamOwnFmtExtFailLogged++ == 0) {
        SLLog(@"注入: 带宿主 extensions 建 fmt 失败 st=%d，已退回空 extensions（宿主可能取不到内参）", (int)st);
    }
    return out;
}

/// 把真帧上的附件整套搬到假帧上。
///
/// CMSampleBufferCreateReadyWithImageBuffer 只传播「像素缓冲区上」的附件，而真帧
/// sample buffer 自己带的那些（相机内参、时间戳对齐信息等）一条都继承不过来。
/// 宿主用 CMGetAttachment / CMCopyDictionaryOfAttachments 去取，就会拿到 NULL。
static void SLCamCopySampleAttachments(CMSampleBufferRef from, CMSampleBufferRef to) {
    if (!from || !to) return;
    CFDictionaryRef atts = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, from,
                                                         kCMAttachmentMode_ShouldPropagate);
    if (!atts) return;
    OSStatus st = CMSetAttachments(to, atts, kCMAttachmentMode_ShouldPropagate);
    if (st != noErr && sSLCamSetAttachFailLogged++ == 0) {
        SLLog(@"注入: 附件回填失败 st=%d（宿主可能取不到内参）", (int)st);
    }
    CFRelease(atts);
}

/// 首次注入时把两边的 key 列表打出来。
/// 万一以后还崩在这个位置，这一行就能直接指出宿主缺哪个 key，不用再猜。
static void SLCamLogAttachmentKeys(CMSampleBufferRef sbuf, CMFormatDescriptionRef fmt) {
    if (sSLCamAttachLogged++ > 0) return;

    CFDictionaryRef atts = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, sbuf,
                                                         kCMAttachmentMode_ShouldPropagate);
    NSArray *attKeys = atts ? [(__bridge NSDictionary *)atts allKeys] : @[];
    CFDictionaryRef ext = fmt ? CMFormatDescriptionGetExtensions(fmt) : NULL;
    NSArray *extKeys = ext ? [(__bridge NSDictionary *)ext allKeys] : @[];

    SLLog(@"注入: 真帧附件 %lu 项 %@ · 宿主 fmt 扩展 %lu 项 %@",
          (unsigned long)attKeys.count, attKeys,
          (unsigned long)extKeys.count, extKeys);
    if (atts) CFRelease(atts);
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

            // 宿主自己的 fmt 和它自己的 buffer 是否自洽？
            // iOS 17 起 AVCaptureConnection 的旋转会直接作用到 VideoDataOutput 的 buffer 上：
            // buffer 变成竖的（1080x1920），而 fmt 还留着传感器尺寸（1920x1080）。
            // 这种 fmt 拿来做 CMSampleBufferCreateReadyWithImageBuffer 的校验必然不过。
            BOOL fmtMatchesReal = CMVideoFormatDescriptionMatchesImageBuffer(
                (CMVideoFormatDescriptionRef)fmt, img);

            if (!sLoggedFirstVideo) {
                sLoggedFirstVideo = YES;
                CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions((CMVideoFormatDescriptionRef)fmt);
                SLLog(@"首帧 视频 %zux%zu pf=%u(%@) · fmt %dx%d %@ · 自洽=%@",
                      (size_t)size.width, (size_t)size.height, (unsigned)pf, SLFourCC(pf),
                      d.width, d.height,
                      SLFourCC(CMFormatDescriptionGetMediaSubType(fmt)),
                      fmtMatchesReal ? @"Y" : @"N");
                // 宿主到底从帧上取了哪些 key，一次看清 —— 以后崩在这个位置能直接定位
                SLCamLogAttachmentKeys(sbuf, fmt);
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
                    SLLog(@"注入: 真帧 duration 非法（value=%lld scale=%d flags=%u），已归一成 1/30",
                          timing.duration.value, timing.duration.timescale, timing.duration.flags);
                }
                timing.duration = CMTimeMake(1, 30);
            }
            if (!CMTIME_IS_VALID(timing.decodeTimeStamp)) {
                if (sSLCamDTSFixLogged++ == 0) {
                    SLLog(@"注入: 真帧 dts 非法（value=%lld scale=%d flags=%u），已置为 invalid",
                          timing.decodeTimeStamp.value, timing.decodeTimeStamp.timescale,
                          timing.decodeTimeStamp.flags);
                }
                timing.decodeTimeStamp = kCMTimeInvalid;
            }
            if (!CMTIME_IS_VALID(timing.presentationTimeStamp)) {
                // 没有有效的 PTS 就没法接进宿主的时间轴，硬塞一个反而会把下游时序搞乱。
                // 这一帧直接放行真画面，下一帧再说。
                if (sSLCamBadPTS++ == 0) SLLog(@"注入: 真帧没有有效 PTS，跳过替换");
                ((SLProcessSampleBufferFn)orig)(self, _cmd, sbuf);
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
                    ownFmt = SLCamMakeFormatDescription(fmt, frame);
                    if (ownFmt) {
                        useFmt = ownFmt;
                        if (sSLCamOwnFmtLogged++ == 0) {
                            CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions((CMVideoFormatDescriptionRef)fmt);
                            SLLog(@"注入: 假帧与宿主 fmt 不匹配，已自建 fmt（帧 %ux%u %@ / fmt %dx%d %@ · 宿主扩展 %ld 项）",
                                  (unsigned)CVPixelBufferGetWidth(frame),
                                  (unsigned)CVPixelBufferGetHeight(frame),
                                  SLFourCC(CVPixelBufferGetPixelFormatType(frame)),
                                  d.width, d.height, SLFourCC(CMFormatDescriptionGetMediaSubType(fmt)),
                                  (long)(CMFormatDescriptionGetExtensions(fmt)
                                         ? CFDictionaryGetCount(CMFormatDescriptionGetExtensions(fmt)) : 0));
                        }
                    }
                }

                OSStatus st = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, frame, useFmt,
                                                                       &timing, &fake);
                if (st != noErr) {
                    fake = NULL;
                    sSLCamFailCount++;
                    // 前 3 次 + 之后每 120 帧打一条，既能看到细节又不会把日志刷爆
                    if (sSLCamFailCount <= 3 || sSLCamFailCount % 120 == 0) {
                        CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions((CMVideoFormatDescriptionRef)fmt);
                        SLLog(@"注入: 打包失败 #%d st=%d · fmt %dx%d %@ · 帧 %ux%u %@ · 自洽=%@ · 兜底fmt=%@",
                              sSLCamFailCount, (int)st,
                              d.width, d.height, SLFourCC(CMFormatDescriptionGetMediaSubType(fmt)),
                              (unsigned)CVPixelBufferGetWidth(frame),
                              (unsigned)CVPixelBufferGetHeight(frame),
                              SLFourCC(CVPixelBufferGetPixelFormatType(frame)),
                              fmtMatchesReal ? @"Y" : @"N",
                              ownFmt ? @"Y" : @"N");
                    }
                } else {
                    if (sSLCamFailCount > 0) {
                        SLLog(@"注入: 打包恢复正常（累计失败 %d 次）", sSLCamFailCount);
                        sSLCamFailCount = 0;
                    }
                    // 真帧的附件必须搬到假帧上：宿主那边 CMGetAttachment /
                    // CMCopyDictionaryOfAttachments 拿不到东西，是不判空就 CFRelease 的
                    SLCamCopySampleAttachments(sbuf, fake);
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

                        OSStatus ast = CMSampleBufferCreate(kCFAllocatorDefault, newBB, true, NULL, NULL, fmt,
                                                            frames, 1, &t, 0, NULL, &fake);
                        if (ast != noErr) {
                            fake = NULL;
                            sSLCamAudioFailCount++;
                            if (sSLCamAudioFailCount <= 3 || sSLCamAudioFailCount % 300 == 0) {
                                SLLog(@"注入: 音频打包失败 #%d st=%d · %u 帧 · %zu 字节",
                                      sSLCamAudioFailCount, (int)ast, (unsigned)frames, len);
                            }
                        } else {
                            // 音频帧同样要把宿主的附件带过去，理由和视频一样
                            SLCamCopySampleAttachments(sbuf, fake);
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

/// 只挂「void + 一个指针参数」的方法。
///
/// 名字带 SampleBuffer 不代表签名就是 (self, _cmd, CMSampleBufferRef)，
/// 万一挂到带 connection 之类的多参方法上，我们的实现会把后面的参数整个丢掉，
/// 宿主当场行为异常。宁可漏挂，不可挂错。
static BOOL SLCamIsSinglePointerArgMethod(Method m) {
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
static void SLCamDumpCandidates(const char *className) {
    Class cls = objc_getClass(className);
    if (!cls) {
        SLLog(@"探测: %s 不存在", className);
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
    SLLog(@"探测: %s → %@", className,
          hits.count ? [hits componentsJoinedByString:@", "] : @"(无)");
}

#pragma mark - 会话输出探测

// App 到底往会话里加了哪些输出？音频是不是走 AVCaptureAudioDataOutput，
// 直接看这个就知道，比猜私有方法名靠谱。
typedef void (*SLAddOutputFn)(id, SEL, id);
static IMP gSLAddOutputOrig = NULL;

static void SLCamAddOutput(id self, SEL _cmd, id output) {
    if (output) {
        SLLog(@"会话加输出: %s", class_getName([output class]));
    }
    if (gSLAddOutputOrig) {
        ((SLAddOutputFn)gSLAddOutputOrig)(self, _cmd, output);
    }
    // 会话开始装配输出，往往意味着 RTC / 录音 SDK 已经加载完了，
    // 这时候补扫一次符号，把刚才还不存在的镜像覆盖上
    SLCamInstallAudioUnitHook();
}

static void SLCamHookSessionOutputs(void) {
    Class cls = objc_getClass("AVCaptureSession");
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, @selector(addOutput:));
    if (!m) return;
    if (gSLAddOutputOrig) return;
    gSLAddOutputOrig = method_getImplementation(m);
    method_setImplementation(m, (IMP)SLCamAddOutput);
}

void SLCamInstallHooks(void) {
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
                if (!SLCamIsSinglePointerArgMethod(list[i])) {
                    [skipped addObject:[NSString stringWithFormat:@"-[%s %s]",
                                        class_getName(c), sel_getName(method_getName(list[i]))]];
                    continue;
                }
                SLCamHookMethod(c, list[i]);
            }
            free(list);
        }
    }

    if (skipped.count) {
        SLLog(@"注入: 跳过 %lu 个方法（签名不是单指针参数，挂了会丢参）: %@",
              (unsigned long)skipped.count, [skipped componentsJoinedByString:@", "]);
    }

    // 音频在各系统版本上未必走 AVCaptureAudioDataOutput，先把候选方法名和
    // 会话里实际加了哪些输出打出来，下次日志就能定位
    SLCamDumpCandidates("AVCaptureAudioDataOutput");
    SLCamDumpCandidates("AVCaptureAudioPreviewOutput");
    SLCamHookSessionOutputs();

    // 第二条链路：不经过 AVCapture 的麦克风（QQ 这类自建音频栈的 App）
    SLCamInstallAudioUnitHook();

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

BOOL SLCamAVCaptureAudioSeen(void) {
    return sSLCamAVCaptureAudioSeen;
}
