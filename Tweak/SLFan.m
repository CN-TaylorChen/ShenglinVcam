//
//  SLFan.m
//  声临 · 虚拟摄像头 —— 长按展开的五个开关球
//

#import "SLFan.h"
#import "SLCamBridge.h"
#import <math.h>
#import <string.h>

#define SL_FAN_BALL_SIDE   38.0
#define SL_FAN_BALL_R      19.0
#define SL_FAN_R0          88.0
#define SL_FAN_HALF0       72.0
#define SL_FAN_COL_W       86.0
#define SL_FAN_PILL_H      30.0
#define SL_FAN_PILL_GAP    6.0
#define SL_FAN_COL_H       (SL_FAN_PILL_H * 4.0 + SL_FAN_PILL_GAP * 3.0)

#pragma mark - 偏好读写

static BOOL SLFanBool(NSString *key, BOOL def) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return v ? [v boolValue] : def;
}

static void SLFanSetBool(NSString *key, BOOL v) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:v forKey:key];
    [d synchronize];
}

static NSInteger SLFanInt(NSString *key, NSInteger def) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return v ? [v integerValue] : def;
}

static void SLFanSetInt(NSString *key, NSInteger v) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:v forKey:key];
    [d synchronize];
}

#pragma mark - 图标

// 五个图标都是 20×20 画布上的线性描边，1.8pt、圆头圆角，
// 和主球的极简风格对齐。返回 template 图，颜色交给 tintColor。
static UIImage *SLFanIcon(NSInteger idx, CGFloat side) {
    if (side <= 0) side = 20.0;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:fmt];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGFloat u = side / 20.0;
        CGContextScaleCTM(c, u, u);
        CGContextSetLineWidth(c, 1.8);
        CGContextSetLineCap(c, kCGLineCapRound);
        CGContextSetLineJoin(c, kCGLineJoinRound);
        CGContextSetStrokeColorWithColor(c, [UIColor blackColor].CGColor);
        CGContextSetFillColorWithColor(c, [UIColor blackColor].CGColor);

        if (idx == 0) {
            // 启用：缺口朝上的圆环 + 中间竖线
            CGContextAddArc(c, 10.0, 10.6, 6.2, M_PI * 0.42, -M_PI * 0.42, 1);
            CGContextStrokePath(c);
            CGContextMoveToPoint(c, 10.0, 3.6);
            CGContextAddLineToPoint(c, 10.0, 10.0);
            CGContextStrokePath(c);
        } else if (idx == 1) {
            // 静音：喇叭 + 叉
            CGContextMoveToPoint(c, 9.2, 4.4);
            CGContextAddLineToPoint(c, 5.6, 7.6);
            CGContextAddLineToPoint(c, 2.6, 7.6);
            CGContextAddLineToPoint(c, 2.6, 12.4);
            CGContextAddLineToPoint(c, 5.6, 12.4);
            CGContextAddLineToPoint(c, 9.2, 15.6);
            CGContextClosePath(c);
            CGContextStrokePath(c);
            CGContextMoveToPoint(c, 13.4, 7.8);
            CGContextAddLineToPoint(c, 17.4, 12.2);
            CGContextMoveToPoint(c, 17.4, 7.8);
            CGContextAddLineToPoint(c, 13.4, 12.2);
            CGContextStrokePath(c);
        } else if (idx == 2) {
            // 旋转：缺口圆环 + 缺口右端的箭头
            CGContextAddArc(c, 10.0, 10.6, 6.2, M_PI * 0.42, -M_PI * 0.42, 1);
            CGContextStrokePath(c);
            CGContextMoveToPoint(c, 11.6, 1.9);
            CGContextAddLineToPoint(c, 11.6, 6.7);
            CGContextAddLineToPoint(c, 15.8, 4.3);
            CGContextClosePath(c);
            CGContextFillPath(c);
        } else if (idx == 3) {
            // 镜像：左右三角 + 中间虚线轴
            CGContextMoveToPoint(c, 8.2, 4.2);
            CGContextAddLineToPoint(c, 8.2, 15.8);
            CGContextAddLineToPoint(c, 3.4, 10.0);
            CGContextClosePath(c);
            CGContextStrokePath(c);
            CGContextMoveToPoint(c, 11.8, 4.2);
            CGContextAddLineToPoint(c, 11.8, 15.8);
            CGContextAddLineToPoint(c, 16.6, 10.0);
            CGContextClosePath(c);
            CGContextStrokePath(c);
            CGContextSetLineDash(c, 0, (const CGFloat[]){1.6, 1.8}, 2);
            CGContextMoveToPoint(c, 10.0, 3.0);
            CGContextAddLineToPoint(c, 10.0, 17.0);
            CGContextStrokePath(c);
            CGContextSetLineDash(c, 0, NULL, 0);
        } else {
            // 循环：上下两条反向箭头
            CGContextMoveToPoint(c, 3.2, 7.8);
            CGContextAddLineToPoint(c, 15.4, 7.8);
            CGContextStrokePath(c);
            CGContextMoveToPoint(c, 12.6, 5.0);
            CGContextAddLineToPoint(c, 15.6, 7.8);
            CGContextAddLineToPoint(c, 12.6, 10.6);
            CGContextStrokePath(c);
            CGContextMoveToPoint(c, 16.8, 12.2);
            CGContextAddLineToPoint(c, 4.6, 12.2);
            CGContextStrokePath(c);
            CGContextMoveToPoint(c, 7.4, 9.4);
            CGContextAddLineToPoint(c, 4.4, 12.2);
            CGContextAddLineToPoint(c, 7.4, 15.0);
            CGContextStrokePath(c);
        }
    }];
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static NSString *SLFanAngleName(NSInteger i) {
    switch (i) {
        case 1: return @"90°";
        case 2: return @"180°";
        case 3: return @"270°";
        default: return @"不旋转";
    }
}

#pragma mark - 扇

@implementation SLFanView {
    CGSize _hostSize;
    CGPoint _center;
    SLFanEdge _edge;
    CGFloat _radius;
    CGFloat _spread;
    CGPoint _pts[5];

    UIView *_ball[5];
    UIView *_tintV[5];
    UIImageView *_iconV[5];
    CAShapeLayer *_ringL[5];
    BOOL _on[5];

    UIView *_col;
    UIView *_pill[4];
    CAShapeLayer *_pillArc[4];
    UILabel *_pillLab[4];

    CAShapeLayer *_arcTrack;
    CAShapeLayer *_arcLive;
    CAShapeLayer *_arcTip;

    NSInteger _hover;
    BOOL _angleOpen;
    BOOL _anglePending;
    NSInteger _angleIndex;
    CGFloat _arcProgress;
    NSInteger _shownAngle;
}

#pragma mark 构建

- (instancetype)initWithHostSize:(CGSize)hostSize
                      ballCenter:(CGPoint)center
                            edge:(SLFanEdge)edge {
    self = [super initWithFrame:CGRectMake(0, 0, hostSize.width, hostSize.height)];
    if (!self) return nil;
    _hostSize = hostSize;
    _center = center;
    _edge = edge;
    _hover = -1;
    _angleIndex = -1;
    _shownAngle = 0;
    self.backgroundColor = [UIColor clearColor];
    self.userInteractionEnabled = NO;
    self.alpha = 0.0;

    [self sl_layoutGeometry];
    [self sl_buildBalls];
    [self sl_buildColumn];
    [self sl_reloadStates];
    return self;
}

// 五个球排在 ±spread 的弧上。越界就缩半径，半径缩到底再收扇角 ——
// 球贴角落时半圆会有一半在屏幕外，这一步就是把它压回屏幕里。
- (void)sl_layoutGeometry {
    CGFloat half = SL_FAN_HALF0;
    CGFloat R = SL_FAN_R0;
    CGRect safe = CGRectInset(CGRectMake(0, 0, _hostSize.width, _hostSize.height), 6.0, 6.0);
    CGPoint pts[5];
    for (int round = 0; round < 30; round++) {
        [self sl_pointsInto:pts radius:R half:half];
        BOOL ok = YES;
        for (int i = 0; i < 5; i++) {
            CGRect br = CGRectMake(pts[i].x - SL_FAN_BALL_R, pts[i].y - SL_FAN_BALL_R,
                                   SL_FAN_BALL_SIDE, SL_FAN_BALL_SIDE);
            if (!CGRectContainsRect(safe, br)) { ok = NO; break; }
        }
        if (ok) break;
        if (R > 62.0) R -= 5.0;
        else if (half > 26.0) half -= 6.0;
        else break;
    }
    // 循环最后一轮可能改了 R / half 就退出，这里按最终值再算一次，避免用上一轮的点
    [self sl_pointsInto:pts radius:R half:half];
    memcpy(_pts, pts, sizeof(pts));
    _radius = R;
    _spread = half;
}

- (CGFloat)sl_dirAngle {
    switch (_edge) {
        case SLFanEdgeLeft:   return 0.0;
        case SLFanEdgeRight:  return 180.0;
        case SLFanEdgeTop:    return 90.0;
        default:              return -90.0;
    }
}

- (void)sl_pointsInto:(CGPoint *)out radius:(CGFloat)R half:(CGFloat)half {
    CGFloat dirA = [self sl_dirAngle];
    // 贴右边 / 下边时，下标 0 要落在「上 / 右」那一侧，所以角度取反
    BOOL flip = (_edge == SLFanEdgeRight || _edge == SLFanEdgeBottom);
    for (int i = 0; i < 5; i++) {
        CGFloat t = -half + half * (i / 2.0);
        CGFloat off = flip ? -t : t;
        CGFloat a = (dirA + off) * M_PI / 180.0;
        out[i] = CGPointMake(_center.x + R * cos(a), _center.y + R * sin(a));
    }
}

- (UIColor *)sl_accent { return [UIColor systemIndigoColor]; }

- (void)sl_buildBalls {
    for (int i = 0; i < 5; i++) {
        UIView *b = [[UIView alloc] initWithFrame:CGRectMake(_center.x - SL_FAN_BALL_R,
                                                             _center.y - SL_FAN_BALL_R,
                                                             SL_FAN_BALL_SIDE, SL_FAN_BALL_SIDE)];
        b.userInteractionEnabled = NO;
        b.alpha = 0.0;

        UIVisualEffectView *blur = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
        blur.frame = b.bounds;
        blur.layer.cornerRadius = SL_FAN_BALL_R;
        blur.layer.cornerCurve = kCACornerCurveContinuous;
        blur.clipsToBounds = YES;
        blur.userInteractionEnabled = NO;
        [b addSubview:blur];

        UIView *tint = [[UIView alloc] initWithFrame:b.bounds];
        tint.layer.cornerRadius = SL_FAN_BALL_R;
        tint.layer.cornerCurve = kCACornerCurveContinuous;
        tint.userInteractionEnabled = NO;
        tint.alpha = 0.0;
        [b addSubview:tint];

        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(9.0, 9.0, 20.0, 20.0)];
        iv.image = SLFanIcon(i, 20.0);
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.userInteractionEnabled = NO;
        [b addSubview:iv];

        CAShapeLayer *ring = [CAShapeLayer layer];
        ring.frame = b.bounds;
        ring.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(b.bounds, 0.8, 0.8)].CGPath;
        ring.fillColor = nil;
        ring.lineWidth = 1.6;
        [b.layer addSublayer:ring];

        [self addSubview:b];
        _ball[i] = b;
        _tintV[i] = tint;
        _iconV[i] = iv;
        _ringL[i] = ring;
    }

    // 旋转球外圈：暗底环 + 实弧 + 端点圆点
    UIView *host = _ball[SLFanSwitchRotate];
    UIView *ringBox = [[UIView alloc] initWithFrame:CGRectMake(-8.0, -8.0, 54.0, 54.0)];
    ringBox.userInteractionEnabled = NO;

    _arcTrack = [CAShapeLayer layer];
    _arcTrack.frame = ringBox.bounds;
    _arcTrack.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(27.0, 27.0) radius:25.0
                                                 startAngle:-M_PI_2 endAngle:M_PI_2 * 3.0
                                                  clockwise:YES].CGPath;
    _arcTrack.fillColor = nil;
    _arcTrack.strokeColor = [[UIColor colorWithWhite:0.5 alpha:1.0] colorWithAlphaComponent:0.28].CGColor;
    _arcTrack.lineWidth = 3.0;
    [ringBox.layer addSublayer:_arcTrack];

    _arcLive = [CAShapeLayer layer];
    _arcLive.frame = ringBox.bounds;
    _arcLive.path = _arcTrack.path;
    _arcLive.fillColor = nil;
    _arcLive.strokeColor = [self sl_accent].CGColor;
    _arcLive.lineWidth = 3.0;
    _arcLive.lineCap = kCALineCapRound;
    _arcLive.strokeEnd = 0.0;
    [ringBox.layer addSublayer:_arcLive];

    // 端点圆点单独给一块 7×7 的 bounds，位置直接由 position 决定；
    // 沿用 54×54 的话，path 会画在图层左上角，dot 会整体偏掉 (-23.5, -23.5)。
    _arcTip = [CAShapeLayer layer];
    _arcTip.bounds = CGRectMake(0, 0, 7.0, 7.0);
    _arcTip.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 7.0, 7.0)].CGPath;
    _arcTip.fillColor = [self sl_accent].CGColor;
    _arcTip.hidden = YES;
    [ringBox.layer addSublayer:_arcTip];

    [host addSubview:ringBox];
}

- (void)sl_buildColumn {
    CGPoint cc = [self sl_columnCenter];
    _col = [[UIView alloc] initWithFrame:CGRectMake(cc.x - SL_FAN_COL_W / 2.0,
                                                    cc.y - SL_FAN_COL_H / 2.0,
                                                    SL_FAN_COL_W, SL_FAN_COL_H)];
    _col.userInteractionEnabled = NO;
    _col.alpha = 0.0;

    for (int i = 0; i < 4; i++) {
        CGFloat y = i * (SL_FAN_PILL_H + SL_FAN_PILL_GAP);
        UIView *p = [[UIView alloc] initWithFrame:CGRectMake(0, y, SL_FAN_COL_W, SL_FAN_PILL_H)];
        p.layer.cornerRadius = SL_FAN_PILL_H / 2.0;
        p.layer.cornerCurve = kCACornerCurveContinuous;
        p.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.16];

        CAShapeLayer *arc = [CAShapeLayer layer];
        arc.frame = CGRectMake(5.0, 3.0, 24.0, 24.0);
        arc.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(12.0, 12.0) radius:9.0
                                              startAngle:-M_PI_2 endAngle:M_PI_2 * 3.0
                                               clockwise:YES].CGPath;
        arc.fillColor = nil;
        arc.strokeColor = [self sl_accent].CGColor;
        arc.lineWidth = 2.0;
        arc.lineCap = kCALineCapRound;
        arc.strokeEnd = i * 0.25;
        [p.layer addSublayer:arc];

        UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(34.0, 0, SL_FAN_COL_W - 38.0, SL_FAN_PILL_H)];
        lab.text = SLFanAngleName(i);
        lab.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
        lab.textColor = [UIColor secondaryLabelColor];
        lab.userInteractionEnabled = NO;
        [p addSubview:lab];

        [_col addSubview:p];
        _pill[i] = p;
        _pillArc[i] = arc;
        _pillLab[i] = lab;
    }
    [self addSubview:_col];
}

- (CGPoint)sl_columnCenter {
    CGFloat a = [self sl_dirAngle] * M_PI / 180.0;
    CGFloat dist = SL_FAN_BALL_R + 8.0 + SL_FAN_COL_W / 2.0;
    CGPoint r = _pts[SLFanSwitchRotate];
    return CGPointMake(r.x + dist * cos(a), r.y + dist * sin(a));
}

#pragma mark 状态

- (void)sl_reloadStates {
    BOOL en = SLFanBool(kSLCamEnabledKey, YES);
    BOOL muted = !SLFanBool(kSLCamAudioKey, YES);
    BOOL loop = SLFanBool(kSLCamLoopKey, YES);
    BOOL mir = SLFanBool(kSLCamMirrorKey, NO);
    NSInteger rot = SLFanInt(kSLCamRotateKey, 0);
    rot %= 360;
    if (rot < 0) rot += 360;
    if (rot != 90 && rot != 180 && rot != 270) rot = 0;

    _on[SLFanSwitchEnabled] = en;
    _on[SLFanSwitchMute] = muted;
    _on[SLFanSwitchRotate] = (rot != 0);
    _on[SLFanSwitchMirror] = mir;
    _on[SLFanSwitchLoop] = loop;

    _shownAngle = rot / 90;
    _angleIndex = _shownAngle;
    _arcProgress = _shownAngle * 0.25;

    for (int i = 0; i < 5; i++) [self sl_applyBallLook:i];
    [self sl_refreshArc];
    [self sl_refreshPills];
}

- (void)sl_applyBallLook:(NSInteger)i {
    BOOL on = _on[i];
    UIColor *accent = [self sl_accent];
    _tintV[i].backgroundColor = accent;
    _tintV[i].alpha = on ? 0.26 : 0.0;
    _iconV[i].tintColor = on ? accent : [UIColor secondaryLabelColor];
    _ringL[i].strokeColor = on ? accent.CGColor
                               : [[UIColor colorWithWhite:0.5 alpha:1.0] colorWithAlphaComponent:0.34].CGColor;
}

- (void)sl_refreshArc {
    _arcLive.strokeEnd = _arcProgress;
    _arcTip.hidden = (_arcProgress < 0.02);
    if (!_arcTip.hidden) {
        CGFloat a = _arcProgress * M_PI * 2.0;
        _arcTip.position = CGPointMake(27.0 + 25.0 * sin(a), 27.0 - 25.0 * cos(a));
    }
}

- (void)sl_refreshPills {
    for (int i = 0; i < 4; i++) {
        BOOL sel = (_angleOpen && i == _angleIndex);
        _pill[i].backgroundColor = sel ? [[self sl_accent] colorWithAlphaComponent:0.24]
                                       : [UIColor colorWithWhite:0.5 alpha:0.16];
        _pillLab[i].textColor = sel ? [self sl_accent] : [UIColor secondaryLabelColor];
        _pillArc[i].strokeColor = sel ? [self sl_accent].CGColor
                                      : [[self sl_accent] colorWithAlphaComponent:0.45].CGColor;
    }
}

#pragma mark 展开 / 收起

- (void)sl_show {
    self.alpha = 1.0;
    for (int i = 0; i < 5; i++) {
        UIView *b = _ball[i];
        b.center = _center;
        b.alpha = 0.0;
        b.transform = CGAffineTransformMakeScale(0.45, 0.45);
        [UIView animateWithDuration:0.44
                              delay:0.055 * i
             usingSpringWithDamping:0.74
              initialSpringVelocity:0.5
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            b.center = self->_pts[i];
            b.alpha = 1.0;
            b.transform = CGAffineTransformIdentity;
        } completion:nil];
    }
}

- (void)sl_hide {
    _hover = -1;
    [self sl_setAngleOpen:NO];
    for (int i = 0; i < 5; i++) {
        UIView *b = _ball[i];
        [UIView animateWithDuration:0.22 delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn
                         animations:^{
            b.center = self->_center;
            b.alpha = 0.0;
            b.transform = CGAffineTransformMakeScale(0.5, 0.5);
        } completion:nil];
    }
    [UIView animateWithDuration:0.24 animations:^{ self.alpha = 0.0; }];
}

#pragma mark 手指追踪

- (void)sl_trackPoint:(CGPoint)p {
    NSInteger hit = [self sl_hitSwitch:p];

    if (_angleOpen) {
        NSInteger ai = [self sl_hitAngle:p];
        if (ai >= 0) {
            _hover = SLFanSwitchRotate;
            [self sl_applyHover];
            CGFloat top = CGRectGetMinY(_col.frame) + 15.0;
            CGFloat t = (p.y - top) / (36.0 * 3.0);
            if (t < 0.0) t = 0.0;
            if (t > 1.0) t = 1.0;
            _arcProgress = t * 0.75;
            _angleIndex = (NSInteger)lround(_arcProgress / 0.25);
            if (_angleIndex < 0) _angleIndex = 0;
            if (_angleIndex > 3) _angleIndex = 3;
            [self sl_refreshArc];
            [self sl_refreshPills];
            return;
        }
        if (hit != SLFanSwitchRotate) {
            [self sl_setAngleOpen:NO];
            _arcProgress = _shownAngle * 0.25;
            [self sl_refreshArc];
        }
    }

    _hover = hit;
    [self sl_applyHover];

    if (hit == SLFanSwitchRotate) {
        if (!_angleOpen && !_anglePending) {
            _anglePending = YES;
            __weak typeof(self) ws = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.16 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                SLFanView *ss = ws;
                if (!ss) return;
                ss->_anglePending = NO;
                if (ss->_hover == SLFanSwitchRotate && !ss->_angleOpen) {
                    ss->_angleIndex = ss->_shownAngle;
                    ss->_arcProgress = ss->_shownAngle * 0.25;
                    [ss sl_setAngleOpen:YES];
                    [ss sl_refreshArc];
                }
            });
        }
    }
}

- (void)sl_applyHover {
    for (int i = 0; i < 5; i++) {
        CGFloat s = (_hover == i) ? 1.14 : 1.0;
        [UIView animateWithDuration:0.16 delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self->_ball[i].transform = CGAffineTransformMakeScale(s, s);
            self->_ball[i].alpha = (self->_hover < 0 || self->_hover == i) ? 1.0 : 0.62;
        } completion:nil];
    }
}

- (void)sl_setAngleOpen:(BOOL)open {
    if (_angleOpen == open) return;
    _angleOpen = open;
    if (open) {
        _col.transform = CGAffineTransformMakeTranslation(-10.0, 0.0);
        [UIView animateWithDuration:0.24 delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self->_col.alpha = 1.0;
            self->_col.transform = CGAffineTransformIdentity;
        } completion:nil];
    } else {
        [UIView animateWithDuration:0.18 delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn
                         animations:^{ self->_col.alpha = 0.0; } completion:nil];
        _angleIndex = -1;
    }
    [self sl_refreshPills];
}

#pragma mark 命中测试

- (NSInteger)sl_hitSwitch:(CGPoint)p {
    NSInteger best = -1;
    CGFloat bestD = 1e9;
    for (int i = 0; i < 5; i++) {
        CGFloat dx = p.x - _pts[i].x, dy = p.y - _pts[i].y;
        CGFloat d = sqrt(dx * dx + dy * dy);
        if (d <= SL_FAN_BALL_R + 8.0 && d < bestD) { bestD = d; best = i; }
    }
    return best;
}

- (NSInteger)sl_hitAngle:(CGPoint)p {
    if (!_angleOpen) return -1;
    if (!CGRectContainsPoint(_col.frame, p)) return -1;
    CGFloat top = CGRectGetMinY(_col.frame);
    CGFloat y = p.y - top;
    NSInteger i = (NSInteger)floor(y / (SL_FAN_PILL_H + SL_FAN_PILL_GAP));
    if (i < 0) i = 0;
    if (i > 3) i = 3;
    return i;
}

#pragma mark 结果

- (NSInteger)slPickedSwitch {
    return _hover;
}

- (NSInteger)slPickedAngle {
    if (_hover != SLFanSwitchRotate || !_angleOpen) return -1;
    return _angleIndex;
}

@end

#pragma mark - 提交

void SLFanCommit(NSInteger sw, NSInteger angle) {
    if (sw < 0) return;
    BOOL changed = NO;
    switch (sw) {
        case SLFanSwitchEnabled:
            SLFanSetBool(kSLCamEnabledKey, !SLFanBool(kSLCamEnabledKey, YES));
            changed = YES;
            break;
        case SLFanSwitchMute: {
            BOOL useAudio = SLFanBool(kSLCamAudioKey, YES);
            SLFanSetBool(kSLCamAudioKey, !useAudio);
            changed = YES;
            break;
        }
        case SLFanSwitchRotate: {
            // 角度列还没展开就松手（手指只是从旋转球上路过）→ 什么都不改。
            // 原来这里把 -1 当 0 处理，一次误触就会把用户设好的 180° 清成「不旋转」。
            if (angle < 0) break;
            SLFanSetInt(kSLCamRotateKey, angle * 90);
            changed = YES;
            break;
        }
        case SLFanSwitchMirror:
            SLFanSetBool(kSLCamMirrorKey, !SLFanBool(kSLCamMirrorKey, NO));
            changed = YES;
            break;
        case SLFanSwitchLoop:
            SLFanSetBool(kSLCamLoopKey, !SLFanBool(kSLCamLoopKey, YES));
            changed = YES;
            break;
        default:
            break;
    }
    if (changed) SLCamReloadAll();
}
