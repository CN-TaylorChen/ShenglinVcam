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

#define SLVVersion @"0.3.1"

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

#pragma mark - 「当前素材」右侧长文本：跑马灯

// Value1 布局里 detailTextLabel 是右对齐的，文字一长就从左边溢出压到标题上 ——
// 系统只在「放得下」时才保证避让。0.3.0 曾把它改成 Subtitle 两行，但那一行的信息量
// 配不上一整行高度，观感太散。0.3.1 回到单行，改成：左侧标题不动，右侧给一块会被
// 裁切的容器，放不下就慢慢往左滚，两端做渐隐，永远碰不到标题。
@interface SLVMarqueeView : UIView
@property (nonatomic, copy) NSString *text;
@end

@implementation SLVMarqueeView {
    UILabel *_label;
    CAGradientLayer *_fade;
    CGFloat _laidWidth;
    NSString *_laidText;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.clipsToBounds = YES;
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];

        _label = [[UILabel alloc] initWithFrame:CGRectZero];
        _label.font = [UIFont systemFontOfSize:15];
        _label.textColor = [UIColor secondaryLabelColor];
        _label.numberOfLines = 1;
        _label.lineBreakMode = NSLineBreakByClipping;   // 裁切交给容器，不走省略号
        [self addSubview:_label];

        // 两端渐隐。硬切在标题边上会像「字从标题里长出来」。
        _fade = [CAGradientLayer layer];
        _fade.colors = @[(__bridge id)[UIColor clearColor].CGColor,
                         (__bridge id)[UIColor blackColor].CGColor,
                         (__bridge id)[UIColor blackColor].CGColor,
                         (__bridge id)[UIColor clearColor].CGColor];
        _fade.startPoint = CGPointMake(0.0, 0.5);
        _fade.endPoint = CGPointMake(1.0, 0.5);
        self.layer.mask = _fade;
    }
    return self;
}

- (void)setText:(NSString *)text {
    _text = [text copy];
    _label.text = _text;
    [self sl_relayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _fade.frame = self.bounds;
    [self sl_relayout];
}

- (void)sl_relayout {
    CGFloat w = CGRectGetWidth(self.bounds), h = CGRectGetHeight(self.bounds);
    if (w <= 0.0 || h <= 0.0) return;
    // layoutSubviews 会被频繁调到，每次重挂动画会让滚动一顿一顿的
    if (fabs(w - _laidWidth) < 0.5 && [_laidText isEqualToString:(_text ?: @"")]) return;
    _laidWidth = w;
    _laidText = [_text copy];

    [_label.layer removeAnimationForKey:@"slMarquee"];
    _label.transform = CGAffineTransformIdentity;

    CGSize s = [_label sizeThatFits:CGSizeMake(CGFLOAT_MAX, h)];
    CGFloat lw = s.width;
    if (lw <= w) {
        // 放得下就右对齐，跟原生 Value1 一模一样，也不需要渐隐
        _label.frame = CGRectMake(w - lw, (h - s.height) / 2.0, lw, s.height);
        _fade.locations = @[@0, @0, @1, @1];
        return;
    }

    _label.frame = CGRectMake(0.0, (h - s.height) / 2.0, lw, s.height);
    CGFloat fade = MIN(13.0, w * 0.25);
    _fade.locations = @[@0, @(fade / w), @(1.0 - fade / w), @1];

    // 停 → 滚 → 停 → 回开头。滚完瞬跳是跑马灯的常规做法，
    // 中间再插淡入淡出会让人以为内容换了。
    CGFloat overflow = lw - w;
    CGFloat move = MAX(1.6, overflow / 26.0);   // 26pt/s，再快就看不清
    CGFloat pause = 1.1;
    CGFloat total = pause * 2.0 + move;

    CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    a.values = @[@0.0, @0.0, @(-overflow), @(-overflow)];
    a.keyTimes = @[@0.0, @(pause / total), @((pause + move) / total), @1.0];
    a.timingFunctions = @[[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut],
                          [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear],
                          [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear]];
    a.duration = total;
    a.repeatCount = HUGE_VALF;
    a.fillMode = kCAFillModeBoth;
    a.removedOnCompletion = NO;
    [_label.layer addAnimation:a forKey:@"slMarquee"];
}
@end

// 右侧箭头仍然用系统那个（accessoryType），只有详情文字换成自己的滚动容器。
// detailTextLabel 留空，这样 Value1 的布局不会再去摆一块文字。
@interface SLVScrollValueCell : UITableViewCell
@property (nonatomic, strong) SLVMarqueeView *valueView;
@end

@implementation SLVScrollValueCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    self = [super initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:rid];
    if (self) {
        _valueView = [[SLVMarqueeView alloc] initWithFrame:CGRectZero];
        [self.contentView addSubview:_valueView];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = CGRectGetHeight(self.contentView.bounds);
    if (h <= 0.0) return;
    // 用标题的固有宽度算左边界，不用 textLabel.frame —— 后者在 Value1 下可能被拉得很宽
    CGFloat titleX = CGRectGetMinX(self.textLabel.frame);
    CGFloat titleW = [self.textLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, h)].width;
    CGFloat left = titleX + titleW + 10.0;
    CGFloat right = CGRectGetWidth(self.contentView.bounds) - 6.0;
    CGFloat w = right - left;
    self.valueView.hidden = (w < 40.0);
    if (!self.valueView.hidden) self.valueView.frame = CGRectMake(left, 0.0, w, h);
}

@end

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

    // 0.3.0 一度改成无底色的紧凑版，结果球和标题栏长得不一样，而且 24pt 明显偏大。
    // 0.3.1 退回带黑底圆的那张（0.2.28 的样子），尺寸也退回 22pt；
    // 只保留「后框裁切」这一处修正 —— 否则小尺寸下两个框会糊成 |||。
    CGFloat iconSide = 22.0;
    UIImageView *icon = [[UIImageView alloc] initWithImage:SLVBrandIconImage(iconSide)];
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

- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip {
    (void)tv; (void)ip;
    cell.backgroundColor = SLVGlassCellColor();
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    // 「当前素材」右侧要显示「1 个 · 完整文件名」，用专门会滚的那一格。
    BOOL scrollRow = (ip.section == 1 && ip.row == 0);
    static NSString *ridValue  = @"slcell";
    static NSString *ridScroll = @"slcell_scroll";
    NSString *rid = scrollRow ? ridScroll : ridValue;
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (!cell) {
        cell = scrollRow
            ? (UITableViewCell *)[[SLVScrollValueCell alloc] initWithStyle:UITableViewCellStyleValue1
                                                           reuseIdentifier:rid]
            : [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:rid];
    }

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
            // 不走 detailTextLabel：它的右对齐在长文本下会从左边溢出压到标题上。
            ((SLVScrollValueCell *)cell).valueView.text = SLVCamStatusSummary();
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
