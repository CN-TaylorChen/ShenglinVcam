//
//  SLVMediaListController.m
//  声临 · 虚拟摄像头 —— 素材列表页
//
//  外观沿用项目里那套：玻璃表格 + 胶囊标题 + 胶囊「＋」+ 段尾说明。
//  只做素材的增删选，不碰解码 / 注入 —— 那部分在 SLVCamFeed / SLVCamInject。
//
//  0.2.20：
//    · 每行带缩略图（图片直接缩，视频抽第 0 帧），异步生成 + NSCache
//    · 导入完自动选中（在 SLVMediaStore 里做），列表最新的排最上面
//
//  0.2.22：
//    · 「＋」不再弹 action sheet，改成锚在按钮下方的小框（点哪儿弹哪儿）
//    · 相册入口合并成一个：图片和视频同屏，一次能选一批
//    · 提示语砍短，只留结论
//

#import "SLMediaListController.h"
#import "SLMediaStore.h"
#import "SLMediaPreview.h"
#import "SLFloatingBall.h"
#import "SLGlass.h"
#import "SLUtil.h"
#import "SLCamBridge.h"
#import "SLLog.h"
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#include <math.h>

#pragma mark - 缩略图

// 缩略图按 3x 屏算：40pt 的坑给 132px，够清晰又不占内存
static const CGFloat kSLThumbPixels = 132.0;

static UIImage *SLVMakeThumb(SLVMediaItem *it) {
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

static NSCache<NSString *, UIImage *> *SLVThumbCache(void) {
    static NSCache *c = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = [NSCache new];
        c.countLimit = 64;      // 一张 132px 缩略图约 70KB，64 张不到 5MB
    });
    return c;
}

static dispatch_queue_t SLVThumbQueue(void) {
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
static dispatch_queue_t SLVImportQueue(void) {
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
static const CGFloat kSLMenuEdge  = 8.0;    // 离容器边缘至少留这么多

// 0.2.23：三角尖去掉了。
//
// 原来画了一枚指向锚点的小尖，两个问题：① 面板是近白实色，尖也是近白，
// 在浅色玻璃上看着就是一块白疙瘩，跟面板之间还有一道 0.5pt 的缝；
// ② 尖的位置靠 midX - x 算，菜单被边缘夹过之后就跟按钮对不上了。
// 系统自己的 UIMenu / 上下文菜单本来就没有箭头 —— 靠位置和弹出动画表达
// 「从哪儿来的」就够了，不需要画一个几何体去指。
static UIColor *SLVMenuFillColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        return tc.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:0.20 alpha:0.98]
            : [UIColor colorWithWhite:1.0 alpha:0.99];
    }];
}

@interface SLVAddMenuRow : UIControl
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLab;
- (instancetype)initWithTitle:(NSString *)title icon:(NSString *)icon;
@end

@implementation SLVAddMenuRow

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

@interface SLVAddMenu : UIView
@property (nonatomic, strong) UIControl *backdrop;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, copy) void (^albumBlock)(void);
@property (nonatomic, copy) void (^filesBlock)(void);
+ (void)showInView:(UIView *)hostView
            anchor:(CGRect)anchor
             album:(void (^)(void))album
             files:(void (^)(void))files;
@end

@implementation SLVAddMenu

+ (void)showInView:(UIView *)hostView anchor:(CGRect)anchor
             album:(void (^)(void))album files:(void (^)(void))files {
    if (!hostView) return;
    // 连点两下「＋」不要叠两层
    for (UIView *v in hostView.subviews) {
        if ([v isKindOfClass:[SLVAddMenu class]]) return;
    }

    SLVAddMenu *m = [[SLVAddMenu alloc] initWithFrame:hostView.bounds];
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
    x = round(x);

    // 默认往下开；下面放不下就翻到锚点上方
    BOOL below = YES;
    CGFloat y = CGRectGetMaxY(anchor) + kSLMenuGap;
    if (y + h > hs.height - kSLMenuEdge) {
        below = NO;
        y = CGRectGetMinY(anchor) - kSLMenuGap - h;
    }
    if (y < kSLMenuEdge) y = kSLMenuEdge;
    y = round(y);

    // 用 bounds + anchorPoint + position 摆，不用 frame：
    // 下面要改 anchorPoint 做「从按钮那一侧长出来」的缩放动画，
    // 而 frame 在 anchorPoint 变了之后会自己变形，写 frame 等于白写。
    self.panel = [[UIView alloc] initWithFrame:CGRectZero];
    self.panel.bounds = CGRectMake(0, 0, w, h);
    self.panel.backgroundColor = SLVMenuFillColor();
    self.panel.layer.cornerRadius = 14.0;
    self.panel.layer.cornerCurve = kCACornerCurveContinuous;
    self.panel.layer.shadowColor = [UIColor blackColor].CGColor;
    self.panel.layer.shadowOpacity = 0.18;
    self.panel.layer.shadowRadius = 14.0;
    self.panel.layer.shadowOffset = CGSizeMake(0, 6);
    self.panel.layer.shadowPath =
        [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, w, h) cornerRadius:14.0].CGPath;

    // 缩放锚点落在「对着按钮的那条边」上：往下开取顶边，往上开取底边。
    // 没有箭头之后，「从哪弹出来的」全靠这个动画交代。
    CGFloat ax = round(MIN(MAX(midX - x, 24.0), w - 24.0));
    self.panel.layer.anchorPoint = CGPointMake(ax / w, below ? 0.0 : 1.0);
    self.panel.layer.position = CGPointMake(x + ax, below ? y : y + h);
    [self addSubview:self.panel];

    SLVAddMenuRow *r1 = [[SLVAddMenuRow alloc] initWithTitle:@"从相册选择" icon:@"photo.on.rectangle"];
    r1.frame = CGRectMake(4.0, kSLMenuPadY, w - 8.0, kSLMenuRowH);
    [r1 addTarget:self action:@selector(sl_tapAlbum) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:r1];

    SLVAddMenuRow *r2 = [[SLVAddMenuRow alloc] initWithTitle:@"从文件导入" icon:@"folder"];
    r2.frame = CGRectMake(4.0, kSLMenuPadY + kSLMenuRowH, w - 8.0, kSLMenuRowH);
    [r2 addTarget:self action:@selector(sl_tapFiles) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:r2];
}

- (void)sl_animateIn {
    self.panel.alpha = 0.0;
    self.panel.transform = CGAffineTransformMakeScale(0.92, 0.92);
    [UIView animateWithDuration:0.20 delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.panel.alpha = 1.0;
        self.panel.transform = CGAffineTransformIdentity;
    } completion:nil];
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
@interface SLVMediaAdder : NSObject <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
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

@implementation SLVMediaAdder

+ (instancetype)shared {
    static SLVMediaAdder *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[SLVMediaAdder alloc] init]; });
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
    [SLVAddMenu showInView:menuHost anchor:anchor
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
    SLVToast(total > 1 ? [NSString stringWithFormat:@"导入中 %lu/%lu",
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
        SLVMediaAdder *ss = ws;
        if (!ss) return;
        if (!url) {
            SLVLog(@"导入: 相册导出失败 %@", err.localizedDescription ?: @"?");
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
    SLVMediaItem *it = [SLVMediaStore importItemAtURL:url error:&e duplicate:&dup];
    if (!it) {
        self.failCount++;
        SLVLog(@"导入: 失败 %@", e.localizedDescription ?: @"?");
        return;
    }
    if (dup) self.dupCount++;
    else self.addedCount++;
}

- (void)sl_finish {
    self.queue = nil;
    [SLVThumbCache() removeAllObjects];
    SLVCamReloadAll();

    NSInteger ok = self.addedCount + self.dupCount;
    NSString *msg;
    if (ok == 0) {
        msg = self.failCount > 0 ? @"导入失败" : @"没有可用素材";
    } else if (ok == 1) {
        msg = (self.dupCount == 1) ? @"已在库中" : @"已添加";
    } else {
        msg = [NSString stringWithFormat:@"已添加 %ld 个", (long)ok];
    }
    SLVToast(msg);

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

    SLVToast(urls.count > 1 ? [NSString stringWithFormat:@"导入中 %lu 个", (unsigned long)urls.count]
                           : @"导入中");

    // asCopy:YES 拿到的已经是沙盒副本，可以慢慢来。
    // 但算指纹 + 体检对 4K 素材是秒级的，一次选五个就会把主线程堵死 —— 挪到后台串行队列。
    __weak typeof(self) ws = self;
    dispatch_async(SLVImportQueue(), ^{
        SLVMediaAdder *ss = ws;
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

@interface SLVMediaCell : UITableViewCell
@property (nonatomic, strong) UIImageView *thumb;
@property (nonatomic, strong) UILabel *nameLab;
@property (nonatomic, strong) UILabel *kindLab;
@property (nonatomic, strong) UIImageView *check;
/// 这一格现在绑的是哪个文件 —— 异步回来的缩略图靠它判断还能不能往上放
@property (nonatomic, copy) NSString *boundFile;
@end

@implementation SLVMediaCell

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

- (void)sl_configureWith:(SLVMediaItem *)it current:(BOOL)cur {
    self.boundFile = it.fileName;
    self.nameLab.text = it.displayName;
    self.kindLab.text = it.isImage ? @"图片 · 定格画面" : @"视频 · 循环播放";
    self.kindLab.textColor = it.isImage ? [UIColor systemBlueColor] : [UIColor secondaryLabelColor];
    self.check.hidden = !cur;

    UIImage *cached = [SLVThumbCache() objectForKey:it.fileName];
    self.thumb.image = cached;
    if (cached) return;

    // 缩略图没现成：先清空，再异步抽。抽不到就留个灰底方块，不显示破图。
    __weak typeof(self) ws = self;
    NSString *name = it.fileName;
    dispatch_async(SLVThumbQueue(), ^{
        UIImage *img = SLVMakeThumb(it);
        if (img) [SLVThumbCache() setObject:img forKey:name];
        if (!img) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            // 回来时这一格可能已经滚走、绑到别的素材上了
            if ([ws.boundFile isEqualToString:name]) ws.thumb.image = img;
        });
    });
}

@end

#pragma mark - 预览台

// 0.3.3：预览从「设置页 → 预览素材」那个独立页面搬到素材页顶部。
//
// 原来想看另一段素材，必须退出去、换选中、再进来，比较两段要来回四趟。
// 现在点哪行就放哪行：播放器全局只有一个，切素材只换 AVPlayerItem ——
// 每个素材建一个 AVPlayer 的话，来回点几下就是十几个解码器，内存和 IO 都扛不住。
//
// 为什么挂成 tableHeaderView 而不是固定压在列表上方：
// UITableViewController 的 tableView 铺满整个 view，要固定就得改 contentInset、
// 滚动指示器位置和 contentOffset，一处算错整页错位。header 跟着列表一起滚，
// 列表短的时候看不出区别，长了正好把空间让出来。
//
// 默认静音，要出声点右上角那颗喇叭。静音播放完全不碰 AVAudioSession ——
// 宿主的会话类别不是我们说了算（抖音/QQ 常用 Ambient），动了它就会互相抢声音。

static const CGFloat kSLStagePad  = 16.0;
static const CGFloat kSLStageBoxH = 156.0;
static const CGFloat kSLStageBarH = 26.0;

/// 预览台整高：上留白 + 舞台 + 间距 + 进度条
static CGFloat SLVStageHeight(void) {
    return 8.0 + kSLStageBoxH + 4.0 + kSLStageBarH;
}

static NSString *SLVStageTime(Float64 sec) {
    if (!isfinite(sec) || sec < 0) sec = 0;
    long t = (long)lround(sec);
    return [NSString stringWithFormat:@"%ld:%02ld", t / 60, t % 60];
}

@interface SLVListPreviewHeader : UIView
/// 现在挂的是哪个素材（文件名），空串表示空台。切素材靠它判要不要重建播放器
@property (nonatomic, copy) NSString *fileKey;
- (void)sl_showItem:(SLVMediaItem *)it autoplay:(BOOL)play;
- (void)sl_replay;
- (void)sl_pause;
- (void)sl_resumeIfPlaying;
@end

@implementation SLVListPreviewHeader {
    UIView *_box;
    UIImageView *_still;
    AVPlayerLayer *_layer;
    AVPlayer *_player;
    UIButton *_playBtn;
    UIButton *_muteBtn;
    UILabel *_nameLab;
    UILabel *_hintLab;
    UILabel *_emptyLab;
    UISlider *_slider;
    UILabel *_timeLab;
    id _timeObs;
    BOOL _playing;      // 「用户希望它在放」，viewWillDisappear 暂停时不动它
    BOOL _scrubbing;
    BOOL _isVideo;
    BOOL _muted;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _muted = YES;                       // 默认不出声
    self.backgroundColor = [UIColor clearColor];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    _box = [[UIView alloc] initWithFrame:CGRectZero];
    _box.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1.0];
    _box.layer.cornerRadius = 14.0;
    _box.layer.cornerCurve = kCACornerCurveContinuous;
    _box.clipsToBounds = YES;
    [self addSubview:_box];

    _still = [[UIImageView alloc] initWithFrame:CGRectZero];
    _still.contentMode = UIViewContentModeScaleAspectFit;
    _still.hidden = YES;
    [_box addSubview:_still];

    _emptyLab = [[UILabel alloc] initWithFrame:CGRectZero];
    _emptyLab.font = [UIFont systemFontOfSize:13];
    _emptyLab.textColor = [UIColor colorWithWhite:1.0 alpha:0.45];
    _emptyLab.textAlignment = NSTextAlignmentCenter;
    _emptyLab.text = @"还没有素材";
    [_box addSubview:_emptyLab];

    _hintLab = [[UILabel alloc] initWithFrame:CGRectZero];
    _hintLab.font = [UIFont systemFontOfSize:11];
    _hintLab.textColor = [UIColor colorWithWhite:1.0 alpha:0.8];
    [_box addSubview:_hintLab];

    _nameLab = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLab.font = [UIFont systemFontOfSize:11];
    _nameLab.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    _nameLab.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [_box addSubview:_nameLab];

    _playBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _playBtn.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    _playBtn.tintColor = [UIColor whiteColor];
    _playBtn.layer.cornerRadius = 20.0;
    _playBtn.hidden = YES;
    [_playBtn addTarget:self action:@selector(sl_togglePlay) forControlEvents:UIControlEventTouchUpInside];
    [_box addSubview:_playBtn];

    _muteBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _muteBtn.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    _muteBtn.tintColor = [UIColor whiteColor];
    _muteBtn.layer.cornerRadius = 17.0;
    _muteBtn.hidden = YES;
    [_muteBtn addTarget:self action:@selector(sl_toggleMute) forControlEvents:UIControlEventTouchUpInside];
    [_box addSubview:_muteBtn];

    _slider = [[UISlider alloc] initWithFrame:CGRectZero];
    _slider.minimumValue = 0.0;
    _slider.maximumValue = 1.0;
    _slider.minimumTrackTintColor = [UIColor systemBlueColor];
    // 进度条在深色舞台外面（贴在玻璃表格上），轨道色得跟着 labelColor 走，
    // 用白色的话浅色背景下整条看不见
    _slider.maximumTrackTintColor = [[UIColor labelColor] colorWithAlphaComponent:0.16];
    _slider.hidden = YES;
    [_slider addTarget:self action:@selector(sl_sliderDown) forControlEvents:UIControlEventTouchDown];
    [_slider addTarget:self action:@selector(sl_sliderMoved) forControlEvents:UIControlEventValueChanged];
    [_slider addTarget:self action:@selector(sl_sliderUp)
      forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self addSubview:_slider];

    _timeLab = [[UILabel alloc] initWithFrame:CGRectZero];
    _timeLab.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];
    _timeLab.textColor = [UIColor secondaryLabelColor];
    _timeLab.textAlignment = NSTextAlignmentRight;
    _timeLab.text = @"0:00 / 0:00";
    _timeLab.hidden = YES;
    [self addSubview:_timeLab];

    [self sl_updateMuteIcon];
    [self sl_updatePlayIcon];
    return self;
}

- (void)dealloc {
    if (_timeObs && _player) [_player removeTimeObserver:_timeObs];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark 布局

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.bounds);
    if (w <= 0.0) return;

    CGFloat bw = w - kSLStagePad * 2.0;
    _box.frame = CGRectMake(kSLStagePad, 8.0, bw, kSLStageBoxH);
    _layer.frame = _box.bounds;
    _still.frame = _box.bounds;
    _emptyLab.frame = CGRectMake(0.0, (kSLStageBoxH - 20.0) / 2.0, bw, 20.0);

    _hintLab.frame = CGRectMake(12.0, 9.0, 140.0, 18.0);
    _nameLab.frame = CGRectMake(12.0, kSLStageBoxH - 27.0, bw - 70.0, 18.0);
    _playBtn.frame = CGRectMake(bw - 50.0, kSLStageBoxH - 50.0, 40.0, 40.0);
    _muteBtn.frame = CGRectMake(bw - 43.0, 9.0, 34.0, 34.0);

    CGFloat barY = 8.0 + kSLStageBoxH + 4.0;
    _timeLab.frame = CGRectMake(w - kSLStagePad - 78.0, barY + 3.0, 78.0, 20.0);
    _slider.frame = CGRectMake(kSLStagePad, barY + 2.0, MAX(60.0, bw - 86.0), kSLStageBarH - 4.0);
}

#pragma mark 内容

- (void)sl_showItem:(SLVMediaItem *)it autoplay:(BOOL)play {
    NSString *key = it.fileName ?: @"";
    // 同一个素材：不重建播放器，只是把暂停的接着放
    if (key.length && [key isEqualToString:(self.fileKey ?: @"")]) {
        if (play && _isVideo) {
            if (!_playing) {
                _playing = YES;
                [self sl_updatePlayIcon];
            }
            // 从别的页面回来时 sl_pause 已经把播放停掉了，但 _playing 还是 YES，
            // 只判 _playing 的话这里会「以为在放」而什么都不做 —— 补一次 rate 检查
            if (_player.rate == 0.0f) [_player play];
        }
        return;
    }

    [self sl_teardown];
    self.fileKey = key;

    if (!it.path.length) {
        _emptyLab.hidden = NO;
        _emptyLab.text = @"还没有素材";
        _hintLab.text = nil;
        _nameLab.text = nil;
        [self sl_showControls:NO];
        return;
    }

    _emptyLab.hidden = YES;
    _nameLab.text = it.displayName;

    if (it.isImage) {
        _isVideo = NO;
        _still.image = [UIImage imageWithContentsOfFile:it.path];
        _still.hidden = NO;
        _hintLab.text = @"图片 · 定格";
        _hintLab.textColor = [UIColor systemBlueColor];
        [self sl_showControls:NO];
        return;
    }

    _isVideo = YES;
    _still.hidden = YES;

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:it.path] options:nil];
    AVPlayerItem *pitem = [AVPlayerItem playerItemWithAsset:asset];
    _player = [AVPlayer playerWithPlayerItem:pitem];
    _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    _player.muted = _muted;

    _layer = [AVPlayerLayer playerLayerWithPlayer:_player];
    _layer.videoGravity = AVLayerVideoGravityResizeAspect;
    _layer.frame = _box.bounds;
    [_box.layer insertSublayer:_layer atIndex:0];

    // 音轨结论跟独立预览页用的是同一个探针，缓存也共用 —— 结论不会两边打架
    SLVMediaAudioInfo *info = SLVProbeMediaAudio(it.path);
    if (!info || !info.hasAudio) {
        _hintLab.text = @"无声音";
        _hintLab.textColor = [UIColor systemOrangeColor];
    } else if (!info.decodable) {
        _hintLab.text = @"音轨解不了";
        _hintLab.textColor = [UIColor systemOrangeColor];
    } else {
        _hintLab.text = @"有声音";
        _hintLab.textColor = [UIColor systemGreenColor];
    }

    __weak typeof(self) ws = self;
    _timeObs = [_player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.1, NSEC_PER_SEC)
                                                    queue:dispatch_get_main_queue()
                                               usingBlock:^(CMTime t) { [ws sl_syncProgress:t]; }];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sl_onItemEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:pitem];

    [self sl_showControls:YES];
    _playing = play;
    if (play) [_player play];
    [self sl_updatePlayIcon];
}

- (void)sl_teardown {
    if (_timeObs && _player) [_player removeTimeObserver:_timeObs];
    _timeObs = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_player pause];
    _player = nil;
    [_layer removeFromSuperlayer];
    _layer = nil;
    _still.image = nil;
    _still.hidden = YES;
    _playing = NO;
    _isVideo = NO;
    _slider.value = 0.0;
    _timeLab.text = @"0:00 / 0:00";
    [self sl_showControls:NO];
}

- (void)sl_showControls:(BOOL)v {
    _playBtn.hidden = !v;
    _muteBtn.hidden = !v;
    _slider.hidden = !v;
    _timeLab.hidden = !v;
    // 注意别在这里动 _emptyLab —— 空台那条路径刚把它显示出来就又会被藏掉
}

- (void)sl_replay {
    if (!_player) return;
    [_player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    [_player play];
    _playing = YES;
    [self sl_updatePlayIcon];
}

- (void)sl_pause {
    // 不动 _playing：回到这一页时还要接着放
    [_player pause];
}

- (void)sl_resumeIfPlaying {
    if (_player && _playing) [_player play];
}

#pragma mark 播放

- (void)sl_togglePlay {
    if (!_player) return;
    if (_playing) { [_player pause]; _playing = NO; }
    else { [_player play]; _playing = YES; }
    [self sl_updatePlayIcon];
}

- (void)sl_toggleMute {
    _muted = !_muted;
    if (_player) _player.muted = _muted;
    [self sl_updateMuteIcon];
}

- (void)sl_updatePlayIcon {
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
    NSString *name = _playing ? @"pause.fill" : @"play.fill";
    [_playBtn setImage:[UIImage systemImageNamed:name withConfiguration:cfg] forState:UIControlStateNormal];
}

- (void)sl_updateMuteIcon {
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
    NSString *name = _muted ? @"speaker.slash.fill" : @"speaker.wave.2.fill";
    [_muteBtn setImage:[UIImage systemImageNamed:name withConfiguration:cfg] forState:UIControlStateNormal];
}

- (void)sl_onItemEnd:(NSNotification *)n {
    (void)n;
    // 跟录制时一样循环：回到 0 接着放
    [_player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    _slider.value = 0.0;
    if (_playing) [_player play];
}

#pragma mark 进度

- (void)sl_syncProgress:(CMTime)t {
    if (_scrubbing || !_player) return;
    Float64 dur = CMTimeGetSeconds(_player.currentItem.duration);
    if (!isfinite(dur) || dur <= 0) return;      // 还没 ready，duration 是 indefinite
    Float64 cur = CMTimeGetSeconds(t);
    if (!isfinite(cur) || cur < 0) cur = 0;
    _slider.value = (float)MIN(1.0, cur / dur);
    _timeLab.text = [NSString stringWithFormat:@"%@ / %@", SLVStageTime(cur), SLVStageTime(dur)];
}

- (void)sl_sliderDown {
    _scrubbing = YES;
}

- (void)sl_sliderMoved {
    if (!_player) return;
    Float64 dur = CMTimeGetSeconds(_player.currentItem.duration);
    if (!isfinite(dur) || dur <= 0) return;
    // 拖动中只更新时间字，不 seek —— 手指每挪一下 seek 一次会把解码器拖垮
    _timeLab.text = [NSString stringWithFormat:@"%@ / %@",
                     SLVStageTime(_slider.value * dur), SLVStageTime(dur)];
}

- (void)sl_sliderUp {
    _scrubbing = NO;
    if (!_player) return;
    Float64 dur = CMTimeGetSeconds(_player.currentItem.duration);
    if (!isfinite(dur) || dur <= 0) return;
    // 别拖到正好 100%：落在末尾会立刻触发「播完」通知，循环回 0，看起来像没拖成
    Float64 target = MIN(_slider.value * dur, MAX(0.0, dur - 0.05));
    __weak typeof(self) ws = self;
    [_player seekToTime:CMTimeMakeWithSeconds(target, 600)
        toleranceBefore:kCMTimeZero
           toleranceAfter:kCMTimeZero
        completionHandler:^(BOOL finished) {
        SLVListPreviewHeader *ss = ws;
        if (finished && ss) [ss sl_resumeIfPlaying];
    }];
}

@end

#pragma mark - 素材页

@interface SLVMediaListController ()
@property (nonatomic, strong) NSArray<SLVMediaItem *> *items;
@property (nonatomic, strong) SLVListPreviewHeader *stage;
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
static void SLVPresentSettingsWhenFree(UIViewController *host, NSInteger attempt) {
    if (!host) return;
    if (host.presentedViewController == nil) {
        [SLVFloatPanelController presentSettingsFrom:host];
        return;
    }
    if (attempt >= 15) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SLVPresentSettingsWhenFree(host, attempt + 1);
    });
}

@implementation SLVMediaListController

+ (void)presentAddMenuFrom:(UIViewController *)host
                    anchor:(UIView *)anchorView
                completion:(void (^)(BOOL))completion {
    [[SLVMediaAdder shared] presentMenuFrom:host anchor:anchorView completion:completion];
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"素材";
    self.navigationItem.titleView = SLVPillTitleView(@"素材");
    SLVApplyGlassTable(self.tableView);
    self.navigationItem.rightBarButtonItems = @[
        SLVPillBarItem(@"完成", self, @selector(sl_done)),
        SLVPillIconBarItem(@"plus", nil, self, @selector(sl_pick)),
    ];
    // 胶囊移除后，设置面板的入口挪到这里：单击球 → 素材页 → 左上角齿轮 → 设置。
    // 放左边是因为右边「完成 / ＋」两个位置都占满了，而「完成」必须留在最右。
    self.navigationItem.leftBarButtonItem = SLVPillIconBarItem(@"gearshape", @"设置", self, @selector(sl_openSettings));
    self.tableView.estimatedSectionFooterHeight = 28;
    self.tableView.estimatedSectionHeaderHeight = 26;
    self.tableView.rowHeight = 56;

    // 预览台挂在表头。宽度先用屏幕宽兜底 —— viewDidLoad 里 tableView 还没被布局，
    // 拿 bounds 可能是 0；真正的宽度在 viewDidLayoutSubviews 里补正。
    CGFloat w0 = UIScreen.mainScreen.bounds.size.width;
    self.stage = [[SLVListPreviewHeader alloc] initWithFrame:CGRectMake(0, 0, w0, SLVStageHeight())];
    self.tableView.tableHeaderView = self.stage;

    [self sl_reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self sl_reload];
    [self sl_refreshStage];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // 页面走了就停解码，不然缩到后台还在跑 AVPlayer
    [self.stage sl_pause];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = CGRectGetWidth(self.tableView.bounds);
    if (w > 0.0 && fabs(CGRectGetWidth(self.stage.frame) - w) > 0.5) {
        self.stage.frame = CGRectMake(0, 0, w, SLVStageHeight());
        // tableHeaderView 必须重新赋值一次，表格才会重新量它的高度
        self.tableView.tableHeaderView = self.stage;
    }
}

/// 把预览台切到「当前素材」。没有素材时切成空台。
- (void)sl_refreshStage {
    [self.stage sl_showItem:[SLVMediaStore currentItem] autoplay:YES];
}

- (void)sl_reload {
    self.items = [SLVMediaStore allItems];
    [self.tableView reloadData];
}

- (void)sl_done {
    SLVCloseHostingPanel(self);
}

// 胶囊移除后，设置面板的入口挪到这里：单击球 → 素材页 → 左上角齿轮 → 设置。
- (void)sl_openSettings {
    UIViewController *host = self.presentingViewController;
    if (!host) return;
    [SLVFloatPanelController dismissSettings];
    SLVPresentSettingsWhenFree(host, 0);
}

- (void)sl_pick {
    // 小框要贴着「＋」展开。锚点是导航栏里那颗胶囊的自定义视图，
    // 菜单本身由 SLVMediaAdder 挂到导航控制器的视图上（表格会滚，挂表格上会跟着跑）。
    UIView *anchor = self.navigationItem.rightBarButtonItems.lastObject.customView;

    __weak typeof(self) ws = self;
    [SLVMediaListController presentAddMenuFrom:self anchor:anchor completion:^(BOOL added) {
        (void)added;
        [ws sl_reload];
        // 导入完会自动选中新素材，预览台跟着换过去，不用再点一次
        [ws sl_refreshStage];
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
        return @"点一行就切过去并在上面播放。左滑可取消替换或删除。";
    }
    return @"还没有素材。点右上角「＋」选一段视频或一张图片，它会替换摄像头画面。";
}

- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip {
    (void)tv; (void)ip;
    cell.backgroundColor = SLVGlassCellColor();
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *rid = @"media";
    SLVMediaCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (!cell) cell = [[SLVMediaCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid];

    SLVMediaItem *it = self.items[ip.row];
    BOOL cur = [[SLVMediaStore currentItem].fileName isEqualToString:it.fileName];
    [cell sl_configureWith:it current:cur];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row >= (NSInteger)self.items.count) return;
    SLVMediaItem *it = self.items[ip.row];
    BOOL cur = [[SLVMediaStore currentItem].fileName isEqualToString:it.fileName];

    // 0.3.3：点行 = 切过去 + 在上面播放。「再点一次取消替换」挪到左滑菜单 ——
    // 同一个点击既要「换片」又要「取消」，两者会打架：点了想预览，结果把替换取消了。
    if (!cur) {
        [SLVMediaStore setCurrentItem:it];
        SLVCamReloadAll();          // 顺带发配置变更通知，设置页的摘要会跟着变
        SLVToast(@"已切换");
        [tv reloadData];
    }
    [self.stage sl_showItem:it autoplay:YES];
    if (cur) [self.stage sl_replay];   // 点已经选中的那行 = 从头再放一遍
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv
trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    (void)tv;
    if (ip.row >= (NSInteger)self.items.count) return nil;
    SLVMediaItem *it = self.items[ip.row];
    __weak typeof(self) ws = self;

    NSMutableArray<UIContextualAction *> *acts = [NSMutableArray array];

    // 「取消替换」只在当前素材那一行出现 —— 别的行本来就没被替换，给了也是误导
    BOOL cur = [[SLVMediaStore currentItem].fileName isEqualToString:it.fileName];
    if (cur) {
        UIContextualAction *off =
            [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                    title:@"取消替换"
                                                  handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            (void)a; (void)v;
            [SLVMediaStore setCurrentItem:nil];
            SLVCamReloadAll();
            [ws sl_reload];
            [ws sl_refreshStage];
            SLVToast(@"已取消");
            done(YES);
        }];
        off.backgroundColor = [UIColor systemOrangeColor];
        [acts addObject:off];
    }

    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                     title:@"删除"
                                                                   handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        (void)a; (void)v;
        [SLVMediaStore removeItem:it];
        [SLVThumbCache() removeObjectForKey:it.fileName];
        [ws sl_reload];
        [ws sl_refreshStage];
        SLVCamReloadAll();
        done(YES);
    }];
    [acts addObject:del];

    return [UISwipeActionsConfiguration configurationWithActions:acts];
}

@end
