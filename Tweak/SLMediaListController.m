//
//  SLMediaListController.m
//  声临 · 虚拟摄像头 —— 素材列表页
//
//  外观沿用项目里那套：玻璃表格 + 胶囊标题 + 胶囊「＋」+ 段尾说明。
//  只做素材的增删选，不碰解码 / 注入 —— 那部分在 SLCamFeed / SLCamInject。
//
//  0.2.20：
//    · 每行带缩略图（图片直接缩，视频抽第 0 帧），异步生成 + NSCache
//    · 导入完自动选中（在 SLMediaStore 里做），列表最新的排最上面
//
//  0.2.22：
//    · 「＋」不再弹 action sheet，改成锚在按钮下方的小框（点哪儿弹哪儿）
//    · 相册入口合并成一个：图片和视频同屏，一次能选一批
//    · 提示语砍短，只留结论
//

#import "SLMediaListController.h"
#import "SLMediaStore.h"
#import "SLFloatingBall.h"
#import "SLGlass.h"
#import "SLUtil.h"
#import "SLCamBridge.h"
#import "SLLog.h"
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>

#pragma mark - 缩略图

// 缩略图按 3x 屏算：40pt 的坑给 132px，够清晰又不占内存
static const CGFloat kSLThumbPixels = 132.0;

static UIImage *SLMakeThumb(SLMediaItem *it) {
    if (it.isImage) {
        CGImageSourceRef src = CGImageSourceCreateWithURL(
            (__bridge CFURLRef)[NSURL fileURLWithPath:it.path], NULL);
        if (!src) return nil;
        NSDictionary *opts = @{
            (id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
            (id)kCGImageSourceCreateThumbnailWithTransform : @YES,   // 顺手把 EXIF 方向摆正
            (id)kCGImageSourceThumbnailMaxPixelSize : @(kSLThumbPixels),
        };
        CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
        CFRelease(src);
        if (!cg) return nil;
        UIImage *img = [UIImage imageWithCGImage:cg];
        CGImageRelease(cg);
        return img;
    }

    // 视频：抽第 0 帧。appliesPreferredTrackTransform 保证竖拍视频不会躺着出来。
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:it.path] options:nil];
    AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    gen.appliesPreferredTrackTransform = YES;
    gen.maximumSize = CGSizeMake(kSLThumbPixels, kSLThumbPixels);
    CGImageRef cg = [gen copyCGImageAtTime:kCMTimeZero actualTime:NULL error:NULL];
    if (!cg) return nil;
    UIImage *img = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return img;
}

static NSCache<NSString *, UIImage *> *SLThumbCache(void) {
    static NSCache *c = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = [NSCache new];
        c.countLimit = 64;      // 一张 132px 缩略图约 70KB，64 张不到 5MB
    });
    return c;
}

static dispatch_queue_t SLThumbQueue(void) {
    static dispatch_queue_t q = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 串行：抽帧是重活，并发抽会跟宿主自己的解码抢 IO
        q = dispatch_queue_create("com.taylorchen.shenglinvcam.thumb", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

// 导入队列：算 SHA-256 指纹 + 解码体检都是秒级操作，批量导入时不能占主线程。
// 串行是因为 importItemAtURL: 会读写 media/.hashes.plist，并发就得再加一层锁。
static dispatch_queue_t SLImportQueue(void) {
    static dispatch_queue_t q = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.taylorchen.shenglinvcam.import", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

#pragma mark - 弹出小框

// 尺寸都在这儿，改一处全变
static const CGFloat kSLMenuRowH  = 44.0;
static const CGFloat kSLMenuPadY  = 6.0;
static const CGFloat kSLMenuWidth = 176.0;
static const CGFloat kSLMenuGap   = 6.0;    // 锚点与小框之间
static const CGFloat kSLMenuArrow = 9.0;    // 三角尖的高度
static const CGFloat kSLMenuEdge  = 8.0;    // 离容器边缘至少留这么多

// 不用毛玻璃：三角尖要跟面板同色，毛玻璃没法画出一个「对得上」的尖。
// 系统自己的弹出菜单也是实色，这里跟着它走。
static UIColor *SLMenuFillColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        return tc.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:0.20 alpha:0.98]
            : [UIColor colorWithWhite:1.0 alpha:0.99];
    }];
}

@interface SLAddMenuRow : UIControl
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLab;
- (instancetype)initWithTitle:(NSString *)title icon:(NSString *)icon;
@end

@implementation SLAddMenuRow

- (instancetype)initWithTitle:(NSString *)title icon:(NSString *)icon {
    if ((self = [super initWithFrame:CGRectZero])) {
        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:15
                                                            weight:UIImageSymbolWeightMedium];
        _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _iconView.image = [UIImage systemImageNamed:icon withConfiguration:cfg];
        _iconView.contentMode = UIViewContentModeCenter;
        _iconView.tintColor = [UIColor labelColor];
        [self addSubview:_iconView];

        _titleLab = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLab.text = title;
        _titleLab.font = [UIFont systemFontOfSize:14.5];
        _titleLab.textColor = [UIColor labelColor];
        [self addSubview:_titleLab];

        self.layer.cornerRadius = 8.0;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    _iconView.frame = CGRectMake(10.0, (b.size.height - 20.0) / 2.0, 20.0, 20.0);
    _titleLab.frame = CGRectMake(36.0, 0, MAX(0.0, b.size.width - 44.0), b.size.height);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = highlighted
        ? [[UIColor labelColor] colorWithAlphaComponent:0.08]
        : [UIColor clearColor];
}

@end

@interface SLAddMenu : UIView
@property (nonatomic, strong) UIControl *backdrop;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) CAShapeLayer *arrow;
@property (nonatomic, copy) void (^albumBlock)(void);
@property (nonatomic, copy) void (^filesBlock)(void);
+ (void)showInView:(UIView *)hostView
            anchor:(CGRect)anchor
             album:(void (^)(void))album
             files:(void (^)(void))files;
@end

@implementation SLAddMenu

+ (void)showInView:(UIView *)hostView anchor:(CGRect)anchor
             album:(void (^)(void))album files:(void (^)(void))files {
    if (!hostView) return;
    // 连点两下「＋」不要叠两层
    for (UIView *v in hostView.subviews) {
        if ([v isKindOfClass:[SLAddMenu class]]) return;
    }

    SLAddMenu *m = [[SLAddMenu alloc] initWithFrame:hostView.bounds];
    m.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    m.albumBlock = album;
    m.filesBlock = files;
    [m sl_buildWithAnchor:anchor hostSize:hostView.bounds.size];
    [hostView addSubview:m];
    [m sl_animateIn];
}

- (void)sl_buildWithAnchor:(CGRect)anchor hostSize:(CGSize)hs {
    self.backgroundColor = [UIColor clearColor];

    // 背板：透明，只负责「点别处关掉」。
    // 不做压暗 —— 小框就贴在手边，压暗整屏反而像切了场景。
    self.backdrop = [[UIControl alloc] initWithFrame:self.bounds];
    self.backdrop.backgroundColor = [UIColor clearColor];
    self.backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.backdrop addTarget:self action:@selector(sl_dismiss)
            forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.backdrop];

    CGFloat w = kSLMenuWidth;
    CGFloat h = kSLMenuPadY * 2.0 + kSLMenuRowH * 2.0;

    CGFloat midX = CGRectGetMidX(anchor);
    CGFloat x = midX - w / 2.0;
    x = MIN(MAX(x, kSLMenuEdge), MAX(kSLMenuEdge, hs.width - w - kSLMenuEdge));

    // 默认往下开；下面放不下就翻到锚点上方
    BOOL below = YES;
    CGFloat y = CGRectGetMaxY(anchor) + kSLMenuGap + kSLMenuArrow;
    if (y + h > hs.height - kSLMenuEdge) {
        below = NO;
        y = CGRectGetMinY(anchor) - kSLMenuGap - kSLMenuArrow - h;
    }
    if (y < kSLMenuEdge) y = kSLMenuEdge;

    self.panel = [[UIView alloc] initWithFrame:CGRectMake(round(x), round(y), w, h)];
    self.panel.backgroundColor = SLMenuFillColor();
    self.panel.layer.cornerRadius = 14.0;
    self.panel.layer.cornerCurve = kCACornerCurveContinuous;
    self.panel.layer.shadowColor = [UIColor blackColor].CGColor;
    self.panel.layer.shadowOpacity = 0.18;
    self.panel.layer.shadowRadius = 14.0;
    self.panel.layer.shadowOffset = CGSizeMake(0, 6);
    self.panel.layer.shadowPath =
        [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, w, h) cornerRadius:14.0].CGPath;
    [self addSubview:self.panel];

    // 三角尖：夹在面板内，别贴着圆角
    CGFloat ax = round(MIN(MAX(midX - x, 20.0), w - 20.0));
    UIBezierPath *tri = [UIBezierPath bezierPath];
    if (below) {
        [tri moveToPoint:CGPointMake(ax - kSLMenuArrow, y - 0.5)];
        [tri addLineToPoint:CGPointMake(ax, y - kSLMenuArrow)];
        [tri addLineToPoint:CGPointMake(ax + kSLMenuArrow, y - 0.5)];
    } else {
        [tri moveToPoint:CGPointMake(ax - kSLMenuArrow, y + h + 0.5)];
        [tri addLineToPoint:CGPointMake(ax, y + h + kSLMenuArrow)];
        [tri addLineToPoint:CGPointMake(ax + kSLMenuArrow, y + h + 0.5)];
    }
    [tri closePath];

    self.arrow = [CAShapeLayer layer];
    self.arrow.path = tri.CGPath;
    self.arrow.fillColor = SLMenuFillColor().CGColor;
    [self.layer insertSublayer:self.arrow below:self.panel.layer];

    SLAddMenuRow *r1 = [[SLAddMenuRow alloc] initWithTitle:@"从相册选择" icon:@"photo.on.rectangle"];
    r1.frame = CGRectMake(4.0, kSLMenuPadY, w - 8.0, kSLMenuRowH);
    [r1 addTarget:self action:@selector(sl_tapAlbum) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:r1];

    SLAddMenuRow *r2 = [[SLAddMenuRow alloc] initWithTitle:@"从文件导入" icon:@"folder"];
    r2.frame = CGRectMake(4.0, kSLMenuPadY + kSLMenuRowH, w - 8.0, kSLMenuRowH);
    [r2 addTarget:self action:@selector(sl_tapFiles) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:r2];
}

- (void)sl_animateIn {
    self.panel.alpha = 0.0;
    self.panel.transform = CGAffineTransformMakeScale(0.94, 0.94);
    self.arrow.opacity = 0.0f;
    [UIView animateWithDuration:0.18 delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.panel.alpha = 1.0;
        self.panel.transform = CGAffineTransformIdentity;
    } completion:nil];
    self.arrow.opacity = 1.0f;
}

- (void)sl_dismiss {
    [UIView animateWithDuration:0.13 animations:^{
        self.panel.alpha = 0.0;
        self.panel.transform = CGAffineTransformMakeScale(0.96, 0.96);
    } completion:^(BOOL done) {
        (void)done;
        [self removeFromSuperview];
    }];
}

// 点完立刻摘掉再起 picker：picker 是全屏的，留着这一层只会挡在转场动画里
- (void)sl_tapAlbum {
    void (^b)(void) = self.albumBlock;
    [self removeFromSuperview];
    if (b) b();
}

- (void)sl_tapFiles {
    void (^b)(void) = self.filesBlock;
    [self removeFromSuperview];
    if (b) b();
}

@end

#pragma mark - 添加素材（相册 / 文件）

/// 相册和文件两个 picker 的 delegate 都放在这个单例上。
/// 放控制器里不行：picker 是 present 出来的，控制器在浮窗里随时可能被关掉。
@interface SLMediaAdder : NSObject <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, copy, nullable) void (^completion)(BOOL added);

// 批量导入：一次选一堆时逐个处理。串行是有意的 ——
// loadFileRepresentation 给的临时文件只在回调里有效，必须当场拷走；
// 并发拷会同时改 .hashes.plist，还得额外加锁。
@property (nonatomic, strong) NSArray<NSItemProvider *> *queue;
@property (nonatomic, assign) NSUInteger cursor;
@property (nonatomic, assign) NSInteger addedCount;
@property (nonatomic, assign) NSInteger dupCount;
@property (nonatomic, assign) NSInteger failCount;

+ (instancetype)shared;
- (void)presentMenuFrom:(UIViewController *)host
                 anchor:(UIView *)anchorView
             completion:(nullable void (^)(BOOL))completion;
@end

@implementation SLMediaAdder

+ (instancetype)shared {
    static SLMediaAdder *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[SLMediaAdder alloc] init]; });
    return s;
}

- (void)presentMenuFrom:(UIViewController *)host
                 anchor:(UIView *)anchorView
             completion:(void (^)(BOOL))completion {
    if (!host) return;
    self.completion = completion;

    // 菜单挂在导航控制器的视图上，不挂在 host.view 上 ——
    // 两个调用方（设置页 / 素材页）都是 UITableViewController，self.view 就是那张表，
    // 菜单加进去会跟着一起滚走。呈现仍然从 host 发起，跟以前一样稳。
    UIView *menuHost = host.navigationController.view ?: host.view;

    // 锚点换到 menuHost 坐标
    CGRect anchor;
    if (anchorView && anchorView.window == menuHost.window) {
        anchor = [menuHost convertRect:anchorView.bounds fromView:anchorView];
    } else {
        CGFloat w = menuHost.bounds.size.width;
        anchor = CGRectMake(w - 60.0, 0, 40.0, 0);
    }

    __weak typeof(self) ws = self;
    [SLAddMenu showInView:menuHost anchor:anchor
                    album:^{ [ws pickPhotosFrom:host]; }
                    files:^{ [ws pickFilesFrom:host]; }];
}

- (void)pickPhotosFrom:(UIViewController *)host {
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    // 图片和视频一起显示 —— 相册本来就是一屏混排，没必要让用户先做一次分类。
    cfg.filter = [PHPickerFilter anyFilterMatchingSubfilters:
                  @[[PHPickerFilter imagesFilter], [PHPickerFilter videosFilter]]];
    // 0 = 不限数量。批量导入按顺序跑，最后导入的那个成为当前素材。
    cfg.selectionLimit = 0;
    // 默认的 automatic 可能让系统挑「兼容表示」，4K / HEVC 素材会被现场转码 ——
    // 慢、临时文件更大、还更容易失败。current 直接拿原文件。
    cfg.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;
    PHPickerViewController *vc = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    vc.delegate = self;
    [host presentViewController:vc animated:YES completion:nil];
}

- (void)pickFilesFrom:(UIViewController *)host {
    // asCopy:YES —— 系统先把文件拷到我们沙盒的临时目录，不用处理 security scoped 权限，
    // 也不会碰到用户的原文件。
    UIDocumentPickerViewController *dp =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeMovie, UTTypeImage]
                                                                   asCopy:YES];
    dp.delegate = self;
    dp.allowsMultipleSelection = YES;
    [host presentViewController:dp animated:YES completion:nil];
}

#pragma mark 相册

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!results.count) return;

    NSMutableArray<NSItemProvider *> *q = [NSMutableArray arrayWithCapacity:results.count];
    for (PHPickerResult *r in results) {
        if (r.itemProvider) [q addObject:r.itemProvider];
    }
    if (!q.count) return;

    self.queue = q;
    self.cursor = 0;
    self.addedCount = 0;
    self.dupCount = 0;
    self.failCount = 0;
    [self sl_step];
}

/// 逐个走：取一个 → 拷进库 → 再取下一个。
- (void)sl_step {
    if (self.cursor >= self.queue.count) {
        [self sl_finish];
        return;
    }

    NSUInteger total = self.queue.count;
    NSUInteger idx = self.cursor + 1;
    self.cursor++;
    SLToast(total > 1 ? [NSString stringWithFormat:@"导入中 %lu/%lu",
                         (unsigned long)idx, (unsigned long)total]
                      : @"导入中");

    NSItemProvider *p = self.queue[idx - 1];
    // 先问图片再问视频：实况照片两种表示都注册了，
    // 先问图片能拿到那张静态帧，比拿一段 3 秒的 MOV 更符合「图片定格」的预期。
    NSString *typeId = nil;
    if ([p hasItemConformingToTypeIdentifier:UTTypeImage.identifier]) {
        typeId = UTTypeImage.identifier;
    } else if ([p hasItemConformingToTypeIdentifier:UTTypeMovie.identifier]) {
        typeId = UTTypeMovie.identifier;
    }
    if (!typeId) {
        self.failCount++;
        [self sl_next];
        return;
    }

    __weak typeof(self) ws = self;
    [p loadFileRepresentationForTypeIdentifier:typeId
                             completionHandler:^(NSURL *url, NSError *err) {
        SLMediaAdder *ss = ws;
        if (!ss) return;
        if (!url) {
            SLLog(@"导入: 相册导出失败 %@", err.localizedDescription ?: @"?");
            ss.failCount++;
        } else {
            [ss sl_importOne:url];   // 临时文件只在这个回调里有效，必须当场拷
        }
        [ss sl_next];
    }];
}

- (void)sl_next {
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [ws sl_step]; });
}

- (void)sl_importOne:(NSURL *)url {
    NSError *e = nil;
    BOOL dup = NO;
    SLMediaItem *it = [SLMediaStore importItemAtURL:url error:&e duplicate:&dup];
    if (!it) {
        self.failCount++;
        SLLog(@"导入: 失败 %@", e.localizedDescription ?: @"?");
        return;
    }
    if (dup) self.dupCount++;
    else self.addedCount++;
}

- (void)sl_finish {
    self.queue = nil;
    [SLThumbCache() removeAllObjects];
    SLCamReloadAll();

    NSInteger ok = self.addedCount + self.dupCount;
    NSString *msg;
    if (ok == 0) {
        msg = self.failCount > 0 ? @"导入失败" : @"没有可用素材";
    } else if (ok == 1) {
        msg = (self.dupCount == 1) ? @"已在库中" : @"已添加";
    } else {
        msg = [NSString stringWithFormat:@"已添加 %ld 个", (long)ok];
    }
    SLToast(msg);

    void (^done)(BOOL) = self.completion;
    self.completion = nil;
    if (done) done(ok > 0);
}

#pragma mark 文件

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    if (!urls.count) return;

    self.queue = nil;
    self.addedCount = 0;
    self.dupCount = 0;
    self.failCount = 0;

    SLToast(urls.count > 1 ? [NSString stringWithFormat:@"导入中 %lu 个", (unsigned long)urls.count]
                           : @"导入中");

    // asCopy:YES 拿到的已经是沙盒副本，可以慢慢来。
    // 但算指纹 + 体检对 4K 素材是秒级的，一次选五个就会把主线程堵死 —— 挪到后台串行队列。
    __weak typeof(self) ws = self;
    dispatch_async(SLImportQueue(), ^{
        SLMediaAdder *ss = ws;
        if (!ss) return;
        for (NSURL *u in urls) [ss sl_importOne:u];
        dispatch_async(dispatch_get_main_queue(), ^{ [ss sl_finish]; });
    });
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller;
}

@end

#pragma mark - 素材行

@interface SLMediaCell : UITableViewCell
@property (nonatomic, strong) UIImageView *thumb;
@property (nonatomic, strong) UILabel *nameLab;
@property (nonatomic, strong) UILabel *kindLab;
@property (nonatomic, strong) UIImageView *check;
/// 这一格现在绑的是哪个文件 —— 异步回来的缩略图靠它判断还能不能往上放
@property (nonatomic, copy) NSString *boundFile;
@end

@implementation SLMediaCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleDefault;

        _thumb = [[UIImageView alloc] initWithFrame:CGRectMake(14, 8, 40, 40)];
        _thumb.contentMode = UIViewContentModeScaleAspectFill;
        _thumb.clipsToBounds = YES;
        _thumb.layer.cornerRadius = 9;
        _thumb.layer.cornerCurve = kCACornerCurveContinuous;
        _thumb.backgroundColor = [UIColor tertiarySystemFillColor];
        [self.contentView addSubview:_thumb];

        _nameLab = [[UILabel alloc] initWithFrame:CGRectZero];
        _nameLab.font = [UIFont systemFontOfSize:15];
        _nameLab.textColor = [UIColor labelColor];
        _nameLab.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [self.contentView addSubview:_nameLab];

        _kindLab = [[UILabel alloc] initWithFrame:CGRectZero];
        _kindLab.font = [UIFont systemFontOfSize:11];
        _kindLab.textColor = [UIColor secondaryLabelColor];
        [self.contentView addSubview:_kindLab];

        _check = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"]];
        _check.tintColor = [UIColor systemBlueColor];
        _check.contentMode = UIViewContentModeScaleAspectFit;
        _check.hidden = YES;
        [self.contentView addSubview:_check];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat h = self.contentView.bounds.size.height;
    _check.frame = CGRectMake(w - 34, (h - 16) / 2.0, 16, 16);

    CGFloat textX = 64;
    CGFloat textW = w - textX - 44;
    _nameLab.frame = CGRectMake(textX, 10, textW, 19);
    _kindLab.frame = CGRectMake(textX, 30, textW, 14);
}

- (void)sl_configureWith:(SLMediaItem *)it current:(BOOL)cur {
    self.boundFile = it.fileName;
    self.nameLab.text = it.displayName;
    self.kindLab.text = it.isImage ? @"图片 · 定格画面" : @"视频 · 循环播放";
    self.kindLab.textColor = it.isImage ? [UIColor systemBlueColor] : [UIColor secondaryLabelColor];
    self.check.hidden = !cur;

    UIImage *cached = [SLThumbCache() objectForKey:it.fileName];
    self.thumb.image = cached;
    if (cached) return;

    // 缩略图没现成：先清空，再异步抽。抽不到就留个灰底方块，不显示破图。
    __weak typeof(self) ws = self;
    NSString *name = it.fileName;
    dispatch_async(SLThumbQueue(), ^{
        UIImage *img = SLMakeThumb(it);
        if (img) [SLThumbCache() setObject:img forKey:name];
        if (!img) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            // 回来时这一格可能已经滚走、绑到别的素材上了
            if ([ws.boundFile isEqualToString:name]) ws.thumb.image = img;
        });
    });
}

@end

#pragma mark - 素材页

@interface SLMediaListController ()
@property (nonatomic, strong) NSArray<SLMediaItem *> *items;
@end

// 素材页和设置页住的是同一个浮窗容器，不能「在浮窗里再叠一个浮窗」——
// 必须先把素材页关掉，再推设置页。
//
// 但 dismiss 是带 0.3s 动画的，`presentFrom:` 里那句 `host.presentedViewController`
// 在动画跑完之前一直为真，写死一个 delay 赌时间会赌输（CrossDissolve 实测 0.35s 上下）。
// 所以改成轮询：每 0.1s 试一次，最多 1.5s。
//
// 用 C 函数而不是方法，是因为素材页在 dismiss 之后立刻就被释放了，
// 捕获 self 的 weak 指针到这里已经是 nil，设置页就永远打不开。
static void SLPresentSettingsWhenFree(UIViewController *host, NSInteger attempt) {
    if (!host) return;
    if (host.presentedViewController == nil) {
        [SLFloatPanelController presentSettingsFrom:host];
        return;
    }
    if (attempt >= 15) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SLPresentSettingsWhenFree(host, attempt + 1);
    });
}

@implementation SLMediaListController

+ (void)presentAddMenuFrom:(UIViewController *)host
                    anchor:(UIView *)anchorView
                completion:(void (^)(BOOL))completion {
    [[SLMediaAdder shared] presentMenuFrom:host anchor:anchorView completion:completion];
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"素材";
    self.navigationItem.titleView = SLPillTitleView(@"素材");
    SLApplyGlassTable(self.tableView);
    self.navigationItem.rightBarButtonItems = @[
        SLPillBarItem(@"完成", self, @selector(sl_done)),
        SLPillIconBarItem(@"plus", nil, self, @selector(sl_pick)),
    ];
    // 胶囊移除后，设置面板的入口挪到这里：单击球 → 素材页 → 左上角齿轮 → 设置。
    // 放左边是因为右边「完成 / ＋」两个位置都占满了，而「完成」必须留在最右。
    self.navigationItem.leftBarButtonItem = SLPillIconBarItem(@"gearshape", @"设置", self, @selector(sl_openSettings));
    self.tableView.estimatedSectionFooterHeight = 28;
    self.tableView.estimatedSectionHeaderHeight = 26;
    self.tableView.rowHeight = 56;
    [self sl_reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self sl_reload];
}

- (void)sl_reload {
    self.items = [SLMediaStore allItems];
    [self.tableView reloadData];
}

- (void)sl_done {
    SLCloseHostingPanel(self);
}

// 胶囊移除后，设置面板的入口挪到这里：单击球 → 素材页 → 左上角齿轮 → 设置。
- (void)sl_openSettings {
    UIViewController *host = self.presentingViewController;
    if (!host) return;
    [SLFloatPanelController dismissSettings];
    SLPresentSettingsWhenFree(host, 0);
}

- (void)sl_pick {
    // 小框要贴着「＋」展开。锚点是导航栏里那颗胶囊的自定义视图，
    // 菜单本身由 SLMediaAdder 挂到导航控制器的视图上（表格会滚，挂表格上会跟着跑）。
    UIView *anchor = self.navigationItem.rightBarButtonItems.lastObject.customView;

    __weak typeof(self) ws = self;
    [SLMediaListController presentAddMenuFrom:self anchor:anchor completion:^(BOOL added) {
        (void)added;
        [ws sl_reload];
    }];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    (void)tv;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    (void)tv; (void)section;
    return self.items.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    (void)tv; (void)section;
    if (!self.items.count) return nil;
    return [NSString stringWithFormat:@"我的素材 · %lu 个", (unsigned long)self.items.count];
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    (void)tv; (void)section;
    if (self.items.count) {
        return @"最新的排在最上面，导入后自动选中。左滑删除。";
    }
    return @"还没有素材。点右上角「＋」选一段视频或一张图片，它会替换摄像头画面。";
}

- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip {
    (void)tv; (void)ip;
    cell.backgroundColor = SLGlassCellColor();
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *rid = @"media";
    SLMediaCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (!cell) cell = [[SLMediaCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid];

    SLMediaItem *it = self.items[ip.row];
    BOOL cur = [[SLMediaStore currentItem].fileName isEqualToString:it.fileName];
    [cell sl_configureWith:it current:cur];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row >= (NSInteger)self.items.count) return;
    SLMediaItem *it = self.items[ip.row];
    // 再点一次已经打勾的那行 = 取消替换。
    // SLMediaStore 本来就支持传 nil 清空（内部走 removeObjectForKey），
    // 只是这里从来没给过 nil —— 所以「勾上了就取消不掉」。
    BOOL cur = [[SLMediaStore currentItem].fileName isEqualToString:it.fileName];
    if (cur) {
        [SLMediaStore setCurrentItem:nil];
        SLToast(@"已取消");
    } else {
        [SLMediaStore setCurrentItem:it];
        SLToast(@"已切换");
    }
    [tv reloadData];
    SLCamReloadAll();
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv
trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.row >= (NSInteger)self.items.count) return nil;
    SLMediaItem *it = self.items[ip.row];
    __weak typeof(self) ws = self;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                     title:@"删除"
                                                                   handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [SLMediaStore removeItem:it];
        [SLThumbCache() removeObjectForKey:it.fileName];
        [ws sl_reload];
        SLCamReloadAll();
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

@end
