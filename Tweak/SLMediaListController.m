//
//  SLMediaListController.m
//  声临 · 虚拟摄像头 —— 素材列表页
//
//  外观沿用项目里那套：玻璃表格 + 胶囊标题 + 胶囊「＋」+ 段尾说明。
//  只做素材的增删选，不碰解码 / 注入 —— 那部分在 SLCamFeed / SLCamInject。
//

#import "SLMediaListController.h"
#import "SLMediaStore.h"
#import "SLFloatingBall.h"
#import "SLGlass.h"
#import "SLUtil.h"
#import "SLCamBridge.h"
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface SLMediaListController () <PHPickerViewControllerDelegate>
@property (nonatomic, strong) NSArray<SLMediaItem *> *items;
@end

@implementation SLMediaListController

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
    self.tableView.estimatedSectionFooterHeight = 28;
    self.tableView.estimatedSectionHeaderHeight = 26;
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

- (void)sl_pick {
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.filter = [PHPickerFilter videosFilter];
    cfg.selectionLimit = 1;
    PHPickerViewController *vc = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    vc.delegate = self;
    [self presentViewController:vc animated:YES completion:nil];
}

#pragma mark - 相册

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!results.count) return;
    NSItemProvider *p = results.firstObject.itemProvider;
    if (![p hasItemConformingToTypeIdentifier:UTTypeMovie.identifier]) {
        SLToast(@"这个文件不是视频");
        return;
    }
    __weak typeof(self) ws = self;
    [p loadFileRepresentationForTypeIdentifier:UTTypeMovie.identifier
                             completionHandler:^(NSURL *url, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!url) {
                SLToast(@"这段视频读不出来");
                return;
            }
            NSError *e = nil;
            if ([SLMediaStore importFileAtURL:url error:&e]) {
                [ws sl_reload];
                SLCamReloadAll();
                SLToast(@"已加入素材");
            } else {
                SLToast(@"保存失败，换一段试试");
            }
        });
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
    return self.items.count ? @"我的素材" : nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    (void)tv; (void)section;
    if (self.items.count) {
        return @"选中的素材会被循环播放，替换摄像头画面。左滑可以删除。";
    }
    return @"还没有素材。点右上角「＋」从相册选一段视频，它会循环播放、替换摄像头画面。";
}

- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip {
    (void)tv; (void)ip;
    cell.backgroundColor = SLGlassCellColor();
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *rid = @"media";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:rid];
        cell.textLabel.font = [UIFont systemFontOfSize:16];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }
    SLMediaItem *it = self.items[ip.row];
    cell.textLabel.text = it.displayName;
    cell.detailTextLabel.text = it.fileName;
    BOOL cur = [[SLMediaStore currentItem].fileName isEqualToString:it.fileName];
    cell.accessoryType = cur ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row >= (NSInteger)self.items.count) return;
    [SLMediaStore setCurrentItem:self.items[ip.row]];
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
        [ws sl_reload];
        SLCamReloadAll();
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

@end
