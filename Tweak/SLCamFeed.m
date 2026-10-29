//
//  SLCamFeed.m
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
#import <unistd.h>

@interface SLCamFeed () {
    NSLock *_lock;

    // ---- 跨线程共享（受 _lock 保护）----
    CVPixelBufferRef _latestVideo;
    NSString *_pipelineKey;              // "875704422:1920x1080"，变了就要重建 reader
    BOOL _reconfigRequested;
    NSMutableData *_audioPCM;
    NSUInteger _audioReadCursor;
    AudioStreamBasicDescription _audioDstASBD;
    BOOL _hasAudioDstASBD;
    AVAudioConverter *_audioConverter;
    NSUInteger _audioBytesPerSecond;
    CGSize _naturalSize;

    // ---- 解码线程独占 ----
    AVAssetReader *_reader;
    AVAssetReaderTrackOutput *_videoOut;
    AVAssetReaderTrackOutput *_audioOut;
    AudioStreamBasicDescription _audioSrcASBD;
    double _frameInterval;               // 秒/帧，按素材自身帧率算，用来给解码线程节流
    int _idleRounds;                     // 连续空转次数，用来区分「读完了」和「音频池满了」

    CIContext *_ciContext;
    NSUInteger _generation;
    BOOL _running;
}

- (void)sl_restart;
- (void)sl_decodeLoopWithGeneration:(NSUInteger)gen;
- (void)sl_buildReaderForKey:(NSString *)key;
- (BOOL)sl_pumpAudio;
- (NSData *)sl_convertAudio:(NSData *)input;
- (NSInteger)sl_normalizedRotation;
- (CVPixelBufferRef)sl_render:(CVPixelBufferRef)src
                      toWidth:(size_t)w
                       height:(size_t)h
                       format:(OSType)pf
                       mirror:(BOOL)mirror
                     rotation:(NSInteger)rotation CF_RETURNS_RETAINED;

@end

@implementation SLCamFeed

+ (instancetype)shared {
    static SLCamFeed *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[SLCamFeed alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSLock new];
        _audioPCM = [NSMutableData data];
        _ciContext = [CIContext contextWithOptions:nil];
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
    [_lock unlock];
    [self sl_restart];
    SLLog(@"feed source -> %@", p.lastPathComponent ?: @"(nil)");
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
    [_lock lock];
    gen = ++_generation;
    _reconfigRequested = YES;
    _pipelineKey = nil;
    if (_latestVideo) { CVPixelBufferRelease(_latestVideo); _latestVideo = NULL; }
    [_audioPCM setLength:0];
    _audioReadCursor = 0;
    _running = (_sourcePath.length > 0);
    BOOL run = _running;
    [_lock unlock];

    if (run) {
        [NSThread detachNewThreadWithBlock:^{
            [self sl_decodeLoopWithGeneration:gen];
        }];
    }
}

- (void)rewind {
    [self sl_restart];
}

#pragma mark - 解码线程

- (void)sl_decodeLoopWithGeneration:(NSUInteger)gen {
    @autoreleasepool {
        [NSThread currentThread].name = @"slcam.decode";
        [NSThread currentThread].qualityOfService = NSQualityOfServiceUserInitiated;
    }

    while (YES) {
        @autoreleasepool {
            [_lock lock];
            BOOL alive = (gen == _generation) && _running;
            BOOL reconfig = _reconfigRequested;
            _reconfigRequested = NO;
            NSString *key = _pipelineKey;
            BOOL loop = _loopEnabled;
            [_lock unlock];
            if (!alive) break;

            if (reconfig || !_reader) {
                [self sl_buildReaderForKey:key];
                if (!_reader) { usleep(30 * 1000); continue; }
            }

            BOOL gotAny = NO;

            if (_videoOut) {
                CMSampleBufferRef sb = [_videoOut copyNextSampleBuffer];
                if (sb) {
                    gotAny = YES;
                    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
                    if (pb) {
                        CVPixelBufferRetain(pb);
                        [_lock lock];
                        CVPixelBufferRef old = _latestVideo;
                        _latestVideo = pb;
                        [_lock unlock];
                        if (old) CVPixelBufferRelease(old);
                    }
                    CFRelease(sb);
                    // 按素材自身帧率节流：不节流会全速解码，画面变成快进
                    if (_frameInterval > 0) {
                        usleep((useconds_t)(_frameInterval * 1000000.0));
                    }
                }
            }

            if (_audioOut && [self sl_pumpAudio]) gotAny = YES;

            if (gotAny) {
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
                    [self sl_buildReaderForKey:key];
                    if (!_reader) usleep(50 * 1000);
                } else {
                    usleep(120 * 1000);
                }
            }
        }
    }
}

/// 解码线程内调用：音频池不够 2 秒才继续解
- (BOOL)sl_pumpAudio {
    [_lock lock];
    NSUInteger buffered = _audioPCM.length - _audioReadCursor;
    NSUInteger limit = _audioBytesPerSecond * 2;
    [_lock unlock];
    if (limit && buffered > limit) return NO;

    CMSampleBufferRef sb = [_audioOut copyNextSampleBuffer];
    if (!sb) return NO;

    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    size_t len = bb ? CMBlockBufferGetDataLength(bb) : 0;
    if (len > 0) {
        NSMutableData *raw = [NSMutableData dataWithLength:len];
        CMBlockBufferCopyDataBytes(bb, 0, len, raw.mutableBytes);
        NSData *converted = [self sl_convertAudio:raw];
        if (converted.length) {
            [_lock lock];
            [_audioPCM appendData:converted];
            [_lock unlock];
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
    AVAudioPCMBuffer *outBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:dstFmt frameCapacity:cap];
    if (!outBuf) return nil;

    __block BOOL supplied = NO;
    NSError *err = nil;
    AVAudioConverterOutputStatus st = [conv convertToBuffer:outBuf error:&err
        withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount n, AVAudioConverterInputStatus *status) {
            if (supplied) { *status = AVAudioConverterInputStatus_NoDataNow; return nil; }
            supplied = YES;
            *status = AVAudioConverterInputStatus_HaveData;
            return inBuf;
        }];
    if (st == AVAudioConverterOutputStatus_Error || outBuf.frameLength == 0) return nil;

    const AudioBufferList *abl = outBuf.audioBufferList;
    if (abl->mNumberBuffers == 1) {
        return [NSData dataWithBytes:abl->mBuffers[0].mData length:abl->mBuffers[0].mDataByteSize];
    }
    // 非交错多声道：拼成一块，配合 mFormatFlags 里的 NonInterleaved 由下游按 plane 读
    NSMutableData *out = [NSMutableData data];
    for (UInt32 i = 0; i < abl->mNumberBuffers; i++) {
        [out appendBytes:abl->mBuffers[i].mData length:abl->mBuffers[i].mDataByteSize];
    }
    return out;
}

#pragma mark - Reader 构建（只在解码线程调用）

- (void)sl_buildReaderForKey:(NSString *)key {
    [_reader cancelReading];
    _reader = nil;
    _videoOut = nil;
    _audioOut = nil;
    _idleRounds = 0;

    NSString *path;
    [_lock lock];
    path = _sourcePath;
    [_lock unlock];
    if (!path.length) return;

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
        SLLog(@"feed reader 创建失败: %@", err.localizedDescription ?: @"?");
        return;
    }

    BOOL wantAudio;
    [_lock lock];
    wantAudio = _hasAudioDstASBD;
    [_lock unlock];

    AVAssetTrack *vt = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (vt) {
        NSDictionary *settings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(pf) };
        AVAssetReaderTrackOutput *o = [[AVAssetReaderTrackOutput alloc] initWithTrack:vt outputSettings:settings];
        o.alwaysCopiesSampleData = NO;
        if ([reader canAddOutput:o]) {
            [reader addOutput:o];
            _videoOut = o;
        } else {
            // 目标格式解码器不认，退回 BGRA，交给 CoreImage 转
            NSDictionary *bg = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
            AVAssetReaderTrackOutput *o2 = [[AVAssetReaderTrackOutput alloc] initWithTrack:vt outputSettings:bg];
            o2.alwaysCopiesSampleData = NO;
            if ([reader canAddOutput:o2]) { [reader addOutput:o2]; _videoOut = o2; }
        }
        CGSize ns = vt.naturalSize;
        float fps = vt.nominalFrameRate;
        if (fps < 1.0f || fps > 240.0f) fps = 30.0f;
        _frameInterval = 1.0 / (double)fps;
        [_lock lock];
        _naturalSize = ns;
        [_lock unlock];
    }

    if (wantAudio) {
        AVAssetTrack *at = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
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
                _audioOut = o;
                [_lock lock];
                _audioSrcASBD = src;
                [_lock unlock];
            }
        }
    }

    if (![reader startReading]) {
        SLLog(@"feed startReading 失败: %@", reader.error.localizedDescription ?: @"?");
        return;
    }
    _reader = reader;

    // 循环播放每轮都要重建 reader，每 11 秒刷一行会把日志淹掉。
    // 只在「首次 / 目标格式变了 / 每 20 轮」打一次 —— 真出问题时也还看得到心跳。
    static NSString *sLastLoggedKey = nil;
    static int sLoopRounds = 0;
    sLoopRounds++;
    BOOL keyChanged = ![sLastLoggedKey isEqualToString:key ?: @""];
    if (keyChanged || sLoopRounds % 20 == 0) {
        sLastLoggedKey = key ?: @"";
        SLLog(@"feed 管线就绪 %@ (video=%@ audio=%@)%@", key ?: @"(nil)",
              _videoOut ? @"Y" : @"N", _audioOut ? @"Y" : @"N",
              keyChanged ? @"" : [NSString stringWithFormat:@" · 第 %d 轮", sLoopRounds]);
    }
}

#pragma mark - 出帧

- (CVPixelBufferRef)copyNextFrame {
    [_lock lock];
    CVPixelBufferRef pb = _latestVideo ? (CVPixelBufferRef)CVPixelBufferRetain(_latestVideo) : NULL;
    [_lock unlock];
    return pb;
}

- (CVPixelBufferRef)copyFrameForPixelFormat:(OSType)pixelFormat size:(CGSize)size {
    if (pixelFormat == 0 || size.width < 1 || size.height < 1) return NULL;
    size_t w = (size_t)size.width;
    size_t h = (size_t)size.height;

    NSString *key = [NSString stringWithFormat:@"%u:%zux%zu", (unsigned)pixelFormat, w, h];
    [_lock lock];
    BOOL changed = ![_pipelineKey isEqualToString:key];
    if (changed) { _pipelineKey = key; _reconfigRequested = YES; }
    BOOL hasFrame = (_latestVideo != NULL);
    [_lock unlock];

    // 目标格式刚变、手里还没有任何帧：放行这一帧真画面，让解码线程按新格式重建
    if (changed && !hasFrame) return NULL;

    [_lock lock];
    CVPixelBufferRef pb = _latestVideo ? (CVPixelBufferRef)CVPixelBufferRetain(_latestVideo) : NULL;
    [_lock unlock];
    if (!pb) return NULL;

    size_t sw = CVPixelBufferGetWidth(pb);
    size_t sh = CVPixelBufferGetHeight(pb);
    OSType spf = CVPixelBufferGetPixelFormatType(pb);
    NSInteger rot = [self sl_normalizedRotation];

    // 尺寸、格式都对上、又没开镜像/旋转，才能零转换直出
    if (sw == w && sh == h && spf == pixelFormat && !self.mirrorEnabled && rot == 0) {
        return pb;
    }

    CVPixelBufferRef out = [self sl_render:pb
                                   toWidth:w
                                    height:h
                                    format:pixelFormat
                                    mirror:self.mirrorEnabled
                                  rotation:rot];
    CVPixelBufferRelease(pb);
    return out;
}

/// 角度只认 0/90/180/270，其余一律当 0（脏数据不该让画面整个歪掉）
- (NSInteger)sl_normalizedRotation {
    NSInteger r = self.rotation % 360;
    if (r < 0) r += 360;
    if (r == 90 || r == 180 || r == 270) return r;
    return 0;
}

- (CVPixelBufferRef)sl_render:(CVPixelBufferRef)src
                      toWidth:(size_t)w
                       height:(size_t)h
                       format:(OSType)pf
                       mirror:(BOOL)mirror
                     rotation:(NSInteger)rotation {
    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey : @{} };
    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, pf, (__bridge CFDictionaryRef)attrs, &dst) != kCVReturnSuccess)
        return NULL;

    size_t sw = CVPixelBufferGetWidth(src);
    size_t sh = CVPixelBufferGetHeight(src);
    if (sw < 1 || sh < 1) { CVPixelBufferRelease(dst); return NULL; }

    CIImage *img = [CIImage imageWithCVPixelBuffer:src];

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
    if (re.size.width < 1 || re.size.height < 1) { CVPixelBufferRelease(dst); return NULL; }
    CGFloat s = MAX((CGFloat)w / re.size.width, (CGFloat)h / re.size.height);
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

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    [_ciContext render:img
       toCVPixelBuffer:dst
                bounds:CGRectMake(0, 0, (CGFloat)w, (CGFloat)h)
            colorSpace:cs];
    CGColorSpaceRelease(cs);
    return dst;
}

#pragma mark - 出音频

- (NSData *)audioForFormat:(const AudioStreamBasicDescription *)asbd numBytes:(size_t)numBytes {
    if (!asbd || asbd->mBytesPerFrame == 0 || numBytes == 0) return nil;

    // 关掉「替换音频」= 静音。这里必须返回全零的 PCM，不能返回 nil：
    // 返回 nil 会让注入层放行真实麦克风，把环境声原样录进去。
    // 走这条分支也就不需要素材有音轨，无声视频同样能静音。
    if (!self.audioReplaceEnabled) {
        return [NSMutableData dataWithLength:numBytes];
    }

    [_lock lock];
    BOOL firstTime = !_hasAudioDstASBD || memcmp(asbd, &_audioDstASBD, sizeof(*asbd)) != 0;
    if (firstTime) {
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
        BOOL needConvert = !(asbd->mFormatFlags & kAudioFormatFlagIsFloat)
                        || !(asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved)
                        || asbd->mChannelsPerFrame != 1
                        || asbd->mSampleRate != 44100;
        if (needConvert) {
            AVAudioFormat *sf = [[AVAudioFormat alloc] initWithStreamDescription:&src];
            AVAudioFormat *df = [[AVAudioFormat alloc] initWithStreamDescription:&_audioDstASBD];
            if (sf && df) {
                _audioConverter = [[AVAudioConverter alloc] initFromFormat:sf toFormat:df];
                if (!_audioConverter) SLLog(@"音频转换器创建失败，将只换画面");
            }
        }
        _reconfigRequested = YES;   // 让解码线程把音频轨挂上
        SLLog(@"audio 目标 %.0fHz %uch %uB/帧 转码=%@", asbd->mSampleRate,
              (unsigned)asbd->mChannelsPerFrame, (unsigned)asbd->mBytesPerFrame,
              needConvert ? @"Y" : @"N");
    }

    NSMutableData *chunk = [NSMutableData dataWithLength:numBytes];
    NSUInteger got = 0;
    NSUInteger avail = _audioPCM.length - _audioReadCursor;
    if (avail > 0) {
        got = MIN(avail, numBytes);
        memcpy(chunk.mutableBytes, (uint8_t *)_audioPCM.bytes + _audioReadCursor, got);
        _audioReadCursor += got;
        if (_audioReadCursor > 44100 * 32) {
            [_audioPCM replaceBytesInRange:NSMakeRange(0, _audioReadCursor) withBytes:NULL length:0];
            _audioReadCursor = 0;
        }
    }
    [_lock unlock];

    if (got == 0) return nil;
    if (got < numBytes) memset((uint8_t *)chunk.mutableBytes + got, 0, numBytes - got);  // 不够补静音
    return chunk;
}

@end
