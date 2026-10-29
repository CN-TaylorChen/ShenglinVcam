#import "SLAlignBox.h"

@interface SLAlignBox ()
@property (nonatomic, weak) UILabel *label;
@property (nonatomic, strong) NSLayoutConstraint *leadingConstraint;
@property (nonatomic, assign) BOOL headerMode;
@property (nonatomic, assign) CGFloat trailingInset;
@end

@implementation SLAlignBox

// 只读查找，不持有、不调数据源，找不到就返回 nil
- (UITableView *)sl_tableView {
    UIView *v = self.superview;
    while (v && ![v isKindOfClass:[UITableView class]]) v = v.superview;
    return [v isKindOfClass:[UITableView class]] ? (UITableView *)v : nil;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    UILabel *lab = self.label;
    CGFloat target = self.targetLeading;
    if (!lab || target <= 0) return;   // 没量到基线：保持原样（宁可继续歪，也不乱动）

    UITableView *tv = [self sl_tableView];
    CGFloat boxX = 0;
    if (tv) boxX = CGRectGetMinX([self convertRect:self.bounds toView:tv]);
    CGFloat x = target - boxX;
    if (x < 0) x = 0;

    if (self.headerMode) {
        CGFloat w = MAX(10, self.bounds.size.width - x - self.trailingInset);
        if (fabs(CGRectGetMinX(lab.frame) - x) > 0.5 || fabs(lab.frame.size.width - w) > 0.5) {
            lab.frame = CGRectMake(x, CGRectGetMinY(lab.frame), w, CGRectGetHeight(lab.frame));
        }
    } else if (self.leadingConstraint && fabs(self.leadingConstraint.constant - x) > 0.5) {
        // 幂等：第二遍算出来的差值是 0，不会再改，不会形成布局回环
        self.leadingConstraint.constant = x;
    }
}

@end

static SLAlignBox *SLAlignMakeBox(NSString *text, CGFloat target, CGFloat width, BOOL header) {
    if (!text.length) return nil;
    CGFloat w = width > 0 ? width : [UIScreen mainScreen].bounds.size.width;

    SLAlignBox *box = [[SLAlignBox alloc] initWithFrame:CGRectMake(0, 0, w, header ? 22 : 0)];
    box.targetLeading = target;
    box.headerMode = header;
    box.trailingInset = 16;

    UILabel *lab = [[UILabel alloc] init];
    lab.font = [UIFont systemFontOfSize:12];
    lab.textColor = [UIColor secondaryLabelColor];
    lab.text = text;

    if (header) {
        // 首帧按目标值先排一次，layoutSubviews 里再按盒子真实位置纠正
        lab.frame = CGRectMake(target, 22 - 19, MAX(10, w - target - 16), 17);
        lab.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [box addSubview:lab];
        box.label = lab;
    } else {
        lab.translatesAutoresizingMaskIntoConstraints = NO;
        lab.numberOfLines = 0;
        [box addSubview:lab];
        NSLayoutConstraint *lead = [lab.leadingAnchor constraintEqualToAnchor:box.leadingAnchor
                                                                    constant:MAX(0, target)];
        box.leadingConstraint = lead;
        [NSLayoutConstraint activateConstraints:@[
            lead,
            [lab.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16],
            [lab.topAnchor constraintEqualToAnchor:box.topAnchor constant:5],
            [lab.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-7],
        ]];
        box.label = lab;
    }
    return box;
}

UIView *SLAlignHeader(NSString *text, CGFloat targetLeading, CGFloat width) {
    return SLAlignMakeBox(text, targetLeading, width, YES);
}

UIView *SLAlignFooter(NSString *text, CGFloat targetLeading, CGFloat width) {
    return SLAlignMakeBox(text, targetLeading, width, NO);
}
