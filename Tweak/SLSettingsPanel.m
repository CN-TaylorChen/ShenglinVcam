//
//  SLVSettingsPanel.m
//  声临 · 虚拟摄像头 —— 设置页
//
//  外观照抄声临那套：玻璃表格 + 胶囊标题（品牌图标 + 名字 + 版本号）+ 胶囊「完成」+
//  左对齐的分组标题 / 多行说明。所有材质都来自 SLVGlass，别在这里写死颜色。
//
//  底包只有四组，套用时按需加行 —— 加行只动三个方法：
//    numberOfRowsInSection / cellForRowAtIndexPath / didSelectRowAtIndexPath。
//  0.2.2 起「画面」组多了旋转一行、「声音」组独立出来放音频开关。
//

#import "SLSettingsPanel.h"
#import "SLFloatingBall.h"
#import "SLGlass.h"
#import "SLAlignBox.h"
#import "SLMediaListController.h"
#import "SLMediaStore.h"
#import "SLMediaPreview.h"
#import "SLCamBridge.h"
#import "SLUtil.h"
#import "SLLogViewController.h"
#import "SLLog.h"

#define SLVVersion @"0.3.0"

// kSLCamLoopKey / kSLCamMirrorKey 现在由 SLVCamCore.m 统一导出（SLVCamBridge.h 里 extern），
// 帧源要读同样的键，不能再各定义一份 static。

#pragma mark - 分组标题 / 说明：统一左基线

// 只读已存在的 cell，绝不调 rectForRowAtIndexPath —— 那个 API 会回调
// heightForFooterInSection，再回来取这个值就死循环了。
static CGFloat SLVMeasureLeading(UITableView *tv) {
    for (UITableViewCell *c in tv.visibleCells) {
        UILabel *lab = c.textLabel;
        if (!lab || lab.hidden || !lab.text.length) continue;
        if (c.imageView.image) continue;
        CGFloat x = CGRectGetMinX(c.frame) + CGRectGetMinX(lab.frame);
        if (x > 0) return x;
    }
    return 36;
}

static UIView *SLVMakeHeader(NSString *text, CGFloat x, CGFloat width) {
    return SLVAlignHeader(text, x, width);
}

static UIView *SLVMakeFooter(NSString *text, CGFloat x, CGFloat width) {
    return SLVAlignFooter(text, x, width);
}

@interface SLVSettingsPanel ()
@property (nonatomic, assign) CGFloat slLeading;
@end

@implementation SLVSettingsPanel

- (instancetype)init {
    // insetGrouped：自带 16pt 边距和每组首尾圆角，等于系统原生设置卡片
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"设置";
    self.navigationItem.titleView = [self sl_titleView];
    self.navigationItem.rightBarButtonItem = SLVPillBarItem(@"完成", self, @selector(sl_close));
    SLVApplyGlassTable(self.tableView);
    self.tableView.estimatedSectionFooterHeight = 28;
    self.tableView.estimatedSectionHeaderHeight = 26;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

// 标题栏 = 品牌图标 + 名字 + 11pt 版本号，外面套一枚毛玻璃胶囊
- (UIView *)sl_titleView {
    CGFloat H = 32.0;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 100, H)];

    // 0.3.0：这里原来用的是 SLVBrandIconImage（黑底圆盘那张）。那张图在小尺寸下
    // 圆底和两个框叠在一起，缩到 22pt 就是一坨黑块 —— 标题栏的 logo「乱了」就是这个。
    // 换成无底色的紧凑版，线条跟着 labelColor 走，深浅色模式都对。
    CGFloat iconSide = 24.0;
    UIImageView *icon = [[UIImageView alloc] initWithImage:SLVBrandGlyphImage(iconSide, [UIColor labelColor])];
    icon.frame = CGRectMake(0, (H - iconSide) / 2.0, iconSide, iconSide);
    icon.contentMode = UIViewContentModeCenter;
    [box addSubview:icon];

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
    name.text = @"声临 · 虚拟摄像头";
    name.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    name.textColor = [UIColor labelColor];
    [name sizeToFit];

    UILabel *ver = [[UILabel alloc] initWithFrame:CGRectZero];
    ver.text = [NSString stringWithFormat:@"v%@", SLVVersion];
    ver.font = [UIFont systemFontOfSize:11];
    ver.textColor = [UIColor secondaryLabelColor];
    [ver sizeToFit];

    CGFloat padX = 10.0, gap = 5.0;
    CGFloat innerW = name.frame.size.width + gap + ver.frame.size.width;
    CGFloat pillW = innerW + padX * 2.0;
    CGFloat pillX = 28.0;
    UIVisualEffectView *pill = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
    pill.frame = CGRectMake(pillX, 0, pillW, H);
    pill.layer.cornerRadius = H / 2.0;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    pill.layer.masksToBounds = YES;
    pill.layer.borderWidth = 0.8;
    pill.layer.borderColor = SLVGlassHairlineColor().CGColor;
    [box addSubview:pill];

    name.frame = CGRectMake(padX, (H - name.frame.size.height) / 2.0, name.frame.size.width, name.frame.size.height);
    [pill.contentView addSubview:name];
    ver.frame = CGRectMake(padX + name.frame.size.width + gap,
                           (H - ver.frame.size.height) / 2.0,
                           ver.frame.size.width, ver.frame.size.height);
    [pill.contentView addSubview:ver];

    box.frame = CGRectMake(0, 0, pillX + pillW, H);
    return box;
}

- (void)sl_close {
    SLVCloseHostingPanel(self);
}

- (CGFloat)sl_leadingForTableView:(UITableView *)tv {
    if (self.slLeading <= 0) self.slLeading = SLVMeasureLeading(tv);
    return self.slLeading;
}

#pragma mark - 存储

static BOOL SLVBoolForKey(NSString *key, BOOL def) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return v ? [v boolValue] : def;
}

static void SLVSetBool(NSString *key, BOOL v) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:v forKey:key];
    [d synchronize];
}

/// 旋转值只认 0/90/180/270，脏数据一律当 0
static NSInteger SLVRotationValue(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:kSLCamRotateKey];
    NSInteger r = v ? [v integerValue] : 0;
    r %= 360;
    if (r < 0) r += 360;
    return (r == 90 || r == 180 || r == 270) ? r : 0;
}

static void SLVSetRotation(NSInteger deg) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:deg forKey:kSLCamRotateKey];
    [d synchronize];
}

static NSString *SLVRotationSummary(void) {
    NSInteger r = SLVRotationValue();
    return r == 0 ? @"不旋转" : [NSString stringWithFormat:@"顺时针 %ld°", (long)r];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    (void)tv;
    return 5;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    (void)tv;
    if (section == 0) return 2;   // 启用 + 悬浮球图标
    if (section == 1) return 2;   // 当前素材 + 预览素材
    if (section == 2) return 3;   // 循环 + 镜像 + 旋转
    if (section == 3) return 1;   // 音频
    return 1;                     // 运行日志
}

- (NSString *)sl_headerForSection:(NSInteger)section {
    return @[@"基本设置", @"素材", @"画面", @"声音", @"诊断"][section];
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)section {
    return SLVMakeHeader([self sl_headerForSection:section],
                        [self sl_leadingForTableView:tv], tv.bounds.size.width);
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)section {
    (void)tv;
    return section == 0 ? 26 : 22;
}

- (NSString *)sl_footerForSection:(NSInteger)section {
    if (section == 0) return @"关掉后胶囊不再展开，长按球仍可进设置。";
    if (section == 1) return @"导入后自动选中。视频循环播放，图片定格不动。";
    if (section == 2) return @"旋转按顺时针计算，画面会铺满取景框、多出来的部分居中裁掉。";
    if (section == 3) return @"关掉后麦克风会被静音，不会录入环境声。素材没有音轨时同样生效。";
    return nil;
}

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)section {
    NSString *text = [self sl_footerForSection:section];
    if (!text.length) return nil;
    return SLVMakeFooter(text, [self sl_leadingForTableView:tv], tv.bounds.size.width);
}

- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)section {
    NSString *text = [self sl_footerForSection:section];
    if (!text.length) return 16.0;   // 没文案时纯当分组间距，返回 0 会让两组贴在一起
    CGFloat w = tv.bounds.size.width - 68;
    if (w <= 0) return UITableViewAutomaticDimension;
    CGRect r = [text boundingRectWithSize:CGSizeMake(w, CGFLOAT_MAX)
                                  options:NSStringDrawingUsesLineFragmentOrigin
                               attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12]}
                                  context:nil];
    return ceil(r.size.height) + 14;
}

// 「当前素材」是 Subtitle 两行，要留出第二行的高度；其余行保持系统默认的 44。
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    (void)tv;
    if (ip.section == 1 && ip.row == 0) return 62.0;
    return 44.0;
}

- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip {
    (void)tv; (void)ip;
    cell.backgroundColor = SLVGlassCellColor();
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    // 「当前素材」右侧要显示「1 个 · 完整文件名」，Value1 布局下详情一长就跟左边的
    // 「当前素材」撞在一起（系统只在文字放得下时才保证避让，右对齐的标签一旦被压窄，
    // 文字会从左边溢出到标题上）。这一行改用 Subtitle：值单独占第二行，怎么长都不会重叠。
    BOOL subtitle = (ip.section == 1 && ip.row == 0);
    static NSString *ridValue = @"slcell";
    static NSString *ridSub   = @"slcell_sub";
    NSString *rid = subtitle ? ridSub : ridValue;
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:(subtitle ? UITableViewCellStyleSubtitle
                                                               : UITableViewCellStyleValue1)
                                     reuseIdentifier:rid];
    }

    cell.detailTextLabel.textAlignment = subtitle ? NSTextAlignmentLeft : NSTextAlignmentRight;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:subtitle ? 13 : 15];
    cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.detailTextLabel.text = nil;
    cell.textLabel.textColor = [UIColor labelColor];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    UISwitch *sw = nil;
    if (ip.section == 0) {
        if (ip.row == 0) {
            cell.textLabel.text = @"启用虚拟摄像头";
            sw = [[UISwitch alloc] init];
            sw.on = SLVCamEnabled();
            [sw addTarget:self action:@selector(sl_enabledChanged:) forControlEvents:UIControlEventValueChanged];
        } else {
            cell.textLabel.text = @"悬浮球图标";
            cell.detailTextLabel.text = SLVFloatIconSummary();
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if (ip.section == 1) {
        if (ip.row == 0) {
            cell.textLabel.text = @"当前素材";
            cell.detailTextLabel.text = SLVCamStatusSummary();
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            // 预览素材：右侧直接给结论，不用点进去才知道有没有声音。
            // 添加素材不在这里再放一份 —— 素材页的「＋」已经是入口了，两处重复。
            cell.textLabel.text = @"预览素材";
            cell.textLabel.textColor = [UIColor systemBlueColor];
            cell.detailTextLabel.text = SLVMediaAudioSummary();
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if (ip.section == 2) {
        if (ip.row == 2) {
            cell.textLabel.text = @"画面旋转";
            cell.detailTextLabel.text = SLVRotationSummary();
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            BOOL loop = (ip.row == 0);
            cell.textLabel.text = loop ? @"循环播放" : @"镜像画面";
            sw = [[UISwitch alloc] init];
            sw.on = SLVBoolForKey(loop ? kSLCamLoopKey : kSLCamMirrorKey, loop);
            sw.tag = ip.row;
            [sw addTarget:self action:@selector(sl_optionChanged:) forControlEvents:UIControlEventValueChanged];
        }
    } else if (ip.section == 3) {
        cell.textLabel.text = @"替换音频";
        sw = [[UISwitch alloc] init];
        sw.on = SLVBoolForKey(kSLCamAudioKey, YES);
        sw.tag = 2;
        [sw addTarget:self action:@selector(sl_optionChanged:) forControlEvents:UIControlEventValueChanged];
    } else {
        cell.textLabel.text = @"运行日志";
        cell.detailTextLabel.text = SLVHookStatusSummary();
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.accessoryView = sw;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0 && ip.row == 1) {
        [self.navigationController pushViewController:[[SLVFloatIconController alloc] init] animated:YES];
    } else if (ip.section == 1) {
        if (ip.row == 0) {
            [self.navigationController pushViewController:[[SLVMediaListController alloc] init] animated:YES];
        } else {
            [self.navigationController pushViewController:[[SLVMediaPreviewController alloc] init] animated:YES];
        }
    } else if (ip.section == 2 && ip.row == 2) {
        [self sl_pickRotation];
    } else if (ip.section == 4) {
        [self.navigationController pushViewController:[[SLVLogViewController alloc] init] animated:YES];
    }
}

#pragma mark - 旋转

- (void)sl_pickRotation {
    NSArray<NSNumber *> *vals  = @[@0, @90, @180, @270];
    NSArray<NSString *> *names = @[@"不旋转", @"顺时针 90°", @"顺时针 180°", @"顺时针 270°"];
    NSInteger cur = SLVRotationValue();

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"画面旋转"
                                                                  message:@"按顺时针方向调整素材画面"
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger i = 0; i < vals.count; i++) {
        NSInteger v = vals[i].integerValue;
        NSString *title = (v == cur) ? [names[i] stringByAppendingString:@"  ✓"] : names[i];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a) {
            SLVSetRotation(v);
            SLVCamReloadAll();
            [self.tableView reloadData];
            SLVToast(v == 0 ? @"不旋转" : [NSString stringWithFormat:@"%ld°", (long)v]);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    // 弹窗形态下没有 anchor 会直接崩，必须给一个
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 开关

- (void)sl_enabledChanged:(UISwitch *)sw {
    SLVSetBool(kSLCamEnabledKey, sw.on);
    SLVCamReloadAll();
    SLVToast(sw.on ? @"已启用" : @"已关闭");
}

- (void)sl_optionChanged:(UISwitch *)sw {
    // tag：0 = 循环播放，1 = 镜像，2 = 替换音频
    if (sw.tag == 2) {
        SLVSetBool(kSLCamAudioKey, sw.on);
        SLVCamReloadAll();
        SLVToast(sw.on ? @"声音：开" : @"声音：关");
        return;
    }
    SLVSetBool(sw.tag == 0 ? kSLCamLoopKey : kSLCamMirrorKey, sw.on);
    SLVCamReloadAll();   // 让帧源立刻读到新值，不用等重启
}

@end
