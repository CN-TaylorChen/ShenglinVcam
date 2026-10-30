//
//  SLVGlass.m
//  见 SLVGlass.h 的说明：把设置页那套玻璃材质 + 胶囊控件抽成全站基座。
//

#import "SLGlass.h"

#pragma mark - 材质

UIColor *SLVGlassCellColor(void) {
    // 与设置页 / 语音包页同一个数：深色 6% 白提亮，浅色 34% 白压住。
    // 深了会把底下的毛玻璃盖死（看着像白板），浅了文字对比度又不够。
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        return tc.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:1.0 alpha:0.06]
            : [UIColor colorWithWhite:1.0 alpha:0.34];
    }];
}

// 发丝高光边：玻璃的「厚度」全靠这一圈，0.8pt 以上就成画框了。
UIColor *SLVGlassHairlineColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        return tc.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:1.0 alpha:0.16]
            : [UIColor colorWithWhite:1.0 alpha:0.55];
    }];
}

// v0.4.53：导航栏胶囊的底。bar item 里毛玻璃不渲染（见下），只能用动态半透明白顶上，
// 深色 14% / 浅色 60%，压出来的亮度跟设置页那张毛玻璃胶囊基本对得上。
UIColor *SLVGlassPillFillColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        return tc.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:1.0 alpha:0.14]
            : [UIColor colorWithWhite:1.0 alpha:0.60];
    }];
}

// 胶囊外壳：超薄毛玻璃 + 全圆角 + 发丝边，与设置页标题胶囊同一套参数。
static UIVisualEffectView *SLVMakePillShell(CGRect frame) {
    UIVisualEffectView *v = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
    v.frame = frame;
    v.layer.cornerRadius = CGRectGetHeight(frame) / 2.0;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    v.layer.masksToBounds = YES;
    v.layer.borderWidth = 0.8;
    v.layer.borderColor = SLVGlassHairlineColor().CGColor;
    v.userInteractionEnabled = NO;   // 触摸要落到外壳底下的按钮上
    return v;
}

// v0.4.53：导航栏按钮的胶囊底。
// UIVisualEffectView 装进 barButtonItem.customView 是不渲染的（连它 contentView 里的
// 文字都跟着一起没了，v0.4.51 的「按钮没字」就是这么来的；0.4.52 换成容器 + UILabel
// 之后字回来了，但毛玻璃外壳依然不画 —— 于是就成了「有字没胶囊」）。
// 所以 bar item 这一侧改用普通 UIView + 动态半透明白 + 发丝边，视觉上接近毛玻璃，
// 但走的是正常渲染路径，一定能画出来。
static UIView *SLVMakeFlatPill(CGRect frame) {
    UIView *v = [[UIView alloc] initWithFrame:frame];
    v.backgroundColor = SLVGlassPillFillColor();
    v.layer.cornerRadius = CGRectGetHeight(frame) / 2.0;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    v.layer.borderWidth = 0.8;
    v.layer.borderColor = SLVGlassHairlineColor().CGColor;
    v.userInteractionEnabled = NO;   // 点击交给最上层的透明 UIControl
    return v;
}

#pragma mark - 表格 / 页面

void SLVApplyGlassTable(UITableView *tv) {
    if (!tv) return;
    // 表格自身透明，底下的浮窗毛玻璃才能透上来（原来铺 systemGroupedBackground 会全盖住）
    tv.backgroundColor = [UIColor clearColor];
    UIVisualEffectView *veil = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
    tv.backgroundView = veil;
}

UIVisualEffectView *SLVInstallGlassBackdrop(UIView *host) {
    if (!host) return nil;
    host.backgroundColor = [UIColor clearColor];
    UIVisualEffectView *veil = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
    veil.frame = host.bounds;
    veil.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    veil.userInteractionEnabled = NO;
    [host insertSubview:veil atIndex:0];
    return veil;
}

#pragma mark - 胶囊控件

// v0.4.51：这一层原来直接是 UIButton + setTitle:forState: / setImage:forState:。
// 装进导航栏后文字和图标一起消失，只剩一颗空胶囊（语音包页的「＋」也是空的）。
// 原因是 iOS 15 起按钮一旦带 UIButtonConfiguration，老 API 会被整体忽略，
// 于是只有我们 insertSubview 插进去的毛玻璃外壳还在、titleLabel / imageView 都不画。
// 现在改成「容器 + UILabel / UIImageView + 透明 UIControl 收点击」，完全不走
// UIButton 的文字图片渲染路径，configuration 那套就绕开了。
static UIControl *SLVMakePillHit(CGRect bounds, id target, SEL action) {
    UIControl *hit = [[UIControl alloc] initWithFrame:bounds];
    hit.backgroundColor = [UIColor clearColor];
    if (target && action) {
        [hit addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    }
    return hit;
}

UIBarButtonItem *SLVPillBarItemSized(NSString *title, CGFloat h, id target, SEL action) {
    UIFont *font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    CGSize ts = [title sizeWithAttributes:@{NSFontAttributeName: font}];
    CGFloat w = ceil(ts.width) + 26.0;   // 左右各 13pt

    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    UIView *shell = SLVMakeFlatPill(box.bounds);
    [box addSubview:shell];

    UILabel *lab = [[UILabel alloc] initWithFrame:shell.bounds];
    lab.text = title;
    lab.font = font;
    lab.textColor = [UIColor labelColor];
    lab.textAlignment = NSTextAlignmentCenter;
    [shell addSubview:lab];

    // 点击层最后加，压在最上面：透明但对触摸有效，文字跟着一起可点。
    [box addSubview:SLVMakePillHit(box.bounds, target, action)];
    return [[UIBarButtonItem alloc] initWithCustomView:box];
}

UIBarButtonItem *SLVPillBarItem(NSString *title, id target, SEL action) {
    return SLVPillBarItemSized(title, 32.0, target, action);
}

UIBarButtonItem *SLVPillIconBarItem(NSString *systemName, NSString *fallbackTitle, id target, SEL action) {
    return SLVPillIconBarItemSized(systemName, fallbackTitle, 32.0, target, action);
}

UIBarButtonItem *SLVPillIconBarItemSized(NSString *_Nullable systemName,
                                        NSString *_Nullable fallbackTitle,
                                        CGFloat h, id target, SEL action) {
    if (!systemName.length) return SLVPillBarItemSized(fallbackTitle ?: @"返回", h, target, action);

    UIImage *icon = [UIImage systemImageNamed:systemName];
    if (!icon) icon = [UIImage systemImageNamed:@"chevron.left"];   // 老系统没有 chevron.backward
    if (!icon) return SLVPillBarItemSized(fallbackTitle ?: @"返回", h, target, action);

    CGFloat w = 40.0;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    UIView *shell = SLVMakeFlatPill(box.bounds);
    [box addSubview:shell];

    CGFloat side = 17.0;
    UIImageView *iv = [[UIImageView alloc] initWithImage:icon];
    iv.tintColor = [UIColor labelColor];    // 显式给色，避免被导航栏 tint 冲掉
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.frame = CGRectMake((w - side) / 2.0, (h - side) / 2.0, side, side);
    [shell addSubview:iv];

    [box addSubview:SLVMakePillHit(box.bounds, target, action)];
    return [[UIBarButtonItem alloc] initWithCustomView:box];
}

UIView *SLVPillTitleView(NSString *text) {
    UIFont *font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    CGSize ts = [text sizeWithAttributes:@{NSFontAttributeName: font}];
    // v0.4.53：24 → 32，跟右边的「完成」胶囊等高（原来标题那枚明显矮一截）。
    CGFloat H = 32.0;
    CGFloat padX = 12.0;
    CGFloat tw = ceil(ts.width);
    CGFloat W = tw + padX * 2.0;

    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, H)];
    // titleView 里毛玻璃是能正常渲染的（和 bar item 不一样），这里保留真毛玻璃。
    UIVisualEffectView *pill = SLVMakePillShell(box.bounds);
    [box addSubview:pill];

    UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(padX, (H - ceil(ts.height)) / 2.0, tw, ceil(ts.height))];
    lab.text = text;
    lab.font = font;
    lab.textColor = [UIColor labelColor];
    [pill.contentView addSubview:lab];
    return box;
}

#pragma mark - 胶囊返回键

// 自绘 leftBarButtonItem 会顶掉系统返回键，iOS 顺带把侧滑也禁了。
// 这里用一个放行的代理把手势接回来：栈里还有上一页才允许侧滑。
@interface SLVPopGestureKeeper : NSObject <UIGestureRecognizerDelegate>
@end

@implementation SLVPopGestureKeeper
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    UIResponder *r = g.view;
    while (r && ![r isKindOfClass:[UINavigationController class]]) r = [r nextResponder];
    UINavigationController *nav = (UINavigationController *)r;
    if (![nav isKindOfClass:[UINavigationController class]]) return NO;
    return nav.viewControllers.count > 1;
}
@end

@interface UIViewController (SLVPillBackTap)
- (void)sl_pillBackTap;
@end

@implementation UIViewController (SLVPillBackTap)
- (void)sl_pillBackTap {
    UINavigationController *nav = self.navigationController;
    if (nav && nav.viewControllers.count > 1) {
        [nav popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}
@end

void SLVInstallPillBackSized(UIViewController *vc, CGFloat height) {
    if (!vc) return;
    // 已经自带左侧按钮（比如语音包页模态时的「完成」）就不要顶掉它
    if (vc.navigationItem.leftBarButtonItem) return;
    vc.navigationItem.hidesBackButton = YES;
    vc.navigationItem.leftBarButtonItem =
        SLVPillIconBarItemSized(@"chevron.backward", @"返回", height, vc, @selector(sl_pillBackTap));
    // 本方法通常在 viewDidLoad 里调，那时 navigationController 可能还没挂上，延后一拍再接管手势
    __weak UIViewController *weakVC = vc;
    dispatch_async(dispatch_get_main_queue(), ^{
        UINavigationController *nav = weakVC.navigationController;
        UIGestureRecognizer *g = nav.interactivePopGestureRecognizer;
        if (!g) return;
        static SLVPopGestureKeeper *keeper = nil;
        if (!keeper) keeper = [[SLVPopGestureKeeper alloc] init];
        g.delegate = keeper;
    });
}

void SLVInstallPillBack(UIViewController *vc) {
    SLVInstallPillBackSized(vc, 32.0);
}

#pragma mark - 搜索胶囊

@interface SLVSearchPill ()
@property (nonatomic, strong) UIVisualEffectView *blur;
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, strong) UITextField *field;
@end

@implementation SLVSearchPill

+ (CGFloat)pillHeight { return 36.0; }

+ (instancetype)pillWithPlaceholder:(NSString *)placeholder {
    CGFloat h = [self pillHeight];
    SLVSearchPill *p = [[SLVSearchPill alloc] initWithFrame:CGRectMake(0, 0, 320.0, h)];
    p.backgroundColor = [UIColor clearColor];
    p.layer.cornerRadius = h / 2.0;
    p.layer.cornerCurve = kCACornerCurveContinuous;
    p.layer.borderWidth = 0.8;
    p.layer.borderColor = SLVGlassHairlineColor().CGColor;

    p.blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
    p.blur.layer.cornerRadius = h / 2.0;
    p.blur.layer.cornerCurve = kCACornerCurveContinuous;
    p.blur.layer.masksToBounds = YES;
    p.blur.userInteractionEnabled = NO;
    [p addSubview:p.blur];

    p.icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"]];
    p.icon.tintColor = [UIColor secondaryLabelColor];
    p.icon.contentMode = UIViewContentModeScaleAspectFit;
    [p addSubview:p.icon];

    // v0.4.54：字号 15 → 14。胶囊整体收小之后 15 号字顶得太满，看着还是「大」。
    UITextField *tf = [[UITextField alloc] initWithFrame:CGRectZero];
    tf.font = [UIFont systemFontOfSize:14];
    tf.placeholder = placeholder;
    tf.borderStyle = UITextBorderStyleNone;
    tf.returnKeyType = UIReturnKeySearch;
    tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    tf.textColor = [UIColor labelColor];
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    [p addSubview:tf];
    p.field = tf;
    return p;
}

// 所有排布只在这里算：图标 13pt 起，文字接在图标后 7pt，右侧留 12pt。
// 原来的写法是在创建时用「当时的视图宽度」算死一次，之后表头被重设宽度也不会跟着走，
// 图标和文字就叠在一起了。
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = CGRectGetHeight(self.bounds);
    CGFloat w = CGRectGetWidth(self.bounds);
    self.blur.frame = self.bounds;

    CGFloat side = 15.0;
    self.icon.frame = CGRectMake(13.0, (h - side) / 2.0, side, side);
    CGFloat tx = CGRectGetMaxX(self.icon.frame) + 7.0;
    self.field.frame = CGRectMake(tx, 0, MAX(0.0, w - tx - 12.0), h);

    // 边框是 CGColor，动态色不会自己跟深浅色变；借每次布局重解一次（比覆写
    // traitCollectionDidChange: 便宜，也不会碰到 iOS 17 起把它标废的 -Werror 坑）。
    self.layer.borderColor = SLVGlassHairlineColor().CGColor;
}

@end
