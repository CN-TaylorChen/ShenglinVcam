//
//  SLVCamAudioUnit.m
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
#import <stdlib.h>
#import <math.h>
#import <dlfcn.h>

typedef OSStatus (*SLVAudioUnitRenderFn)(AudioUnit, AudioUnitRenderActionFlags *,
                                        const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);
typedef OSStatus (*SLVAudioQueueNewInputFn)(const AudioStreamBasicDescription *,
                                           AudioQueueInputCallback, void *, CFRunLoopRef,
                                           CFStringRef, UInt32, AudioQueueRef *);

static SLVAudioUnitRenderFn gSLRenderOrig = NULL;
static SLVAudioQueueNewInputFn gSLAQOrig = NULL;

static BOOL gSLHooked = NO;
static BOOL gSLRegistered = NO;
static BOOL gSLAQProbeLogged = NO;
static int  gSLReplaceCount = 0;

// ---- 0.2.6 诊断计数 ----
// 这段代码里每一道提前返回都是静默的，日志上「hook 没被调用」和「被某道门挡掉」
// 长得一模一样。下面这些标志让每道门第一次拒绝时留一行痕，之后不再刷屏。
static int  sCalls = 0;         // AudioUnitRender 被调用总次数
static int  sBus1Calls = 0;     // 其中 bus=1（输入方向）的次数
// 0.2.18：心跳改成「每 500 次一条 + 报本轮 bus=1 增量」。
// 原来 3000 次才打一条，而 sCalls 是 bus=0 + bus=1 的总和 —— 一次几十秒的录制
// 根本攒不到 3000，日志上完全看不出录制期间麦克风有没有走这条路。
// 现在只要录几秒就能看到「本轮 +N」，N>0 = 走的是我们挂住的 unit。
static int  sBus1AtLastBeat = 0;
#define SLV_HEARTBEAT_EVERY 500
static BOOL sLoggedEntry = NO;
static BOOL sLoggedBus1 = NO;
static BOOL sLoggedRenderFail = NO;
static BOOL sLoggedNotInjecting = NO;
static BOOL sLoggedYieldAVCap = NO;
static BOOL sLoggedCacheFull = NO;
static BOOL sLoggedNoASBD = NO;
static BOOL sLoggedNotPCM = NO;
static BOOL sLoggedPassThrough = NO;
static int  sAddOutputLogs = 0;

#pragma mark - 每个 AudioUnit 的属性缓存

// 采集回调每 10ms 就要跑一次，不能每次都去 AudioUnitGetProperty（那是加锁的）。
// 按 (unit, bus) 缓存一次查询结果即可。
//
// 0.2.7 的教训：以前把 EnableIO 当硬门用 —— 查不到就整条链路放行。
// 可这个查询有两个坑：① 返回错误和返回 enabled=0 在我们这边长得一样；
// ② 首次 bus=1 调用恰好是麦克风 unit 刚启动的时刻，属性查不到很正常，
// 而这个否定结果被永久缓存了，后面几千次调用再也翻不了身。
// 现在 EnableIO 只作参考信息，真正的判据是「bus==1 且能拿到有效的 PCM 格式」。
typedef struct {
    AudioUnit unit;
    UInt32 bus;
    OSStatus enableSt;         // EnableIO 查询返回码
    UInt32 enableVal;          // EnableIO 查询值
    BOOL hasASBD;
    OSStatus asbdSt;           // StreamFormat 查询返回码
    int  attempts;             // ASBD 失败次数
    int  calls;                // 这条缓存被命中的次数（用于周期性补试）
    BOOL logged;               // 「unit 就绪」这行只打一次
    BOOL replacedLogged;       // 「已接管」按 unit 各打一次，不是全局只打一次
    int  seq;                  // 0.3.49：最近一次调用序号，缓存满了按它踢最久未用的
    int  levelLogs;            // 0.3.49：注入电平日志条数（首包 + 之后每 250 包）
    BOOL silenceClearedLogged; // 0.3.49：「清掉 OutputIsSilence」只打一次
    char caller[64];           // 0.3.49：谁在拉麦克风（调用方镜像名）
    AudioStreamBasicDescription asbd;
} SLVUnitCache;

#define SLV_UNIT_CACHE 8
// 0.3.49：缓存满了不能再「跳过」。
//
// 以前是 `if (sUnitCacheCount >= 8) return NULL;` —— 宿主每换一次场景就新建一个
// AudioUnit，攒够 8 个之后**新 unit 永远不接管**，而且新旧 unit 长得一模一样，
// 日志上只留一行「跳过 —— unit 缓存已满」，后面心跳照样在涨，看着完全正常。
// 视频通话里被跳过的很可能正是上行那个 unit，对方听到的就是真麦克风（安静房间＝无声）。
// 现在满了就顶掉最久没被调用的那个。
#define SLV_ASBD_MAX_TRIES 200
// 格式重读间隔。10ms 一包，500 次约 5 秒 —— 切到拍摄页之后几秒内就能看到变化，
// 又不至于每包都去查属性（AudioUnitGetProperty 内部是加锁的）。
#define SLV_ASBD_RECHECK_EVERY 500

static SLVUnitCache sUnitCache[SLV_UNIT_CACHE];
static int sUnitCacheCount = 0;
static int sUnitSeq = 0;

/// 调用方是谁。视频通话里 RTC SDK 会在同一个进程里开好几个 unit，
/// 光看 unit 指针分不出哪个是上行、哪个是本地电平表 —— 把镜像名打出来才看得见。
static NSString *SLVCallerImageName(void *addr) {
    if (!addr) return @"?";
    Dl_info info;
    if (dladdr(addr, &info) == 0 || !info.dli_fname) return @"?";
    const char *slash = strrchr(info.dli_fname, '/');
    const char *base = slash ? slash + 1 : info.dli_fname;
    return @(base);
}

/// 一包 PCM 的电平（dBFS）。日志里一直只有「水位」「丢多少字节」，
/// 全是「有多少数据」，没有一条是「数据响不响」—— 所以「注入进去了但内容其实是静音」
/// 这种情况在日志上完全看不出来。这里补上。
///
/// 返回 NAN = 采样格式不认识（不是「静音」）。0.3.50 及以前用 -1.0 当「不认识」的
/// 哨兵，又拿「>= -0.5 才算有声」去判 —— 两个错误叠在一起，结果是**任何正常音量
/// 都被打成「静音」**：ASMR 这类轻声大约 -30 dBFS，-30 >= -0.5 不成立，直接走静音分支。
/// 于是日志连续三分钟喊静音，池子里其实一直是好数据。
static double SLVPCMLeveldBFS(const void *bytes, size_t len, const AudioStreamBasicDescription *asbd) {
    if (!bytes || !len || !asbd) return NAN;
    BOOL isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    double sum = 0;
    size_t n = 0;

    if (isFloat && asbd->mBitsPerChannel == 32) {
        const float *f = (const float *)bytes;
        size_t cnt = len / sizeof(float);
        for (size_t i = 0; i < cnt; i++) { double v = f[i]; sum += v * v; n++; }
    } else if (!isFloat && asbd->mBitsPerChannel == 16) {
        const int16_t *s = (const int16_t *)bytes;
        size_t cnt = len / sizeof(int16_t);
        for (size_t i = 0; i < cnt; i++) { double v = s[i] / 32768.0; sum += v * v; n++; }
    } else if (!isFloat && asbd->mBitsPerChannel == 32) {
        const int32_t *s = (const int32_t *)bytes;
        size_t cnt = len / sizeof(int32_t);
        for (size_t i = 0; i < cnt; i++) { double v = s[i] / 2147483648.0; sum += v * v; n++; }
    } else {
        return NAN;   // 不认识的格式，别冒充「静音」
    }
    if (!n) return -120.0;
    double rms = sqrt(sum / (double)n);
    if (rms <= 1e-9) return -120.0;
    double db = 20.0 * log10(rms);
    return db < -120.0 ? -120.0 : db;
}

/// 查一次 StreamFormat。失败不缓存否定结论 —— unit 可能还没初始化完，下次再来。
static void SLVTryASBD(SLVUnitCache *c) {
    if (c->hasASBD) return;

    AudioStreamBasicDescription a;
    memset(&a, 0, sizeof(a));
    UInt32 sz = sizeof(a);
    OSStatus st = AudioUnitGetProperty(c->unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, c->bus, &a, &sz);
    c->asbdSt = st;

    // 格式字段必须自洽，全零的 ASBD 当失败处理，否则后面算字节数会出错
    if (st == noErr && a.mSampleRate > 0 && a.mChannelsPerFrame > 0 && a.mBytesPerFrame > 0) {
        c->asbd = a;
        c->hasASBD = YES;
    } else {
        c->attempts++;
    }
}

/// 逐字段比较。不用 memcmp 是因为 ASBD 里有 `mReserved` 这种保留字段，
/// 万一系统没清零，memcmp 会一直判「变了」，导致转换器被反复重建、声音一顿一顿。
static BOOL SLVASBDEqual(const AudioStreamBasicDescription *a, const AudioStreamBasicDescription *b) {
    return a->mSampleRate == b->mSampleRate
        && a->mFormatID == b->mFormatID
        && a->mFormatFlags == b->mFormatFlags
        && a->mBytesPerPacket == b->mBytesPerPacket
        && a->mFramesPerPacket == b->mFramesPerPacket
        && a->mBytesPerFrame == b->mBytesPerFrame
        && a->mChannelsPerFrame == b->mChannelsPerFrame
        && a->mBitsPerChannel == b->mBitsPerChannel;
}

/// 周期性重读一次 StreamFormat，格式变了就更新。
///
/// 为什么需要：0.2.13 之前 `hasASBD` 是一票否决 —— 读到就再也不看了。可宿主
/// 会复用同一个 AudioUnit 换场景：QQ 视频通话是 16000Hz / 1ch / 4B，切到拍摄页
/// 录制往往变成 44100Hz / 2ch。格式变了我们还在按旧格式要 PCM，而
/// `pcm.length == mDataByteSize` 依然成立（按字节数申请的），memcpy 照做、
/// 不报错、不打日志，听感就是「声音又慢又低」。这条日志就是为了把它暴露出来。
static void SLVRefreshASBD(SLVUnitCache *c) {
    if (!c->hasASBD) { SLVTryASBD(c); return; }
    if (c->calls % SLV_ASBD_RECHECK_EVERY != 0) return;

    AudioStreamBasicDescription a;
    memset(&a, 0, sizeof(a));
    UInt32 sz = sizeof(a);
    OSStatus st = AudioUnitGetProperty(c->unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, c->bus, &a, &sz);
    if (st != noErr || a.mSampleRate <= 0 || a.mChannelsPerFrame <= 0 || a.mBytesPerFrame <= 0) return;
    if (SLVASBDEqual(&a, &c->asbd)) return;

    SLVLog(@"音频: unit 格式变化 bus=%u %.0fHz %uch %uB/帧 → %.0fHz %uch %uB/帧",
          (unsigned)c->bus,
          c->asbd.mSampleRate, (unsigned)c->asbd.mChannelsPerFrame, (unsigned)c->asbd.mBytesPerFrame,
          a.mSampleRate, (unsigned)a.mChannelsPerFrame, (unsigned)a.mBytesPerFrame);
    c->asbd = a;
}

static SLVUnitCache *SLVCacheFor(AudioUnit unit, UInt32 bus, void *callerAddr, BOOL *isNew) {
    if (isNew) *isNew = NO;
    for (int i = 0; i < sUnitCacheCount; i++) {
        if (sUnitCache[i].unit == unit && sUnitCache[i].bus == bus) {
            sUnitCache[i].seq = ++sUnitSeq;
            return &sUnitCache[i];
        }
    }

    SLVUnitCache *c = NULL;
    BOOL evicted = NO;
    if (sUnitCacheCount < SLV_UNIT_CACHE) {
        c = &sUnitCache[sUnitCacheCount++];
    } else {
        // 满了：顶掉最久没被调用的那个（0.3.49）
        int victim = 0;
        for (int i = 1; i < sUnitCacheCount; i++) {
            if (sUnitCache[i].seq < sUnitCache[victim].seq) victim = i;
        }
        c = &sUnitCache[victim];
        evicted = YES;
    }

    memset(c, 0, sizeof(*c));
    c->unit = unit;
    c->bus = bus;
    c->enableSt = -1;
    c->asbdSt = -1;
    c->seq = ++sUnitSeq;
    NSString *img = SLVCallerImageName(callerAddr);
    strlcpy(c->caller, img.UTF8String ?: "?", sizeof(c->caller));

    // EnableIO 只查一次、只用来解释日志：
    // 「App 有没有显式打开输入」是旁证，不是判据。
    UInt32 enabled = 0, sz = sizeof(enabled);
    c->enableSt = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input, 1, &enabled, &sz);
    if (c->enableSt == noErr) {
        c->enableVal = enabled;
    }

    // ASBD 无条件查 —— 以前被 isInput 短路，连试都没试过，等于自断信息
    SLVTryASBD(c);

    if (evicted) {
        SLVLog(@"音频: unit 缓存已满，顶掉最久未用的那个（新 unit 0x%lx ← %@）",
              (unsigned long)(uintptr_t)unit, img);
    } else if (sUnitCacheCount > 1) {
        // 第一个 unit 由下面的「unit 就绪」行负责，这里只补后来者的出身
        SLVLog(@"音频: 新 unit 0x%lx bus=%u ← %@", (unsigned long)(uintptr_t)unit,
              (unsigned)bus, img);
    }

    if (isNew) *isNew = YES;
    return c;
}

#pragma mark - AudioUnitRender

static OSStatus SLVCamAudioUnitRender(AudioUnit unit, AudioUnitRenderActionFlags *flags,
                                     const AudioTimeStamp *ts, UInt32 bus,
                                     UInt32 frames, AudioBufferList *ioData) {
    SLVAudioUnitRenderFn orig = gSLRenderOrig;
    if (!orig) return -1;

    // 0.3.49：调用方地址（谁的代码在拉麦克风）。这个值只在建缓存时用一次。
    void *callerAddr = __builtin_return_address(0);

    // 先让宿主把麦克风数据拿到手，再就地替换 —— 这样无论它怎么处理
    // 时间戳、错误码、静音标志，我们都不改变行为，只换内容。
    OSStatus st = orig(unit, flags, ts, bus, frames, ioData);

    // ---- 诊断：先证明「这个 hook 到底有没有被调用」 ----
    sCalls++;
    if (bus == 1) sBus1Calls++;

    if (!sLoggedEntry) {
        sLoggedEntry = YES;
        SLVLog(@"音频: AudioUnitRender 首次被调用 bus=%u frames=%u bufs=%u st=%d",
              (unsigned)bus, (unsigned)frames,
              ioData ? (unsigned)ioData->mNumberBuffers : 0, (int)st);
    }
    if (bus == 1 && !sLoggedBus1) {
        sLoggedBus1 = YES;
        SLVLog(@"音频: 首次出现 bus=1 输入调用 frames=%u bufs=%u st=%d",
              (unsigned)frames,
              ioData ? (unsigned)ioData->mNumberBuffers : 0, (int)st);
    }
    if (sCalls % SLV_HEARTBEAT_EVERY == 0) {
        int delta = sBus1Calls - sBus1AtLastBeat;
        sBus1AtLastBeat = sBus1Calls;
        // 0.3.52：实时线程，走 RT 版（不 NSLog、时间戳在后台队列取）
        SLVLogRT(@"音频: 心跳 调用 %d / bus=1 累计 %d（本轮 +%d）", sCalls, sBus1Calls, delta);
    }

    if (st != noErr || !ioData || ioData->mNumberBuffers == 0) {
        if (!sLoggedRenderFail) {
            sLoggedRenderFail = YES;
            SLVLog(@"音频: 放行 —— 宿主渲染没成功 st=%d bufs=%u", (int)st,
                  ioData ? (unsigned)ioData->mNumberBuffers : 0);
        }
        return st;
    }

    // 输入元素固定是 bus 1（RemoteIO / VoiceProcessingIO 都一样）。
    // bus 0 是播放方向，绝对不能碰，否则会把对方的声音也改掉。
    if (bus != 1) return st;

    if (!SLVCamInjecting()) {
        if (!sLoggedNotInjecting) {
            sLoggedNotInjecting = YES;
            SLVLog(@"音频: 跳过 —— 当前没开启替换");
        }
        return st;
    }

    // 宿主音频此刻是不是正走 AVCapture / AudioQueue？
    //
    // 以前这里看的是「曾经见过 AVCapture 音频」这种一票否决标志，置上就永不清除。
    // 于是「先录一段视频消息、再打视频通话」这种最平常的操作里，通话整场都在
    // 让路 —— 而通话里根本没有 AVCapture 音频在跑，最后谁也不注入。
    // 现在只认「那条链路 1 秒内真的来拿过数据」。
    if (SLVCamAVCaptureAudioSeen() && [[SLVCamFeed shared] audioConsumerActive:NULL]) {
        if (!sLoggedYieldAVCap) {
            sLoggedYieldAVCap = YES;
            SLVLog(@"音频: 让路 —— 宿主音频正在走 AVCapture/AudioQueue，交给那条链路");
        }
        return st;
    }

    SLVUnitCache *c = SLVCacheFor(unit, bus, callerAddr, NULL);
    if (!c) {
        if (!sLoggedCacheFull) {
            sLoggedCacheFull = YES;
            SLVLog(@"音频: 跳过 —— unit 缓存拿不到条目（上限 %d）", SLV_UNIT_CACHE);
        }
        return st;
    }

    // 格式还没拿到就再试。首次 bus=1 调用时 unit 往往刚启动，属性暂时查不到很正常，
    // 不能像 0.2.6 那样一次失败就永久放弃。
    // 前 200 次密集重试（约 2 秒），之后每 3000 次补一次 —— 属性查询要加锁，
    // 不能每 10ms 都去问。
    c->calls++;
    if (!c->hasASBD) {
        if (c->attempts < SLV_ASBD_MAX_TRIES || (c->calls % 3000) == 0) SLVTryASBD(c);
    } else {
        // 已经拿到过格式也不能就此锁死：宿主换场景时同一个 unit 的格式会变
        SLVRefreshASBD(c);
    }

    // 拿到格式就说明这条 bus 确实在往外送音频数据，可以干活了。
    // EnableIO 只写进日志：它是旁证，不是判据。
    if (c->hasASBD && !c->logged) {
        c->logged = YES;
        SLVLog(@"音频: unit 就绪 bus=%u EnableIO st=%d val=%u · ASBD st=%d fmt=%u %.0fHz %uch %uB/帧 交错=%@",
              (unsigned)bus, (int)c->enableSt, (unsigned)c->enableVal,
              (int)c->asbdSt, (unsigned)c->asbd.mFormatID, c->asbd.mSampleRate,
              (unsigned)c->asbd.mChannelsPerFrame, (unsigned)c->asbd.mBytesPerFrame,
              (c->asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? @"N" : @"Y");
    }

    if (!c->hasASBD) {
        if (!sLoggedNoASBD) {
            sLoggedNoASBD = YES;
            SLVLog(@"音频: 跳过 —— 试了 %d 次仍拿不到 bus=%u 的格式（st=%d）",
                  c->attempts, (unsigned)bus, (int)c->asbdSt);
        }
        return st;
    }
    if (c->asbd.mFormatID != kAudioFormatLinearPCM || c->asbd.mBytesPerFrame == 0) {
        if (!sLoggedNotPCM) {
            sLoggedNotPCM = YES;
            SLVLog(@"音频: 跳过 —— 输入不是线性 PCM（formatID=%u %uB/帧）",
                  (unsigned)c->asbd.mFormatID, (unsigned)c->asbd.mBytesPerFrame);
        }
        return st;
    }

    SLVCamFeed *feed = [SLVCamFeed shared];

    int replacedHere = 0;
    double levelDB = NAN;
    BOOL haveLevel = NO;
    for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
        AudioBuffer *b = &ioData->mBuffers[i];
        if (!b->mData || b->mDataByteSize == 0) continue;

        // 按 unit 分开取：同一个进程里可能有第二个 unit 也在拉麦克风，
        // 共用一个游标会让两边各拿到隔包数据（0.3.49）。
        NSData *pcm = [feed audioForFormat:&c->asbd numBytes:b->mDataByteSize
                                  consumer:(const void *)unit];
        if (pcm.length != b->mDataByteSize) {
            // 拿不到素材 PCM → 这一包放行真麦克风。
            // 以前这里是完全静默的 continue，「录制时音频没被替换」在日志上
            // 一个字都看不到，只能靠猜。现在第一次撞上就留一行痕。
            if (!sLoggedPassThrough) {
                sLoggedPassThrough = YES;
                SLVLog(@"音频: 放行真麦克风 —— 素材没给出 PCM（%uB/帧 · %.0fHz %uch %uB/帧）",
                      (unsigned)b->mDataByteSize, c->asbd.mSampleRate,
                      (unsigned)c->asbd.mChannelsPerFrame, (unsigned)c->asbd.mBytesPerFrame);
            }
            continue;
        }

        memcpy(b->mData, pcm.bytes, pcm.length);
        replacedHere++;
        gSLReplaceCount++;
        if (!haveLevel) { levelDB = SLVPCMLeveldBFS(pcm.bytes, pcm.length, &c->asbd); haveLevel = YES; }
    }

    // 0.3.49：真把数据换进去了，就把「这一包是静音」的标志清掉。
    //
    // 系统（尤其语音处理单元）在麦克风被判成静音时会把
    // kAudioUnitRenderAction_OutputIsSilence 置上；RTC SDK 看到这个标志会直接
    // 把整包丢掉、不送去编码 —— 我们把 buffer 写满了素材，标志还在，等于白写。
    if (replacedHere > 0 && flags && (*flags & kAudioUnitRenderAction_OutputIsSilence)) {
        *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
        if (!c->silenceClearedLogged) {
            c->silenceClearedLogged = YES;
            SLVLog(@"音频: 清掉 OutputIsSilence 标志（bus=%u ← %s）—— 宿主原本会把这一包整包丢掉",
                  (unsigned)c->bus, c->caller);
        }
    }

    // 0.3.49：注入电平。首包 + 之后每 250 包一行。
    // 只有「水位」看不出内容响不响 —— 水位 180ms 也可能是 180ms 的静音。
    //
    // 0.3.51：判断改成「真实的 dBFS」。以前拿 -0.5 dBFS 当有声的门槛，
    // 那等于要求素材比满刻度只低半个 dB —— 现实里根本不存在，
    // 于是所有正常音量都被打成「静音」，把真正的答案埋了三天。
    if (replacedHere > 0) {
        c->levelLogs++;
        if (c->levelLogs == 1 || c->levelLogs % 250 == 0) {
            // 0.3.52：每 5 秒一条、跑在实时线程 —— 必须走 RT 版
            if (isnan(levelDB)) {
                SLVLogRT(@"音频: 注入电平 未知（采样格式不认识 · bits=%u flags=0x%x · 第 %d 包 · %@）",
                        (unsigned)c->asbd.mBitsPerChannel, (unsigned)c->asbd.mFormatFlags,
                        c->levelLogs, [feed audioDiag]);
            } else if (levelDB <= -90.0) {
                // 真静音：这时才需要看现场（池子空了 / 音轨没挂 / 素材本身无声）
                SLVLogRT(@"音频: 注入电平 = 静音（bus=%u ← %s · 第 %d 包 · %@）",
                        (unsigned)c->bus, c->caller, c->levelLogs, [feed audioDiag]);
            } else {
                SLVLogRT(@"音频: 注入电平 %.1f dBFS（bus=%u ← %s · 第 %d 包 · %@）",
                        levelDB, (unsigned)c->bus, c->caller, c->levelLogs, [feed audioDiag]);
            }
        }
    }

    // 「已接管」改成按 unit 打：全局只打一次的话，第二个 unit（比如通话结束、
    // 拍摄页新建的那个）接管时日志上是空的，看起来像没接管。
    if (!c->replacedLogged && gSLReplaceCount > 0) {
        c->replacedLogged = YES;
        SLVLog(@"音频: 已接管 AudioUnit 麦克风输入（bus=%u %.0fHz %uch）",
              (unsigned)c->bus, c->asbd.mSampleRate, (unsigned)c->asbd.mChannelsPerFrame);
    }
    return st;
}

#pragma mark - AudioQueue 链路（抖音拍摄走这条）

// 抖音拍视频的麦克风不走 AudioUnitRender，也不走 AVCaptureAudioDataOutput，
// 而是 AudioQueueNewInput + 回调 —— 0.2.7 只挂了个探针，日志里那行
// 「宿主使用 AudioQueue 录音，暂未接管」就是它。结果是这条路径上「替换音频」
// 完全空转，录进去的是真麦克风。
//
// 接管方式：AudioQueueNewInput 的 inCallback/inUserData 由宿主传入，我们换成
// 自己的回调 + 上下文，回调触发时先用素材音频覆盖 buffer，再把原回调叫起来。
// 宿主拿到的 buffer 内容和时序都没变，只是内容被换掉了。

typedef struct {
    AudioQueueInputCallback origCb;
    void *origUd;
    AudioStreamBasicDescription asbd;
    BOOL usable;            // 格式能替换（线性 PCM 且字段自洽）
    BOOL fired;             // 回调是否已经来过（诊断用）
    BOOL replacedLogged;
    int  replaced;
    int  skipped;           // 没换成（抢不到锁 / 素材没数据）的包数，诊断用
} SLVAQContext;

/// 这些上下文要和 AudioQueue 同生共死，不能回收 —— 队列什么时候停、停完还调不调
/// 回调，都不在我们控制范围内。每次 NewInput 泄漏一百多字节，一个进程也就几次。
static SLVAQContext *gSLAQContexts[8] = {NULL};
static int gSLAQContextCount = 0;

static BOOL SLVAQFormatUsable(const AudioStreamBasicDescription *fmt) {
    return fmt
        && fmt->mFormatID == kAudioFormatLinearPCM
        && fmt->mSampleRate > 0
        && fmt->mChannelsPerFrame > 0
        && fmt->mBytesPerFrame > 0
        && fmt->mBytesPerFrame < 64;      // 明显不对的值直接放弃，别拿它算字节数
}

static void SLVCamAudioQueueInputCallback(void *inUserData, AudioQueueRef inAQ,
                                         AudioQueueBufferRef inBuffer,
                                         const AudioTimeStamp *inStartTime,
                                         UInt32 inNumberPacketDescriptions,
                                         const AudioStreamPacketDescription *inPacketDescs) {
    SLVAQContext *ctx = (SLVAQContext *)inUserData;
    if (!ctx) return;

    if (!ctx->fired) {
        ctx->fired = YES;
        SLVLog(@"音频: AudioQueue 回调首次触发 %uB", 
              inBuffer ? (unsigned)inBuffer->mAudioDataByteSize : 0);
    }

    if (ctx->usable && inBuffer && inBuffer->mAudioData && inBuffer->mAudioDataByteSize > 0
        && SLVCamInjecting() && !SLVCamAVCaptureAudioSeen()) {
        // 这个回调跑在宿主的音频线程上，可能就在主线程的 runloop 里。
        // 所以只能走 tryAudioForFormat: —— 抢不到锁就放行这一包真麦克风，
        // 绝不能在这里等锁，否则宿主整条音频链路（乃至界面）都会被拖住。
        NSData *pcm = [[SLVCamFeed shared] tryAudioForFormat:&ctx->asbd
                                                   numBytes:inBuffer->mAudioDataByteSize
                                                   consumer:(const void *)ctx];
        if (pcm.length == inBuffer->mAudioDataByteSize) {
            memcpy(inBuffer->mAudioData, pcm.bytes, pcm.length);
            ctx->replaced++;
            if (!ctx->replacedLogged) {
                ctx->replacedLogged = YES;
                SLVLog(@"音频: 已接管 AudioQueue 麦克风输入（%.0fHz %uch）",
                      ctx->asbd.mSampleRate, (unsigned)ctx->asbd.mChannelsPerFrame);
            } else if (ctx->replaced % 3000 == 0) {
                // 0.3.52：AudioQueue 回调同样在音频线程上，走 RT 版
                SLVLogRT(@"音频: AudioQueue 心跳 %d 次（未替换 %d）",
                        ctx->replaced, ctx->skipped);
            }
        } else if (pcm == nil && ctx->replaced == 0) {
            ctx->skipped++;
        }
    }

    if (ctx->origCb) {
        ctx->origCb(ctx->origUd, inAQ, inBuffer, inStartTime,
                    inNumberPacketDescriptions, inPacketDescs);
    }
}

static OSStatus SLVCamAudioQueueNewInput(const AudioStreamBasicDescription *fmt,
                                        AudioQueueInputCallback cb, void *ud,
                                        CFRunLoopRef rl, CFStringRef mode,
                                        UInt32 flags, AudioQueueRef *outAQ) {
    if (!gSLAQOrig) return -1;

    // 格式拿不到、或不是线性 PCM（压缩格式没法逐包替换）就原样放行
    if (!cb || !SLVAQFormatUsable(fmt) || gSLAQContextCount >= 8) {
        if (!gSLAQProbeLogged) {
            gSLAQProbeLogged = YES;
            SLVLog(@"音频: AudioQueue 录音格式不可替换（%.0fHz %uch fmt=%u），放行真实麦克风",
                  fmt ? fmt->mSampleRate : 0, fmt ? (unsigned)fmt->mChannelsPerFrame : 0,
                  fmt ? (unsigned)fmt->mFormatID : 0);
        }
        return gSLAQOrig(fmt, cb, ud, rl, mode, flags, outAQ);
    }

    SLVAQContext *ctx = calloc(1, sizeof(SLVAQContext));
    if (!ctx) return gSLAQOrig(fmt, cb, ud, rl, mode, flags, outAQ);
    ctx->origCb = cb;
    ctx->origUd = ud;
    ctx->asbd = *fmt;
    ctx->usable = YES;

    // 关键一步：交给系统的是我们的回调和上下文，不是宿主的。
    // 宿主原来那对 (cb, ud) 存在 ctx 里，由包装函数在替换完数据后再叫起来。
    OSStatus st = gSLAQOrig(fmt, SLVCamAudioQueueInputCallback, ctx, rl, mode, flags, outAQ);

    // 建队列失败说明宿主自己都用不了，把上下文还回去，别占坑
    if (st != noErr) {
        free(ctx);
        return st;
    }

    gSLAQContexts[gSLAQContextCount++] = ctx;

    // 提前登记格式：解码线程要据此把音轨挂上，否则开头一段只能出静音。
    // 但**不能在宿主线程上同步做** —— 里面要建 AVAudioConverter，而抖音是在
    // 打开录像页的主线程上调 AudioQueueNewInput 的，同步做会把 UI 卡住。
    AudioStreamBasicDescription fmtCopy = *fmt;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [[SLVCamFeed shared] primeAudioFormat:&fmtCopy];
    });

    SLVLog(@"音频: 已接管 AudioQueue 录音（%.0fHz %uch %uB/帧）· 素材音 %@",
          fmt->mSampleRate, (unsigned)fmt->mChannelsPerFrame, (unsigned)fmt->mBytesPerFrame,
          [[SLVCamFeed shared] isReady] ? @"已就绪" : @"待命");
    return st;
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

static NSString *SLVSymHookGuardPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:kSLSymHookGuard];
}

void SLVCamInstallAudioUnitHook(void) {
    if (!gSLRegistered) {
        gSLRegistered = YES;

        NSString *guard = SLVSymHookGuardPath();
        NSFileManager *fm = [NSFileManager defaultManager];

        if ([fm fileExistsAtPath:guard]) {
            [fm removeItemAtPath:guard error:NULL];
            SLVLog(@"守护: 上次启动在扫描符号表时崩溃过，本次跳过 C 函数 hook（画面不受影响）");
            return;
        }

        [fm createFileAtPath:guard contents:[NSData data] attributes:nil];

        int hits = SLVSymbolHook("AudioUnitRender", (void *)SLVCamAudioUnitRender,
                                (void **)&gSLRenderOrig);
        gSLHooked = (hits > 0 && gSLRenderOrig != NULL);
        if (gSLHooked) {
            SLVLog(@"音频: AudioUnitRender 已接管（%d 处符号槽）", hits);
        } else {
            SLVLog(@"音频: 没找到 AudioUnitRender 的符号槽，AudioUnit 链路暂不可用");
        }

        SLVSymbolHook("AudioQueueNewInput", (void *)SLVCamAudioQueueNewInput,
                     (void **)&gSLAQOrig);

        // 后加载的 framework 自动补扫：QQ 的拍摄模块是启动之后才 dlopen 的，
        // 启动那一遍扫描根本看不到它（日志里「扫过 6 个 App 镜像」就是证据）
        SLVSymbolHookInstallAutoRescan();

        // 走完了，撤哨兵 —— 下次正常启动不该再看到它
        [fm removeItemAtPath:guard error:NULL];
        return;
    }

    // 已经装过：只补扫，把后加载的 SDK / 插件进程里新映射的镜像也覆盖到
    if (gSLHooked) {
        SLVSymbolHookRescan();
        // 会话开始装配输出时，正好是个观察点：此刻 AudioUnitRender 被调过几次。
        // 全程都是 0，就说明宿主的麦克风压根不经过这个函数（调用点在系统框架内部，
        // 或者走了 dlsym 动态解析）—— 指针表 hook 再怎么改也够不着。
        if (sAddOutputLogs < 4) {
            sAddOutputLogs++;
            SLVLog(@"音频: 会话加输出时 AudioUnitRender 累计调用 %d 次 / bus=1 %d 次",
                  sCalls, sBus1Calls);
        }
    }
}

BOOL SLVCamAudioUnitHooked(void) {
    return gSLHooked;
}
