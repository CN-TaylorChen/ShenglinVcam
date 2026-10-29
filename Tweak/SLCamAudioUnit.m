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
    if (st != noErr || !ioData || ioData->mNumberBuffers == 0) return st;

    // 输入元素固定是 bus 1（RemoteIO / VoiceProcessingIO 都一样）。
    // bus 0 是播放方向，绝对不能碰，否则会把对方的声音也改掉。
    if (bus != 1) return st;

    if (!SLCamInjecting()) return st;

    // 宿主音频已经走 AVCapture 了（比如陌陌），这条链路必须让路
    if (SLCamAVCaptureAudioSeen()) return st;

    BOOL isNew = NO;
    SLUnitCache *c = SLCacheFor(unit, bus, &isNew);
    if (!c || !c->isInput || !c->hasASBD) return st;
    if (c->asbd.mFormatID != kAudioFormatLinearPCM || c->asbd.mBytesPerFrame == 0) return st;

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

void SLCamInstallAudioUnitHook(void) {
    if (!gSLRegistered) {
        gSLRegistered = YES;

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
        return;
    }

    // 已经装过：只补扫，把后加载的 SDK / 插件进程里新映射的镜像也覆盖到
    if (gSLHooked) SLSymbolHookRescan();
}

BOOL SLCamAudioUnitHooked(void) {
    return gSLHooked;
}
