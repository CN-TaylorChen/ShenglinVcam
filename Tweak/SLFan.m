//
//  SLVFan.m
//  声临 · 虚拟摄像头 —— 长按展开的五个开关球
//

#import "SLFan.h"
#import "SLCamBridge.h"
#import "SLUtil.h"
#import <math.h>
#import <string.h>

// 0.2.14：球径 38 → 44，跟主球（48）拉近。原来 38 放在 48 旁边像另一个 App 的控件。
#define SLV_FAN_BALL_SIDE   44.0
#define SLV_FAN_BALL_R      22.0
#define SLV_FAN_R0          92.0
// 半径下限按「相邻两球不重叠」算：相邻夹角 = 2*half/4 = 36°，
// 弦长 = 2R·sin18° = 0.618R，要 ≥ 44 就得 R ≥ 71.2，取 74 留点余量。
#define SLV_FAN_RMIN        74.0
#define SLV_FAN_HALF0       72.0
#define SLV_FAN_COL_W       92.0
#define SLV_FAN_PILL_H      34.0
#define SLV_FAN_PILL_GAP    8.0
#define SLV_FAN_COL_H       (SLV_FAN_PILL_H * 4.0 + SLV_FAN_PILL_GAP * 3.0)
#define SLV_FAN_ICON_PT     17.0

#pragma mark - 偏好读写

static BOOL SLVFanBool(NSString *key, BOOL def) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return v ? [v boolValue] : def;
}

static void SLVFanSetBool(NSString *key, BOOL v) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:v forKey:key];
    [d synchronize];
}

static NSInteger SLVFanInt(NSString *key, NSInteger def) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return v ? [v integerValue] : def;
}

static void SLVFanSetInt(NSString *key, NSInteger v) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:v forKey:key];
    [d synchronize];
}

#pragma mark - 图标

// 0.2.14：整套手绘图标删掉，换成 SF Symbols。
//
// 手绘那版有两个坑：① UIGraphicsImageRenderer 的 CTM 是 y 向下的，
// CGContextAddArc 的 clockwise 在这个坐标系里视觉上是逆时针，而且从
// +0.42π 递减到 -0.42π 会经过 0°（正右方）—— 缺口落在了左边而不是顶部，
// 启用和旋转两个图标整体转了 90°，渲染出来是「Ɑ」和「↻钩子」；
// ② 20pt 画布上两个三角形只差 3.6pt，糊成一个菱形。
// 换成系统符号之后形状、粗细、光学对齐都是 Apple 调过的，这一类问题从根上没了。
// 镜像图标：原来用 arrow.left.and.right，就是两根箭头，没有「翻转」的语义，
// 摆在旋转球旁边更像「左右移动」。flip.horizontal 是一个被左右箭头穿过的方框，
// 一眼就是左右镜像（iOS 15 起才有，更老的系统退回原来那根箭头）。
static NSString *SLVFanMirrorIconName(void) {
    if (@available(iOS 15.0, *)) return @"flip.horizontal";
    return @"arrow.left.and.right";
}

static NSString *SLVFanIconName(NSInteger idx) {
    switch (idx) {
        case SLVFanSwitchEnabled: return @"power";
        case SLVFanSwitchMute:    return @"speaker.slash.fill";
        case SLVFanSwitchRotate:  return @"rotate.right";
        case SLVFanSwitchMirror:  return SLVFanMirrorIconName();
        default:                 return @"repeat";
    }
}

static UIImage *SLVFanIcon(NSInteger idx) {
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:SLV_FAN_ICON_PT
                                                        weight:UIImageSymbolWeightSemibold];
    UIImage *img = [UIImage systemImageNamed:SLVFanIconName(idx) withConfiguration:cfg];
    if (!img) img = [UIImage systemImageNamed:@"circle" withConfiguration:cfg];   // 兜底，别留空白
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

/// 「启用」球被按住之后换成这个 —— 从电源变成网格，一眼看出松手会进素材库
static UIImage *SLVFanLibraryIcon(void) {
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:SLV_FAN_ICON_PT
                                                        weight:UIImageSymbolWeightSemibold];
    UIImage *img = [UIImage systemImageNamed:@"square.grid.2x2" withConfiguration:cfg];
    if (!img) img = [UIImage systemImageNamed:@"rectangle.grid.2x2.fill" withConfiguration:cfg];
    if (!img) img = [UIImage systemImageNamed:@"photo.on.rectangle" withConfiguration:cfg];
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

/// 「循环」球被按住之后换成这个 —— 中间一块的方框 = 只留正中、不放大
static UIImage *SLVFanSquareCropIcon(void) {
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:SLV_FAN_ICON_PT
                                                        weight:UIImageSymbolWeightSemibold];
    UIImage *img = nil;
    if (@available(iOS 16.0, *)) {
        img = [UIImage systemImageNamed:@"rectangle.center.inset.filled" withConfiguration:cfg];
    }
    if (!img) img = [UIImage systemImageNamed:@"square.dashed" withConfiguration:cfg];
    if (!img) img = [UIImage systemImageNamed:@"crop" withConfiguration:cfg];
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static NSString *SLVFanAngleName(NSInteger i) {
    switch (i) {
        case 1: return @"90°";
        case 2: return @"180°";
        case 3: return @"270°";
        default: return @"不旋转";
    }
}

#pragma mark - 扇

@implementation SLVFanView {
    CGSize _hostSize;
    CGPoint _center;        // 主球球心（调用方给的，不动）
    CGPoint _fanCenter;     // 扇心：贴角时被推进安全区，可能不等于 _center
    SLVFanEdge _edge;
    CGFloat _radius;
    CGFloat _spread;
    CGPoint _pts[5];

    UIView *_ball[5];
    UIView *_tintV[5];
    UIImageView *_iconV[5];
    CAShapeLayer *_ringL[5];
    CAShapeLayer *_glowL[5];
    CAShapeLayer *_progL[5];   // 0.3.13：双功能球的按住进度环
    CAShapeLayer *_badgeDot;   // 0.3.15：循环球内**左上角**的「实拍时刻开着」小圆点
    BOOL _on[5];

    UIView *_col;
    UIView *_pill[4];
    UIView *_pillSel[4];
    CAShapeLayer *_pillArc[4];
    UILabel *_pillLab[4];

    CAShapeLayer *_arcTrack;
    CAShapeLayer *_arcLive;
    CAShapeLayer *_arcTip;
    CGPoint _arcRingCenter;
    CGFloat _arcRingR;

    NSInteger _hover;
    BOOL _angleOpen;
    BOOL _anglePending;
    NSInteger _angleIndex;
    CGFloat _arcProgress;
    NSInteger _shownAngle;

    // 0.3.13：双功能球。停在「启用」上不动 = 进素材库，停在「循环」上不动 = 切实拍时刻。
    // 扇的交互本来就是「按下 → 滑到某个球 → 松手提交」，没有单击，
    // 所以只能靠「停留时长」区分：滑过去就松手 = 切开关，停住不走 = 第二功能。
    NSInteger _armedSwitch;    // 已经切成第二功能的球，-1 = 没有
    NSInteger _armToken;       // 递增令牌：换了球之后旧的计时回调自己作废
    // 0.3.14：**正在计时的那颗球**，-1 = 没有。
    //
    // 0.3.13 少了这一项，判重只看 _armedSwitch，而它要 0.55s 之后才赋值 ——
    // 这 0.55s 里手指每抖一下（sl_trackPoint: 每次 touch move 都会被调用）都会
    // 走一遍「取消动画 + 重开动画」，进度环永远跑不满，看起来就是「快满了又从头跑」。
    NSInteger _armBall;
}

#pragma mark 构建

- (instancetype)initWithHostSize:(CGSize)hostSize
                      ballCenter:(CGPoint)center
                            edge:(SLVFanEdge)edge {
    self = [super initWithFrame:CGRectMake(0, 0, hostSize.width, hostSize.height)];
    if (!self) return nil;
    _hostSize = hostSize;
    _center = center;
    _edge = edge;
    _hover = -1;
    _angleIndex = -1;
    _shownAngle = 0;
    // 0.3.14：必须显式置 -1。ivar 默认是 0，而 0 正好是 SLVFanSwitchEnabled ——
    // 不置的话第一次长按「启用」球会被 sl_trackPoint: 里的 _armedSwitch == hit
    // 直接挡掉，进度环根本不起，「长按进素材库」第一次永远不生效。
    _armedSwitch = -1;
    _armBall = -1;
    self.backgroundColor = [UIColor clearColor];
    self.userInteractionEnabled = NO;
    self.alpha = 0.0;

    [self sl_layoutGeometry];
    [self sl_buildBalls];
    [self sl_buildColumn];
    [self sl_reloadStates];
    return self;
}

- (CGFloat)sl_dirAngle {
    switch (_edge) {
        case SLVFanEdgeLeft:   return 0.0;
        case SLVFanEdgeRight:  return 180.0;
        case SLVFanEdgeTop:    return 90.0;
        default:              return -90.0;
    }
}

- (void)sl_pointsInto:(CGPoint *)out radius:(CGFloat)R half:(CGFloat)half center:(CGPoint)c {
    CGFloat dirA = [self sl_dirAngle];
    // 贴右边 / 下边时，下标 0 要落在「上 / 右」那一侧，所以角度取反
    BOOL flip = (_edge == SLVFanEdgeRight || _edge == SLVFanEdgeBottom);
    for (int i = 0; i < 5; i++) {
        CGFloat t = -half + half * (i / 2.0);
        CGFloat off = flip ? -t : t;
        CGFloat a = (dirA + off) * M_PI / 180.0;
        out[i] = CGPointMake(c.x + R * cos(a), c.y + R * sin(a));
    }
}

// 五个球排在 ±spread 的弧上。
//
// 0.2.15 之前是「越界就缩半径 + 逐球夹取」，球贴角落时有两个问题：
//   ① 半径缩到下限 74 就不再缩，剩下的越界全靠逐个夹 —— 一侧两三个球被推到
//      同一条竖线上，弧被压成一条直线，看起来就是「展开后错位」；
//   ② 也不能靠收扇角解决：相邻夹角 = 2*half/4，收 half 会让弦长一起变小，
//      五个球直接叠在一起。
// 现在改成**扇心内推**：球心不动，把扇心沿垂直于张开方向的那一维推进安全区。
// 扇心最多推到「整扇刚好贴住安全区边缘」，弧线形状完全不变，只是整体平移。
// 只有屏幕比整扇还窄时才按比例缩半径，半径下限仍是 74（再小就叠球），
// 最后留一道逐球兜底。
- (void)sl_layoutGeometry {
    CGFloat half = SLV_FAN_HALF0;
    CGFloat R = SLV_FAN_R0;
    CGRect safe = CGRectInset(CGRectMake(0, 0, _hostSize.width, _hostSize.height), 8.0, 8.0);
    CGRect ballSafe = CGRectInset(safe, SLV_FAN_BALL_R, SLV_FAN_BALL_R);
    CGPoint pts[5];
    CGPoint c = _center;

    if (ballSafe.size.width > 0 && ballSafe.size.height > 0) {
        for (int pass = 0; pass < 4; pass++) {
            [self sl_pointsInto:pts radius:R half:half center:_center];
            // 五个点相对球心的包围盒 —— 只跟 R 和 half 有关，跟球心落在哪无关
            CGFloat minDx = 0, maxDx = 0, minDy = 0, maxDy = 0;
            for (int i = 0; i < 5; i++) {
                CGFloat dx = pts[i].x - _center.x;
                CGFloat dy = pts[i].y - _center.y;
                minDx = MIN(minDx, dx); maxDx = MAX(maxDx, dx);
                minDy = MIN(minDy, dy); maxDy = MAX(maxDy, dy);
            }
            CGFloat spanW = maxDx - minDx;
            CGFloat spanH = maxDy - minDy;

            // 整扇比安全区还大 → 按比例缩。两个方向取更狠的那个比例。
            CGFloat k = 1.0;
            if (spanW > ballSafe.size.width  && spanW > 0) k = MIN(k, ballSafe.size.width  / spanW);
            if (spanH > ballSafe.size.height && spanH > 0) k = MIN(k, ballSafe.size.height / spanH);
            if (k < 1.0) {
                CGFloat next = R * k;
                if (next >= SLV_FAN_RMIN) { R = next; continue; }
                R = SLV_FAN_RMIN;
                break;   // 到底了，剩下的交给兜底
            }

            // 放得下 → 把扇心推进安全区。横竖各自独立夹。
            CGFloat nx = MIN(MAX(_center.x, CGRectGetMinX(ballSafe) - minDx),
                             CGRectGetMaxX(ballSafe) - maxDx);
            CGFloat ny = MIN(MAX(_center.y, CGRectGetMinY(ballSafe) - minDy),
                             CGRectGetMaxY(ballSafe) - maxDy);
            c = CGPointMake(nx, ny);
            break;
        }
    }

    // 按最终扇心与半径出点
    [self sl_pointsInto:pts radius:R half:half center:c];

    // 兜底：只有「屏幕比下限半径的整扇还窄」这种极端情况会走到这里
    if (ballSafe.size.width > 0 && ballSafe.size.height > 0) {
        for (int i = 0; i < 5; i++) {
            pts[i].x = MIN(MAX(pts[i].x, CGRectGetMinX(ballSafe)), CGRectGetMaxX(ballSafe));
            pts[i].y = MIN(MAX(pts[i].y, CGRectGetMinY(ballSafe)), CGRectGetMaxY(ballSafe));
        }
    }
    memcpy(_pts, pts, sizeof(pts));
    _fanCenter = c;
    _radius = R;
    _spread = half;
}

// 0.2.15：systemIndigoColor（偏紫）→ systemBlueColor。
// 紫靛在深色背景上跟主球的绿色撞得厉害，蓝色跟「已就绪」的绿是同一套系统色阶，
// 放在一起更协调；选中态的 pill、弧、光晕都跟着这个走，改一处全变。
- (UIColor *)sl_accent { return [UIColor systemBlueColor]; }

- (void)sl_buildBalls {
    // 主球那圈 0.8pt 白色高光。小球以前没有它，所以看着像平涂的色块。
    UIColor *hairColor = [UIColor colorWithWhite:1.0 alpha:0.62];

    for (int i = 0; i < 5; i++) {
        UIView *b = [[UIView alloc] initWithFrame:CGRectMake(_center.x - SLV_FAN_BALL_R,
                                                             _center.y - SLV_FAN_BALL_R,
                                                             SLV_FAN_BALL_SIDE, SLV_FAN_BALL_SIDE)];
        b.userInteractionEnabled = NO;
        b.alpha = 0.0;
        // 阴影参数抄主球。必须给 shadowPath —— 这一层没有背景色，
        // 光靠 shadowColor / shadowOpacity 是画不出影子的。
        b.layer.shadowColor = [UIColor blackColor].CGColor;
        b.layer.shadowOpacity = 0.18;
        b.layer.shadowRadius = 9.0;
        b.layer.shadowOffset = CGSizeMake(0, 3);
        b.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:b.bounds].CGPath;

        UIVisualEffectView *blur = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
        blur.frame = b.bounds;
        blur.layer.cornerRadius = SLV_FAN_BALL_R;
        blur.layer.cornerCurve = kCACornerCurveContinuous;
        blur.clipsToBounds = YES;
        blur.userInteractionEnabled = NO;
        [b addSubview:blur];

        UIView *tint = [[UIView alloc] initWithFrame:b.bounds];
        tint.layer.cornerRadius = SLV_FAN_BALL_R;
        tint.layer.cornerCurve = kCACornerCurveContinuous;
        tint.userInteractionEnabled = NO;
        tint.alpha = 0.0;
        [b addSubview:tint];

        UIImageView *iv = [[UIImageView alloc] initWithFrame:b.bounds];
        iv.contentMode = UIViewContentModeCenter;
        iv.image = SLVFanIcon(i);
        iv.userInteractionEnabled = NO;
        [b addSubview:iv];

        UIBezierPath *outline = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b.bounds, 0.4, 0.4)
                                                          cornerRadius:SLV_FAN_BALL_R - 0.4];

        CAShapeLayer *hair = [CAShapeLayer layer];
        hair.frame = b.bounds;
        hair.path = outline.CGPath;
        hair.fillColor = [UIColor clearColor].CGColor;
        hair.strokeColor = hairColor.CGColor;
        hair.lineWidth = 0.8;
        [b.layer addSublayer:hair];

        // 状态环：开着的时候压一层 accent 描边，关着就不画（靠 hairline 勾边）
        CAShapeLayer *ring = [CAShapeLayer layer];
        ring.frame = b.bounds;
        ring.path = outline.CGPath;
        ring.fillColor = nil;
        ring.lineWidth = 1.8;
        ring.strokeColor = nil;
        [b.layer addSublayer:ring];

        // 选中光晕。0.2.13 用 transform 放大 1.14 做选中反馈，看起来像
        // 「这个球尺寸跟别的不一样」—— 改成向外扩一圈同色光晕。
        CAShapeLayer *glow = [CAShapeLayer layer];
        glow.frame = b.bounds;
        glow.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b.bounds, -4.0, -4.0)
                                               cornerRadius:SLV_FAN_BALL_R + 4.0].CGPath;
        glow.fillColor = nil;
        glow.lineWidth = 2.0;
        glow.strokeColor = [self sl_accent].CGColor;
        glow.opacity = 0.0;
        [b.layer addSublayer:glow];

        // 0.3.13：双功能球的「按住进度环」。画在球外沿一圈，strokeEnd 从 0 走到 1。
        // 只有「启用」「循环」两个球会用到，其余球的层常驻隐藏，不占视觉。
        CAShapeLayer *prog = [CAShapeLayer layer];
        prog.frame = b.bounds;
        prog.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(SLV_FAN_BALL_R, SLV_FAN_BALL_R)
                                                   radius:SLV_FAN_BALL_R + 2.0
                                               startAngle:-M_PI_2
                                                 endAngle:M_PI_2 * 3.0
                                                clockwise:YES].CGPath;
        prog.fillColor = nil;
        prog.strokeColor = [self sl_accent].CGColor;
        prog.lineWidth = 2.5;
        prog.lineCap = kCALineCapRound;
        prog.strokeEnd = 0.0;
        prog.hidden = YES;
        [b.layer addSublayer:prog];

        [self addSubview:b];
        _ball[i] = b;
        _tintV[i] = tint;
        _iconV[i] = iv;
        _ringL[i] = ring;
        _glowL[i] = glow;
        _progL[i] = prog;

        // 0.3.15：实拍时刻开着时，在循环球内的**左上角**点一个小圆点。
        //
        // 位置一路挪过三版：
        //   0.3.13  15pt 方块画在球内 (25,25) → 压图标
        //   0.3.14  挪到球外右下 +20          → 飘着，更丑
        //   0.3.15  球内左上 (-12.5,-12.5)    → 贴边、不压、不飘
        //
        // 位置：球心往**左上** 12.5pt，半径 4.5，白色 1.2 描边。
        //
        // 为什么左上这一档刚好：
        //   球心到点心 = 12.5×√2 ≈ 17.7，点半径 4.5
        //   → 点内沿离球心 13.2，图标半径只有 10  → 不压图标
        //   → 点外沿离球心 22.2，球半径 22        → 正好贴边，不飘
        //   → 进度环在 24±1.25，点外沿 22.2 还差 0.5 才碰到 → 不打架
        // 左上还有个好处：标签列在球右边，左边是空的，不会挤。
        if (i == SLVFanSwitchLoop) {
            CGPoint dc = CGPointMake(SLV_FAN_BALL_R - 12.5, SLV_FAN_BALL_R - 12.5);

            CAShapeLayer *dot = [CAShapeLayer layer];
            dot.frame = b.bounds;
            dot.path = [UIBezierPath bezierPathWithArcCenter:dc
                                                      radius:4.5
                                                  startAngle:0
                                                    endAngle:M_PI * 2.0
                                                   clockwise:YES].CGPath;
            dot.fillColor = [self sl_accent].CGColor;
            dot.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.95].CGColor;
            dot.lineWidth = 1.2;
            dot.hidden = YES;
            [b.layer addSublayer:dot];

            _badgeDot = dot;
        }
    }

    // 旋转球外圈：暗底环 + 实弧 + 端点圆点
    UIView *host = _ball[SLVFanSwitchRotate];
    CGFloat ringSide = (SLV_FAN_BALL_R + 6.0) * 2.0;
    CGFloat ringR = SLV_FAN_BALL_R + 4.0;
    CGFloat ringC = ringSide / 2.0;
    UIView *ringBox = [[UIView alloc] initWithFrame:CGRectMake((SLV_FAN_BALL_SIDE - ringSide) / 2.0,
                                                               (SLV_FAN_BALL_SIDE - ringSide) / 2.0,
                                                               ringSide, ringSide)];
    ringBox.userInteractionEnabled = NO;

    _arcTrack = [CAShapeLayer layer];
    _arcTrack.frame = ringBox.bounds;
    _arcTrack.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(ringC, ringC) radius:ringR
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
    // 沿用整块 bounds 的话，path 会画在图层左上角，dot 会整体偏掉。
    _arcTip = [CAShapeLayer layer];
    _arcTip.bounds = CGRectMake(0, 0, 7.0, 7.0);
    _arcTip.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 7.0, 7.0)].CGPath;
    _arcTip.fillColor = [self sl_accent].CGColor;
    _arcTip.hidden = YES;
    [ringBox.layer addSublayer:_arcTip];

    [host addSubview:ringBox];
    _arcRingCenter = CGPointMake(ringC, ringC);
    _arcRingR = ringR;
}

- (void)sl_buildColumn {
    CGPoint cc = [self sl_columnCenter];
    CGRect r = CGRectMake(cc.x - SLV_FAN_COL_W / 2.0, cc.y - SLV_FAN_COL_H / 2.0,
                          SLV_FAN_COL_W, SLV_FAN_COL_H);
    // 0.2.13 完全没做边界判断，贴顶 / 贴底时整列会跑出屏幕
    CGRect safe = CGRectInset(CGRectMake(0, 0, _hostSize.width, _hostSize.height), 8.0, 8.0);
    if (r.size.height <= safe.size.height && r.size.width <= safe.size.width) {
        if (CGRectGetMinX(r) < CGRectGetMinX(safe)) r.origin.x = CGRectGetMinX(safe);
        if (CGRectGetMaxX(r) > CGRectGetMaxX(safe)) r.origin.x = CGRectGetMaxX(safe) - r.size.width;
        if (CGRectGetMinY(r) < CGRectGetMinY(safe)) r.origin.y = CGRectGetMinY(safe);
        if (CGRectGetMaxY(r) > CGRectGetMaxY(safe)) r.origin.y = CGRectGetMaxY(safe) - r.size.height;
    }
    _col = [[UIView alloc] initWithFrame:r];
    _col.userInteractionEnabled = NO;
    _col.alpha = 0.0;
    // 这一层不设阴影：它自己没有背景色也没有 shadowPath，画不出影子；
    // 「把内容托起来」的效果由每个 pill 自己的 shadowPath 完成。

    UIColor *hairColor = [UIColor colorWithWhite:1.0 alpha:0.55];

    for (int i = 0; i < 4; i++) {
        CGFloat y = i * (SLV_FAN_PILL_H + SLV_FAN_PILL_GAP);
        UIView *p = [[UIView alloc] initWithFrame:CGRectMake(0, y, SLV_FAN_COL_W, SLV_FAN_PILL_H)];
        p.layer.cornerRadius = SLV_FAN_PILL_H / 2.0;
        p.layer.cornerCurve = kCACornerCurveContinuous;
        p.backgroundColor = [UIColor clearColor];
        p.layer.shadowColor = [UIColor blackColor].CGColor;
        p.layer.shadowOpacity = 0.12;
        p.layer.shadowRadius = 6.0;
        p.layer.shadowOffset = CGSizeMake(0, 2);
        p.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:p.bounds
                                                       cornerRadius:SLV_FAN_PILL_H / 2.0].CGPath;

        // 0.2.13 用的是 colorWithWhite:0.5 alpha:0.16 —— 在白色聊天页上基本是一层灰雾，
        // 文字又是 secondaryLabelColor，整列几乎读不出来。换成毛玻璃材质 + 实色文字。
        UIVisualEffectView *mat = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
        mat.frame = p.bounds;
        mat.layer.cornerRadius = SLV_FAN_PILL_H / 2.0;
        mat.layer.cornerCurve = kCACornerCurveContinuous;
        mat.clipsToBounds = YES;
        mat.userInteractionEnabled = NO;
        [p addSubview:mat];

        UIView *sel = [[UIView alloc] initWithFrame:p.bounds];
        sel.layer.cornerRadius = SLV_FAN_PILL_H / 2.0;
        sel.layer.cornerCurve = kCACornerCurveContinuous;
        sel.backgroundColor = [self sl_accent];
        sel.alpha = 0.0;
        sel.userInteractionEnabled = NO;
        [p addSubview:sel];

        CAShapeLayer *hair = [CAShapeLayer layer];
        hair.frame = p.bounds;
        hair.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(p.bounds, 0.25, 0.25)
                                               cornerRadius:SLV_FAN_PILL_H / 2.0].CGPath;
        hair.fillColor = [UIColor clearColor].CGColor;
        hair.strokeColor = hairColor.CGColor;
        hair.lineWidth = 0.5;
        [p.layer addSublayer:hair];

        // 底环：一整圈淡色轨道，四档都画。
        // 以前只有「进度弧」，而 0° 那档 strokeEnd = 0，等于什么都不画 ——
        // 「不旋转」那行看着像漏了图标，跟旁边三行不在一个语汇里。
        // 有了底环，0° 显示成一枚空环，1/4、2/4、3/4 则是环上一段实色弧，
        // 四行是同一个「环形刻度」的四个刻度，视觉上就齐了。
        CAShapeLayer *track = [CAShapeLayer layer];
        track.frame = CGRectMake(7.0, (SLV_FAN_PILL_H - 22.0) / 2.0, 22.0, 22.0);
        track.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(11.0, 11.0) radius:8.5
                                                startAngle:-M_PI_2 endAngle:M_PI_2 * 3.0
                                                 clockwise:YES].CGPath;
        track.fillColor = nil;
        track.strokeColor = [[self sl_accent] colorWithAlphaComponent:0.20].CGColor;
        track.lineWidth = 2.2;
        [p.layer addSublayer:track];

        CAShapeLayer *arc = [CAShapeLayer layer];
        arc.frame = CGRectMake(7.0, (SLV_FAN_PILL_H - 22.0) / 2.0, 22.0, 22.0);
        arc.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(11.0, 11.0) radius:8.5
                                              startAngle:-M_PI_2 endAngle:M_PI_2 * 3.0
                                               clockwise:YES].CGPath;
        arc.fillColor = nil;
        arc.strokeColor = [self sl_accent].CGColor;
        arc.lineWidth = 2.2;
        arc.lineCap = kCALineCapRound;
        arc.strokeEnd = i * 0.25;
        [p.layer addSublayer:arc];

        UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(36.0, 0, SLV_FAN_COL_W - 44.0, SLV_FAN_PILL_H)];
        lab.text = SLVFanAngleName(i);
        lab.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightMedium];
        lab.textColor = [UIColor labelColor];
        lab.userInteractionEnabled = NO;
        [p addSubview:lab];

        [_col addSubview:p];
        _pill[i] = p;
        _pillSel[i] = sel;
        _pillArc[i] = arc;
        _pillLab[i] = lab;
    }
    [self addSubview:_col];
}

- (CGPoint)sl_columnCenter {
    CGFloat a = [self sl_dirAngle] * M_PI / 180.0;
    CGFloat dist = SLV_FAN_BALL_R + 8.0 + SLV_FAN_COL_W / 2.0;
    CGPoint r = _pts[SLVFanSwitchRotate];
    return CGPointMake(r.x + dist * cos(a), r.y + dist * sin(a));
}

// 命中判定一律用 center 推矩形，不用 frame —— 列展开动画里带着 (-10, 0) 的平移，
// frame 在那 0.24 秒里是偏的，命中区和眼睛看到的对不上。
- (CGRect)sl_colRect {
    if (!_col) return CGRectZero;
    CGPoint c = _col.center;
    return CGRectMake(c.x - SLV_FAN_COL_W / 2.0, c.y - SLV_FAN_COL_H / 2.0,
                      SLV_FAN_COL_W, SLV_FAN_COL_H);
}

#pragma mark 状态

- (void)sl_reloadStates {
    BOOL en = SLVFanBool(kSLCamEnabledKey, YES);
    BOOL muted = !SLVFanBool(kSLCamAudioKey, YES);
    BOOL loop = SLVFanBool(kSLCamLoopKey, YES);
    BOOL mir = SLVFanBool(kSLCamMirrorKey, NO);
    NSInteger rot = SLVFanInt(kSLCamRotateKey, 0);
    rot %= 360;
    if (rot < 0) rot += 360;
    if (rot != 90 && rot != 180 && rot != 270) rot = 0;

    _on[SLVFanSwitchEnabled] = en;
    _on[SLVFanSwitchMute] = muted;
    _on[SLVFanSwitchRotate] = (rot != 0);
    _on[SLVFanSwitchMirror] = mir;
    _on[SLVFanSwitchLoop] = loop;

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
    _tintV[i].alpha = on ? 0.20 : 0.0;
    _iconV[i].tintColor = on ? accent : [UIColor colorWithWhite:0.55 alpha:1.0];
    _ringL[i].strokeColor = on ? [accent colorWithAlphaComponent:0.9].CGColor : nil;

    // 0.3.15：实拍时刻开着 → 循环球内左上角亮一个小圆点
    if (i == SLVFanSwitchLoop && _badgeDot) {
        _badgeDot.hidden = !SLVFanBool(kSLCamSquareCropKey, NO);
    }
}

- (void)sl_refreshArc {
    // 必须关掉隐式动画。
    //
    // strokeEnd 和 position 都是独立 CAShapeLayer 的属性，默认带 0.25s 隐式动画。
    // 拖拽时每帧改目标值：strokeEnd 沿路径插值（对的），position 却是**两点之间
    // 直线插值** —— 走的是弦不是弧，点会离开圆环抄近路。这就是「点的运动轨迹有问题」。
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _arcLive.strokeEnd = _arcProgress;
    _arcTip.hidden = (_arcProgress < 0.02);
    if (!_arcTip.hidden) {
        CGFloat a = _arcProgress * M_PI * 2.0;
        _arcTip.position = CGPointMake(_arcRingCenter.x + _arcRingR * sin(a),
                                       _arcRingCenter.y - _arcRingR * cos(a));
    }
    [CATransaction commit];
}

- (void)sl_refreshPills {
    for (int i = 0; i < 4; i++) {
        BOOL sel = (_angleOpen && i == _angleIndex);
        _pillSel[i].alpha = sel ? 0.22 : 0.0;
        _pillLab[i].textColor = sel ? [self sl_accent] : [UIColor labelColor];
        _pillLab[i].font = [UIFont systemFontOfSize:13.5
                                             weight:(sel ? UIFontWeightSemibold : UIFontWeightMedium)];
        _pillArc[i].strokeColor = (sel ? [self sl_accent]
                                       : [[self sl_accent] colorWithAlphaComponent:0.5]).CGColor;
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
    // 调用方在 sl_hide 之前已经读过 slWantsLibrary / slWantsSquareCrop，
    // 这里清掉不会丢结果。
    [self sl_cancelArmProgress];
    [self sl_setArmedSwitch:-1];
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
            _hover = SLVFanSwitchRotate;
            [self sl_applyHover];
            [self sl_setArcFromPoint:p];
            return;
        }
        if ([self sl_inKeepAlive:p]) {
            // 落在「球 → 列」的走廊或列的边缘缓冲里：保持展开，角度不变。
            // 0.2.13 没有这一层 —— 球的命中半径 27pt 和列的左边缘正好重合，
            // 两者只在一个点相接，手指一抖 hit 就变 -1，列立刻收掉。
            _hover = SLVFanSwitchRotate;
            [self sl_applyHover];
            return;
        }
        [self sl_setAngleOpen:NO];
        _arcProgress = _shownAngle * 0.25;
        [self sl_refreshArc];
    }

    _hover = hit;
    [self sl_applyHover];

    if (hit == SLVFanSwitchRotate) {
        if (!_angleOpen && !_anglePending) {
            _anglePending = YES;
            __weak typeof(self) ws = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.16 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                SLVFanView *ss = ws;
                if (!ss) return;
                ss->_anglePending = NO;
                if (ss->_hover == SLVFanSwitchRotate && !ss->_angleOpen) {
                    ss->_angleIndex = ss->_shownAngle;
                    ss->_arcProgress = ss->_shownAngle * 0.25;
                    [ss sl_setAngleOpen:YES];
                    [ss sl_refreshArc];
                }
            });
        }
    }

    // 0.3.13：双功能球 —— 停住不动 0.55s 转成第二功能，松手执行第二功能。
    //   启用球 → 进素材库      循环球 → 切实拍时刻
    // 其余三个球只有单一功能，滑过去就是切开关，不参与这套。
    BOOL dual = (hit == SLVFanSwitchEnabled || hit == SLVFanSwitchLoop);
    if (!dual) {
        [self sl_cancelArmProgress];
        [self sl_setArmedSwitch:-1];
        return;
    }
    // 0.3.14：同一颗球已经在计时就直接返回。
    //
    // 这一行是「环快跑满了又从头跑」的解药。0.3.13 只判 _armedSwitch，
    // 而它要 0.55s 之后才赋值 —— 这段时间里 sl_trackPoint: 每次 touch move
    // 都会被调用一次，手指只要抖 1px 就会把环清零重跑。
    if (_armedSwitch == hit || _armBall == hit) return;

    // 换球了：先把上一颗的进度收掉，再给这颗起新的
    [self sl_cancelArmProgress];
    NSInteger token = ++_armToken;
    NSInteger target = hit;
    [self sl_startArmProgress:target];

    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SLVFanView *ss = ws;
        if (!ss || ss->_armToken != token) return;
        // 松手后 _hover 会被 sl_hide 清成 -1，所以这里能顺带挡掉「刚滑过去就松手」
        if (ss->_hover == target) [ss sl_setArmedSwitch:target];
    });
}

/// 给某颗球起一次按住进度：环从 0 线性走到 1，时长和判定阈值一致。
- (void)sl_startArmProgress:(NSInteger)sw {
    if (sw < 0 || sw >= 5) return;
    CAShapeLayer *p = _progL[sw];
    if (!p) return;

    _armBall = sw;                        // 记住「正在计时的是这颗」

    p.hidden = NO;
    p.strokeEnd = 1.0;                    // 模型值直接设终态，动画只负责过程
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
    a.fromValue = @0.0;
    a.toValue = @1.0;
    a.duration = 0.55;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    [p addAnimation:a forKey:@"slArm"];

    // 0.3.15：落球给一次 Medium —— 0.3.14 用 Light 太轻，实际用下来「没什么感觉」。
    // 这一下是告诉手指「已经开始计时了，再按住不动就能换功能」。
    UIImpactFeedbackGenerator *h =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [h prepare];
    [h impactOccurred];
}

/// 收掉所有进度环，并作废还在跑的计时回调。
- (void)sl_cancelArmProgress {
    _armToken++;                          // 旧回调看到令牌对不上就自己退出
    _armBall = -1;
    for (int i = 0; i < 5; i++) {
        if (!_progL[i]) continue;
        [_progL[i] removeAnimationForKey:@"slArm"];
        _progL[i].strokeEnd = 0.0;
        _progL[i].hidden = YES;
    }
}

/// 把某颗球切成第二功能（-1 = 全部恢复）。
///
/// 图标和进度环**一起**变 —— 保证「看到的」和「松手会执行的」永远是同一个功能。
/// 只换文字不换图标（或反过来）就会出现「写着循环、松手却切了实拍时刻」的错位。
- (void)sl_setArmedSwitch:(NSInteger)sw {
    if (_armedSwitch == sw) return;
    NSInteger old = _armedSwitch;
    _armedSwitch = sw;

    if (old >= 0 && old < 5) {
        _iconV[old].image = SLVFanIcon(old);
        _iconV[old].transform = CGAffineTransformIdentity;
    }
    if (sw >= 0 && sw < 5) {
        _iconV[sw].image = (sw == SLVFanSwitchEnabled) ? SLVFanLibraryIcon()
                                                       : SLVFanSquareCropIcon();

        // 0.3.15：环满换功能用 **Heavy + Rigid 双段**。
        // 0.3.14 是单发 Medium，实机几乎摸不到。Heavy 打底、60ms 后补一发 Rigid，
        // 两下叠起来是 UIKit 能给的最强手感（不用 CoreHaptics 也不会太吵）。
        UIImpactFeedbackGenerator *hHeavy =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
        [hHeavy prepare];
        [hHeavy impactOccurred];

        UIImpactFeedbackGenerator *hRigid =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleRigid];
        [hRigid prepare];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [hRigid impactOccurred];      // block 持有它，不会提前释放
        });

        // 图标弹一下。光换图不弹，眼睛容易漏掉 —— 这一下是把「换了」推到眼前。
        UIImageView *iv = _iconV[sw];
        iv.transform = CGAffineTransformMakeScale(0.78, 0.78);
        [UIView animateWithDuration:0.34
                              delay:0
             usingSpringWithDamping:0.48
              initialSpringVelocity:0.7
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ iv.transform = CGAffineTransformIdentity; }
                         completion:nil];
    }
}

/// 从旋转球到角度列之间的「安全带」：球本身（外扩 14）∪ 列（外扩 10）∪ 走廊。
/// 只要手指还在这块区域里，列就不收。
- (BOOL)sl_inKeepAlive:(CGPoint)p {
    CGPoint rc = _pts[SLVFanSwitchRotate];
    if (hypot(p.x - rc.x, p.y - rc.y) <= SLV_FAN_BALL_R + 14.0) return YES;

    CGRect col = [self sl_colRect];
    if (CGRectContainsPoint(CGRectInset(col, -10.0, -10.0), p)) return YES;

    // 走廊：沿轴向从球心铺到列的外缘，横向按列的宽度给足
    CGRect corridor;
    switch (_edge) {
        case SLVFanEdgeLeft:
            corridor = CGRectMake(rc.x, CGRectGetMinY(col) - 10.0,
                                  CGRectGetMinX(col) - rc.x + 10.0, col.size.height + 20.0);
            break;
        case SLVFanEdgeRight:
            corridor = CGRectMake(CGRectGetMaxX(col) - 10.0, CGRectGetMinY(col) - 10.0,
                                  rc.x - CGRectGetMaxX(col) + 10.0, col.size.height + 20.0);
            break;
        case SLVFanEdgeTop:
            corridor = CGRectMake(CGRectGetMinX(col) - 10.0, rc.y,
                                  col.size.width + 20.0, CGRectGetMinY(col) - rc.y + 10.0);
            break;
        default:
            corridor = CGRectMake(CGRectGetMinX(col) - 10.0, CGRectGetMaxY(col) - 10.0,
                                  col.size.width + 20.0, rc.y - CGRectGetMaxY(col) + 10.0);
            break;
    }
    return CGRectContainsPoint(corridor, p);
}

/// 手指纵向位置 → 弧长。0 → 0.75 圈，走满四档。
- (void)sl_setArcFromPoint:(CGPoint)p {
    CGRect col = [self sl_colRect];
    CGFloat top = CGRectGetMinY(col) + SLV_FAN_PILL_H / 2.0;
    CGFloat span = (SLV_FAN_PILL_H + SLV_FAN_PILL_GAP) * 3.0;
    CGFloat t = (p.y - top) / span;
    if (t < 0.0) t = 0.0;
    if (t > 1.0) t = 1.0;
    _arcProgress = t * 0.75;
    _angleIndex = (NSInteger)lround(_arcProgress / 0.25);
    if (_angleIndex < 0) _angleIndex = 0;
    if (_angleIndex > 3) _angleIndex = 3;
    [self sl_refreshArc];
    [self sl_refreshPills];
}

- (void)sl_applyHover {
    for (int i = 0; i < 5; i++) {
        BOOL hot = (_hover == i);
        CGFloat glow = hot ? 1.0 : 0.0;
        CGFloat dim = (_hover < 0 || hot) ? 1.0 : 0.62;
        [UIView animateWithDuration:0.16 delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self->_ball[i].alpha = dim;
        } completion:nil];
        // 光晕用 opacity 动画，不改 transform —— 缩放会让五个球看起来尺寸不一
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"opacity"];
        a.fromValue = @((float)_glowL[i].opacity);
        a.toValue = @((float)glow);
        a.duration = 0.16;
        _glowL[i].opacity = (float)glow;
        [_glowL[i] addAnimation:a forKey:@"slGlow"];
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
        if (d <= SLV_FAN_BALL_R + 8.0 && d < bestD) { bestD = d; best = i; }
    }
    return best;
}

- (NSInteger)sl_hitAngle:(CGPoint)p {
    if (!_angleOpen) return -1;
    CGRect col = [self sl_colRect];
    // 四周外扩：纵向 8pt 让掉在 pill 间隙里的手指也能吸附到最近一档
    if (!CGRectContainsPoint(CGRectInset(col, -10.0, -8.0), p)) return -1;
    CGFloat y = p.y - CGRectGetMinY(col);
    NSInteger i = (NSInteger)floor(y / (SLV_FAN_PILL_H + SLV_FAN_PILL_GAP));
    if (i < 0) i = 0;
    if (i > 3) i = 3;
    return i;
}

#pragma mark 结果

- (NSInteger)slPickedSwitch {
    return _hover;
}

- (NSInteger)slPickedAngle {
    if (_hover != SLVFanSwitchRotate || !_angleOpen) return -1;
    return _angleIndex;
}

- (BOOL)slWantsLibrary {
    return _armedSwitch == SLVFanSwitchEnabled;
}

- (BOOL)slWantsSquareCrop {
    return _armedSwitch == SLVFanSwitchLoop;
}

- (CGPoint)slFanCenter {
    return _fanCenter;
}

@end

#pragma mark - 提交

void SLVFanCommit(NSInteger sw, NSInteger angle) {
    if (sw < 0) return;
    BOOL changed = NO;
    NSString *msg = nil;
    switch (sw) {
        case SLVFanSwitchEnabled: {
            BOOL on = !SLVFanBool(kSLCamEnabledKey, YES);
            SLVFanSetBool(kSLCamEnabledKey, on);
            msg = on ? @"替换：开" : @"替换：关";
            changed = YES;
            break;
        }
        case SLVFanSwitchMute: {
            // 这个开关管的是「素材里的声音」，不是「麦克风静音」：
            // 关掉 = 素材不发声，真麦克风原样放行。
            BOOL on = !SLVFanBool(kSLCamAudioKey, YES);
            SLVFanSetBool(kSLCamAudioKey, on);
            msg = on ? @"声音：开" : @"声音：关";
            changed = YES;
            break;
        }
        case SLVFanSwitchRotate: {
            // 角度列还没展开就松手（手指只是从旋转球上路过）→ 什么都不改。
            // 原来这里把 -1 当 0 处理，一次误触就会把用户设好的 180° 清成「不旋转」。
            if (angle < 0) break;
            SLVFanSetInt(kSLCamRotateKey, angle * 90);
            NSArray<NSString *> *names = @[@"方向：不旋转", @"方向：90°", @"方向：180°", @"方向：270°"];
            msg = names[angle % 4];
            changed = YES;
            break;
        }
        case SLVFanSwitchMirror: {
            BOOL on = !SLVFanBool(kSLCamMirrorKey, NO);
            SLVFanSetBool(kSLCamMirrorKey, on);
            msg = on ? @"镜像：开" : @"镜像：关";
            changed = YES;
            break;
        }
        case SLVFanSwitchLoop: {
            BOOL on = !SLVFanBool(kSLCamLoopKey, YES);
            SLVFanSetBool(kSLCamLoopKey, on);
            msg = on ? @"循环：开" : @"循环：关";
            changed = YES;
            break;
        }
        default:
            break;
    }
    if (changed) {
        SLVCamReloadAll();
        // 松开手指那一刻扇已经收了，屏幕上什么反馈都没有 —— 补一句说明改了什么。
        if (msg.length) SLVToast(msg);
    }
}

void SLVFanToggleSquareCrop(void) {
    BOOL on = !SLVFanBool(kSLCamSquareCropKey, NO);
    SLVFanSetBool(kSLCamSquareCropKey, on);
    SLVCamReloadAll();
    // 0.3.15：文案砍到最短。这时候手上已经有中震 + 图标切换 + 成功震三重反馈了，
    // toast 只负责确认「现在是开还是关」，不需要再解释「不放大 / 铺满」。
    SLVToast(on ? @"不放大 开" : @"不放大 关");
}
