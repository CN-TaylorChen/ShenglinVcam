#import "SLLogViewController.h"
#import "SLLog.h"
#import "SLGlass.h"

@interface SLVLogViewController ()
@property (nonatomic, strong) UITextView *tv;             // 日志正文（主区）
@property (nonatomic, strong) UIView *statusCard;         // 钩子状态卡（默认 1 行，可展开）
@property (nonatomic, strong) UILabel *statusLabel;       // 「已装钩子 N 个」1 行
@property (nonatomic, strong) UITextView *statusDetail;   // 展开后的完整方法列表
@property (nonatomic, strong) NSLayoutConstraint *statusDetailHeight;
@property (nonatomic, assign) BOOL statusExpanded;
@property (nonatomic, copy) NSString *fullSummary;
@property (nonatomic, assign) NSInteger hookCount;
@end

@implementation SLVLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"运行日志";

    // v0.4.50：跟设置页统一材质。原来这里是实心 systemBackground 的纯白页，
    // 从毛玻璃设置页点进来像跳到了另一个 App；现在铺超薄毛玻璃 + 胶囊标题 + 胶囊按钮。
    SLVInstallGlassBackdrop(self.view);
    self.navigationItem.titleView = SLVPillTitleView(@"运行日志");
    SLVInstallPillBack(self);   // v0.4.53：系统返回键换胶囊，否则这一页顶部只有右边三颗胶囊
    self.navigationItem.rightBarButtonItems = @[
        SLVPillBarItem(@"刷新", self, @selector(sl_reload)),
        SLVPillBarItem(@"复制", self, @selector(sl_copy)),
        SLVPillBarItem(@"清空", self, @selector(sl_clear))
    ];

    // v0.4.69：钩子状态收成 1 行（点开才展开完整列表），把整块屏幕让给日志正文。
    // 之前状态卡高度没有约束（只有内部 textView 的固定高、没有把卡片底边钉住），
    // 状态卡会抢满整屏、把日志卡挤成底部一条空框 —— 就是「日志本体没了 + 最下面还有个框」的根因。
    self.statusCard = [[UIView alloc] initWithFrame:CGRectZero];
    self.statusCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusCard.backgroundColor = SLVGlassCellColor();
    self.statusCard.layer.cornerRadius = 12.0;
    self.statusCard.layer.cornerCurve = kCACornerCurveContinuous;
    [self.view addSubview:self.statusCard];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.statusLabel.textColor = [UIColor labelColor];
    self.statusLabel.numberOfLines = 1;
    self.statusLabel.userInteractionEnabled = YES;
    [self.statusLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(sl_toggleStatus)]];
    [self.statusCard addSubview:self.statusLabel];

    self.statusDetail = [[UITextView alloc] initWithFrame:CGRectZero];
    self.statusDetail.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusDetail.editable = NO;
    self.statusDetail.selectable = NO;
    self.statusDetail.scrollEnabled = YES;
    self.statusDetail.font = [UIFont systemFontOfSize:11];
    self.statusDetail.textColor = [UIColor secondaryLabelColor];
    self.statusDetail.backgroundColor = [UIColor clearColor];
    self.statusDetail.textContainerInset = UIEdgeInsetsMake(0, 0, 0, 0);
    self.statusDetail.hidden = YES;
    [self.statusCard addSubview:self.statusDetail];

    // 日志正文（主区）：占满状态卡以外的全部空间，可滚动
    self.tv = [[UITextView alloc] initWithFrame:CGRectZero];
    self.tv.translatesAutoresizingMaskIntoConstraints = NO;
    self.tv.editable = NO;
    self.tv.scrollEnabled = YES;
    self.tv.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    self.tv.textColor = [UIColor labelColor];
    self.tv.backgroundColor = [UIColor clearColor];
    self.tv.alwaysBounceVertical = YES;

    UIView *logCard = [[UIView alloc] initWithFrame:CGRectZero];
    logCard.translatesAutoresizingMaskIntoConstraints = NO;
    logCard.backgroundColor = SLVGlassCellColor();
    logCard.layer.cornerRadius = 12.0;
    logCard.layer.cornerCurve = kCACornerCurveContinuous;
    [self.view addSubview:logCard];
    [logCard addSubview:self.tv];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    self.statusDetailHeight = [self.statusDetail.heightAnchor constraintEqualToConstant:0];

    [NSLayoutConstraint activateConstraints:@[
        [self.statusCard.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.statusCard.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.statusCard.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],

        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.statusCard.leadingAnchor constant:12],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.statusCard.trailingAnchor constant:-12],
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.statusCard.topAnchor constant:10],
        [self.statusLabel.heightAnchor constraintEqualToConstant:28],

        [self.statusDetail.leadingAnchor constraintEqualToAnchor:self.statusCard.leadingAnchor constant:12],
        [self.statusDetail.trailingAnchor constraintEqualToAnchor:self.statusCard.trailingAnchor constant:-12],
        [self.statusDetail.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:6],
        self.statusDetailHeight,
        [self.statusDetail.bottomAnchor constraintEqualToAnchor:self.statusCard.bottomAnchor constant:-10],

        [logCard.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [logCard.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [logCard.topAnchor constraintEqualToAnchor:self.statusCard.bottomAnchor constant:10],
        [logCard.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],

        [self.tv.leadingAnchor constraintEqualToAnchor:logCard.leadingAnchor constant:10],
        [self.tv.trailingAnchor constraintEqualToAnchor:logCard.trailingAnchor constant:-10],
        [self.tv.topAnchor constraintEqualToAnchor:logCard.topAnchor constant:8],
        [self.tv.bottomAnchor constraintEqualToAnchor:logCard.bottomAnchor constant:-8]
    ]];

    [self sl_reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 状态是实时变的（去开一下相机，待命就变替换中），回到这一页要重新取一次。
    // 只刷状态卡、不重读日志正文 —— 否则滚动位置会被顶回底部。
    [self sl_refreshStatus];
}

- (void)sl_toggleStatus {
    self.statusExpanded = !self.statusExpanded;
    self.statusDetail.hidden = !self.statusExpanded;
    self.statusDetailHeight.constant = self.statusExpanded ? 168 : 0;
    [self sl_updateStatusLabel];
    [UIView animateWithDuration:0.22 animations:^{
        [self.view layoutIfNeeded];
    }];
}

- (void)sl_updateStatusLabel {
    NSString *arrow = self.statusExpanded ? @"▾" : @"▸";
    NSString *hint = self.statusExpanded ? @"轻点收起" : @"轻点展开";
    NSString *state = SLVHookStateShort();
    if (self.hookCount > 0) {
        self.statusLabel.text = [NSString stringWithFormat:@"%@ 已装钩子 %ld 个 · %@（%@）",
                                 arrow, (long)self.hookCount, state, hint];
    } else {
        // 0 个有两种情况（根本没装上 / 装上了但一个都没命中），靠 state 区分，
        // 不再像以前那样一律说「未装上」。
        self.statusLabel.text = [NSString stringWithFormat:@"%@ %@（%@）", arrow, state, hint];
    }
}

// 只刷状态卡，不碰日志正文。
//
// 0.3.10：原来这里靠解析 SLVHookStatusSummary() 的字符串数个数 —— 找「已装钩子：」
// 前缀、再按两个空格切分。那个格式早就不存在了（现在返回「替换中 · N 个方法」），
// 前缀永远对不上，于是数量恒为 0，标题行永远显示「未装上钩子」，
// 跟展开后写着的「替换中 · 2 个方法」自相矛盾。
// 现在直接问 SLVHookCount() 要数字，不再猜字符串。
- (void)sl_refreshStatus {
    NSString *summary = @"没有装上任何钩子（类名/方法签名不匹配，把日志发给开发者）";
    @try { NSString *s = SLVHookStatusSummary(); if (s.length) summary = s; } @catch (NSException *e) { }
    self.fullSummary = summary;

    NSInteger n = 0;
    @try { n = SLVHookCount(); } @catch (NSException *e) { n = 0; }
    self.hookCount = n;

    self.statusDetail.text = [NSString stringWithFormat:@"%@\n\n文件：%@",
                              summary.length ? summary : @"(无)", [SLVLog filePath] ?: @"(不可写)"];
    [self sl_updateStatusLabel];
}

- (void)sl_reload {
    [self sl_refreshStatus];

    self.tv.text = [SLVLog tailLines:400] ?: @"(暂无日志)";
    if (self.tv.text.length > 1) {
        [self.tv scrollRangeToVisible:NSMakeRange(self.tv.text.length - 1, 1)];
    }
}

- (void)sl_copy {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    pb.string = [NSString stringWithFormat:@"%@\n文件：%@\n---\n%@",
                 self.fullSummary ?: @"", [SLVLog filePath] ?: @"", self.tv.text ?: @""];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"已复制"
                                                               message:@"粘贴给开发者即可定位问题"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)sl_clear {
    [SLVLog clear];
    [self sl_reload];
}

@end
