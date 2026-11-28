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
#import <math.h>

#pragma mark - 宿主音频链路的活动状态（0.3.55）

// 「宿主此刻是不是正在走 AVCapture / AudioQueue 那条音频链」。
//
// 以前这是 SLCamInject 里一个永久标志（见过 AVCapture 音频就置上，永不清除），
// 于是「先录一段语音消息、再打视频通话」的 App（微信、QQ 都这样）通话整场都在让路，
// 结果谁也不注入 —— 微信里「替换音频没反应」就是这么来的。
//
// 现在只认「1 秒内真的来拿过数据」。这里用原子读写而不是 _lock：这个判据要在
// 实时音频线程里用，那边绝对不能等锁。存成毫秒整数 —— 整数原子操作在所有架构上
// 都是内联的，不会牵出 libatomic。
static int64_t gSLExternalAudioAtMs = 0;

static inline int64_t SLVNowMs(void) {
    return (int64_t)(CFAbsoluteTimeGetCurrent() * 1000.0);
}

static inline void SLVMarkExternalAudio(void) {
    __atomic_store_n(&gSLExternalAudioAtMs, SLVNowMs(), __ATOMIC_RELAXED);
}

static inline BOOL SLVExternalAudioActiveNow(void) {
    int64_t t = __atomic_load_n(&gSLExternalAudioAtMs, __ATOMIC_RELAXED);
    return t > 0 && (SLVNowMs() - t) < 1000;
}

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
        // 苹果相机管线一律 BT.709。
        //
        // 0.3.17：permuteMap 从 {0,1,2,3} 改成 {3,2,1,0} —— 整片发蓝的真凶。
        //
        // kvImageARGB8888 说的是**逻辑通道序 A,R,G,B**，permuteMap 也按这个顺序
        // 解释：permute[0] 是喂给 A 的源通道，[1] 喂 R，[2] 喂 G，[3] 喂 B。
        // 而我们的 buffer 内存里是 B,G,R,A，于是恒等映射变成：
        //     A←B   R←G   G←R   B←A(=255)
        // B 通道被 alpha 顶死成 255，暗部不再是黑而是满值蓝 —— 就是那个紫蓝屏。
        // 反过来映射回 B,G,R,A 就对了。
        //
        // 注意 range 是在 GenerateConversion 里用掉的，转换函数本身不吃它 ——
        // 第 5 个参数就是 permuteMap。
        const uint8_t permute[4] = { 3, 2, 1, 0 };
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

/// 自建 CVPixelBuffer 的属性。
///
/// 0.3.8：把 MetalCompatibility 显式打开。
///
/// 之前只给了 IOSurfaceProperties，想着「有 IOSurface 就够了」。但宿主（抖音）
/// 拿帧的方式是 CVMetalTextureCacheCreateTextureFromImage —— buffer 没标
/// Metal 兼容，纹理就建不出来，采样到的是空纹理，整片画成绿色。
/// 这跟「我们往 buffer 里写的字节对不对」完全是两件事：日志里中心像素
/// B=139 G=146 R=149 是正常的中性灰，说明 CPU 这边写对了，是宿主读不出来。
///
/// 视频帧一直正常，因为它是解码器分配的，这些标记天生就带全了。
static NSDictionary *SLVPixelBufferAttrs(void) {
    return @{
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        (id)kCVPixelBufferMetalCompatibilityKey : @YES,
        (id)kCVPixelBufferOpenGLESCompatibilityKey : @YES,
    };
}

/// 两个**同格式同尺寸**的 buffer 之间按行搬字节。
///
/// 跨度和尺寸都对齐的情况下就是一次 memcpy；宿主的 buffer 往往按 64/128 字节
/// 对齐，比 w*4 宽，那就一行一行搬。多出来的只是对齐填充，搬不搬无所谓。
static BOOL SLVBlitSameFormat(CVPixelBufferRef src, CVPixelBufferRef dst) {
    if (!src || !dst) return NO;

    size_t w = CVPixelBufferGetWidth(dst);
    size_t h = CVPixelBufferGetHeight(dst);
    if (w < 1 || h < 1) return NO;
    if (CVPixelBufferGetWidth(src) != w || CVPixelBufferGetHeight(src) != h) return NO;
    if (CVPixelBufferGetPixelFormatType(src) != CVPixelBufferGetPixelFormatType(dst)) return NO;

    BOOL planar = CVPixelBufferIsPlanar(dst);
    size_t planes = planar ? CVPixelBufferGetPlaneCount(dst) : 1;
    if (planar && CVPixelBufferGetPlaneCount(src) != planes) return NO;

    if (CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return NO;
    if (CVPixelBufferLockBaseAddress(dst, 0) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        return NO;
    }

    BOOL ok = YES;
    for (size_t i = 0; i < planes && ok; i++) {
        uint8_t *s = planar ? CVPixelBufferGetBaseAddressOfPlane(src, i) : CVPixelBufferGetBaseAddress(src);
        uint8_t *d = planar ? CVPixelBufferGetBaseAddressOfPlane(dst, i) : CVPixelBufferGetBaseAddress(dst);
        size_t srb = planar ? CVPixelBufferGetBytesPerRowOfPlane(src, i) : CVPixelBufferGetBytesPerRow(src);
        size_t drb = planar ? CVPixelBufferGetBytesPerRowOfPlane(dst, i) : CVPixelBufferGetBytesPerRow(dst);
        size_t ph = planar ? CVPixelBufferGetHeightOfPlane(dst, i) : h;

        size_t row = MIN(srb, drb);
        if (!s || !d || row == 0 || ph == 0) { ok = NO; break; }

        if (srb == drb) {
            memcpy(d, s, row * ph);
        } else {
            for (size_t y = 0; y < ph; y++) memcpy(d + y * drb, s + y * srb, row);
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
        // sRGB 的伽马，不是 BT.709 的视频伽马（那个约 1.9，会把对比度压扁）。
        // 用 NSString 字面量而不是 CFSTR：CFString 和 NSString 是 toll-free bridged，
        // 但 CFSTR 展开成 CFStringRef，塞进 NSDictionary 字面量会报「不是 ObjC 对象」。
        (id)kCVImageBufferTransferFunctionKey: @"IEC_sRGB",
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

/// 读 NV12 buffer 中心的 Y / Cb / Cr。
///
/// 0.3.17 加这个是为了把「整片发蓝」钉死在具体某一步上：
/// 一边打转换**输入**（BGRA 中心像素），一边打转换**输出**（Y/Cb/Cr），
/// 两边一对就知道是通道序错了、范围错了，还是根本没错。
static void SLVLogNV12Center(CVPixelBufferRef pb, NSString *tag) {
    if (!pb) return;
    if (!CVPixelBufferIsPlanar(pb) || CVPixelBufferGetPlaneCount(pb) < 2) return;

    size_t w = CVPixelBufferGetWidth(pb);
    size_t h = CVPixelBufferGetHeight(pb);
    if (w < 4 || h < 4) return;
    if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return;

    uint8_t *yB  = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    uint8_t *uvB = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    size_t yRB  = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    size_t uvRB = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);

    if (yB && uvB) {
        // 亮度平面是全尺寸，色度平面只有一半宽高；中心点两边都要各取一半
        size_t yi = (h / 2) * yRB + (w / 2);
        size_t ui = (h / 4) * uvRB + (w / 4) * 2;
        SLVLog(@"%@ 中心 Y=%u Cb=%u Cr=%u（%zux%zu）",
               tag, yB[yi], uvB[ui], uvB[ui + 1], w, h);
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
}

/// 按 BT.709 把 BGRA 中心像素换算成「应该得到的 Y/Cb/Cr」。
///
/// 跟 `SLVLogNV12Center` 配套：期望值和实际值差得离谱 = 转换错了；
/// 两个值对得上但画面还是蓝 = 错在更上游（CI 读素材帧那一步）。
static void SLVLogExpectYCbCr(CVPixelBufferRef bgra, BOOL full, NSString *tag) {
    if (!bgra) return;
    if (CVPixelBufferGetPixelFormatType(bgra) != kCVPixelFormatType_32BGRA) return;

    size_t w = CVPixelBufferGetWidth(bgra);
    size_t h = CVPixelBufferGetHeight(bgra);
    if (w < 2 || h < 2) return;
    if (CVPixelBufferLockBaseAddress(bgra, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return;

    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(bgra);
    if (base) {
        uint8_t *p = base + (h / 2) * CVPixelBufferGetBytesPerRow(bgra) + (w / 2) * 4;
        double B = p[0], G = p[1], R = p[2];
        double Y  = 0.2126 * R + 0.7152 * G + 0.0722 * B;
        double Cb = (B - Y) / 1.8556 + 128.0;
        double Cr = (R - Y) / 1.5748 + 128.0;
        if (!full) {                       // 16-235 / 16-240
            Y  = 16.0 + Y * 219.0 / 255.0;
            Cb = 128.0 + (Cb - 128.0) * 224.0 / 255.0;
            Cr = 128.0 + (Cr - 128.0) * 224.0 / 255.0;
        }
        SLVLog(@"%@ Y=%.0f Cb=%.0f Cr=%.0f（源 B=%u G=%u R=%u · %@）",
               tag, Y, Cb, Cr, p[0], p[1], p[2], full ? @"全范围" : @"16-235");
    }
    CVPixelBufferUnlockBaseAddress(bgra, kCVPixelBufferLock_ReadOnly);
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

    NSDictionary *attrs = SLVPixelBufferAttrs();
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

// 0.3.56：目标格式的定型时间。
//
// 池子只能有一种布局，但宿主可能同时有两套格式在拉：陌陌的日志里 AVCapture 音频是
// 1ch/2B、AudioUnit 是 2ch/4B。如果每来一个请求就跟着翻一次格式，池子会被反复清空 ——
// 比原来的噪声更糟（变成整场静音）。
//
// 所以：格式定型后 1.5 秒内不接受「另一种格式」的请求（那几包放行真麦克风）。
// 采集会话装配那几秒的临时格式自然会过去，真正长期在拉的那条会赢得定型。
static const CFAbsoluteTime SLV_AUDIO_FORMAT_STABLE = 1.5;

// 0.3.49：每个消费者一条独立游标。
//
// 视频通话里宿主经常同时开两个 AudioUnit（RTC 上行一个、本地电平/试音一个），
// 两个都在 bus=1 上拉麦克风。以前它们共用一个读游标 —— 等于「你一包我一包」：
// 每个 unit 每 20ms 只拿到一包 20ms，但内容往前跳了 40ms，听感是隔包跳、语速翻倍，
// 在通话里就是「对方听不清 / 听不到声音」。日志上还看不出来：水位照常、丢 0 字节。
#define SLV_AUDIO_CONSUMERS 4

// 0.3.50：多久没来拉数据就认为这个消费者已经死了。
//
// 视频通话里宿主会先建一个 AudioUnit 探格式，拉一两包就丢掉，再建真正做
// 上行编码的那个。死掉的那个游标永远停在原地，而生产端是看「最落后的游标」
// 判断水位的 —— 于是池子补到 120ms 就再也不补，活着的 unit 把这点数据吃完，
// 之后每一包都是补零，对端从第一秒起就没声音。日志上看起来一切正常：
// 心跳照涨、丢 0 字节、接管成功。所以必须按时间去认「谁还在拉」。
static const CFAbsoluteTime SLV_AUDIO_CONSUMER_TTL = 1.0;

// 0.3.53：音画对齐。
//
// 视频和音频是两条完全独立的轨：视频只留「最新一帧」，宿主来要就给；音频则是
// 一个 FIFO 池顺序往外吐。两边没有任何共同的时间基准 —— 池子每被剪一次（重建
// 采集会话、切素材、换格式），音频内容就整体前移一段，而画面照旧，偏差一旦出现
// 就永久留着，后面还会越滚越大。
//
// 修法：给池子里的 PCM 记上素材 PTS，于是「游标读到第几秒」和「画面显示第几秒」
// 可以直接比。差得多了就把游标挪过去，两边重新咬合。
typedef struct {
    NSUInteger off;         // 相对 _audioPCM 的字节偏移
    double pts;             // 这个偏移处的素材时间（秒）
} SLVAudioTS;

// 0.3.55：目标格式的迟滞时间。
//
// 微信视频通话里同时挂着「预览」和「通话」两个 AVCaptureVideoDataOutput，
// 它们的分辨率不同（日志里 1920x1080 与 1280x720 交替出现），两路帧混在同一个
// hook 里进来，管线 key 就会来回变。每变一次都重建 reader —— 解码器重开、
// 画面从头解一遍、卡一下。交替几次，整场通话就等于一直在重启。
//
// 新的 key 必须连续稳定这么久才真的切；这段等待里继续用旧管线出帧，
// 因为渲染那一步本来就能把任意尺寸铺到宿主 buffer 上，尺寸变了并不需要换解码器。
static const CFAbsoluteTime SLV_KEY_STABLE_SEC = 0.8;

// 偏差超过这个就一刀对齐。正常稳态只有「生产端领跑水位」那 100ms 左右的固定
// 差，超过 120ms 说明真的错开了。
static const double SLV_AUDIO_SYNC_TOL = 0.12;
// 每个消费者最多这么频繁检查一次（音频实时线程，别每包都算）
static const double SLV_AUDIO_SYNC_CHECK = 0.25;
#define SLV_AUDIO_TS_MAX 512

// 0.3.54：生产端的判据从「水位」改成「素材时刻」。
//
// 水位是相对消费者的：没人拉就一直满，生产端于是原地不动；而画面是按墙钟走的，
// 两边一旦被拉开（重建 reader、切素材、宿主播一下）就再也追不回来。0.3.53 的
// 日志里那行「音频 8.36s / 画面 14.00s → 挪 -5641ms」就是这条造的 —— 生产端根本
// 没解到 14 秒，对齐逻辑只能把游标夹到池尾，白丢一段再补一段静音。
//
// 现在生产端只认一件事：**已经解出来的音频够不够「画面时刻 + 120ms」**。
// 不够就一直解，够了就停。这样音频的解码位置天生跟着画面走。
//
// 解码位置落后画面超过这个值，说明中间断过（重建 / 卡顿），这时候
// 1) 一次多补一些包（追赶），2) 解出来但比画面早这么多的块直接扔掉 ——
// 那部分内容按定义已经播过了，进池子只会变成「延后播放的旧声音」。
static const double SLV_AUDIO_STALE_SEC    = 0.30;
#define SLV_AUDIO_CATCHUP_MAX 24      // 追赶时一轮最多补几包（稳态是 8）

// 视频追赶：一次最多连解几帧。视频落后时（解码慢、系统忙）不能只解一帧就睡，
// 否则会越落越远，最后整段变成慢放 —— 那才是「音画不同步」里最难察觉的一种。
#define SLV_VIDEO_CATCHUP_MAX 6

typedef struct {
    const void *key;        // AudioUnit 指针；NULL = AVCapture / AudioQueue 那条链
    NSUInteger cursor;      // 相对 _audioPCM 的读位置
    CFAbsoluteTime lastCall;
    CFAbsoluteTime lastSync; // 上次做音画对齐检查的时间

    // 0.3.56：接缝处理。
    //
    // 0.3.55 的日志里，一场 98 秒的通话有 7 次「重建立管 + 池子清零」，每次注入流都
    // 从波形上某一点瞬间跳到另一点。对端听到的就是「啪」——连跳几次就是一串爆响，
    // 也就是用户说的「有的时候有很大的杂音」。这里给每个消费者记住上一包最后一个
    // 样本，下一包开头和它差得远就做 8ms 淡入，把台阶抹平。
    int32_t lastVal[2];     // 上一包最后一个样本（最多两声道，按 int16 满刻度归一）
    BOOL hasLast;
    float gain;             // 上一包用的限幅增益（1.0 = 没限幅），做块间渐变用
    NSUInteger splices;     // 这个消费者累计做了多少次接缝淡入
    NSUInteger limits;      // 累计限幅次数

    // 0.3.58：接缝改成「事件驱动」。
    //
    // 0.3.57 只靠波形判断（|本包首样本 - 上包尾样本| > 0.25）。这个判据在音乐素材
    // 上是错的：48kHz 下鼓点、镲的相邻样本差本来就能超过 0.25，于是包边界一落在
    // 鼓点上就误判。0.3.57 的日志里 10 秒出现 35 次接缝（每 285ms 一次，正好是
    // 鼓点节奏），每次都被强制套一个 40ms 淡入 —— 鼓点被削成渐强，听感发闷。
    //
    // 现在改成：只有真的发生了位置跳变（重建 reader / 对齐挪位 / 追帧丢弃 / 硬切）
    // 才置 _audioJumpEpoch，消费者看到 epoch 变了才淡入。波形只留一个很高的阈值
    // 兜底真爆音，不再拿它当主判据。
    NSUInteger seenEpoch;   // 上次取包时看到的 _audioJumpEpoch
} SLVAudioConsumer;

/// 一段 PCM 的响度（dBFS），NAN = 格式不认识。
/// 和 SLCamAudioUnit.m 里那份是同一套算法，故意各写一份：
/// 生产端和注入端必须能互相印证，共用一份的话探针错了会一起错。
static double SLVPCMLoudnessdBFS(const void *bytes, size_t len, const AudioStreamBasicDescription *asbd) {
    if (!bytes || !len || !asbd) return NAN;
    BOOL isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    double sum = 0;
    size_t n = 0;
    if (isFloat && asbd->mBitsPerChannel == 32) {
        const float *f = (const float *)bytes;
        for (size_t i = 0; i < len / sizeof(float); i++) { double v = f[i]; sum += v * v; n++; }
    } else if (!isFloat && asbd->mBitsPerChannel == 16) {
        const int16_t *s = (const int16_t *)bytes;
        for (size_t i = 0; i < len / sizeof(int16_t); i++) { double v = s[i] / 32768.0; sum += v * v; n++; }
    } else {
        return NAN;
    }
    if (!n) return -120.0;
    double rms = sqrt(sum / (double)n);
    if (rms <= 1e-9) return -120.0;
    double db = 20.0 * log10(rms);
    return db < -120.0 ? -120.0 : db;
}

/// 两个 ASBD 是不是同一种「字节布局」。
///
/// 不用 memcmp：ASBD 里有 mReserved 这种保留字段，宿主填什么都有可能；
/// 一次误判就够把池子清空一次，来回几次整场通话就全是静音了。
static BOOL SLVASBDSame(const AudioStreamBasicDescription *a, const AudioStreamBasicDescription *b) {
    if (!a || !b) return NO;
    return a->mSampleRate == b->mSampleRate
        && a->mFormatID == b->mFormatID
        && a->mFormatFlags == b->mFormatFlags
        && a->mBytesPerPacket == b->mBytesPerPacket
        && a->mFramesPerPacket == b->mFramesPerPacket
        && a->mBytesPerFrame == b->mBytesPerFrame
        && a->mChannelsPerFrame == b->mChannelsPerFrame
        && a->mBitsPerChannel == b->mBitsPerChannel;
}

#pragma mark - 响度规整 + 接缝淡入（0.3.57）

/// 一个样本读成归一化 float（int16 / float32 都支持）。
static inline float SLVGetSample(const uint8_t *b, size_t i, BOOL isFloat) {
    if (isFloat) return ((const float *)b)[i];
    return ((const int16_t *)b)[i] / 32768.0f;
}

static inline void SLVSetSample(uint8_t *b, size_t i, BOOL isFloat, float v) {
    if (isFloat) {
        ((float *)b)[i] = (v > 1.0f) ? 1.0f : ((v < -1.0f) ? -1.0f : v);
        return;
    }
    if (v > 1.0f) v = 1.0f; else if (v < -1.0f) v = -1.0f;
    ((int16_t *)b)[i] = (int16_t)lrintf(v * 32767.0f);
}

/// 送话音量目标：-18 dBFS RMS。
///
/// 素材是短视频音乐，RMS 常在 -5 dBFS 上下（几乎满刻度）。这个电平直接进语音
/// 编码器（单声道、低码率）会被压碎，再经对端 AGC / 降噪就是破音、机器人音、
/// 嗡嗡声 —— 也就是用户说的「很大的杂音」。降到语音域，编码器才工作在它设计的
/// 位置上；同时峰值也自动远离满刻度，硬削波不再发生。
static const float SLV_TALK_RMS = 0.1259f;      // 10^(-18/20)
static const float SLV_TALK_GAIN_MIN = 0.15f;   // 最多衰减 16dB（再低说明素材本来就很轻）
static const float SLV_TALK_GAIN_MAX = 3.0f;    // 最多放大 9.5dB
static const float SLV_PEAK_CEIL = 0.891f;      // -1 dBFS

/// 就地处理一包已经填好的 PCM：先做响度规整，再在接缝处淡入。
///
/// 为什么是「就地」：这包数据是我们自己 memcpy 出来的副本，改它不影响池子，
/// 也不会让下一个消费者读到被改过的内容。
///
/// 返回位掩码：1 = 做了接缝淡入，2 = 触发了峰值兜底，0 = 这包本来就很干净。
static NSUInteger SLVPolishChunk(uint8_t *bytes, size_t len,
                                const AudioStreamBasicDescription *a,
                                int32_t *lastVal, BOOL *hasLast, float *gainInOut,
                                BOOL jumped) {
    if (!bytes || !len || !a || a->mBytesPerFrame == 0) return 0;

    BOOL isFloat = (a->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    UInt32 bits = a->mBitsPerChannel;
    if (!((isFloat && bits == 32) || (!isFloat && bits == 16))) return 0;  // 不认识的格式不碰

    UInt32 ch = a->mChannelsPerFrame ? a->mChannelsPerFrame : 1;
    UInt32 bps = bits / 8;
    // 只处理「交错」和「单声道」。非交错多声道的 plane 长度跟帧数对不上，
    // 硬算会把左右声道拌在一起 —— 那是比爆音更难听的噪声。
    if ((a->mFormatFlags & kAudioFormatFlagIsNonInterleaved) && ch > 1) return 0;
    if (ch > 2) return 0;
    if (a->mBytesPerFrame != ch * bps) return 0;

    size_t frames = len / a->mBytesPerFrame;
    if (frames < 2) return 0;

    NSUInteger did = 0;

    // ---- ① 响度规整：把这一包拉到语音域 ----
    //
    // 0.3.56 做的是「超过 -1 dBFS 就整块缩小」。但素材 RMS 本来就是 -5 dBFS，
    // 峰值≈1.0，那套逻辑只降 1dB —— 削波是没了，响度一点没降，对端听到的
    // 依然是被编码器压碎的近满幅音乐。
    //
    // 现在按 RMS 求增益，并且用非对称时间常数：素材太响时 40ms 就压下去，
    // 太轻时 260ms 慢慢抬。关键是块内增益基本恒定 —— 0.3.56 那种逐包
    // 0.9↔0.95 抖动等于给信号加 50Hz 幅度调制，听感是沙沙/发颤。
    double sum = 0;
    float peak = 0.0f;
    size_t nsamp = len / bps;
    for (size_t i = 0; i < nsamp; i++) {
        float v = SLVGetSample(bytes, i, isFloat);
        sum += (double)v * v;
        float av = v < 0 ? -v : v;
        if (av > peak) peak = av;
    }
    double rms = nsamp ? sqrt(sum / (double)nsamp) : 0.0;

    float ideal = 1.0f;
    if (rms > 1e-4) {
        ideal = (float)(SLV_TALK_RMS / rms);
        if (ideal < SLV_TALK_GAIN_MIN) ideal = SLV_TALK_GAIN_MIN;
        if (ideal > SLV_TALK_GAIN_MAX) ideal = SLV_TALK_GAIN_MAX;
    }

    // gainInOut <= 0 表示「这个消费者还没定过增益」（新接上的 unit）——
    // 直接用它自己的 ideal，不要让前 100ms 顶着满幅音乐出声。
    float prev = (*gainInOut > 0.0f) ? *gainInOut : ideal;
    float want = prev;
    if (rms > 1e-4) {
        double tau = (ideal < prev) ? 0.040 : 0.260;
        double alpha = 1.0 - exp(-(double)frames / (a->mSampleRate * tau));
        if (alpha > 1.0) alpha = 1.0;
        want = prev + (ideal - prev) * (float)alpha;
    }

    // ---- ② 峰值兜底 ----
    // 规整之后峰值一般远低于满刻度，只有极短促的瞬态（鼓、镲）才会顶到。
    // 这里把整包增益压到刚好不削波，并把状态一起压下去；下一包靠 ① 的慢放
    // 回升，所以不会每包在 0.9↔0.95 之间反复。
    if (peak > 1e-6f && peak * want > SLV_PEAK_CEIL) {
        want = SLV_PEAK_CEIL / peak;
        did |= 2;
    }

    // ---- ③ 施加增益（块内从上一包线性过渡到本包）----
    // want 本身就是慢变量，这一步只是把包边界的微小差值抹平，不会产生调制。
    if (fabsf(want - 1.0f) > 1e-4f || fabsf(prev - 1.0f) > 1e-4f) {
        for (size_t f = 0; f < frames; f++) {
            float g = prev + (want - prev) * (float)(f + 1) / (float)frames;
            for (UInt32 c = 0; c < ch; c++) {
                size_t i = f * ch + c;
                SLVSetSample(bytes, i, isFloat, SLVGetSample(bytes, i, isFloat) * g);
            }
        }
    }
    *gainInOut = want;

    // ---- ④ 接缝淡入 ----
    //
    // 0.3.58：主判据换成事件。`jumped` 为真表示这一包之前确实发生过位置跳变
    //（重建 reader / 对齐挪位 / 追帧丢弃 / 硬切），波形在这里必然有个台阶。
    //
    // 波形只做兜底：阈值 0.55（≈ -5 dBFS 的相邻样本跳变）。整幅跳变才会到这里，
    // 鼓点、镲那类真实瞬态（0.25 上下）不再被误判 —— 0.3.57 的日志里 10 秒误判
    // 35 次，每次都白套一个 40ms 淡入，把鼓点削成了渐强。
    float cur0 = SLVGetSample(bytes, 0, isFloat);
    BOOL seam = jumped;
    if (!seam && *hasLast && fabsf(cur0 - lastVal[0] / 32768.0f) > 0.55f) {
        seam = YES;
    }
    if (seam && frames >= 2) {
        uint32_t fade = (uint32_t)(a->mSampleRate * 0.040);
        if (fade < 16) fade = 16;
        if (fade > frames) fade = (uint32_t)frames;
        for (uint32_t f = 0; f < fade; f++) {
            float w = (float)(f + 1) / (float)fade;
            w = w * w * (3.0f - 2.0f * w);        // smoothstep，两端都不带折角
            for (UInt32 c = 0; c < ch; c++) {
                size_t i = (size_t)f * ch + c;
                float pv = (c < 2 ? lastVal[c] : lastVal[0]) / 32768.0f;
                float v = SLVGetSample(bytes, i, isFloat);
                SLVSetSample(bytes, i, isFloat, pv + (v - pv) * w);
            }
        }
        did |= 1;
    }

    // ---- 记住本包最后一个样本，下一包拿它比 ----
    for (UInt32 c = 0; c < ch; c++) {
        float v = SLVGetSample(bytes, (frames - 1) * ch + c, isFloat);
        lastVal[c < 2 ? c : 0] = (int32_t)lrintf(v * 32768.0f);
    }
    *hasLast = YES;
    return did;
}

@interface SLVCamFeed () {
    NSLock *_lock;

    // ---- 跨线程共享（受 _lock 保护）----
    CVPixelBufferRef _latestVideo;
    NSString *_pipelineKey;              // "875704422:1920x1080"，变了就要重建 reader
    BOOL _reconfigRequested;
    // 0.3.55：目标格式迟滞（见 SLV_KEY_STABLE_SEC）
    NSString *_pendingKey;
    CFAbsoluteTime _pendingKeyAt;
    CFAbsoluteTime _lastKeySwitchAt;
    int _keySwitchCount;                 // 累计真正切换管线的次数（诊断用）
    NSMutableData *_audioPCM;
    // 0.3.49：按消费者分开的游标（key 是 AudioUnit 指针，NULL = AVCapture/AudioQueue 那条链）
    SLVAudioConsumer _audioConsumers[SLV_AUDIO_CONSUMERS];
    int _audioConsumerCount;
    int _audioConsumerPruned;            // 累计被判定「死了」而摘掉的消费者数（诊断用）
    AudioStreamBasicDescription _audioDstASBD;
    BOOL _hasAudioDstASBD;
    AVAudioConverter *_audioConverter;
    NSUInteger _audioBytesPerSecond;
    BOOL _assetHasAudio;                 // 素材本身有没有音轨：决定「没数据」时是静音还是放行真麦克风
    BOOL _audioTrackAttached;            // 当前 reader 到底把音轨挂上了没有（0.3.50 诊断用）
    NSUInteger _audioDropped;            // 累计丢弃字节（诊断用）
    NSUInteger _audioHardCuts;           // 0.3.57：累计「缓冲过高硬切」次数
    CFAbsoluteTime _audioDropLogAt;      // 硬切日志限流（以前是一次性标志，之后全静默）
    BOOL _audioPassLogged;               // 「放行真麦克风」只打一次，诊断用
    NSUInteger _audioCalls;              // 消费端被调用次数（水位心跳用）
    NSUInteger _audioPumped;             // 生产端写入的 PCM 块数（素材解出电平日志用）
    CMTime _lastVideoPTS;                // 0.3.50：重建 reader 时从这里续播，画面不跳回开头

    // 0.3.53：音频池的「字节偏移 → 素材时间」映射，音画对齐全靠它
    SLVAudioTS _audioTS[SLV_AUDIO_TS_MAX];
    int _audioTSCount;
    NSUInteger _audioSyncJumps;          // 累计做了多少次音画对齐（诊断用）
    CFAbsoluteTime _audioSyncLogAt;
    BOOL _resumeValid;
    CGSize _naturalSize;

    // 0.3.54：生产端自己的位置（已解出的最后一包结束时刻）。
    // 池子空的时候时间轴给不出答案，但生产端必须知道「自己解到第几秒」，
    // 否则重建 reader 后第一包还没进来时就没法判断该不该继续解。
    double _audioHeadPTS;
    NSUInteger _audioSkipBlocks;         // 被「丢弃追帧」扔掉的块数（诊断用）
    CFAbsoluteTime _audioSkipLogAt;

    // 0.3.56：目标格式切换次数 / 接缝淡入次数 / 限幅次数（诊断用）
    NSUInteger _audioFormatJumps;
    NSUInteger _audioSplices;
    NSUInteger _audioLimits;
    // 0.3.58：跳位纪元。任何「内容位置真的变了」的事件都 ++，消费者看到变了才淡入。
    // 反过来说：没有这些事件就不该有淡入 —— 波形本身不构成跳位的证据。
    NSUInteger _audioJumpEpoch;
    BOOL _primePending;                  // 已有一件「后台登记格式」的活在路上
    BOOL _audioMismatchLogged;
    CFAbsoluteTime _audioFormatAt;       // 当前目标格式是哪一刻定型的（迟滞用）

    // ---- 解码线程独占 ----
    AVAssetReader *_reader;
    NSUInteger _readerGen;               // 0.3.58：这个 reader 属于哪一代（防旧线程取消新一代）
    AVAssetReaderTrackOutput *_videoOut;
    AVAssetReaderTrackOutput *_audioOut;
    AudioStreamBasicDescription _audioSrcASBD;
    double _frameInterval;               // 秒/帧，按素材自身帧率算，用来给解码线程节流
    int _idleRounds;                     // 连续空转次数，用来区分「读完了」和「音频池满了」

    // 0.3.53：视频按墙钟播。以前是「解一帧 + 睡 1/fps」，实际周期里还带着解码
    // 耗时，1080p 以上素材就会整体慢放；慢放不会被看出来，但会和实时推进的
    // 音频越错越开。现在定一个「墙钟 ↔ 素材时间」的锚，落后就补解帧追上来。
    double _playWall;                    // 锚点：当时墙钟
    double _playPTS;                     // 锚点：对应素材时间（秒）
    BOOL _playValid;

    CIContext *_ciContext;
    NSUInteger _generation;
    BOOL _running;

    // ---- 图片素材（0.2.20）----
    // 图片没有「下一帧」，解一次就够。解完塞进 _latestVideo，
    // 下游三条出图路径（预览 / 拍照 / 抖音 pixelBuffer）读的都是它，一行都不用改。
    BOOL _isImage;
    BOOL _stillLoaded;
    NSString *_stillKey;                 // 这张静态图是按哪个 "格式:宽x高" 渲染的

    // ---- 注入专用缓存（0.3.8）----
    // 图片是静态的，但宿主每帧给的 buffer 都是新的，所以每帧都要往里搬一次。
    // 旋转 / 镜像 / 尺寸转换只做一次，结果按 key 缓存，之后每帧纯 memcpy。
    CVPixelBufferRef _hostStill;
    NSString *_hostStillKey;             // "格式:宽x高:m镜像:r角度"

    // 0.3.58：视频出帧路径计数。
    //
    // 这两个数决定「糊到底该不该算在我们头上」：
    //   · 直出很大 = 素材尺寸/格式本来就贴着宿主，我们一个像素都没动
    //   · 渲染很大 = 每帧都在过 CoreImage 缩放，质量和耗时都要盯
    // 之前没有这两个数，只能靠 key 里的尺寸去猜。
    NSUInteger _videoDirectCount;
    NSUInteger _videoRenderCount;
}

- (void)sl_restart;
+ (BOOL)sl_isImagePath:(NSString *)p;
- (void)sl_loadStillImage;
- (void)sl_decodeLoopWithGeneration:(NSUInteger)gen;
// 0.3.59：返回值给解码线程自己持有。
// 以前 reader 只挂在 ivar 上，换一代时新线程一赋值就把旧 reader 释放掉 ——
// 而旧线程可能正阻塞在 copyNextSampleBuffer 里，读到一半对象没了 → 闪退。
//
// 0.3.60：两个输出也一并出参返回，不再让调用方去 ivar 里拿。
// 之前 output 是在 addOutput 之后、startReading **之前**就写进共享 ivar 的，
// 一个慢一代的旧线程正好在这个窗口里把它覆盖掉，新线程快照到的就是一个
// 「没挂上 / 没 start」的 output → copyNextSampleBuffer 直接抛
// "cannot copy next sample buffer before adding this output to an instance of
// AVAssetReader ... and calling -startReading"。
- (AVAssetReader * _Nullable)sl_buildReaderForKey:(NSString *)key generation:(NSUInteger)gen
                                         videoOut:(AVAssetReaderTrackOutput * _Nullable * _Nullable)outV
                                         audioOut:(AVAssetReaderTrackOutput * _Nullable * _Nullable)outA;
- (BOOL)sl_pumpAudio:(AVAssetReaderTrackOutput *)out;
- (BOOL)sl_audioNeedMore;
- (BOOL)sl_audioNeedMoreLocked;
- (NSData *)sl_audioLocked:(const AudioStreamBasicDescription *)asbd numBytes:(size_t)numBytes
                configure:(BOOL)configure consumer:(const void * _Nullable)consumer;
- (int)sl_consumerSlotLocked:(const void * _Nullable)key;
- (NSUInteger)sl_bufferedLocked;
- (double)sl_videoPTSLocked;
- (double)sl_ptsAtOffsetLocked:(NSUInteger)off;
- (NSInteger)sl_offsetAtPTSLocked:(double)pts;
- (void)sl_trimPoolLocked:(NSUInteger)cut;
- (NSData *)sl_convertAudio:(NSData *)input;
- (NSInteger)sl_normalizedRotation;
- (nullable CIImage *)sl_image:(CIImage *)img
                       toWidth:(size_t)w
                        height:(size_t)h
                        mirror:(BOOL)mirror
                      rotation:(NSInteger)rotation
                    squareCrop:(BOOL)squareCrop;
- (CVPixelBufferRef)sl_render:(CVPixelBufferRef)src
                      toWidth:(size_t)w
                       height:(size_t)h
                       format:(OSType)pf
                       mirror:(BOOL)mirror
                     rotation:(NSInteger)rotation
                   squareCrop:(BOOL)squareCrop CF_RETURNS_RETAINED;
- (BOOL)sl_writeSource:(CVPixelBufferRef)src
                  into:(CVPixelBufferRef)dst
                mirror:(BOOL)mirror
              rotation:(NSInteger)rotation
            squareCrop:(BOOL)squareCrop;
- (CIImage *)sl_blurBackdropForImage:(CIImage *)img
                                 src:(CVPixelBufferRef)src
                               width:(size_t)w
                              height:(size_t)h;

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
    AVAssetReader *retired = nil;
    [_lock lock];
    gen = ++_generation;
    _reconfigRequested = YES;
    _pipelineKey = nil;
    _stillLoaded = NO;
    _stillKey = nil;
    if (_latestVideo) { CVPixelBufferRelease(_latestVideo); _latestVideo = NULL; }
    // 注入缓存也是按旧素材渲的，换素材必须一起扔掉
    if (_hostStill) { CVPixelBufferRelease(_hostStill); _hostStill = NULL; }
    _hostStillKey = nil;
    // 0.3.59：换素材 = 换了一条时间轴，续播点必须作废。
    //
    // 以前这里什么都不清，于是新素材会拿**上一部片**的 PTS 去 timeRange 续播
    // （日志里「feed 从 8.05 秒续播」就是这么来的）。新片比这个点短的话，
    // timeRange 直接落在片尾之后 → startReading 失败「这项操作无法完成」。
    _resumeValid = NO;
    _lastVideoPTS = kCMTimeInvalid;
    _playValid = NO;
    // 旧 reader 在这里就摘掉并停掉：它那一代的线程还在 decodeLoop 里，
    // 不 cancel 它会一直读到片尾；cancel 之后它在下一次 copyNextSampleBuffer
    // 立刻拿到 nil，看到 generation 变了就退出。
    if (_reader) { retired = _reader; _reader = nil; }
    // 0.3.60：output 也一起摘掉。旧线程自己持有强引用（ownReader / vOut），
    // 这里置 nil 只是别让新线程从 ivar 里读到上一代的东西。
    _videoOut = nil;
    _audioOut = nil;
    [_audioPCM setLength:0];
    _audioTSCount = 0;
    _audioJumpEpoch++;                   // 0.3.58：池子清空 = 内容断点，下一个包必须渐入
    _audioHeadPTS = NAN;                 // 0.3.54：池子清空了，生产端位置也没了
    // 换素材必须把所有人的游标一起归零，否则旧位置会落在新池子外面
    for (int i = 0; i < _audioConsumerCount; i++) {
        _audioConsumers[i].cursor = 0;
        _audioConsumers[i].hasLast = NO;      // 换了素材，上一包的样本值不再有意义
        _audioConsumers[i].gain = 1.0f;
    }
    _running = (_sourcePath.length > 0);
    BOOL run = _running;
    [_lock unlock];

    if (retired) [retired cancelReading];

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
// 只做一次。之后所有出图路径（注入的 copyFrameForHostBuffer:、拍照的
// copyOrientedFrameForPixelFormat: / renderIntoPixelBuffer:）读的都是
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

    // 目标尺寸：宿主已经告诉我们格式就按它来（这样注入时能直接 memcpy
    // 进宿主的 buffer），还没告诉就按原图（长边封顶 2048）。
    OSType pf = kCVPixelFormatType_32BGRA;
    size_t w = 0, h = 0;
    if (key.length) {
        NSArray<NSString *> *parts = [key componentsSeparatedByString:@":"];
        // 0.3.12 起 key 多了一段 ":q0/1"（正方形裁切状态），所以不能只认 2 段。
        // 只看前两段：像素格式、宽高。后面的是给解码管线做失效判断用的。
        if (parts.count >= 2) {
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
    // squareCrop:YES —— 这是注入用的预览帧，陌陌开关打开时要按正方形裁。
    CIImage *scaled = [self sl_image:img toWidth:w height:h mirror:NO rotation:0 squareCrop:YES];
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
    NSDictionary *attrs = SLVPixelBufferAttrs();
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

    // 0.3.59：本线程自己持有 reader / 输出，不再直接拿 ivar 当调用目标。
    //
    // 崩溃现场（企业微信，视频通话中换素材，必现）：
    //   15:40:10 feed source -> xxx.mov
    //   15:40:10 feed startReading 失败
    //   15:40:13 === 进程重启 ===
    // 换素材时 sl_restart 会 detach 一个新线程，新线程在 buildReader 里
    // `_reader = reader` 这一句就把**旧 reader 释放**了；而旧线程这时多半
    // 正阻塞在 `[_videoOut copyNextSampleBuffer]` 里 —— 对象在自己的调用栈上
    // 被释放，下一次访问就是野指针。旧 ivar 里存的 AVAssetReaderTrackOutput
    // 又只由那个 reader 持有，跟着一起没。
    //
    // 现在：reader 由本线程的强引用保命，ivar 只做「给新线程看/给日志看」，
    // 谁也不能把别人正在用的对象free掉。
    AVAssetReader *ownReader = nil;
    // 输出对象也按「本线程」持有：它们在 buildReader 成功后跟 ownReader 一一对应，
    // 之后每次解码调用用的都是自己这一份，不会因为别的线程重建而指到别人的管线上去。
    AVAssetReaderTrackOutput *vOut = nil;
    AVAssetReaderTrackOutput *aOut = nil;

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
            if (!alive) {
                // 自己这一代的 reader 自己收尾，别指望别人替你 cancel
                if (ownReader) [ownReader cancelReading];
                break;
            }

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
                // 否则注入时每帧都要现场做一次 CI 缩放，
                // 30fps 下等于白烧一整个核。
                BOOL same = (skey == nil && key == nil) || [skey isEqualToString:key];
                if (!loaded || !same) [self sl_loadStillImage];
                usleep(200 * 1000);
                continue;
            }

            if (reconfig || !ownReader) {
                // 0.3.55：格式变化不该让画面回到素材开头。
                //
                // 以前 _resumeValid 只在「补挂音轨」那一处置上，任何其它重建都从 0 秒
                // 重新解。陌陌一场通话只重建一两次，看不出来；微信会时不时重配采集
                // 会话（日志里 1920x1080 / 1280x720 来回切），每重配一次画面就从开头
                // 播一遍 —— 表现就是「视频一直重头开始 / 根本不像在通话」。
                if (ownReader) {
                    [_lock lock];
                    _resumeValid = CMTIME_IS_VALID(_lastVideoPTS) && CMTIME_IS_NUMERIC(_lastVideoPTS);
                    [_lock unlock];
                    // 同一代内部换格式：先把旧的停掉再建新的，否则两个 reader
                    // 同时读同一个文件，解码器那边会报「无法完成」。
                    [ownReader cancelReading];
                    ownReader = nil;
                }
                AVAssetReaderTrackOutput *newV = nil, *newA = nil;
                ownReader = [self sl_buildReaderForKey:key generation:gen
                                             videoOut:&newV audioOut:&newA];
                if (!ownReader) { usleep(30 * 1000); continue; }
                // 0.3.60：直接用 build 交回来的对象，不再去 ivar 快照 ——
                // 快照这一步本身就是上个版本崩掉的地方。
                vOut = newV;
                aOut = newA;
            }

            BOOL gotAny = NO;
            BOOL videoEnded = NO;

            if (vOut) {
                // 0.3.53：按墙钟播，不再「解一帧睡 1/fps」。
                //
                // 旧写法每帧实际耗时 = 解码耗时 + 1/fps，1080p 以上素材光解码就
                // 十几毫秒，于是视频内容比真实时间慢；音频那边是硬件时钟，严格
                // 实时。两者差值会一直累积 —— 表现就是通话越久越对不上。
                //
                // 现在先算「此刻素材应该播到第几秒」，落后就连续补解几帧追上来，
                // 追上了就睡到下一帧该出现的时间点。
                double now = CFAbsoluteTimeGetCurrent();
                double target = _playValid ? (_playPTS + (now - _playWall)) : NAN;
                double lastPTS = NAN;

                for (int k = 0; k < SLV_VIDEO_CATCHUP_MAX; k++) {
                    CMSampleBufferRef sb = [vOut copyNextSampleBuffer];
                    if (!sb) {
                        videoEnded = YES;
                        break;
                    }
                    gotAny = YES;
                    CMTime ts = CMSampleBufferGetPresentationTimeStamp(sb);
                    double t = (CMTIME_IS_VALID(ts) && CMTIME_IS_NUMERIC(ts))
                             ? CMTimeGetSeconds(ts) : NAN;
                    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
                    if (pb) {
                        CVPixelBufferRetain(pb);
                        [_lock lock];
                        CVPixelBufferRef old = _latestVideo;
                        _latestVideo = pb;
                        if (!isnan(t)) _lastVideoPTS = ts;
                        [_lock unlock];
                        if (old) CVPixelBufferRelease(old);
                    }
                    CFRelease(sb);
                    if (isnan(t)) break;
                    lastPTS = t;

                    if (!_playValid) {
                        // 首帧（或重建 reader 后的首帧）定锚：从这里开始按实时走
                        _playValid = YES;
                        _playWall = CFAbsoluteTimeGetCurrent();
                        _playPTS = t;
                        break;
                    }
                    if (t >= target - 0.002) break;   // 追上了，这帧就是此刻该显示的
                    // 落后：这帧已经过期，丢掉继续解下一帧（最多补 6 帧）
                }

                if (_playValid && !isnan(lastPTS) && _frameInterval > 0) {
                    double due = _playWall + (lastPTS + _frameInterval - _playPTS);
                    double wait = due - CFAbsoluteTimeGetCurrent();
                    if (wait > 0.002) {
                        usleep((useconds_t)(MIN(wait, 0.05) * 1000000.0));
                    }
                }
            }

            // 一个视频帧周期里音频往往不止需要一包（一包 AAC 通常只有 23ms，
            // 而 30fps 一帧是 33ms），以前「一帧只补一包」会让缓冲长期处于抽干状态。
            //
            // 0.3.54：补到「画面时刻 + 120ms」为止（判据在 sl_audioNeedMore 里）。
            // 落后多的时候一轮多补几包 —— 这段是追赶，不是稳态，不能按 8 包憋着
            // 慢慢追，否则一次 1 秒的断档要 1 秒才补回来，听起来就是持续的口型错位。
            if (aOut) {
                int maxBlocks = 8;
                [_lock lock];
                double headPTS = _audioHeadPTS;
                double vptsNow = [self sl_videoPTSLocked];
                [_lock unlock];
                if (!isnan(headPTS) && !isnan(vptsNow) && vptsNow - headPTS > SLV_AUDIO_STALE_SEC) {
                    maxBlocks = SLV_AUDIO_CATCHUP_MAX;
                }
                for (int i = 0; i < maxBlocks; i++) {
                    if (![self sl_pumpAudio:aOut]) break;
                    gotAny = YES;
                    if (![self sl_audioNeedMore]) break;
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
                    [ownReader cancelReading];
                    ownReader = nil;
                    vOut = nil;
                    aOut = nil;
                    AVAssetReaderTrackOutput *loopV = nil, *loopA = nil;
                    ownReader = [self sl_buildReaderForKey:key generation:gen
                                                 videoOut:&loopV audioOut:&loopA];
                    if (!ownReader) {
                        usleep(50 * 1000);
                    } else {
                        vOut = loopV;
                        aOut = loopA;
                    }
                } else {
                    usleep(120 * 1000);
                }
            }
        }
    }
}

/// 摘掉已经不再来拉数据的消费者。调用方必须已持有 _lock。
///
/// 判断依据只能是时间：AudioUnit 被宿主销毁时没有任何通知能落到 tweak 上，
/// 我们只看到「它再也没来」。
- (void)sl_pruneConsumersLocked {
    if (_audioConsumerCount == 0) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    int w = 0, dropped = 0;
    for (int i = 0; i < _audioConsumerCount; i++) {
        if (now - _audioConsumers[i].lastCall > SLV_AUDIO_CONSUMER_TTL) { dropped++; continue; }
        _audioConsumers[w++] = _audioConsumers[i];
    }
    if (!dropped) return;
    _audioConsumerCount = w;
    _audioConsumerPruned += dropped;

    // 一个都不剩了：把池子里「画面已经播过」的那段扔掉。
    //
    // 0.3.53 之前这里都留最后 120ms、其余全砍 —— 砍掉的其实是**还没播的内容**
    //（没人在拉，生产端照样在解），下一个 unit 接上时内容就整体前移 0.6~1.9 秒，
    // 听感就是「声音突然跑到画面前面」，而画面那边一点没变。日志里那行
    //「清掉池里 1865ms 旧数据」就是这次跳变的记录。
    //
    // 现在按素材时间剪：只丢「比画面当前时刻还早」的部分。那部分永远不会再被
    // 播到，剪掉不影响任何内容的位置。
    NSUInteger trimmedMs = 0;
    if (_audioConsumerCount == 0 && _audioPCM.length > 0 && _audioBytesPerSecond > 0) {
        NSUInteger cut = 0;
        double vpts = [self sl_videoPTSLocked];
        if (!isnan(vpts) && _audioTSCount > 0) {
            NSInteger from = [self sl_offsetAtPTSLocked:vpts - SLV_AUDIO_SYNC_TOL];
            if (from > 0) cut = (NSUInteger)MIN((NSUInteger)from, _audioPCM.length);
        } else {
            // 还没有时间轴（刚开始 / 素材没音轨）：退回「只留高水位」
            NSUInteger keep = (NSUInteger)(_audioBytesPerSecond * SLV_AUDIO_HIGH_SEC);
            if (keep < 4096) keep = 4096;
            if (_audioPCM.length > keep) cut = _audioPCM.length - keep;
        }
        if (cut) {
            trimmedMs = cut * 1000 / _audioBytesPerSecond;
            [self sl_trimPoolLocked:cut];
        }
    }

    // 这条日志很重要：它解释「为什么前面静音、后面又好了」。
    // 不限流就会每次取数据刷一行，所以每 5 秒最多一条。
    static CFAbsoluteTime sLastPruneLog = 0;
    if (now - sLastPruneLog > 5.0) {
        sLastPruneLog = now;
        if (trimmedMs) {
            SLVLog(@"音频: 摘掉 %d 个不再来拉数据的消费者（剩 %d 个 · 累计 %d 个）· 丢掉已播过的 %lums",
                  dropped, _audioConsumerCount, _audioConsumerPruned, (unsigned long)trimmedMs);
        } else {
            SLVLog(@"音频: 摘掉 %d 个不再来拉数据的消费者（剩 %d 个 · 累计 %d 个）",
                  dropped, _audioConsumerCount, _audioConsumerPruned);
        }
    }
}

/// 池子里还剩多少（按最落后的那个**还活着**的消费者算）。
/// 生产端只关心「最落后的消费者还缺多少」—— 用最靠前的会一直以为没人消费。
/// 调用方必须已持有 _lock。
- (NSUInteger)sl_bufferedLocked {
    [self sl_pruneConsumersLocked];
    if (_audioConsumerCount == 0) return _audioPCM.length;
    NSUInteger min = _audioPCM.length;
    for (int i = 0; i < _audioConsumerCount; i++) {
        if (_audioConsumers[i].cursor < min) min = _audioConsumers[i].cursor;
    }
    if (min > _audioPCM.length) min = _audioPCM.length;
    return _audioPCM.length - min;
}

/// 生产端是否还要继续解音频。调用方必须已持有 _lock。
///
/// 判据只有一条：已经解出来的音频够不够「画面时刻 + 缓冲」。
/// 不能用池子水位判 —— 水位是相对消费者的，没有人拉的时候它一直满，
/// 生产端就停在那儿不动，而画面按墙钟继续走，差距永久留下。
- (BOOL)sl_audioNeedMoreLocked {
    if (_audioBytesPerSecond == 0) return YES;      // 目标格式还没确定，先别停

    // 0.3.57：**撤回** 0.3.55 的「没人拉就不要再解」。
    //
    // 那条本意是省解码，代价却全落到对端耳朵上：宿主每 10~16 秒重建一次采集会话，
    // 那一两秒没人拉数据，生产端就停在原地，画面按墙钟继续走。新 unit 接上时音频
    // 已经落后 2~5 秒，只能一路「丢弃追帧」把中间内容整段扔（0.3.56 日志里 33 块），
    // 每丢一块都是一次内容层面的跳段 —— 就是「咔、咔」那串杂音。
    //
    // 现在不管有没有消费者都按画面时刻解。多出来的代价是一条单声道 44.1k 音轨的
    // 解码 + memcpy（每秒约 176KB），可以忽略；换来的是池子里永远是画面此刻前后
    // 120ms 的内容，重连时不需要 seek、不需要丢块。
    double vpts = [self sl_videoPTSLocked];
    if (!isnan(vpts) && !isnan(_audioHeadPTS)) {
        return _audioHeadPTS < vpts + SLV_AUDIO_HIGH_SEC;
    }
    // 画面时刻还不知道（图片素材 / 首帧还没出来）：退回水位判断
    [self sl_pruneConsumersLocked];
    NSUInteger buffered = [self sl_bufferedLocked];
    return buffered < (NSUInteger)(_audioBytesPerSecond * SLV_AUDIO_HIGH_SEC);
}

/// 同上，自己加锁。解码线程用。
- (BOOL)sl_audioNeedMore {
    [_lock lock];
    BOOL need = [self sl_audioNeedMoreLocked];
    [_lock unlock];
    return need;
}

/// 解码线程内调用：按画面时刻补齐音频
/// 0.3.59：输出对象由调用方传进来（强引用），不再直接摸 ivar —— 见 decodeLoop 里的说明。
- (BOOL)sl_pumpAudio:(AVAssetReaderTrackOutput *)out {
    if (!out) return NO;
    [_lock lock];
    BOOL need = [self sl_audioNeedMoreLocked];
    [_lock unlock];
    if (!need) return NO;

    CMSampleBufferRef sb = [out copyNextSampleBuffer];
    if (!sb) return NO;

    CMTime sbPTS = CMSampleBufferGetPresentationTimeStamp(sb);
    BOOL hasPTS = CMTIME_IS_VALID(sbPTS) && CMTIME_IS_NUMERIC(sbPTS);
    double pts = hasPTS ? CMTimeGetSeconds(sbPTS) : NAN;
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    size_t len = bb ? CMBlockBufferGetDataLength(bb) : 0;
    if (len > 0) {
        // 0.3.56：转码前先记下「按哪个目标格式转」。转码是慢活（几毫秒），
        // 这期间宿主完全可能换格式；拼进池子时必须还是同一个格式，否则池子里
        // 会同时躺着两种布局的字节 —— 读端只能按一种标尺读，另一半就是噪声。
        [_lock lock];
        AudioStreamBasicDescription dstBefore = _audioDstASBD;
        BOOL hadDstBefore = _hasAudioDstASBD;
        [_lock unlock];

        NSMutableData *raw = [NSMutableData dataWithLength:len];
        OSStatus copySt = CMBlockBufferCopyDataBytes(bb, 0, len, raw.mutableBytes);
        NSData *converted = (copySt == noErr) ? [self sl_convertAudio:raw] : nil;
        if (converted.length) {
            double db = NAN;
            BOOL probe = NO;
            BOOL skipped = NO;
            double skipSec = 0;
            [_lock lock];
            if (!hadDstBefore || !_hasAudioDstASBD ||
                !SLVASBDSame(&dstBefore, &_audioDstASBD)) {
                // 转码期间格式变了：这包按旧格式转的字节已经作废。
                // 丢掉它比塞进池子便宜得多 —— 生产端位置不动，下一包会按新格式重解。
                [_lock unlock];
                CFRelease(sb);
                return YES;
            }
            double blk = _audioBytesPerSecond
                       ? (double)converted.length / (double)_audioBytesPerSecond : 0.0;
            double vpts = [self sl_videoPTSLocked];
            AudioStreamBasicDescription srcA = _audioSrcASBD;
            // 无论这块要不要，生产端的位置都要前移 —— 否则「丢弃追帧」会永远以为
            // 自己还在原处，一轮 8 包全扔掉，白烧解码。
            if (!isnan(pts)) _audioHeadPTS = pts + blk;

            // 0.3.54：比画面早 300ms 以上的块直接扔掉。
            // 这段内容按定义已经播过了（画面都走到它后面了），进池子只会变成
            // 「延后播放的旧声音」，然后被读取端的对齐逻辑再跳过一次 —— 白白
            // 让池子里塞一堆没人要的数据，还占着内存。
            if (!isnan(pts) && !isnan(vpts) && (pts + blk) < (vpts - SLV_AUDIO_STALE_SEC)) {
                skipped = YES;
                skipSec = blk;
                _audioSkipBlocks++;
                _audioJumpEpoch++;        // 0.3.58：整块被扔掉，前后的内容接不上
            } else {
                NSUInteger at = _audioPCM.length;
                [_audioPCM appendData:converted];
                // 0.3.53：记下这块 PCM 在池子里的位置和它对应的素材时间。
                // 音画对齐就是拿它反推「游标读到第几秒」。
                if (hasPTS) {
                    if (_audioTSCount == 0 || pts > _audioTS[_audioTSCount - 1].pts + 0.0005) {
                        if (_audioTSCount >= SLV_AUDIO_TS_MAX) {
                            // 满了就抽稀一半，保留偶数位（时间上仍单调）
                            int w = 0;
                            for (int i = 0; i < _audioTSCount; i += 2) _audioTS[w++] = _audioTS[i];
                            _audioTSCount = w;
                        }
                        if (_audioTSCount < SLV_AUDIO_TS_MAX) {
                            _audioTS[_audioTSCount].off = at;
                            _audioTS[_audioTSCount].pts = pts;
                            _audioTSCount++;
                        }
                    }
                }
                _audioPumped++;
                if (_audioPumped == 1 || _audioPumped % 600 == 0) {
                    probe = YES;
                    db = SLVPCMLoudnessdBFS(converted.bytes, converted.length, &_audioDstASBD);
                }
            }
            CFAbsoluteTime nowT = CFAbsoluteTimeGetCurrent();
            BOOL skipLog = skipped && (nowT - _audioSkipLogAt > 2.0);
            if (skipLog) _audioSkipLogAt = nowT;
            NSUInteger skipCount = _audioSkipBlocks;
            [_lock unlock];
            if (skipLog) {
                SLVLog(@"音频: 丢弃追帧 跳过 %.0fms（画面已到 %.2fs · 累计 %lu 块）",
                      skipSec * 1000.0, isnan(vpts) ? 0.0 : vpts, (unsigned long)skipCount);
            }
            if (probe) {
                // 生产端的独立证据：万一注入端又报「静音」，这一行能立刻分出
                // 是「素材根本没解出声音」还是「注入/探测的问题」。
                if (isnan(db)) {
                    SLVLog(@"音频: 素材解出 未知格式（第 %lu 块 %luB · bits=%u flags=0x%x）",
                          (unsigned long)_audioPumped, (unsigned long)converted.length,
                          (unsigned)_audioDstASBD.mBitsPerChannel, (unsigned)_audioDstASBD.mFormatFlags);
                } else if (db <= -90.0) {
                    // 0.3.55：输出全零时把输入也量一遍。
                    // 只报「-120 dBFS」分不清是「素材这一段本来就是静音」还是
                    //「转码把声音弄丢了」，而微信那次就是卡在这个歧义上。
                    double inDB = SLVPCMLoudnessdBFS(raw.bytes, raw.length, &srcA);
                    SLVLog(@"音频: 素材解出 = 静音（第 %lu 块 %luB · 输入 %.1f dBFS · 源 %.0fHz %uch / 目标 %.0fHz %uch %uB/帧）%@",
                          (unsigned long)_audioPumped, (unsigned long)converted.length,
                          inDB, srcA.mSampleRate, (unsigned)srcA.mChannelsPerFrame,
                          _audioDstASBD.mSampleRate, (unsigned)_audioDstASBD.mChannelsPerFrame,
                          (unsigned)_audioDstASBD.mBytesPerFrame,
                          (inDB > -90.0 ? @" ← 转码丢了声音" : @""));
                } else {
                    SLVLog(@"音频: 素材解出 %.1f dBFS（第 %lu 块 %luB）",
                          db, (unsigned long)_audioPumped, (unsigned long)converted.length);
                }
            }
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

    // 0.3.55：一次 convertToBuffer 只取一轮输出是不够的。
    //
    // 采样率下降（44.1k → 16k，微信通话就是这个格式）时，转换器要先把内部的重采样
    // 滤波器和 priming 喂满，第一轮常常只吐出一小段、甚至整段是零。以前只看第一轮，
    // 于是微信日志里出现 `素材解出 -120.0 dBFS`（全零）—— 看起来像「素材没声音」，
    // 其实只是转换器还没热身。现在一直取到 inputRanDry 为止，多轮结果拼起来。
    NSMutableData *out = [NSMutableData data];
    __block BOOL supplied = NO;
    for (int round = 0; round < 8; round++) {
        AVAudioPCMBuffer *outBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:dstFmt frameCapacity:cap];
        if (!outBuf) break;
        NSError *err = nil;
        AVAudioConverterOutputStatus st = [conv convertToBuffer:outBuf error:&err
            withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount n, AVAudioConverterInputStatus *status) {
                if (supplied) { *status = AVAudioConverterInputStatus_NoDataNow; return nil; }
                supplied = YES;
                *status = AVAudioConverterInputStatus_HaveData;
                return inBuf;
            }];
        if (st == AVAudioConverterOutputStatus_Error) break;

        const AudioBufferList *abl = outBuf.audioBufferList;
        BOOL multiPlane = NO;
        if (outBuf.frameLength > 0 && abl) {
            multiPlane = (abl->mNumberBuffers > 1);
            for (UInt32 i = 0; i < abl->mNumberBuffers; i++) {
                if (abl->mBuffers[i].mData && abl->mBuffers[i].mDataByteSize > 0) {
                    [out appendBytes:abl->mBuffers[i].mData length:abl->mBuffers[i].mDataByteSize];
                }
            }
        }
        // 非交错多声道是按 plane 拼接的，多轮拼会把 plane 交错 —— 那种格式只取第一轮。
        if (multiPlane) break;
        if (st != AVAudioConverterOutputStatus_HaveData) break;
    }
    if (out.length == 0) return nil;
    return out;
}

#pragma mark - Reader 构建（只在解码线程调用）

- (AVAssetReader * _Nullable)sl_buildReaderForKey:(NSString *)key generation:(NSUInteger)gen
                                         videoOut:(AVAssetReaderTrackOutput * _Nullable * _Nullable)outV
                                         audioOut:(AVAssetReaderTrackOutput * _Nullable * _Nullable)outA {
    if (outV) *outV = nil;
    if (outA) *outA = nil;
    // 0.3.60：构建期间一律用局部变量。
    // 以前这里直接把 output 写进 _videoOut / _audioOut，而那些写在 startReading
    // 之前 —— 只要有一代更旧的线程还在这个窗口里，它就会把新线程刚发布的值覆盖
    // 成一个「尚未 startReading」的 output，新线程拿去做 copyNextSampleBuffer
    // 立刻抛异常闪退。现在共享 ivar 只在「startReading 成功且代次仍是最新」的
    // 那一刻、在锁内一次性发布。
    AVAssetReaderTrackOutput *vNew = nil;
    AVAssetReaderTrackOutput *aNew = nil;
    AudioStreamBasicDescription aASBD;
    memset(&aASBD, 0, sizeof(aASBD));
    BOOL hasAudioNew = NO;
    // 0.3.58：换素材会 detach 新线程，旧线程在 buildReader 里还会再跑一段。
    // 以前它无条件 `[_reader cancelReading]` —— 正好把新线程刚 startReading 成功的
    // 那个 reader 取消掉，日志里就是「startReading 失败: 这项操作无法完成」，
    // 代价是换素材后 3~5 秒还是旧画面（13:08:18 失败，13:08:22 才恢复）。
    // 现在旧线程一进这个方法就掉头，绝不碰共享的 reader。
    [_lock lock];
    if (gen != _generation) {
        [_lock unlock];
        return nil;
    }
    // 只取消「自己这一代」的 reader。别人的由它自己的线程收拾。
    AVAssetReader *old = (_readerGen == gen) ? _reader : nil;
    if (old) _reader = nil;
    _videoOut = nil;
    _audioOut = nil;
    [_lock unlock];
    if (old) [old cancelReading];

    _idleRounds = 0;
    _playValid = NO;                     // 0.3.53：新 reader 的时间轴从新锚点算起
    [_lock lock];
    _audioTrackAttached = NO;
    // 0.3.53：重建 reader 后音频从新的位置重新解，池子里的旧内容和旧映射全部作废。
    // 不清会出事 —— 旧映射指向的是上一轮的素材时间，对齐时会把游标挪到错误位置。
    [_audioPCM setLength:0];
    _audioTSCount = 0;
    _audioJumpEpoch++;                   // 0.3.58：池子清空 = 内容断点，下一个包必须渐入
    _audioHeadPTS = NAN;                 // 0.3.54：新 reader 从新位置重新解
    for (int i = 0; i < _audioConsumerCount; i++) _audioConsumers[i].cursor = 0;
    [_lock unlock];

    NSString *path;
    [_lock lock];
    path = _sourcePath;
    [_lock unlock];
    if (!path.length) return nil;

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
        return nil;
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
            vNew = o;
        } else {
            // 目标格式解码器不认，退回 BGRA，交给 CoreImage 转
            NSDictionary *bg = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
            AVAssetReaderTrackOutput *o2 = [[AVAssetReaderTrackOutput alloc] initWithTrack:vt outputSettings:bg];
            o2.alwaysCopiesSampleData = NO;
            if ([reader canAddOutput:o2]) {
                [reader addOutput:o2];
                vNew = o2;
            }
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
                aNew = o;
                aASBD = src;
                hasAudioNew = YES;
            } else {
                // 音轨在，但解不成 float32 / 单声道。表现就是「有音轨却全程静音」，
                // 必须留一行，否则只能靠猜。
                SLVLog(@"feed 音轨解不成 PCM（编码不支持），这条素材只能静音");
            }
        }
    }

    CMTimeRange range = kCMTimeRangeInvalid;
    [_lock lock];
    if (_resumeValid && CMTIME_IS_VALID(_lastVideoPTS) && CMTIME_IS_NUMERIC(_lastVideoPTS)) {
        range = CMTimeRangeMake(_lastVideoPTS, kCMTimePositiveInfinity);
    }
    _resumeValid = NO;
    [_lock unlock];
    if (CMTIMERANGE_IS_VALID(range)) {
        reader.timeRange = range;
        SLVLog(@"feed 从 %@ 秒续播（补挂音轨后不跳回开头）",
              @((double)range.start.value / (double)range.start.timescale));
    }

    if (![reader startReading]) {
        SLVLog(@"feed startReading 失败: %@", reader.error.localizedDescription ?: @"?");
        return nil;
    }
    // startReading 这段可能又换了素材：这一代已经不是最新的，reader 直接作废，
    // 不挂到共享变量上 —— 否则下一轮会被别的线程 cancel 掉，白跑一趟还留一行错误。
    [_lock lock];
    BOOL stillCurrent = (gen == _generation);
    AVAssetReader *prev = nil;
    if (stillCurrent) {
        // 0.3.59：把上一代还挂在 ivar 上的 reader 摘下来，稍后 cancel。
        // sl_restart 现在会先把 _reader 置 nil，这里兜的是「同代换格式但
        // 上一代线程还没退完」的情况。不 cancel 它就一直读到片尾，
        // 两个 reader 同时读同一个文件时 startReading 也会互相顶。
        if (_reader && _reader != reader) prev = _reader;
        _reader = reader;
        _readerGen = gen;
        // 0.3.60：output / 音频格式到这里才发布 —— 此刻 reader 一定已经
        // startReading 成功，且代次仍是最新。晚一步发布的代价是零，
        // 但它杜绝了「快照到半成品 output」这条崩溃路径。
        _videoOut = vNew;
        _audioOut = aNew;
        if (hasAudioNew) {
            _audioSrcASBD = aASBD;
            _audioTrackAttached = YES;
        } else {
            _audioTrackAttached = NO;
        }
        if (outV) *outV = vNew;
        if (outA) *outA = aNew;
    }
    [_lock unlock];
    if (prev) [prev cancelReading];
    if (!stillCurrent) {
        [reader cancelReading];
        SLVLog(@"feed 重建完成时素材已换，丢弃这一代 reader（gen %lu）", (unsigned long)gen);
        return nil;
    }

    // 循环播放每轮都要重建 reader，每 11 秒刷一行会把日志淹掉。
    // 只在「首次 / 目标格式变了 / 每 20 轮」打一次 —— 真出问题时也还看得到心跳。
    static NSString *sLastLoggedKey = nil;
    static int sLoopRounds = 0;
    sLoopRounds++;
    BOOL keyChanged = ![sLastLoggedKey isEqualToString:key ?: @""];
    if (keyChanged || sLoopRounds % 20 == 0) {
        sLastLoggedKey = key ?: @"";
        // 0.3.17：把素材真实尺寸 / 解码格式也打出来。
        // 「素材尺寸 ≠ 宿主尺寸」是走不走零拷贝的唯一判据，而蓝屏只出现在非零拷贝那条路，
        // 所以这两个数必须能在日志里直接对上，不然只能靠猜。
        CGSize ns = CGSizeZero;
        [_lock lock];
        ns = _naturalSize;
        [_lock unlock];
        // 0.3.60：日志直接用本次构建的局部对象，不读 ivar —— 锁外读共享 ivar
        // 本身就是多余的风险（另一个线程可能正在改写）。
        OSType decPf = (OSType)[[vNew.outputSettings objectForKey:(id)kCVPixelBufferPixelFormatTypeKey] unsignedIntValue];
        SLVLog(@"feed 管线就绪 %@ (video=%@ audio=%@) · 素材 %.0fx%.0f %u%@",
              key ?: @"(nil)",
              vNew ? @"Y" : @"N", aNew ? @"Y" : @"N",
              ns.width, ns.height, (unsigned)decPf,
              keyChanged ? @"" : [NSString stringWithFormat:@" · 第 %d 轮", sLoopRounds]);
    }
    return reader;
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

/// 0.3.58：出帧路径计数（诊断）。
/// 直出 = 素材帧原样交出去（零拷贝）；渲染 = 过了一趟 CoreImage（缩放/旋转/镜像）。
- (void)videoPathCountsDirect:(NSUInteger *)direct render:(NSUInteger *)render {
    [_lock lock];
    if (direct) *direct = _videoDirectCount;
    if (render) *render = _videoRenderCount;
    [_lock unlock];
}

// 注入专用（0.3.8）：把宿主**自己的**真帧 buffer 交进来，返回一帧能直接交给宿主的画面。
//
// 为什么不再自己造 buffer —— 三轮日志把这个方向堵死了：
//   0.3.5 以为是 NV12 色度平面渲错 → 日志 pf=1111970369(BGRA)，宿主根本不要 YUV
//   0.3.6 以为是 Metal 版 CIContext 坏 → 改 CPU 渲染，中心像素 B=139 G=146 R=149，正常
//   0.3.7 以为是 bytesPerRow 不一致 → 日志三个跨度全是 4352，一模一样
// 子类型一样、尺寸一样、跨度一样，CMVideoFormatDescriptionMatchesImageBuffer 却仍然
// 判不匹配、画面也仍然是绿的 —— 那差别就只剩「buffer 是谁造的」。
// 真帧是摄像头采集出来的 IOSurface，我们 CVPixelBufferCreate 出来的是另一种内存排布，
// 宿主按自己的方式去读就串了色（绿）。
//
// 所以现在改成原地改写宿主的 buffer：指针、格式、IOSurface 属性全是宿主熟悉的那个，
// MatchesImageBuffer 天然为真，自建 fmt 那套兜底彻底用不上。
//
// 返回 +1 的 buffer（调用方负责 CFRelease）：
//   · 等于 host 的 retain 版 → 内容已改写，直接用
//   · 其它 buffer → 素材帧本身就是对的，零拷贝直出
//   · NULL → 这一帧放行真画面
- (CVPixelBufferRef)copyFrameForHostBuffer:(CVPixelBufferRef)host {
    if (!host) return NULL;
    size_t hw = CVPixelBufferGetWidth(host);
    size_t hh = CVPixelBufferGetHeight(host);
    if (hw < 1 || hh < 1) return NULL;
    OSType hpf = CVPixelBufferGetPixelFormatType(host);

    NSInteger rot = [self sl_normalizedRotation];
    BOOL mirror = self.mirrorEnabled;

    // 跟原来一样，把「宿主想要的格式」记下来，解码线程据此重建 reader。
    // 这一步不能省：视频只有按宿主格式解出来才能走下面的零拷贝直出，
    // 否则每帧都要 CPU 过一遍 CI 做格式转换，30fps 根本扛不住。
    // 0.3.12：key 里带上「正方形裁切」状态。拨开关时 key 一变，解码管线就会
    // 按新的缩放数学重建 —— 否则图片会一直用旧缓存，拨了开关看不到变化。
    NSString *key = [NSString stringWithFormat:@"%u:%zux%zu:q%d",
                     (unsigned)hpf, hw, hh,
                     (self.squareCropEnabled && SLVCamIsMomoProcess()) ? 1 : 0];
    CFAbsoluteTime nowKey = CFAbsoluteTimeGetCurrent();
    NSString *switchNote = nil;
    int keySwitches = 0;
    [_lock lock];
    BOOL hasFrame = (_latestVideo != NULL);
    BOOL changed = ![_pipelineKey isEqualToString:key];
    if (changed) {
        NSString *prevKey = _pipelineKey;
        BOOL accept = NO;
        if (!hasFrame) {
            // 手里一帧都没有：一般要立刻切（首帧必须尽快出画面）。
            //
            // 但刚切过 2 秒还没出帧，说明上一次重建正在解第一帧 —— 这时再切只会让
            // 重建永远跑不完。微信的 1080p / 720p 两路混在一个 hook 里就是这种情形：
            // 谁都没有帧，然后 key 每来一帧变一次。
            accept = (_pipelineKey == nil) || (nowKey - _lastKeySwitchAt > 2.0);
        } else if ([_pendingKey isEqualToString:key] &&
                   nowKey - _pendingKeyAt >= SLV_KEY_STABLE_SEC) {
            // 新格式连续稳定了这么久，认定是真切换（换分辨率 / 换会话）
            accept = YES;
        } else {
            // 刚冒出来还没站稳 —— 大概率是另一路采集混进来的（微信预览 720p /
            // 通话 1080p 交替）。先不切，继续用旧管线出帧：渲染那一步会把素材
            // 铺到宿主这一帧的尺寸上，尺寸变化并不需要换解码器。
            if (![_pendingKey isEqualToString:key]) {
                _pendingKey = key;
                _pendingKeyAt = nowKey;
            }
            changed = NO;
        }
        if (accept) {
            _pipelineKey = key;
            _pendingKey = nil;
            _reconfigRequested = YES;
            _keySwitchCount++;
            _lastKeySwitchAt = nowKey;
            keySwitches = _keySwitchCount;
            // 只在头几次和每 10 次打一行：这是判断「宿主是不是在反复重配采集」的证据
            if (keySwitches <= 5 || keySwitches % 10 == 0) {
                switchNote = [NSString stringWithFormat:@"视频: 管线切换 #%d → %@（原 %@）",
                              keySwitches, key, prevKey ?: @"(空)"];
            }
        }
    } else {
        _pendingKey = nil;
    }
    [_lock unlock];
    if (switchNote) SLVLog(@"%@", switchNote);

    // 目标格式真的变了、手里还没有任何帧：放行这一帧真画面，等解码线程按新格式重建
    if (changed && !hasFrame) return NULL;

    [_lock lock];
    BOOL isImage = _isImage;
    CVPixelBufferRef src = _latestVideo ? (CVPixelBufferRef)CVPixelBufferRetain(_latestVideo) : NULL;
    [_lock unlock];
    if (!src) return NULL;

    size_t sw = CVPixelBufferGetWidth(src);
    size_t sh = CVPixelBufferGetHeight(src);
    OSType spf = CVPixelBufferGetPixelFormatType(src);

    // 素材帧本来就跟宿主要的一模一样 → 零拷贝直出。
    // 视频不旋转不镜像走的就是这条，它一直正常，别为了「统一」把它拖慢。
    if (!isImage && !mirror && rot == 0 && sw == hw && sh == hh && spf == hpf) {
        _videoDirectCount++;             // 0.3.58：零拷贝，画质就是我们素材的原样
        return src;                      // 已 retain
    }

    if (!isImage) {
        // 视频开了旋转 / 镜像：直接写进宿主的 buffer，
        // 省掉「先渲到自建 buffer、再搬一趟」的整趟开销
        _videoRenderCount++;             // 0.3.58：这一帧要过 CI，耗时和质量都记在这里
        BOOL ok = [self sl_writeSource:src into:host mirror:mirror rotation:rot squareCrop:YES];
        CVPixelBufferRelease(src);
        return ok ? (CVPixelBufferRef)CVPixelBufferRetain(host) : NULL;
    }

    // ---- 图片 ----
    // 静态图不该每帧过 CI：按「宿主格式 / 尺寸 + 镜像 + 旋转」渲一次缓存起来，
    // 之后每帧只是一次 memcpy。1080x1920 的 BGRA 搬一次约 1~2ms，30fps 扛得住；
    // 每帧现场过 CI 是 20ms 起，那才会掉帧。
    if (!mirror && rot == 0 && spf == hpf && sw == hw && sh == hh) {
        BOOL ok = SLVBlitSameFormat(src, host);
        CVPixelBufferRelease(src);
        return ok ? (CVPixelBufferRef)CVPixelBufferRetain(host) : NULL;
    }

    NSString *hostKey = [NSString stringWithFormat:@"%u:%zux%zu:m%d:r%ld:q%d",
                         (unsigned)hpf, hw, hh, mirror ? 1 : 0, (long)rot,
                         (self.squareCropEnabled && SLVCamIsMomoProcess()) ? 1 : 0];
    CVPixelBufferRef cached = NULL;
    [_lock lock];
    if (_hostStill && [_hostStillKey isEqualToString:hostKey]) {
        cached = (CVPixelBufferRef)CVPixelBufferRetain(_hostStill);
    }
    [_lock unlock];

    if (!cached) {
        cached = [self sl_render:src toWidth:hw height:hh format:hpf mirror:mirror rotation:rot squareCrop:YES];
        if (!cached) { CVPixelBufferRelease(src); return NULL; }
        [_lock lock];
        if (_hostStill) CVPixelBufferRelease(_hostStill);
        _hostStill = (CVPixelBufferRef)CVPixelBufferRetain(cached);
        _hostStillKey = [hostKey copy];
        [_lock unlock];
    }
    CVPixelBufferRelease(src);

    BOOL ok = SLVBlitSameFormat(cached, host);
    CVPixelBufferRelease(cached);
    return ok ? (CVPixelBufferRef)CVPixelBufferRetain(host) : NULL;
}

/// 角度只认 0/90/180/270，其余一律当 0（脏数据不该让画面整个歪掉）
- (NSInteger)sl_normalizedRotation {
    NSInteger r = self.rotation % 360;
    if (r < 0) r += 360;
    if (r == 90 || r == 180 || r == 270) return r;
    return 0;
}

// 拍照专用出帧。跟 copyFrameForHostBuffer: 的区别只有一点：
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
                                  rotation:rot
                                squareCrop:NO];   // 拍照不走实拍时刻裁切
    CVPixelBufferRelease(pb);
    return out;
}

- (CVPixelBufferRef)sl_render:(CVPixelBufferRef)src
                      toWidth:(size_t)w
                       height:(size_t)h
                       format:(OSType)pf
                       mirror:(BOOL)mirror
                     rotation:(NSInteger)rotation
                   squareCrop:(BOOL)squareCrop {
    size_t sw = CVPixelBufferGetWidth(src);
    size_t sh = CVPixelBufferGetHeight(src);
    if (sw < 1 || sh < 1 || w < 1 || h < 1) return NULL;

    CIImage *img = [self sl_image:[CIImage imageWithCVPixelBuffer:src]
                          toWidth:w
                           height:h
                           mirror:mirror
                         rotation:rotation
                       squareCrop:squareCrop];
    if (!img) return NULL;

    // 0.3.5：先渲染成 BGRA，再按目标格式转。
    //
    // 原来直接把结果往 pf 上渲染。宿主要 420f/420v（NV12 双平面）时，
    // Metal 版 CIContext 写出来的色度平面是错的 —— 亮度进去了、色度没进去，
    // 解出来就是「白底 + 亮绿人形轮廓」。开镜像 / 旋转的视频和所有图片都中招，
    // 不旋转不镜像的视频走解码器直出，所以一直正常。
    //
    // BGRA 是 CI 最可靠的输出格式，转 NV12 交给 vImage（平面偏移和 stride 它自己算）。
    NSDictionary *attrs = SLVPixelBufferAttrs();
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

/// 当前进程是不是陌陌。设置页用它决定要不要显示「实拍时刻不放大」那一行。
BOOL SLVCamIsMomoProcess(void) {
    static BOOL momo = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        momo = [bid isEqualToString:@"com.immomo.momo"]              // 国内版
            || [bid isEqualToString:@"com.wemomo.momoappdemo1"];     // 海外 / 测试包
    });
    return momo;
}

/// 旋转 + 铺满裁切 + 镜像，全部在 CI 坐标系里做完，返回摆好姿势的图。
/// `sl_render:`（自己建 buffer）和 `renderIntoPixelBuffer:`（改写宿主 buffer）
/// 共用这一份数学 —— 两处各写一遍迟早会不一致。
///
/// `squareCrop` 只有「注入预览帧」这条路才传 YES。拍照**必须传 NO**：
/// 前置摄像头出的是 3024×4032 这种竖图，按正方形裁会把照片上下切掉一大块。
- (CIImage *)sl_image:(CIImage *)img
              toWidth:(size_t)w
               height:(size_t)h
               mirror:(BOOL)mirror
             rotation:(NSInteger)rotation
           squareCrop:(BOOL)squareCrop {
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

    // 0.3.12：陌陌的实拍时刻只看得见整帧中间那个正方形，按整帧铺满会让素材
    // 白放一遍再被它裁一遍。开关打开时把参考框收成正方形，只裁一刀 —— 方图正好
    // 1:1 落进去。只在「buffer 比正方形高」时收，横过来的 buffer 保持原样，
    // 免得把参考框撑到比 buffer 还高。
    CGFloat rw = (CGFloat)w;
    CGFloat rh = (CGFloat)h;
    if (squareCrop && self.squareCropEnabled && SLVCamIsMomoProcess()) {
        static BOOL loggedOnce = NO;
        if (!loggedOnce) {
            loggedOnce = YES;
            SLVLog(@"feed 陌陌实拍时刻：按中间正方形裁切，不放大");
        }
        if (rh > rw) rh = rw;
    }

    CGFloat s = MAX(rw / re.size.width, rh / re.size.height);
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

/// 把一帧素材写进**已经存在**的 dst（原地改写内容），尺寸 / 格式一律以 dst 为准。
///
/// `sl_render:` 是自己建 buffer 再返回，这个是往别人的 buffer 里画 —— 注入层必须走
/// 这条：宿主的 buffer 只能改内容，不能换指针（换了它就按自己的方式读，读出来是绿的）。
- (BOOL)sl_writeSource:(CVPixelBufferRef)src
                  into:(CVPixelBufferRef)dst
                mirror:(BOOL)mirror
              rotation:(NSInteger)rotation
            squareCrop:(BOOL)squareCrop {
    if (!src || !dst) return NO;
    size_t w = CVPixelBufferGetWidth(dst);
    size_t h = CVPixelBufferGetHeight(dst);
    if (w < 1 || h < 1) return NO;

    OSType dpf = CVPixelBufferGetPixelFormatType(dst);
    OSType spf = CVPixelBufferGetPixelFormatType(src);

    // 尺寸、格式都对、又不用转不用镜 → 纯搬字节，比过一遍 CI 快一个数量级
    if (rotation == 0 && !mirror && spf == dpf
        && CVPixelBufferGetWidth(src) == w && CVPixelBufferGetHeight(src) == h) {
        return SLVBlitSameFormat(src, dst);
    }

    CIImage *img = [self sl_image:[CIImage imageWithCVPixelBuffer:src]
                          toWidth:w
                           height:h
                           mirror:mirror
                         rotation:rotation
                       squareCrop:squareCrop];
    if (!img) return NO;

    // 0.3.13：素材盖不满整个框时，先用同一帧的模糊放大版把框铺满。
    //
    // 不铺会怎样：CI 只把 img 覆盖到的像素写进去，**其余像素保持原值** ——
    // 而 dst 是宿主的真帧，原值就是真实摄像头画面。实拍时刻开正方形裁切后，
    // 横屏素材上下各空 420px，录出来就是「中间素材、上下键盘和地毯」。
    // 铺一层模糊底既不露真摄像头，也比黑条自然。
    img = [self sl_blurBackdropForImage:img src:src width:w height:h];

    BOOL isNV12 = (dpf == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                   dpf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);

    if (!isNV12) {
        // BGRA（或其它单平面格式）：CI 直接写进 dst 就行
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        [_ciContext render:img
           toCVPixelBuffer:dst
                    bounds:CGRectMake(0, 0, (CGFloat)w, (CGFloat)h)
                colorSpace:cs];
        CGColorSpaceRelease(cs);
        return YES;
    }

    // NV12：CI 往双平面上写色度会错（白底 + 亮绿轮廓），先渲 BGRA 再让 vImage 写平面
    NSDictionary *attrs = SLVPixelBufferAttrs();
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

    // 0.3.17：首次（以及每次换尺寸 / 换格式）把「输入 · 期望 · 实际」三个数打出来。
    // 期望 ≈ 实际 说明转换是对的；差得远就是通道序或范围错了。
    // 只在变化时打，30fps 下不会刷屏。
    static NSString *sLastConvLog = nil;
    NSString *convKey = [NSString stringWithFormat:@"%zux%zu:%u", w, h, (unsigned)dpf];
    if (![sLastConvLog isEqualToString:convKey]) {
        sLastConvLog = [convKey copy];
        SLVLogCenterPixel(bgra, @"feed 转换前");
        SLVLogExpectYCbCr(bgra, dpf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, @"feed 期望");
        SLVLogNV12Center(dst, @"feed 转换后");
    }

    CVPixelBufferRelease(bgra);
    return ok;
}

/// 素材没盖满目标框时，补一层「同一帧的模糊放大版」当底。
///
/// 返回的图保证覆盖满 (0,0,w,h)：本来就盖满的原样返回，没盖满的叠一层模糊底。
///
/// 模糊在 **1/4 分辨率**上做 —— 模糊本来就不需要高分辨率，缩下去再放大回来肉眼
/// 分不出，成本却降到几分之一。1080×1920 直接 sigma=30 是 30fps 扛不住的。
- (CIImage *)sl_blurBackdropForImage:(CIImage *)img
                                 src:(CVPixelBufferRef)src
                               width:(size_t)w
                              height:(size_t)h {
    if (!img) return img;

    CGRect e = img.extent;
    BOOL covers = e.origin.x <= 0.5 && e.origin.y <= 0.5
               && e.size.width >= (CGFloat)w - 0.5
               && e.size.height >= (CGFloat)h - 0.5;
    if (covers) return img;   // 9:16 素材走这里，一次额外渲染都不做

    // 底图：同一帧按「铺满整帧」算一遍（squareCrop:NO），再裁到目标框。
    // 不旋转不镜像 —— 模糊完看不出方向，省一次变换。
    CIImage *base = [self sl_image:[CIImage imageWithCVPixelBuffer:src]
                           toWidth:w
                            height:h
                            mirror:NO
                          rotation:0
                        squareCrop:NO];
    if (!base) return img;
    base = [base imageByCroppingToRect:CGRectMake(0, 0, (CGFloat)w, (CGFloat)h)];

    CIImage *small = [base imageByApplyingTransform:CGAffineTransformMakeScale(0.25, 0.25)];
    small = [small imageByApplyingGaussianBlurWithSigma:8.0];   // ≈ 全尺寸 sigma 32
    CIImage *blurred = [[small imageByApplyingTransform:CGAffineTransformMakeScale(4.0, 4.0)]
                        imageByCroppingToRect:CGRectMake(0, 0, (CGFloat)w, (CGFloat)h)];

    return [img imageByCompositingOverImage:blurred];
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
    if (CVPixelBufferGetWidth(dst) < 1 || CVPixelBufferGetHeight(dst) < 1) return NO;

    [_lock lock];
    CVPixelBufferRef src = _latestVideo ? (CVPixelBufferRef)CVPixelBufferRetain(_latestVideo) : NULL;
    [_lock unlock];
    if (!src) return NO;

    // 用户设的旋转 + 拍照补偿角，归一成 0/90/180/270
    NSInteger rot = ([self sl_normalizedRotation] + extraRotation) % 360;
    if (rot < 0) rot += 360;
    if (rot != 90 && rot != 180 && rot != 270) rot = 0;

    BOOL ok = [self sl_writeSource:src into:dst mirror:self.mirrorEnabled rotation:rot squareCrop:NO];
    CVPixelBufferRelease(src);
    return ok;
}

#pragma mark - 音频时间轴（0.3.53）

/// 画面此刻显示的是素材第几秒。调用方必须已持有 _lock。NAN = 还不知道。
- (double)sl_videoPTSLocked {
    if (!CMTIME_IS_VALID(_lastVideoPTS) || !CMTIME_IS_NUMERIC(_lastVideoPTS)) return NAN;
    return CMTimeGetSeconds(_lastVideoPTS);
}

/// 池子里第 off 个字节对应素材第几秒。调用方必须已持有 _lock。NAN = 没有时间轴。
- (double)sl_ptsAtOffsetLocked:(NSUInteger)off {
    if (_audioTSCount <= 0 || _audioBytesPerSecond == 0) return NAN;
    SLVAudioTS m = _audioTS[0];
    for (int i = 0; i < _audioTSCount; i++) {
        if (_audioTS[i].off <= off) m = _audioTS[i];
        else break;
    }
    double t = m.pts + (double)(off > m.off ? off - m.off : 0) / (double)_audioBytesPerSecond;
    return t;
}

/// 素材第 pts 秒对应池子里的哪个字节偏移。调用方必须已持有 _lock。
/// 返回 -1 表示没有时间轴；超出池子范围会被夹到 [0, length]。
- (NSInteger)sl_offsetAtPTSLocked:(double)pts {
    if (_audioTSCount <= 0 || _audioBytesPerSecond == 0) return -1;
    SLVAudioTS m = _audioTS[0];
    BOOL found = NO;
    for (int i = 0; i < _audioTSCount; i++) {
        if (_audioTS[i].pts <= pts) { m = _audioTS[i]; found = YES; }
        else break;
    }
    if (!found) return 0;            // 目标比池子里最早的内容还早：从头开始
    double d = (pts - m.pts) * (double)_audioBytesPerSecond;
    if (d < 0) d = 0;
    NSUInteger off = m.off + (NSUInteger)d;
    if (off > _audioPCM.length) off = _audioPCM.length;
    return (NSInteger)off;
}

/// 从池子头部剪掉 cut 个字节。时间轴标记和所有消费者游标一起平移。
/// 调用方必须已持有 _lock。
- (void)sl_trimPoolLocked:(NSUInteger)cut {
    if (cut == 0 || cut > _audioPCM.length) return;
    [_audioPCM replaceBytesInRange:NSMakeRange(0, cut) withBytes:NULL length:0];

    int w = 0;
    SLVAudioTS head;
    BOOL hasHead = NO;
    for (int i = 0; i < _audioTSCount; i++) {
        SLVAudioTS m = _audioTS[i];
        if (m.off < cut) {
            // 落在被剪区域里：留最后一个当新的 0 点，插值才准
            head = m;
            hasHead = YES;
            continue;
        }
        m.off -= cut;
        _audioTS[w++] = m;
    }
    if (hasHead) {
        head.off = 0;
        if (w < SLV_AUDIO_TS_MAX) {
            memmove(&_audioTS[1], &_audioTS[0], (size_t)w * sizeof(SLVAudioTS));
            _audioTS[0] = head;
            w++;
        } else {
            _audioTS[0] = head;
        }
    }
    _audioTSCount = w;

    for (int i = 0; i < _audioConsumerCount; i++) {
        _audioConsumers[i].cursor = (_audioConsumers[i].cursor > cut)
                                  ? _audioConsumers[i].cursor - cut : 0;
    }
}

#pragma mark - 出音频

/// 登记宿主音频格式并建好转换器。调用方必须已持有 _lock。
/// **返回 YES 表示池子现在就是这种格式，可以往里取数据**。
/// 返回 NO = 拒绝切换（迟滞期内来了另一种格式），调用方这一包必须放行。
- (BOOL)sl_configureAudioLocked:(const AudioStreamBasicDescription *)asbd {
    if (!asbd || asbd->mBytesPerFrame == 0 || asbd->mSampleRate == 0) return NO;
    if (_hasAudioDstASBD && SLVASBDSame(asbd, &_audioDstASBD)) return YES;

    // 迟滞：刚定型不久，而且此刻还有人正在按旧格式读 —— 不跟着翻。
    // 翻了就要清池子，两套格式来回翻的结果是两边都拿不到数据。
    if (_hasAudioDstASBD) {
        [self sl_pruneConsumersLocked];
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (_audioConsumerCount > 0 && (now - _audioFormatAt) < SLV_AUDIO_FORMAT_STABLE) {
            return NO;
        }
    }

    // 0.3.56：格式一变，池子必须**当场**清空，不能等解码线程下一轮重建。
    //
    // 池子里的字节是按旧格式排的，而 _audioBytesPerSecond 这一行一改，读端立刻
    // 按新标尺去算偏移。0.3.55 的日志里就有这么一段：11:47:21 目标 1ch/2B，
    // 11:47:41 突然变成 2ch/4B（AudioUnit 那条链接管了），池子里还是 1ch 的字节。
    // 按 2ch 读等于把「相邻两个单声道样本」当成左右声道 —— 对端听到的是严重失真，
    // 用户的话就是「很大的杂音」。而真正的清池要等解码线程处理 _reconfigRequested，
    // 中间这几百毫秒是纯粹的垃圾数据。
    //
    // 现在改标尺和清池是同一个原子的动作：格式换了就当作「这段音频作废」，
    // 接下来宁可给这一小段静音，也不给错位的字节。
    BOOL hadPool = (_audioPCM.length > 0 || _audioTSCount > 0);
    if (hadPool) {
        [_audioPCM setLength:0];
        _audioTSCount = 0;
        _audioJumpEpoch++;               // 0.3.58：换格式清池，字节标尺都变了
        _audioHeadPTS = NAN;
        for (int i = 0; i < _audioConsumerCount; i++) {
            _audioConsumers[i].cursor = 0;
            _audioConsumers[i].hasLast = NO;      // 新格式的第一个样本没有可比对象
            _audioConsumers[i].gain = 1.0f;
        }
        _audioFormatJumps++;
        SLVLog(@"音频: 目标格式切换 #%lu → %.0fHz %uch %uB/帧（池已清空：旧格式字节不能按新标尺读）",
              (unsigned long)_audioFormatJumps, asbd->mSampleRate,
              (unsigned)asbd->mChannelsPerFrame, (unsigned)asbd->mBytesPerFrame);
    }
    _audioFormatAt = CFAbsoluteTimeGetCurrent();   // 迟滞的起点（首次登记也算）

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
    BOOL needConvert = !(asbd->mFormatFlags & kAudioFormatFlagIsFloat)                    || !(asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved)
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
    // 让解码线程把音频轨挂上。
    //
    // 视频通话就是这个顺序：宿主先建好采集会话、我们先把 reader 建出来（那时
    // 还不知道宿主音频格式，音轨挂不上），三秒后 AudioUnitRender 才第一次被调、
    // 格式才登记进来。之前这里只是把 _reconfigRequested 置上，但缺音轨这件事
    // 在日志里没有任何痕迹，只看得到「管线就绪 (video=Y audio=N)」和满屏静音。
    _reconfigRequested = YES;
    if (!_audioTrackAttached) {
        // 重建要从当前帧接着播，否则画面会跳回素材开头。
        _resumeValid = CMTIME_IS_VALID(_lastVideoPTS) && CMTIME_IS_NUMERIC(_lastVideoPTS);
        SLVLog(@"音频: 当前管线没有音轨（宿主格式登记晚了），重建 reader 挂上音轨%@",
              _resumeValid ? @"，画面从当前帧续播" : @"");
    }
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

/// 找到（或新建）某个消费者的游标槽。调用方必须已持有 _lock。
///
/// 新建时起点对齐「画面此刻的素材时刻」（见下面的 0.3.55 说明）。
- (int)sl_consumerSlotLocked:(const void * _Nullable)key {
    [self sl_pruneConsumersLocked];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    for (int i = 0; i < _audioConsumerCount; i++) {
        if (_audioConsumers[i].key == key) {
            _audioConsumers[i].lastCall = now;
            return i;
        }
    }

    // 0.3.55：新消费者的起点直接用「画面此刻的时刻」。
    //
    // 以前起点取「其它消费者游标的最大值」，一个都没有就取 0 —— 也就是池子里最老
    // 的那一块。于是每次 AudioUnit 换代，对端都会先听到 0.25~0.5 秒旧位置的声音，
    // 等到下一次对齐检查（每 0.25 秒才做一次）才被拽回画面。0.3.54 日志里那六次
    // 「音画对齐 音频 0.00s / 画面 4.37s → 挪 -4367ms」全是这一条造成的。
    NSUInteger start = 0;
    BOOL startResolved = NO;
    double vpts = [self sl_videoPTSLocked];

    // 生产端落在画面后面 2.5 秒以上：解码真跟不上了（不是「没人拉」——0.3.57 起
    // 没人拉也照解）。这时候让解码线程重建 reader、直接从画面时刻接上，不要一包
    // 一包追 —— 追 5 秒音频要几十轮，那几十轮里新消费者听到的全是静音。
    if (!isnan(vpts) && !isnan(_audioHeadPTS) && (vpts - _audioHeadPTS) > 2.5) {
        _resumeValid = CMTIME_IS_VALID(_lastVideoPTS) && CMTIME_IS_NUMERIC(_lastVideoPTS);
        _reconfigRequested = YES;
    }

    if (!isnan(vpts) && _audioTSCount > 0) {
        NSInteger at = [self sl_offsetAtPTSLocked:vpts];
        if (at >= 0 && (NSUInteger)at <= _audioPCM.length) {
            start = (NSUInteger)at;
            startResolved = YES;
        }
    }
    if (!startResolved) {
        for (int i = 0; i < _audioConsumerCount; i++) {
            if (_audioConsumers[i].cursor > start) start = _audioConsumers[i].cursor;
        }
    }
    if (start > _audioPCM.length) start = _audioPCM.length;

    int slot;
    if (_audioConsumerCount < SLV_AUDIO_CONSUMERS) {
        slot = _audioConsumerCount++;
    } else {
        // 槽满了：抢最落后的那个（它已经跟不上，换人更划算）
        slot = 0;
        for (int i = 1; i < _audioConsumerCount; i++) {
            if (_audioConsumers[i].cursor < _audioConsumers[slot].cursor) slot = i;
        }
    }
    _audioConsumers[slot].key = key;
    _audioConsumers[slot].cursor = start;
    _audioConsumers[slot].lastCall = now;
    _audioConsumers[slot].lastSync = 0;   // 0.3.53：新消费者第一次调用就做一次音画对齐
    // 0.3.56：新消费者是从池子中间起读的，第一个样本和「上一包」没有关系 ——
    // 不能拿别人留下的 lastVal 去比，否则第一包就被淡入成一小段渐强。
    // 0.3.57：gain 置 0 表示「增益还没定过」，SLVPolishChunk 会直接用这一包的
    // 理想增益，免得新 unit 接上前 100ms 顶着满幅音乐出声。
    _audioConsumers[slot].hasLast = NO;
    _audioConsumers[slot].gain = 0.0f;
    _audioConsumers[slot].lastVal[0] = 0;
    _audioConsumers[slot].lastVal[1] = 0;
    _audioConsumers[slot].splices = 0;
    _audioConsumers[slot].limits = 0;
    return slot;
}

/// 实时线程用：把「宿主换了一种格式」这件事丢给后台去登记，自己立刻返回。
///
/// 不能在音频线程上建 AVAudioConverter（几十毫秒），那会把宿主的录音回调卡住。
/// 这里只做一件事：保证同一时间只有一件登记活在路上，避免格式来回变时堆一队。
- (void)sl_primeAsyncLocked:(const AudioStreamBasicDescription *)asbd {
    if (!asbd || _primePending) return;
    _primePending = YES;
    AudioStreamBasicDescription copy = *asbd;
    NSLock *lk = _lock;
    SLVCamFeed *me = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [me primeAudioFormat:&copy];
        [lk lock];
        me->_primePending = NO;
        [lk unlock];
    });
}

/// 取一包 PCM。调用方必须已持有 _lock。
/// consumer：谁在取（AudioUnit 指针；NULL = AVCapture / AudioQueue 那条链）。
- (NSData *)sl_audioLocked:(const AudioStreamBasicDescription *)asbd numBytes:(size_t)numBytes
                configure:(BOOL)configure consumer:(const void * _Nullable)consumer {
    if (!asbd || asbd->mBytesPerFrame == 0 || numBytes == 0) return nil;

    // 关掉「替换音频」= 静音。这里必须返回全零的 PCM，不能返回 nil：
    // 返回 nil 会让注入层放行真实麦克风，把环境声原样录进去。
    // 走这条分支也就不需要素材有音轨，无声视频同样能静音。
    if (!self.audioReplaceEnabled) {
        return [NSMutableData dataWithLength:numBytes];
    }

    if (configure) {
        if (![self sl_configureAudioLocked:asbd]) {
            // 0.3.56：迟滞期内的「另一种格式」。这包放行真麦克风，池子保持原样——
            // 跟着翻会把正在按旧格式读的那条链一起打断，两边都没声音。
            return nil;
        }
    } else if (!_hasAudioDstASBD) {        // 实时线程不建转换器 —— 那是几十毫秒的活，让 primeAudioFormat: 去做。
        // 但这条路以前是静默返回 nil 的，而 nil 在三条注入链路里都等于
        // 「放行真麦克风」。所以「录制时音频没被替换」在日志上完全看不见，
        // 现在第一次撞上就留一行痕。
        if (!_audioPassLogged) {
            _audioPassLogged = YES;
            SLVLog(@"音频: 放行真麦克风 —— 目标格式还没配置（素材 %.0fHz %uch，宿主未登记）",
                  asbd->mSampleRate, (unsigned)asbd->mChannelsPerFrame);
        }
        return nil;
    } else if (!SLVASBDSame(asbd, &_audioDstASBD)) {
        // 0.3.56：实时线程要求一种「池子不是这个布局」的格式。
        //
        // 池子只能按一种标尺读 —— 按别的格式去 memcpy，拿到的就是错位的字节，
        // 对端听到的是噪声而不是声音。这时候唯一正确的做法是放行这一包（宿主
        // 拿到真麦克风），同时把新格式丢到后台登记；下一包起池子就是对的。
        // AudioQueue（16k/1ch）和 AudioUnit（48k/2ch）同时活着时走的就是这里。
        [self sl_primeAsyncLocked:asbd];
        if (!_audioMismatchLogged) {
            _audioMismatchLogged = YES;
            SLVLog(@"音频: 格式不一致 —— 宿主这次要 %.0fHz %uch %uB/帧，池子是 %.0fHz %uch %uB/帧（这一包放行，格式已丢到后台重配）",
                  asbd->mSampleRate, (unsigned)asbd->mChannelsPerFrame, (unsigned)asbd->mBytesPerFrame,
                  _audioDstASBD.mSampleRate, (unsigned)_audioDstASBD.mChannelsPerFrame,
                  (unsigned)_audioDstASBD.mBytesPerFrame);
        }
        return nil;
    }

    NSMutableData *chunk = [NSMutableData dataWithLength:numBytes];
    NSUInteger got = 0;

    int slot = [self sl_consumerSlotLocked:consumer];
    // consumer == NULL 就是 AVCapture 那条链在拿数据（见 audioForFormat:numBytes:）
    if (consumer == NULL) SLVMarkExternalAudio();
    NSUInteger *cursor = &_audioConsumers[slot].cursor;
    if (*cursor > _audioPCM.length) *cursor = _audioPCM.length;

    // 0.3.53：音画对齐。
    //
    // 音频是顺序读的，视频是「最新一帧」，两者没有共同基准 —— 池子每被剪一次，
    // 音频内容就整体挪一段，画面却不动。这里用池子里记的 PTS 直接比一下
    //「游标读到第几秒」和「画面显示第几秒」，差超过阈值就把游标挪过去。
    //
    // 只做「跳」，不做慢慢追：稳态两边的速率本来就一致（都跟硬件时钟走），
    // 需要跳的场合全是重建 / 切换这类台阶，一次跳完最干净。
    CFAbsoluteTime syncNow = CFAbsoluteTimeGetCurrent();
    if (_audioConsumers[slot].lastSync == 0 ||
        syncNow - _audioConsumers[slot].lastSync >= SLV_AUDIO_SYNC_CHECK) {
        _audioConsumers[slot].lastSync = syncNow;
        double vpts = [self sl_videoPTSLocked];
        double apts = [self sl_ptsAtOffsetLocked:*cursor];
        if (!isnan(vpts) && !isnan(apts)) {
            double drift = apts - vpts;       // >0：音频跑在画面前面
            if (fabs(drift) > SLV_AUDIO_SYNC_TOL) {
                NSInteger want = [self sl_offsetAtPTSLocked:vpts];
                // 0.3.54：只有「目标位置确实有数据」才挪。
                //
                // 以前是无条件挪，而 offsetAtPTS 会把超出池子的目标夹到池尾 ——
                // 于是「画面 14 秒、音频只解到 8 秒」时，游标被扔到池尾，池子里
                // 那一小段有效数据白丢，接着就是「池 0ms」+ 一整段静音。现在数据
                // 不到位就不动游标，交给生产端按 PTS 补齐（见 sl_audioNeedMoreLocked），
                // 下一轮再看。
                if (want >= 0 && (NSUInteger)want + numBytes <= _audioPCM.length &&
                    (NSUInteger)want <= _audioPCM.length) {
                    *cursor = (NSUInteger)want;
                    _audioSyncJumps++;
                    _audioJumpEpoch++;   // 0.3.58：游标被挪走了，波形在这里不连续
                    if (syncNow - _audioSyncLogAt > 1.0) {
                        _audioSyncLogAt = syncNow;
                        SLVLogRT(@"音频: 音画对齐 音频 %.2fs / 画面 %.2fs → 挪 %+.0fms（累计 %lu 次）",
                                 apts, vpts, drift * 1000.0, (unsigned long)_audioSyncJumps);
                    }
                } else if (syncNow - _audioSyncLogAt > 3.0) {
                    _audioSyncLogAt = syncNow;
                    SLVLogRT(@"音频: 音画偏差 %.0fms 但数据还没解到（音频 %.2fs / 画面 %.2fs · 池 %lums），等生产端补齐",
                             drift * 1000.0, apts, vpts,
                             (unsigned long)(_audioBytesPerSecond
                                             ? (_audioPCM.length - *cursor) * 1000 / _audioBytesPerSecond : 0));
                }
            }
        }
    }

    NSUInteger avail = _audioPCM.length - *cursor;

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
            *cursor += drop;
            avail -= drop;
            _audioDropped += drop;
            _audioHardCuts++;
            _audioJumpEpoch++;          // 0.3.58：池子被切掉一段，下一个包必须渐入
            // 0.3.56 这里是一次性标志：第一次打过就永远静默，于是池子后面又切了
            // 多少次日志上都看不见。改成 2 秒限流 + 累计次数，切几次一目了然。
            // 这一行在音频实时线程上，必须走 SLVLogRT（只入队，不 NSLog）。
            CFAbsoluteTime cutNow = CFAbsoluteTimeGetCurrent();
            if (cutNow - _audioDropLogAt > 2.0) {
                _audioDropLogAt = cutNow;
                SLVLogRT(@"音频: 缓冲 %lums 严重偏高，硬切 %lu 字节回 %lums（累计 %lu 次）",
                         (unsigned long)((avail + drop) * 1000 / _audioBytesPerSecond),
                         (unsigned long)drop,
                         (unsigned long)(target * 1000 / _audioBytesPerSecond),
                         (unsigned long)_audioHardCuts);
            }
        }
    }

    if (avail > 0) {
        got = MIN(avail, numBytes);
        memcpy(chunk.mutableBytes, (uint8_t *)_audioPCM.bytes + *cursor, got);
        *cursor += got;

        // 池子按「最落后的那个消费者」剪前缀 —— 用最靠前的会把别人还没读的数据一起删掉。
        //
        // 0.3.53：只剪足够久远的历史（留 0.3 秒给时间轴插值用）。以前是攒到 2 秒
        // 才剪一刀，并且剪完把别人的游标一起减掉，逻辑上没错，但和「无人消费就砍到
        // 120ms」那条组合起来，就成了「内容整段前移」的跳变源。现在两边都只剪
        // 已经播过的部分，游标由 sl_trimPoolLocked 一并平移。
        NSUInteger minCursor = *cursor;
        for (int i = 0; i < _audioConsumerCount; i++) {
            if (_audioConsumers[i].cursor < minCursor) minCursor = _audioConsumers[i].cursor;
        }
        NSUInteger keepBack = _audioBytesPerSecond ? (NSUInteger)(_audioBytesPerSecond * 0.3) : 13230;
        if (minCursor > keepBack) {
            [self sl_trimPoolLocked:minCursor - keepBack];
        }
    }

    // 心跳：每 500 包（约 10 秒）打一次水位。
    //
    // 0.3.56 是 3000 包 = 60 秒，而实际通话常常只有 20~40 秒，加上新加的
    // 「接缝/限幅」两个指标，等于这一版全程没自证过一次。降到 500 包。
    _audioCalls++;
    if (_audioCalls % 500 == 0 && _audioBytesPerSecond > 0) {
        NSUInteger mine = _audioPCM.length - *cursor;
        double vpts = [self sl_videoPTSLocked];
        double apts = [self sl_ptsAtOffsetLocked:*cursor];
        double driftMs = (isnan(vpts) || isnan(apts)) ? 0.0 : (apts - vpts) * 1000.0;
        // 生产端位置：>0 表示已经解到画面之后（正常，领先一个水位），
        // 明显 <0 表示解不过来（解码跟不上），这时才会出现持续的口型错位。
        double prodMs = (isnan(vpts) || isnan(_audioHeadPTS)) ? 0.0 : (_audioHeadPTS - vpts) * 1000.0;
        // 0.3.52：这是音频实时线程（AudioUnitRender 里调进来的），走 RT 版
        // 0.3.57：把响度规整的增益也打出来 —— 「增益 -13dB」说明素材原本是满幅，
        // 「增益 0dB」说明素材已经落在语音域。这是判断送话音量对不对最直接的一个数。
        float g = _audioConsumers[slot].gain;
        double gainDb = (g > 1e-4f) ? 20.0 * log10((double)g) : 0.0;
        SLVLogRT(@"音频: 水位 %lums · 丢 %lu 字节 · 第 %lu 包 · 消费者 %d 个 · 音画偏差 %+.0fms · 生产 %+.0fms · 增益 %+.1fdB · 对齐 %lu 次 · 跳帧 %lu · 硬切 %lu · 接缝 %lu · 限幅 %lu",
                (unsigned long)(mine * 1000 / _audioBytesPerSecond),
                (unsigned long)_audioDropped, (unsigned long)_audioCalls, _audioConsumerCount,
                driftMs, prodMs, gainDb, (unsigned long)_audioSyncJumps,
                (unsigned long)_audioSkipBlocks, (unsigned long)_audioHardCuts,
                (unsigned long)_audioSplices, (unsigned long)_audioLimits);
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

    // 0.3.56：接缝淡入 + 峰值限幅。
    //
    // 放在最后一步、对**这一包副本**做，池子里的数据保持原样 —— 下一个消费者
    // 读同一段内容时看到的还是原始波形，只是各自在自己那一段的接缝处补了斜坡。
    // 0.3.58：这一包是不是紧接一次「位置真的跳了」。
    // 首次取包（hasLast=NO）也算 —— 那时候要从静音渐入，不能直接怼上去。
    BOOL jumped = (_audioConsumers[slot].seenEpoch != _audioJumpEpoch) || !_audioConsumers[slot].hasLast;
    _audioConsumers[slot].seenEpoch = _audioJumpEpoch;

    NSUInteger polished = SLVPolishChunk((uint8_t *)chunk.mutableBytes, numBytes, asbd,
                                         _audioConsumers[slot].lastVal,
                                         &_audioConsumers[slot].hasLast,
                                         &_audioConsumers[slot].gain,
                                         jumped);
    if (polished & 1) {
        _audioConsumers[slot].splices++;
        _audioSplices++;
    }
    if (polished & 2) {
        _audioConsumers[slot].limits++;
        _audioLimits++;
    }
    return chunk;
}

/// 某个消费者此刻是否真的在拉数据（1 秒内来过）；key = NULL 表示 AVCapture / AudioQueue 那条链。
///
/// 用来替代「曾经见过 AVCapture 音频」这种一票否决的标志 —— 那个标志一旦置上就
/// 永不清除，于是「先录了一段视频消息、再打视频通话」时，AudioUnit 链路整场都在
/// 让路，而通话里根本没有 AVCapture 音频在跑，结果谁也不注入。
- (BOOL)audioConsumerActive:(const void * _Nullable)key {
    [_lock lock];
    [self sl_pruneConsumersLocked];
    BOOL found = NO;
    for (int i = 0; i < _audioConsumerCount; i++) {
        if (_audioConsumers[i].key == key) { found = YES; break; }
    }
    [_lock unlock];
    return found;
}

/// 宿主是否正走 AVCapture / AudioQueue 那条音频链（1 秒内来过数据）。
/// 实时音频线程专用：不加锁、不分配内存。
- (BOOL)externalAudioActive {
    return SLVExternalAudioActiveNow();
}

/// 一行状态串，给注入层打「静音」时带上现场。
/// 实时音频线程调用，拿不到锁就返回占位符，绝不阻塞宿主。
- (NSString *)audioDiag {
    if (![_lock tryLock]) return @"诊断锁忙";
    [self sl_pruneConsumersLocked];
    NSUInteger buffered = [self sl_bufferedLocked];
    NSUInteger ms = _audioBytesPerSecond ? (buffered * 1000 / _audioBytesPerSecond) : 0;
    // 0.3.53：带上音画偏差。这是判断「同步有没有跑掉」最直接的一个数。
    //
    // 0.3.54：偏差必须按「播放位置」算 —— 也就是最靠前的那个消费者游标。
    // 以前这里拿的是池尾，而池尾天然比播放位置领先一个水位（100~200ms），
    // 稳态下就会被读成「音频超前 150ms」，其实根本没超。口径不一致比没数据更糟。
    NSUInteger play = 0;
    BOOL hasPlay = NO;
    for (int i = 0; i < _audioConsumerCount; i++) {
        if (!hasPlay || _audioConsumers[i].cursor > play) { play = _audioConsumers[i].cursor; hasPlay = YES; }
    }
    double vpts = [self sl_videoPTSLocked];
    double apts = [self sl_ptsAtOffsetLocked:(hasPlay ? play : _audioPCM.length)];
    NSString *drift = (isnan(vpts) || isnan(apts))
        ? @"播放偏差 -"
        : [NSString stringWithFormat:@"播放偏差 %+.0fms", (apts - vpts) * 1000.0];
    NSString *s = [NSString stringWithFormat:@"池 %lums · 消费者 %d · 音轨 %@ · 素材音轨 %@ · %@",
                   (unsigned long)ms, _audioConsumerCount,
                   _audioTrackAttached ? @"已挂" : @"未挂",
                   _assetHasAudio ? @"有" : @"无", drift];
    [_lock unlock];
    return s;
}

- (NSData *)audioForFormat:(const AudioStreamBasicDescription *)asbd numBytes:(size_t)numBytes {
    return [self audioForFormat:asbd numBytes:numBytes consumer:NULL];
}

- (NSData *)audioForFormat:(const AudioStreamBasicDescription *)asbd numBytes:(size_t)numBytes
                  consumer:(const void * _Nullable)consumer {
    [_lock lock];
    NSData *d = [self sl_audioLocked:asbd numBytes:numBytes configure:YES consumer:consumer];
    [_lock unlock];
    return d;
}

- (NSData *)tryAudioForFormat:(const AudioStreamBasicDescription *)asbd numBytes:(size_t)numBytes {
    return [self tryAudioForFormat:asbd numBytes:numBytes consumer:NULL];
}

- (NSData *)tryAudioForFormat:(const AudioStreamBasicDescription *)asbd numBytes:(size_t)numBytes
                     consumer:(const void * _Nullable)consumer {
    // 实时音频线程专用：拿不到锁就放行这一包真麦克风，绝不阻塞宿主。
    // 锁只在解码线程 append 那一瞬间被持有，正常几乎不会撞上；
    // 一旦撞上，说明解码线程正在干重活，这时候卡住宿主才是灾难。
    if (![_lock tryLock]) return nil;
    NSData *d = [self sl_audioLocked:asbd numBytes:numBytes configure:NO consumer:consumer];
    [_lock unlock];
    return d;
}

#pragma mark - AVAudioEngine tap（0.3.56）

- (BOOL)fillTapBuffer:(AVAudioPCMBuffer *)buf consumer:(const void * _Nullable)consumer {
    if (!buf || buf.frameLength == 0) return NO;
    const AudioStreamBasicDescription *sd = buf.format.streamDescription;
    if (!sd || sd->mBytesPerFrame == 0 || sd->mSampleRate == 0) return NO;

    AudioBufferList *abl = buf.mutableAudioBufferList;
    if (!abl) return NO;

    AudioStreamBasicDescription a = *sd;
    UInt32 planes = abl->mNumberBuffers;
    if (planes == 0) return NO;
    size_t bps = a.mBitsPerChannel / 8;
    if (bps == 0) return NO;

    if (a.mFormatFlags & kAudioFormatFlagIsNonInterleaved) {
        // 每个 plane 一条声道。素材是单声道，直接铺到所有 plane 上：
        //   ① 交给池子的标尺必须是「1 声道」的字节率，否则游标会按 2 倍速走；
        //   ② 铺同一份数据不会有左右声道相位差，比拆包安全得多。
        a.mChannelsPerFrame = 1;
        a.mBytesPerFrame = (UInt32)bps;
        a.mBytesPerPacket = (UInt32)bps;
        size_t n = (size_t)buf.frameLength * bps;
        NSData *pcm = [self tryAudioForFormat:&a numBytes:n consumer:consumer];
        if (pcm.length != n) return NO;
        for (UInt32 i = 0; i < planes; i++) {
            AudioBuffer *b = &abl->mBuffers[i];
            if (b->mData && b->mDataByteSize >= n) memcpy(b->mData, pcm.bytes, n);
        }
        return YES;
    }

    AudioBuffer *b0 = &abl->mBuffers[0];
    if (!b0->mData) return NO;
    size_t n = (size_t)buf.frameLength * a.mBytesPerFrame;
    if (b0->mDataByteSize < n) n = b0->mDataByteSize;
    if (n == 0) return NO;
    NSData *pcm = [self tryAudioForFormat:&a numBytes:n consumer:consumer];
    if (pcm.length != n) return NO;
    memcpy(b0->mData, pcm.bytes, n);
    return YES;
}

@end
