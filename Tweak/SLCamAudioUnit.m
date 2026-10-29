//
//  SLCamAudioUnit.m
//  声临 · 虚拟摄像头 —— 麦克风的第二条链路（AudioUnit 层）
//

#import "SLCamAudioUnit.h"
#import "SLCamSymbolHook.h"
#import "SLCamFeed.h"
#import "SLCamInject.h"
#import "SLLog.h"

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <string.h>

typedef OSStatus (*SLAudioUnitRenderFn)(AudioUnit, AudioUnitRenderActionFlags *,
                                        const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);
typedef OSStatus (*SLAudioQueueNewInputFn)(const AudioStreamBasicDescription *,
                                           AudioQueueInputCallback, void *, CFRunLoopRef,
                                           CFStringRef, UInt32, AudioQueueRef *);

static SLAudioUnitRenderFn gSLRenderOrig = NULL;
static SLAudioQueueNewInputFn gSLAQOrig = NULL;

static BOOL gSLHooked = NO;
static BOOL gSLRegistered = NO;
static BOOL gSLReplacedLogged = NO;
static BOOL gSLAQProbeLogged = NO;
static int  gSLReplaceCount = 0;

// ---- 0.2.6 诊断计数 ----
// 这段代码里每一道提前返回都是静默的，日志上「hook 没被调用」和「被某道门挡掉」
// 长得一模一样。下面这些标志让每道门第一次拒绝时留一行痕，之后不再刷屏。
static int  sCalls = 0;         // AudioUnitRender 被调用总次数
static int  sBus1Calls = 0;     // 其中 bus=1（输入方向）的次数
static BOOL sLoggedEntry = NO;
static BOOL sLoggedBus1 = NO;
static BOOL sLoggedRenderFail = NO;
static BOOL sLoggedNotInjecting = NO;
static BOOL sLoggedYieldAVCap = NO;
static BOOL sLoggedCacheFull = NO;
static BOOL sLoggedNotInput = NO;
static BOOL sLoggedNoASBD = NO;
static BOOL sLoggedNotPCM = NO;
static int  sAddOutputLogs = 0;

#pragma mark - 每个 AudioUnit 的属性缓存

// 采集回调每 10ms 就要跑一次，不能每次都去 AudioUnitGetProperty（那是加锁的）。
// 按 (unit, bus) 缓存一次查询结果即可。
typedef struct {
    AudioUnit unit;
    UInt32 bus;
    BOOL isInput;
    BOOL hasASBD;
    AudioStreamBasicDescription asbd;
} SLUnitCache;

#define SL_UNIT_CACHE 8
static SLUnitCache sUnitCache[SL_UNIT_CACHE];
static int sUnitCacheCount = 0;

static SLUnitCache *SLCacheFor(AudioUnit unit, UInt32 bus, BOOL *isNew) {
    if (isNew) *isNew = NO;
    for (int i = 0; i < sUnitCacheCount; i++) {
        if (sUnitCache[i].unit == unit && sUnitCache[i].bus == bus) return &sUnitCache[i];
    }
    if (sUnitCacheCount >= SL_UNIT_CACHE) return NULL;

    SLUnitCache *c = &sUnitCache[sUnitCacheCount];
    memset(c, 0, sizeof(*c));
    c->unit = unit;
    c->bus = bus;

    // 是不是「开了麦克风输入的输出单元」？不是就直接判定为非输入，后面全部跳过
    UInt32 enabled = 0, sz = sizeof(enabled);
    if (AudioUnitGetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input, 1, &enabled, &sz) == noErr && enabled) {
        c->isInput = YES;
    }

    sz = sizeof(c->asbd);
    if (c->isInput &&
        AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output, bus, &c->asbd, &sz) == noErr) {
        c->hasASBD = YES;
    }

    sUnitCacheCount++;
    if (isNew) *isNew = YES;
    return c;
}

#pragma mark - AudioUnitRender

static OSStatus SLCamAudioUnitRender(AudioUnit unit, AudioUnitRenderActionFlags *flags,
                                     const AudioTimeStamp *ts, UInt32 bus,
                                     UInt32 frames, AudioBufferList *ioData) {
    SLAudioUnitRenderFn orig = gSLRenderOrig;
    if (!orig) return -1;

    // 先让宿主把麦克风数据拿到手，再就地替换 —— 这样无论它怎么处理
    // 时间戳、错误码、静音标志，我们都不改变行为，只换内容。
    OSStatus st = orig(unit, flags, ts, bus, frames, ioData);

    // ---- 诊断：先证明「这个 hook 到底有没有被调用」 ----
    sCalls++;
    if (bus == 1) sBus1Calls++;

    if (!sLoggedEntry) {
        sLoggedEntry = YES;
        SLLog(@"音频: AudioUnitRender 首次被调用 bus=%u frames=%u bufs=%u st=%d",
              (unsigned)bus, (unsigned)frames,
              ioData ? (unsigned)ioData->mNumberBuffers : 0, (int)st);
    }
    if (bus == 1 && !sLoggedBus1) {
        sLoggedBus1 = YES;
        SLLog(@"音频: 首次出现 bus=1 输入调用 frames=%u bufs=%u st=%d",
              (unsigned)frames,
              ioData ? (unsigned)ioData->mNumberBuffers : 0, (int)st);
    }
    if (sCalls % 3000 == 0) {
        SLLog(@"音频: 心跳 调用 %d 次 / bus=1 %d 次", sCalls, sBus1Calls);
    }

    if (st != noErr || !ioData || ioData->mNumberBuffers == 0) {
        if (!sLoggedRenderFail) {
            sLoggedRenderFail = YES;
            SLLog(@"音频: 放行 —— 宿主渲染没成功 st=%d bufs=%u", (int)st,
                  ioData ? (unsigned)ioData->mNumberBuffers : 0);
        }
        return st;
    }

    // 输入元素固定是 bus 1（RemoteIO / VoiceProcessingIO 都一样）。
    // bus 0 是播放方向，绝对不能碰，否则会把对方的声音也改掉。
    if (bus != 1) return st;

    if (!SLCamInjecting()) {
        if (!sLoggedNotInjecting) {
            sLoggedNotInjecting = YES;
            SLLog(@"音频: 跳过 —— 当前没开启替换");
        }
        return st;
    }

    // 宿主音频已经走 AVCapture 了（比如陌陌），这条链路必须让路
    if (SLCamAVCaptureAudioSeen()) {
        if (!sLoggedYieldAVCap) {
            sLoggedYieldAVCap = YES;
            SLLog(@"音频: 让路 —— 宿主音频走 AVCapture，交给那条链路");
        }
        return st;
    }

    BOOL isNew = NO;
    SLUnitCache *c = SLCacheFor(unit, bus, &isNew);
    if (!c) {
        if (!sLoggedCacheFull) {
            sLoggedCacheFull = YES;
            SLLog(@"音频: 跳过 —— unit 缓存已满（上限 %d）", SL_UNIT_CACHE);
        }
        return st;
    }
    if (!c->isInput) {
        if (!sLoggedNotInput) {
            sLoggedNotInput = YES;
            SLLog(@"音频: 跳过 —— 这个 unit 的输入元素没开，不是麦克风采集");
        }
        return st;
    }
    if (!c->hasASBD) {
        if (!sLoggedNoASBD) {
            sLoggedNoASBD = YES;
            SLLog(@"音频: 跳过 —— 拿不到输入格式（StreamFormat 查询失败）");
        }
        return st;
    }
    if (c->asbd.mFormatID != kAudioFormatLinearPCM || c->asbd.mBytesPerFrame == 0) {
        if (!sLoggedNotPCM) {
            sLoggedNotPCM = YES;
            SLLog(@"音频: 跳过 —— 输入不是线性 PCM（formatID=%u %uB/帧）",
                  (unsigned)c->asbd.mFormatID, (unsigned)c->asbd.mBytesPerFrame);
        }
        return st;
    }

    if (isNew) {
        SLLog(@"音频: AudioUnit 输入 %.0fHz %uch %uB/帧 交错=%@ flags=0x%x",
              c->asbd.mSampleRate, (unsigned)c->asbd.mChannelsPerFrame,
              (unsigned)c->asbd.mBytesPerFrame,
              (c->asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? @"N" : @"Y",
              (unsigned)c->asbd.mFormatFlags);
    }

    SLCamFeed *feed = [SLCamFeed shared];

    for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
        AudioBuffer *b = &ioData->mBuffers[i];
        if (!b->mData || b->mDataByteSize == 0) continue;

        NSData *pcm = [feed audioForFormat:&c->asbd numBytes:b->mDataByteSize];
        if (pcm.length != b->mDataByteSize) continue;   // 素材还没解出音频，放行真麦克风

        memcpy(b->mData, pcm.bytes, pcm.length);
        gSLReplaceCount++;
    }

    if (!gSLReplacedLogged && gSLReplaceCount > 0) {
        gSLReplacedLogged = YES;
        SLLog(@"音频: 已接管 AudioUnit 麦克风输入");
    }
    return st;
}

#pragma mark - 只探测不接管

// AudioQueue 走的是另一套回调，不是 AudioUnitRender 能覆盖的。
// 先挂个只记日志的探针 —— 万一哪个 App 用它，日志里能直接看出来，
// 不用再靠猜。
static OSStatus SLCamAudioQueueNewInput(const AudioStreamBasicDescription *fmt,
                                        AudioQueueInputCallback cb, void *ud,
                                        CFRunLoopRef rl, CFStringRef mode,
                                        UInt32 flags, AudioQueueRef *outAQ) {
    if (!gSLAQProbeLogged) {
        gSLAQProbeLogged = YES;
        SLLog(@"音频: 宿主使用 AudioQueue 录音（%.0fHz %uch），暂未接管",
              fmt ? fmt->mSampleRate : 0,
              fmt ? (unsigned)fmt->mChannelsPerFrame : 0);
    }
    if (!gSLAQOrig) return -1;
    return gSLAQOrig(fmt, cb, ud, rl, mode, flags, outAQ);
}

#pragma mark - 安装

// 崩溃哨兵。
// 扫符号表这一步是整个插件里唯一「可能把宿主搞死」的操作 —— 一旦算错地址就是
// EXC_BAD_ACCESS，用户看到的就是「装了插件 App 打不开」。
// 所以装之前先落一个哨兵文件，装完再撤掉；下次启动如果还看到它，
// 说明上个进程正是死在这一步，那就这一次别装了 —— 画面链路走的是
// method_setImplementation，跟这里无关，照常能用。
// 用 tmp 目录：每个 App 各一份，重启设备也不影响。
static NSString *const kSLSymHookGuard = @"shenglin_vcam_symhook.lock";

static NSString *SLSymHookGuardPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:kSLSymHookGuard];
}

void SLCamInstallAudioUnitHook(void) {
    if (!gSLRegistered) {
        gSLRegistered = YES;

        NSString *guard = SLSymHookGuardPath();
        NSFileManager *fm = [NSFileManager defaultManager];

        if ([fm fileExistsAtPath:guard]) {
            [fm removeItemAtPath:guard error:NULL];
            SLLog(@"守护: 上次启动在扫描符号表时崩溃过，本次跳过 C 函数 hook（画面不受影响）");
            return;
        }

        [fm createFileAtPath:guard contents:[NSData data] attributes:nil];

        int hits = SLSymbolHook("AudioUnitRender", (void *)SLCamAudioUnitRender,
                                (void **)&gSLRenderOrig);
        gSLHooked = (hits > 0 && gSLRenderOrig != NULL);
        if (gSLHooked) {
            SLLog(@"音频: AudioUnitRender 已接管（%d 处符号槽）", hits);
        } else {
            SLLog(@"音频: 没找到 AudioUnitRender 的符号槽，AudioUnit 链路暂不可用");
        }

        SLSymbolHook("AudioQueueNewInput", (void *)SLCamAudioQueueNewInput,
                     (void **)&gSLAQOrig);

        // 走完了，撤哨兵 —— 下次正常启动不该再看到它
        [fm removeItemAtPath:guard error:NULL];
        return;
    }

    // 已经装过：只补扫，把后加载的 SDK / 插件进程里新映射的镜像也覆盖到
    if (gSLHooked) {
        SLSymbolHookRescan();
        // 会话开始装配输出时，正好是个观察点：此刻 AudioUnitRender 被调过几次。
        // 全程都是 0，就说明宿主的麦克风压根不经过这个函数（调用点在系统框架内部，
        // 或者走了 dlsym 动态解析）—— 指针表 hook 再怎么改也够不着。
        if (sAddOutputLogs < 4) {
            sAddOutputLogs++;
            SLLog(@"音频: 会话加输出时 AudioUnitRender 累计调用 %d 次 / bus=1 %d 次",
                  sCalls, sBus1Calls);
        }
    }
}

BOOL SLCamAudioUnitHooked(void) {
    return gSLHooked;
}
