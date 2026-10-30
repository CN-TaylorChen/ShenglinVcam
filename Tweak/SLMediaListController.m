//
//  SLMediaListController.m
//  声临 · 虚拟摄像头 —— 素材列表页
//
//  外观沿用项目里那套：玻璃表格 + 胶囊标题 + 胶囊「＋」+ 段尾说明。
//  只做素材的增删选，不碰解码 / 注入 —— 那部分在 SLCamFeed / SLCamInject。
//
//  0.2.20：
//    · 每行带缩略图（图片直接缩，视频抽第 0 帧），异步生成 + NSCache
//    · 「＋」变成一个三选一菜单：相册视频 / 相册图片 / 文件导入
//    · 导入完自动选中（在 SLMediaStore 里做），列表最新的排最上面
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

#pragma mark - 添加素材（相册 / 文件）

/// 相册和文件两个 picker 的 delegate 都放在这个单例上。
/// 放控制器里不行：picker 是 present 出来的，控制器在浮窗里随时可能被关掉。
@interface SLMediaAdder : NSObject <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, copy, nullable) void (^completion)(BOOL added);
@property (nonatomic, assign) BOOL wantsVideo;
+ (instancetype)shared;
- (void)presentMenuFrom:(UIViewController *)host completion:(nullable void (^)(BOOL))completion;
@end

@implementation SLMediaAdder

+ (instancetype)shared {
    static SLMediaAdder *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[SLMediaAdder alloc] init]; });
    return s;
}

- (void)presentMenuFrom:(UIViewController *)host completion:(void (^)(BOOL))completion {
    if (!host) return;
    self.completion = completion;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) ws = self;

    [sheet addAction:[UIAlertAction actionWithTitle:@"从相册选视频"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { [ws pickPhotosFrom:host video:YES]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"从相册选图片"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { [ws pickPhotosFrom:host video:NO]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"从文件导入"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { [ws pickFilesFrom:host]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    // 弹窗形态下没有 anchor 会直接崩，必须给一个
    sheet.popoverPresentationController.sourceView = host.view;
    sheet.popoverPresentationController.sourceRect = host.view.bounds;
    [host presentViewController:sheet animated:YES completion:nil];
}

- (void)pickPhotosFrom:(UIViewController *)host video:(BOOL)video {
    self.wantsVideo = video;
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.filter = video ? [PHPickerFilter videosFilter] : [PHPickerFilter imagesFilter];
    cfg.selectionLimit = 1;
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
    dp.allowsMultipleSelection = NO;
    [host presentViewController:dp animated:YES completion:nil];
}

#pragma mark 相册

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!results.count) return;

    NSItemProvider *p = results.firstObject.itemProvider;
    NSString *typeId = self.wantsVideo ? UTTypeMovie.identifier : UTTypeImage.identifier;
    if (![p hasItemConformingToTypeIdentifier:typeId]) {
        SLToast(self.wantsVideo ? @"这个文件不是视频" : @"这个文件不是图片");
        return;
    }

    SLToast(@"正在导入…");   // 大文件要几秒，给个反馈
    __weak typeof(self) ws = self;
    [p loadFileRepresentationForTypeIdentifier:typeId
                             completionHandler:^(NSURL *url, NSError *err) {
        if (!url) {
            SLLog(@"导入: 相册导出失败 %@", err.localizedDescription ?: @"?");
            SLToast(@"相册导出失败，换一个试试");
            return;
        }
        [ws importURL:url];
    }];
}

#pragma mark 文件

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    SLToast(@"正在导入…");
    [self importURL:url];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller;
}

#pragma mark 落地

- (void)importURL:(NSURL *)url {
    // 这个 URL 指向**临时文件**，handler 一返回就可能被清理。
    // 以前是先 dispatch 到主线程再拷，主线程忙或文件大时文件已经没了 ——
    // 表现就是「有的视频导入失败」。必须在这里就拷走。
    NSError *e = nil;
    BOOL dup = NO;
    SLMediaItem *it = [SLMediaStore importItemAtURL:url error:&e duplicate:&dup];
    NSString *reason = e.localizedDescription;
    BOOL isImage = it.isImage;
    void (^done)(BOOL) = self.completion;
    self.completion = nil;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (it) {
            [SLThumbCache() removeAllObjects];
            SLCamReloadAll();
            if (dup) {
                SLToast(@"这份素材已经在库里，已切到它");
            } else {
                SLToast(isImage ? @"已加入图片，画面已定格" : @"已加入视频");
            }
            if (done) done(YES);
        } else {
            SLLog(@"导入: 保存失败 %@", reason ?: @"?");
            SLToast(reason.length ? reason : @"导入失败，换一个试试");
            if (done) done(NO);
        }
    });
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

+ (void)presentAddMenuFrom:(UIViewController *)host completion:(void (^)(BOOL))completion {
    [[SLMediaAdder shared] presentMenuFrom:host completion:completion];
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
    __weak typeof(self) ws = self;
    [SLMediaListController presentAddMenuFrom:self completion:^(BOOL added) {
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
        return @"新添加的素材自动选中并排在最上面。视频循环播放，图片定格不动。左滑可以删除。";
    }
    return @"还没有素材。点右上角「＋」从相册或文件里选一段视频 / 一张图片，它会替换摄像头画面。";
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
        SLToast(@"已取消替换 · 恢复真实摄像头");
    } else {
        [SLMediaStore setCurrentItem:it];
        SLToast(it.isImage ? @"已切换 · 画面定格在这张图" : @"已切换素材");
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
