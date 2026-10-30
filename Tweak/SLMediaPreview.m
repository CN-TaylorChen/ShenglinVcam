//
//  SLVMediaPreview.m
//  声临 · 虚拟摄像头 —— 素材预览
//

#import "SLMediaPreview.h"
#import "SLMediaStore.h"
#import "SLFloatingBall.h"
#import "SLGlass.h"
#import "SLUtil.h"
#import "SLLog.h"
#import <AVFoundation/AVFoundation.h>
#include <math.h>

#pragma mark - 音轨体检

@implementation SLVMediaAudioInfo
@end

/// 4CC → 可读名。别写 'aac ' 这种多字符字面量 —— 实现定义，换编译器就可能变。
static NSString *SLVFourCCName(FourCharCode fc) {
    char s[5] = {
        (char)((fc >> 24) & 0xFF),
        (char)((fc >> 16) & 0xFF),
        (char)((fc >> 8) & 0xFF),
        (char)(fc & 0xFF),
        0,
    };
    NSString *raw = [[NSString stringWithUTF8String:s] stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *k = raw.lowercaseString;

    if ([k isEqualToString:@"aac"] || [k isEqualToString:@"mp4a"]) return @"AAC";
    if ([k isEqualToString:@"alac"]) return @"ALAC";
    if ([k isEqualToString:@"ac-3"]) return @"AC-3";
    if ([k isEqualToString:@"ec-3"]) return @"E-AC-3";
    if ([k isEqualToString:@"opus"]) return @"Opus";
    if ([k isEqualToString:@"lpcm"] || [k isEqualToString:@"sowt"]
        || [k isEqualToString:@"twos"] || [k isEqualToString:@"fl32"]) return @"PCM";
    if ([k isEqualToString:@"samr"]) return @"AMR";
    if ([k isEqualToString:@"ulaw"] || [k isEqualToString:@"alaw"]) return @"G.711";
    return raw.length ? raw : @"未知";
}

/// 音轨能不能解成 PCM —— 判据跟 SLVCamFeed 建 reader 时保持一致，
/// 否则会出现「预览说能出声、录制时却静音」这种前后矛盾。
static BOOL SLVTrackDecodesToPCM(AVAsset *asset, AVAssetTrack *track) {
    if (!asset || !track) return NO;
    NSError *err = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
    if (!reader) return NO;
    NSDictionary *settings = @{
        AVFormatIDKey : @(kAudioFormatLinearPCM),
        AVLinearPCMBitDepthKey : @16,
        AVLinearPCMIsFloatKey : @NO,
        AVLinearPCMIsBigEndianKey : @NO,
        AVLinearPCMIsNonInterleaved : @NO,
    };
    AVAssetReaderTrackOutput *out =
        [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
    return [reader canAddOutput:out];
}

SLVMediaAudioInfo *SLVProbeMediaAudio(NSString *path) {
    if (!path.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) return nil;

    // 缓存键带上修改时间：同名文件被替换过就要重新探
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    NSTimeInterval mtime = [(NSDate *)attrs[NSFileModificationDate] timeIntervalSince1970];
    NSString *key = [NSString stringWithFormat:@"%@|%.0f", path.lastPathComponent, mtime];

    static NSMutableDictionary<NSString *, SLVMediaAudioInfo *> *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    @synchronized (cache) {
        SLVMediaAudioInfo *hit = cache[key];
        if (hit) return hit;
    }

    SLVMediaAudioInfo *info = [[SLVMediaAudioInfo alloc] init];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    AVAssetTrack *at = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;

    if (!at) {
        info.hasAudio = NO;
        info.decodable = NO;
        info.codec = @"";
        info.detail = @"";
    } else {
        info.hasAudio = YES;
        info.decodable = SLVTrackDecodesToPCM(asset, at);

        CMFormatDescriptionRef fd =
            (__bridge CMFormatDescriptionRef)at.formatDescriptions.firstObject;
        if (fd) {
            info.codec = SLVFourCCName(CMFormatDescriptionGetMediaSubType(fd));
            const AudioStreamBasicDescription *asbd =
                CMAudioFormatDescriptionGetStreamBasicDescription(fd);
            if (asbd && asbd->mSampleRate > 0) {
                info.detail = [NSString stringWithFormat:@"%.1f kHz · %u 声道",
                               asbd->mSampleRate / 1000.0, (unsigned)asbd->mChannelsPerFrame];
            }
        }
        if (!info.codec.length) info.codec = @"未知";
        if (!info.detail.length) info.detail = @"";
    }

    @synchronized (cache) {
        cache[key] = info;
        // 素材删了缓存不会自己掉，超过 200 条整表清一次，别让字典无限长
        if (cache.count > 200) [cache removeAllObjects];
    }
    return info;
}

NSString *SLVMediaAudioSummary(void) {
    SLVMediaItem *it = [SLVMediaStore currentItem];
    if (!it) return @"未选素材";
    if (it.isImage) return @"图片";
    SLVMediaAudioInfo *info = SLVProbeMediaAudio(it.path);
    if (!info) return @"读不到";
    if (!info.hasAudio) return @"无声音";
    if (!info.decodable) return @"音轨不可解";
    return @"有声音";
}

#pragma mark - 预览页

/// 素材「摆正之后」的显示尺寸。
/// 直接读 naturalSize 会拿到传感器坐标（竖拍的视频是 1920x1080），
/// 必须过一遍 preferredTransform 才是眼睛看到的宽高。
static CGSize SLVDisplaySizeOfAsset(AVAsset *asset) {
    if (!asset) return CGSizeZero;
    AVAssetTrack *vt = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!vt) return CGSizeZero;
    CGSize s = vt.naturalSize;
    CGAffineTransform t = vt.preferredTransform;
    CGSize d = CGSizeApplyAffineTransform(s, t);
    d.width = fabs(d.width);
    d.height = fabs(d.height);
    if (d.width < 1.0 || d.height < 1.0) return s;
    return d;
}

static NSString *SLVTimeText(Float64 sec) {
    if (!isfinite(sec) || sec < 0) sec = 0;
    long total = (long)lround(sec);
    return [NSString stringWithFormat:@"%ld:%02ld", total / 60, total % 60];
}

@interface SLVMediaPreviewController ()
@property (nonatomic, strong) SLVMediaItem *item;
@property (nonatomic, strong) UIView *stage;
@property (nonatomic, strong) UIImageView *stillView;
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, strong) UIView *infoCard;
@property (nonatomic, strong) UILabel *stateLab;
@property (nonatomic, strong) UILabel *codecLab;
@property (nonatomic, strong) UILabel *noteLab;
@property (nonatomic, strong) UIButton *playBtn;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UILabel *timeLab;
@property (nonatomic, strong) id timeObs;
@property (nonatomic, assign) BOOL playing;
@property (nonatomic, assign) BOOL scrubbing;
@property (nonatomic, assign) BOOL audioActive;
/// 素材宽 / 高，0 表示还不知道
@property (nonatomic, assign) CGFloat aspect;
@end

@implementation SLVMediaPreviewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    self.title = @"预览";
    self.navigationItem.titleView = SLVPillTitleView(@"预览");
    self.navigationItem.rightBarButtonItem = SLVPillBarItem(@"完成", self, @selector(sl_close));

    self.item = [SLVMediaStore currentItem];

    self.stage = [[UIView alloc] initWithFrame:CGRectZero];
    self.stage.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.86];
    self.stage.layer.cornerRadius = 14.0;
    self.stage.layer.cornerCurve = kCACornerCurveContinuous;
    self.stage.clipsToBounds = YES;
    [self.view addSubview:self.stage];

    self.stillView = [[UIImageView alloc] initWithFrame:CGRectZero];
    self.stillView.contentMode = UIViewContentModeScaleAspectFit;
    self.stillView.hidden = YES;
    [self.stage addSubview:self.stillView];

    self.infoCard = [[UIView alloc] initWithFrame:CGRectZero];
    self.infoCard.backgroundColor = SLVGlassCellColor();
    self.infoCard.layer.cornerRadius = 14.0;
    self.infoCard.layer.cornerCurve = kCACornerCurveContinuous;
    [self.view addSubview:self.infoCard];

    self.stateLab = [[UILabel alloc] initWithFrame:CGRectZero];
    self.stateLab.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.stateLab.textColor = [UIColor labelColor];
    [self.infoCard addSubview:self.stateLab];

    self.codecLab = [[UILabel alloc] initWithFrame:CGRectZero];
    self.codecLab.font = [UIFont systemFontOfSize:13];
    self.codecLab.textColor = [UIColor secondaryLabelColor];
    self.codecLab.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.infoCard addSubview:self.codecLab];

    self.noteLab = [[UILabel alloc] initWithFrame:CGRectZero];
    self.noteLab.font = [UIFont systemFontOfSize:12];
    self.noteLab.textColor = [UIColor tertiaryLabelColor];
    self.noteLab.numberOfLines = 2;
    [self.infoCard addSubview:self.noteLab];

    self.playBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.playBtn.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    self.playBtn.tintColor = [UIColor whiteColor];
    self.playBtn.layer.cornerRadius = 20.0;
    self.playBtn.hidden = YES;
    [self.playBtn addTarget:self action:@selector(sl_togglePlay) forControlEvents:UIControlEventTouchUpInside];
    [self.stage addSubview:self.playBtn];

    // 进度条：0.2.25 起能拖。以前只有播放/暂停，想确认「后面那段有没有声音」
    // 只能干等到那儿，或者从头再放一遍。
    self.slider = [[UISlider alloc] initWithFrame:CGRectZero];
    self.slider.minimumValue = 0.0;
    self.slider.maximumValue = 1.0;
    self.slider.minimumTrackTintColor = [UIColor systemBlueColor];
    self.slider.maximumTrackTintColor = [[UIColor labelColor] colorWithAlphaComponent:0.16];
    self.slider.hidden = YES;
    [self.slider addTarget:self action:@selector(sl_sliderDown)
          forControlEvents:UIControlEventTouchDown];
    [self.slider addTarget:self action:@selector(sl_sliderMoved)
          forControlEvents:UIControlEventValueChanged];
    [self.slider addTarget:self action:@selector(sl_sliderUp)
          forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside
                        | UIControlEventTouchCancel];
    [self.view addSubview:self.slider];

    self.timeLab = [[UILabel alloc] initWithFrame:CGRectZero];
    self.timeLab.font = [UIFont monospacedDigitSystemFontOfSize:11.5 weight:UIFontWeightRegular];
    self.timeLab.textColor = [UIColor secondaryLabelColor];
    self.timeLab.textAlignment = NSTextAlignmentRight;
    self.timeLab.text = @"0:00 / 0:00";
    self.timeLab.hidden = YES;
    [self.view addSubview:self.timeLab];

    [self sl_loadContent];
}

- (void)sl_close {
    SLVCloseHostingPanel(self);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.player) return;
    [self sl_activateAudio];
    // 从预览里推走别的页再回来，接着放
    if (self.playing) [self.player play];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.player pause];
    [self sl_deactivateAudio];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // 周期性观察者必须自己摘，player 释放后再调会崩
    if (_timeObs && _player) [_player removeTimeObserver:_timeObs];
}

#pragma mark 内容

- (void)sl_loadContent {
    SLVMediaItem *it = self.item;
    if (!it.path.length) {
        self.stateLab.text = @"没有素材";
        self.stateLab.textColor = [UIColor secondaryLabelColor];
        self.codecLab.text = @"先去素材页选一段视频或一张图片";
        self.noteLab.text = nil;
        return;
    }

    if (it.isImage) {
        self.stillView.hidden = NO;
        UIImage *img = [UIImage imageWithContentsOfFile:it.path];
        self.stillView.image = img;
        if (img.size.height > 1.0) self.aspect = img.size.width / img.size.height;
        self.stateLab.text = @"图片 · 画面定格";
        self.stateLab.textColor = [UIColor labelColor];
        self.codecLab.text = img ? [NSString stringWithFormat:@"%.0f × %.0f",
                                    img.size.width * img.scale, img.size.height * img.scale]
                                 : @"图片读不出来";
        self.noteLab.text = @"图片素材没有音轨，录制时会全程静音。";
        [self.view setNeedsLayout];
        return;
    }

    // ---- 视频 ----
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:it.path] options:nil];
    AVPlayerItem *pitem = [AVPlayerItem playerItemWithAsset:asset];
    self.player = [AVPlayer playerWithPlayerItem:pitem];
    self.player.actionAtItemEnd = AVPlayerActionAtItemEndNone;

    CGSize disp = SLVDisplaySizeOfAsset(asset);
    if (disp.height > 1.0) self.aspect = disp.width / disp.height;

    self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
    self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    self.playerLayer.frame = self.stage.bounds;
    [self.stage.layer insertSublayer:self.playerLayer atIndex:0];

    self.playBtn.hidden = NO;
    self.slider.hidden = NO;
    self.timeLab.hidden = NO;
    [self sl_updatePlayIcon];

    // 每 0.1s 拿一次播放位置。用弱引用，别让 block 把控制器钉住。
    __weak typeof(self) ws = self;
    self.timeObs = [self.player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.1, NSEC_PER_SEC)
                                                            queue:dispatch_get_main_queue()
                                                       usingBlock:^(CMTime time) {
        [ws sl_syncProgressWithTime:time];
    }];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sl_onItemEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:pitem];

    // ---- 音轨结论 ----
    SLVMediaAudioInfo *info = SLVProbeMediaAudio(it.path);
    if (!info || !info.hasAudio) {
        self.stateLab.text = @"无声音";
        self.stateLab.textColor = [UIColor systemOrangeColor];
        self.codecLab.text = @"这段素材没有音轨";
        self.noteLab.text = @"录制时会输出静音，不会放行真麦克风。";
    } else if (!info.decodable) {
        self.stateLab.text = @"有音轨 · 解不了";
        self.stateLab.textColor = [UIColor systemOrangeColor];
        self.codecLab.text = info.codec;
        self.noteLab.text = @"这个编码解不成 PCM，录制时会静音。换 AAC 试试。";
    } else {
        self.stateLab.text = @"有声音";
        self.stateLab.textColor = [UIColor systemGreenColor];
        self.codecLab.text = info.detail.length
            ? [NSString stringWithFormat:@"%@ · %@", info.codec, info.detail]
            : info.codec;
        self.noteLab.text = @"现在放的就是素材原声，录制时会用它替换麦克风。";
    }

    [self.player play];
    self.playing = YES;
    [self sl_updatePlayIcon];
    [self.view setNeedsLayout];
}

- (void)sl_onItemEnd:(NSNotification *)n {
    (void)n;
    // 循环：回到 0 再放，跟录制时的循环行为一致
    [self.player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    self.slider.value = 0.0;
    if (self.playing) [self.player play];
}

- (void)sl_togglePlay {
    if (!self.player) return;
    if (self.playing) {
        [self.player pause];
        self.playing = NO;
    } else {
        [self.player play];
        self.playing = YES;
    }
    [self sl_updatePlayIcon];
}

- (void)sl_updatePlayIcon {
    NSString *name = self.playing ? @"pause.fill" : @"play.fill";
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
    [self.playBtn setImage:[UIImage systemImageNamed:name withConfiguration:cfg]
                  forState:UIControlStateNormal];
}

#pragma mark 进度

- (void)sl_syncProgressWithTime:(CMTime)time {
    if (self.scrubbing || !self.player) return;
    AVPlayerItem *item = self.player.currentItem;
    Float64 dur = CMTimeGetSeconds(item.duration);
    if (!isfinite(dur) || dur <= 0) return;      // 还没 ready，duration 是 indefinite
    Float64 cur = CMTimeGetSeconds(time);
    if (!isfinite(cur) || cur < 0) cur = 0;
    self.slider.value = (float)MIN(1.0, cur / dur);
    self.timeLab.text = [NSString stringWithFormat:@"%@ / %@",
                         SLVTimeText(cur), SLVTimeText(dur)];
}

- (void)sl_sliderDown {
    self.scrubbing = YES;
}

- (void)sl_sliderMoved {
    if (!self.player) return;
    Float64 dur = CMTimeGetSeconds(self.player.currentItem.duration);
    if (!isfinite(dur) || dur <= 0) return;
    // 拖动过程中只更新时间字，不 seek —— 手指每挪一下 seek 一次会把解码器拖垮
    self.timeLab.text = [NSString stringWithFormat:@"%@ / %@",
                         SLVTimeText(self.slider.value * dur), SLVTimeText(dur)];
}

- (void)sl_sliderUp {
    self.scrubbing = NO;
    if (!self.player) return;
    Float64 dur = CMTimeGetSeconds(self.player.currentItem.duration);
    if (!isfinite(dur) || dur <= 0) return;
    // 别拖到正好 100%：落在末尾会立刻触发「播完」通知，循环回 0，看起来像没拖成
    Float64 target = MIN(self.slider.value * dur, MAX(0.0, dur - 0.05));
    __weak typeof(self) ws = self;
    [self.player seekToTime:CMTimeMakeWithSeconds(target, 600)
            toleranceBefore:kCMTimeZero
               toleranceAfter:kCMTimeZero
            completionHandler:^(BOOL finished) {
        SLVMediaPreviewController *ss = ws;
        if (finished && ss && ss.playing) [ss.player play];
    }];
}

#pragma mark 音频会话

// 不改会话的话，宿主 app（抖音 / QQ）可能把类别设成 Ambient，
// 手机一开静音键预览就没声 —— 用户会当成「素材坏了」。这里临时用 Playback + 混音。
- (void)sl_activateAudio {
    if (self.audioActive) return;
    self.audioActive = YES;
    NSError *err = nil;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    [s setCategory:AVAudioSessionCategoryPlayback
       withOptions:AVAudioSessionCategoryOptionMixWithOthers
             error:&err];
    if (err) SLVLog(@"预览: 音频类别设置失败 %@", err.localizedDescription ?: @"?");
    err = nil;
    [s setActive:YES error:&err];
    if (err) SLVLog(@"预览: 音频会话激活失败 %@", err.localizedDescription ?: @"?");
}

- (void)sl_deactivateAudio {
    if (!self.audioActive) return;
    self.audioActive = NO;
    [[AVAudioSession sharedInstance] setActive:NO
                                   withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                         error:nil];
}

#pragma mark 布局

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    if (b.size.width < 1.0) return;

    // 导航栏是透明的，self.view 从卡片顶就开始 —— 内容得自己让开它
    CGFloat top = 44.0;
    UINavigationBar *nb = self.navigationController.navigationBar;
    if (nb && nb.superview) {
        CGFloat y = CGRectGetMaxY([self.view convertRect:nb.frame fromView:nb.superview]);
        if (y > top) top = y;
    }

    CGFloat pad = 16.0;
    CGFloat w = b.size.width - pad * 2.0;
    BOOL isVideo = (self.player != nil);

    // 0.2.25：画面高度按素材自己的宽高比算。
    // 以前写死 9:16 的横框（w * 9/16），竖拍的视频在横框里按 aspectFit 一缩，
    // 宽度只剩一百出头，等于在看一张邮票。
    CGFloat barH = isVideo ? 26.0 : 0.0;
    CGFloat cardH = 112.0;
    CGFloat reserved = 4.0 + (isVideo ? 8.0 + barH : 0.0) + 12.0 + cardH + 12.0;
    CGFloat maxStageH = b.size.height - top - reserved;
    if (maxStageH < 140.0) maxStageH = 140.0;

    CGFloat stageH = maxStageH;
    if (self.aspect > 0.01) stageH = round(w / self.aspect);
    stageH = MIN(MAX(stageH, 140.0), maxStageH);

    self.stage.frame = CGRectMake(pad, top + 4.0, w, stageH);
    self.playerLayer.frame = self.stage.bounds;
    self.stillView.frame = self.stage.bounds;
    self.playBtn.frame = CGRectMake(w - 50.0, stageH - 50.0, 40.0, 40.0);

    CGFloat y = CGRectGetMaxY(self.stage.frame) + 8.0;
    if (isVideo) {
        self.timeLab.frame = CGRectMake(b.size.width - pad - 78.0, y + 3.0, 78.0, 18.0);
        self.slider.frame = CGRectMake(pad, y + 2.0, MAX(60.0, w - 86.0), 22.0);
        y += barH + 8.0;
    }

    self.infoCard.frame = CGRectMake(pad, y, w, cardH);
    CGFloat iw = w - 28.0;
    self.stateLab.frame = CGRectMake(14.0, 12.0, iw, 21.0);
    self.codecLab.frame = CGRectMake(14.0, 36.0, iw, 18.0);
    self.noteLab.frame = CGRectMake(14.0, 58.0, iw, 44.0);
}

@end
