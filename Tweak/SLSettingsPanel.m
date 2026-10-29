//
//  SLSettingsPanel.m
//  声临 · 虚拟摄像头 —— 设置页
//
//  外观照抄声临那套：玻璃表格 + 胶囊标题（品牌图标 + 名字 + 版本号）+ 胶囊「完成」+
//  左对齐的分组标题 / 多行说明。所有材质都来自 SLGlass，别在这里写死颜色。
//
//  底包只有四组，套用时按需加行 —— 加行只动三个方法：
//    numberOfRowsInSection / cellForRowAtIndexPath / didSelectRowAtIndexPath。
//

#import "SLSettingsPanel.h"
#import "SLFloatingBall.h"
#import "SLGlass.h"
#import "SLAlignBox.h"
#import "SLMediaListController.h"
#import "SLMediaStore.h"
#import "SLCamBridge.h"
#import "SLUtil.h"
#import "SLLogViewController.h"
#import "SLLog.h"

#define SLVersion @"0.2.1"

// kSLCamLoopKey / kSLCamMirrorKey 现在由 SLCamCore.m 统一导出（SLCamBridge.h 里 extern），
// 帧源要读同样的键，不能再各定义一份 static。

#pragma mark - 分组标题 / 说明：统一左基线

// 只读已存在的 cell，绝不调 rectForRowAtIndexPath —— 那个 API 会回调
// heightForFooterInSection，再回来取这个值就死循环了。
static CGFloat SLMeasureLeading(UITableView *tv) {
    for (UITableViewCell *c in tv.visibleCells) {
        UILabel *lab = c.textLabel;
        if (!lab || lab.hidden || !lab.text.length) continue;
        if (c.imageView.image) continue;
        CGFloat x = CGRectGetMinX(c.frame) + CGRectGetMinX(lab.frame);
        if (x > 0) return x;
    }
    return 36;
}

static UIView *SLMakeHeader(NSString *text, CGFloat x, CGFloat width) {
    return SLAlignHeader(text, x, width);
}

static UIView *SLMakeFooter(NSString *text, CGFloat x, CGFloat width) {
    return SLAlignFooter(text, x, width);
}

@interface SLSettingsPanel ()
@property (nonatomic, assign) CGFloat slLeading;
@end

@implementation SLSettingsPanel

- (instancetype)init {
    // insetGrouped：自带 16pt 边距和每组首尾圆角，等于系统原生设置卡片
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"设置";
    self.navigationItem.titleView = [self sl_titleView];
    self.navigationItem.rightBarButtonItem = SLPillBarItem(@"完成", self, @selector(sl_close));
    SLApplyGlassTable(self.tableView);
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

    UIImageView *icon = [[UIImageView alloc] initWithImage:SLBrandIconImage(44)];
    icon.frame = CGRectMake(0, (H - 22) / 2.0, 22, 22);
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [box addSubview:icon];

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
    name.text = @"声临 · 虚拟摄像头";
    name.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    name.textColor = [UIColor labelColor];
    [name sizeToFit];

    UILabel *ver = [[UILabel alloc] initWithFrame:CGRectZero];
    ver.text = [NSString stringWithFormat:@"v%@", SLVersion];
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
    pill.layer.borderColor = SLGlassHairlineColor().CGColor;
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
    SLCloseHostingPanel(self);
}

- (CGFloat)sl_leadingForTableView:(UITableView *)tv {
    if (self.slLeading <= 0) self.slLeading = SLMeasureLeading(tv);
    return self.slLeading;
}

#pragma mark - 存储

static BOOL SLBoolForKey(NSString *key, BOOL def) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return v ? [v boolValue] : def;
}

static void SLSetBool(NSString *key, BOOL v) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:v forKey:key];
    [d synchronize];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    (void)tv;
    return 4;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    (void)tv;
    if (section == 0) return 2;   // 启用 + 悬浮球图标
    if (section == 1) return 1;   // 当前素材
    if (section == 2) return 2;   // 循环 + 镜像
    return 1;                     // 运行日志
}

- (NSString *)sl_headerForSection:(NSInteger)section {
    return @[@"基本设置", @"素材", @"画面", @"诊断"][section];
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)section {
    return SLMakeHeader([self sl_headerForSection:section],
                        [self sl_leadingForTableView:tv], tv.bounds.size.width);
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)section {
    (void)tv;
    return section == 0 ? 26 : 22;
}

- (NSString *)sl_footerForSection:(NSInteger)section {
    if (section == 0) return @"关掉后胶囊不再展开，长按球仍可进设置。";
    if (section == 2) return @"这两个开关只负责存值，由注入层读取。";
    return nil;
}

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)section {
    NSString *text = [self sl_footerForSection:section];
    if (!text.length) return nil;
    return SLMakeFooter(text, [self sl_leadingForTableView:tv], tv.bounds.size.width);
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

- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip {
    (void)tv; (void)ip;
    cell.backgroundColor = SLGlassCellColor();
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *rid = @"slcell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:rid];

    cell.detailTextLabel.textAlignment = NSTextAlignmentRight;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:15];
    cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
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
            sw.on = SLCamEnabled();
            [sw addTarget:self action:@selector(sl_enabledChanged:) forControlEvents:UIControlEventValueChanged];
        } else {
            cell.textLabel.text = @"悬浮球图标";
            cell.detailTextLabel.text = SLFloatIconSummary();
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if (ip.section == 1) {
        cell.textLabel.text = @"当前素材";
        cell.detailTextLabel.text = SLCamStatusSummary();
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (ip.section == 2) {
        BOOL loop = (ip.row == 0);
        cell.textLabel.text = loop ? @"循环播放" : @"镜像画面";
        sw = [[UISwitch alloc] init];
        sw.on = SLBoolForKey(loop ? kSLCamLoopKey : kSLCamMirrorKey, loop);
        sw.tag = ip.row;
        [sw addTarget:self action:@selector(sl_optionChanged:) forControlEvents:UIControlEventValueChanged];
    } else {
        cell.textLabel.text = @"运行日志";
        cell.detailTextLabel.text = SLHookStatusSummary();
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.accessoryView = sw;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0 && ip.row == 1) {
        [self.navigationController pushViewController:[[SLFloatIconController alloc] init] animated:YES];
    } else if (ip.section == 1) {
        [self.navigationController pushViewController:[[SLMediaListController alloc] init] animated:YES];
    } else if (ip.section == 3) {
        [self.navigationController pushViewController:[[SLLogViewController alloc] init] animated:YES];
    }
}

#pragma mark - 开关

- (void)sl_enabledChanged:(UISwitch *)sw {
    SLSetBool(kSLCamEnabledKey, sw.on);
    SLCamReloadAll();
    SLToast(sw.on ? @"已启用虚拟摄像头" : @"已关闭，点球不再展开");
}

- (void)sl_optionChanged:(UISwitch *)sw {
    SLSetBool(sw.tag == 0 ? kSLCamLoopKey : kSLCamMirrorKey, sw.on);
    // 业务侧自己读这两个键；底包只负责存，不做任何画面处理
}

@end
