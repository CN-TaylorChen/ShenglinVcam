//
//  SLVFloatingBall.m
//  声临 · 虚拟摄像头 —— 悬浮球 / 胶囊 / 玻璃浮窗（底包外壳，不含任何业务）
//
//  从 ShenglinMomo 的 SLVEntry.m 抽出来，删掉了语音包列表三个类（SLVPackMenu /
//  SLVPackMenuRow / SLVPackGroupRow）和所有 SLVVoicePack 调用，改成 SLVCamBridge 里
//  那几个函数。业务侧只看到三件事：开关（SLVCamEnabled）、胶囊上的名字
//  （SLVCamCurrentName）、点箭头弹什么（SLVCamHandleArrowTap）。
//
//  外观部分沿用底包：状态配色、光环呼吸、自定义图标律动、名字滚动、
//  拖动跟手 + 越线翻面 + 松手贴边、球位比例存储、窗口迁移。
//  0.2.26 把球上的图形换成了「叠层」（两个错开的框），动画也从四态收到两态 ——
//  Vcam 只有空闲和装填两种形态，陌陌那套录音/合成的节奏在这里永远不会触发。
//

#import "SLFloatingBall.h"
#import "SLSettingsPanel.h"
#import "SLMediaListController.h"
#import "SLMediaPreview.h"
#import "SLCamBridge.h"
#import "SLFan.h"
#import "SLUtil.h"
#import "SLLog.h"
#import "SLGlass.h"
#import <PhotosUI/PhotosUI.h>
#import <AVFoundation/AVFoundation.h>
#include <stdlib.h>   // v0.4.75：SLVHazeImage 里的 calloc/free

// ===================== 悬浮球图标 =====================
// v0.4.33：默认图标换成「双声波」品牌图形（代码绘制，黑底 + 六根条：
// 左三根 30% 白表示被替换掉的原声，右三根纯白表示合成声）。
// 存一个字符串：
//   brand            品牌图形（默认）
//   image:icon.png   相册选的自定义图片（已裁成圆形，存沙盒）
//   text:xxx         旧版遗留值，读取时自动迁移成默认
#define kSLFloatIconKey @"SLVFloatIcon"
// 0.3.0 改名前的旧键（当时和声临陌陌同名，同进程会互相抢图标）。只读不写。
#define kSLFloatIconKeyOld @"SLFloatIcon"
#define kSLFloatIconDefault @"brand"

// v0.4.74：自定义图标动效。外圈（光晕 + 26% 状态底色）永远不动，
// 四态差异全部由图标自身的运动表达。
// v0.4.80：动效不再是可选项 —— 设置页里「图标动效」整段删掉，只要当前图标是
// 自定义图片就默认走律动（四态缩放，合成态「泵动」：慢缩 → 急弹 → 缓落）。
// 这个键 v0.4.80 起不再读写，留着只为旧版本存过的值不显得突兀。
#define kSLFloatEffectKey @"SLVFloatEffect"

static NSString *SLVFloatIconDir(void) {
    NSString *dir = [SLVDocumentsPath() stringByAppendingPathComponent:@"ShenglinMomo/float"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return dir;
}

static NSString *SLVFloatIconImagePath(NSString *name) {
    return [SLVFloatIconDir() stringByAppendingPathComponent:(name.length ? name : @"icon.png")];
}

// v0.4.75：胶囊底色 = 图标图的「色晕」。
// 把图片降采样成 32×6 再交给 UIImageView 拉伸，靠 layer 的线性插值自己平滑成一条横向色带。
// 只留大块明暗与色相分布、不留任何细节，所以胶囊上不会出现「一张缩略图糊上去」。
// 取景跟 _thumb 的 aspectFill 对齐（中心横条），色晕和图标才是同一段画面。
// v0.4.76：目标网格改成参数 —— 胶囊用 32×6；列表卡片用 6×1（面积大，32 段会拉出竖光带）。
static UIImage *SLVHazeImage(UIImage *src, size_t w, size_t h) {
    if (!src.CGImage || w == 0 || h == 0) return nil;
    unsigned char *buf = (unsigned char *)calloc(w * h * 4, sizeof(unsigned char));
    if (!buf) return nil;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return nil; }

    CGImageRef cg = src.CGImage;
    CGFloat iw = (CGFloat)CGImageGetWidth(cg), ih = (CGFloat)CGImageGetHeight(cg);
    CGFloat bandH = iw * (CGFloat)h / (CGFloat)w;   // 保持宽高比，别把脸压扁
    if (bandH > ih) bandH = ih;
    CGImageRef part = CGImageCreateWithImageInRect(cg, CGRectMake(0.0, (ih - bandH) * 0.5, iw, bandH));
    if (part) {
        CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
        CGContextDrawImage(ctx, CGRectMake(0.0, 0.0, (CGFloat)w, (CGFloat)h), part);
        CGImageRelease(part);
    }
    CGImageRef small = CGBitmapContextCreateImage(ctx);
    UIImage *out = small ? [UIImage imageWithCGImage:small scale:1.0 orientation:UIImageOrientationUp] : nil;
    if (small) CGImageRelease(small);
    CGContextRelease(ctx);
    free(buf);
    return out;
}

static NSString *SLVFloatIconValue(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *v = [d stringForKey:kSLFloatIconKey];
    if (!v.length) {
        // 0.3.0 改名迁移：旧键里的值搬过来，用户选过的自定义图标不会丢。
        NSString *old = [d stringForKey:kSLFloatIconKeyOld];
        if (old.length) {
            [d setObject:old forKey:kSLFloatIconKey];
            v = old;
        }
    }
    if (!v.length) return kSLFloatIconDefault;
    if ([v hasPrefix:@"text:"]) return kSLFloatIconDefault;        // 旧版文字图标 → 默认
    return v;
}

// v0.4.80：没有「关闭」这一档了。只要图标是自定义图片就走律动，
// 真正决定动不动的是 sl_updateIconMotion 里的「当前有没有图」——
// 默认叠层图标本来就是自己那套动画，不走这里。
static NSInteger SLVFloatEffectValue(void) {
    return 1;
}

NSString *SLVFloatIconSummary(void) {
    NSString *v = SLVFloatIconValue();
    NSString *base = @"默认";
    if ([v hasPrefix:@"image:"]) base = @"自定义图片";
    // v0.4.80：动效固定随图片开启，右侧不再挂「· 律动」后缀
    return base;
}

// 品牌图形：黑底圆 + 两个错开的圆角框。
//
// 0.2.26 换掉了原来那套竖条。竖条是「声临·陌陌」的音频波形语义，装在虚拟摄像头上
// 说不通，而且两个 tweak 同时装时图标长得一样、球分不出谁是谁。
//
// 现在的语义是「叠层」：前面一张画面完整，后面一张从右侧透出来 —— 你看到的这一层
// 底下还压着另一层，正好对上虚拟摄像头的实际行为（送去编码的是素材，不是现场）。
//
// 100 单位为画布基准，跟设计稿一一对应，48pt 球和 44pt 标题栏图标是同一张图。
//
// 0.3.2：图形整体缩到圆内的 66%。
// 图形是按 100 单位的**正方形**铺的（y 从 4 到 96，几乎顶满），但底色是个**圆**：
// y=4 那个高度圆的宽度只有 39 单位，而框有 56 单位宽 —— 框比圆还宽，白框的角就戳到
// 圆外面去了（标题栏上看着像「白色贴纸没裁好」）。
// 图形最外点离圆心 63.5 单位，圆半径只有 50，所以最多只能缩到 78% 才刚好贴边；
// 取 66%，四周留出 8.1% 的黑边，像素对齐抖一下也不会擦到。
static const CGFloat kSLVBrandGlyphScale = 0.66;

static UIImage *SLVBrandIcon(CGFloat side, UIColor *bg) {
    if (side <= 0) side = 96;
    UIColor *base = bg ?: [UIColor blackColor];
    BOOL small = (side < 32.0);
    CGFloat lwU = small ? 6.5 : 8.5;
    CGFloat radU = small ? 15.0 : 17.0;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextSetFillColorWithColor(c, base.CGColor);
        CGContextFillEllipseInRect(c, CGRectMake(0, 0, side, side));
        // 圆心对齐的等比缩小：底色画完之后再改坐标系，圆本身不受影响。
        // 描边宽度会跟着一起缩 —— 这正是想要的，不然缩完线条会显得过粗。
        CGFloat k = kSLVBrandGlyphScale;
        CGContextTranslateCTM(c, side * (1.0 - k) * 0.5, side * (1.0 - k) * 0.5);
        CGContextScaleCTM(c, k, k);
        CGFloat u = side / 100.0;
        CGFloat lw = lwU * u;
        CGFloat rad = radU * u;
        CGRect frontRect = CGRectMake(2.0 * u, 4.0 * u, 56.0 * u, 92.0 * u);
        CGRect backRect  = CGRectMake(42.0 * u, 4.0 * u, 56.0 * u, 92.0 * u);
        // 后框只留「前框右边线以右」那半截。整条画出来的话，它的左边线会落在
        // 前框内部（相隔 7.5 单位），小尺寸下两条竖线糊成「|||」，像三根柱子。
        CGContextSaveGState(c);
        CGContextClipToRect(c, CGRectMake(CGRectGetMaxX(frontRect), 0, side, side));
        [[UIColor colorWithWhite:1.0 alpha:0.5] setStroke];
        UIBezierPath *back = [UIBezierPath bezierPathWithRoundedRect:backRect cornerRadius:rad];
        back.lineWidth = lw;
        [back stroke];
        CGContextRestoreGState(c);
        [[UIColor whiteColor] setStroke];
        UIBezierPath *front = [UIBezierPath bezierPathWithRoundedRect:frontRect cornerRadius:rad];
        front.lineWidth = lw;
        [front stroke];
    }];
}

UIImage *SLVBrandIconImage(CGFloat side) {
    return SLVBrandIcon(side, nil);
}

UIImage *SLVBrandIconImageTinted(CGFloat side, UIColor *bg) {
    return SLVBrandIcon(side, bg);
}

// 小尺寸版本：去掉底色，线条换成传进来的颜色，供模板图 / 标题栏这类静态场合用。
//
// 0.3.0：后框加了一道裁切 —— 只保留「前框右边线以右」的那半截。
// 原来后框整条画出来，它的左边线（x=42）正好落在前框内部（2..58），
// 两条竖线只隔 7.5 单位，22pt 标题栏上糊成「|||」，看起来像三根柱子而不是两张叠起来的卡。
// 裁掉之后后框只剩右侧露出的一小截，语义回到「前面这张挡着后面那张」。
// 尺寸小的时候描边和圆角再收一点，否则 22pt 下前框的洞会被描边吃掉。
static UIImage *SLVBrandGlyphCompact(CGFloat side, UIColor *color) {
    if (side <= 0) side = 44;
    UIColor *c = color ?: [UIColor labelColor];
    BOOL small = (side < 32.0);
    CGFloat lwU = small ? 6.5 : 8.5;
    CGFloat radU = small ? 15.0 : 17.0;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef cg = ctx.CGContext;
        CGFloat u = side / 100.0;
        CGFloat lw = lwU * u;
        CGFloat rad = radU * u;
        CGRect frontRect = CGRectMake(2.0 * u, 4.0 * u, 56.0 * u, 92.0 * u);
        CGRect backRect  = CGRectMake(42.0 * u, 4.0 * u, 56.0 * u, 92.0 * u);

        CGContextSaveGState(cg);
        CGContextClipToRect(cg, CGRectMake(CGRectGetMaxX(frontRect), 0, side, side));
        [[c colorWithAlphaComponent:0.5] setStroke];
        UIBezierPath *back = [UIBezierPath bezierPathWithRoundedRect:backRect cornerRadius:rad];
        back.lineWidth = lw;
        [back stroke];
        CGContextRestoreGState(cg);

        [c setStroke];
        UIBezierPath *front = [UIBezierPath bezierPathWithRoundedRect:frontRect cornerRadius:rad];
        front.lineWidth = lw;
        [front stroke];
    }];
}

// 对外：无底色的品牌图形，颜色自己给。标题栏、列表缩略图这类场合用这个，
// 别再拿 SLVBrandIconImage（那张带黑色圆底，小尺寸下会糊成一坨黑）。
UIImage *SLVBrandGlyphImage(CGFloat side, UIColor *color) {
    return SLVBrandGlyphCompact(side, color);
}

// 把任意图片居中裁成圆形（直接当 backgroundImage 用，省得给按钮加裁剪打断阴影）
static UIImage *SLVCircleIcon(UIImage *src) {
    if (!src) return nil;
    CGSize s = CGSizeMake(120, 120);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:s format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextAddEllipseInRect(c, CGRectMake(0, 0, s.width, s.height));
        CGContextClip(c);
        CGFloat iw = src.size.width, ih = src.size.height;
        if (iw <= 0 || ih <= 0) return;
        CGFloat sc = MAX(s.width / iw, s.height / ih);
        CGRect dst = CGRectMake((s.width - iw * sc) / 2.0, (s.height - ih * sc) / 2.0, iw * sc, ih * sc);
        [src drawInRect:dst];
    }];
}

static BOOL SLVSaveFloatIconImage(UIImage *img) {
    UIImage *c = SLVCircleIcon(img);
    NSData *d = c ? UIImagePNGRepresentation(c) : nil;
    if (!d.length) return NO;
    if (![d writeToFile:SLVFloatIconImagePath(@"icon.png") atomically:YES]) return NO;
    [[NSUserDefaults standardUserDefaults] setObject:@"image:icon.png" forKey:kSLFloatIconKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    return YES;
}

static void SLVApplyFloatIcon(UIButton *btn);

// 0.2.27：球贴边时离屏幕边缘留多少。
//
// 原来写死 4pt，但外圈光晕是 CGRectInset(b, -7, -7) + 2pt 描边 —— 向外要 8pt。
// 留 4pt 装 8pt 的东西，贴边那一侧的光晕就被屏幕切掉一条弧，看着像缺了一块。
// 10pt = 光晕 8pt + 2pt 余量，阴影（radius 9 / offset y+3）也基本容得下。
// 拖动的实时夹取和松手贴边都用这一个值，别各写一份。
static const CGFloat SLVBallEdgeInset = 10.0;

// v0.4.40：位置相关的三个工具（定义在文件后面，拖动手势要用到）
static CGSize SLVHostSizeFor(UIView *sv);
static CGPoint SLVClampFloatPos(CGPoint c, CGSize size);
static void SLVStoreFloatPos(CGPoint c, CGSize size);
static CGPoint SLVLoadFloatPos(CGSize size);

// v0.4.60：合成完成「落定」回弹的静音开关。
// 试听面板那条路本身有卡片弹入动画，「完成」的信号已经给足了，球再缩一下就撞车；
// 所以在面板路径上临时静音，只有「无面板直接就绪」才保留回弹。
static BOOL sSLFloatSettleMuted = NO;

// ===================== 浮动入口 =====================

// 20931 是声临陌陌在用的 tag。两个 dylib 同进程加载时，同 tag 会互相 viewWithTag
// 抢到对方的球，所以 Vcam 单独换一个值。改 tag 只是避让，不是根治 ——
// 类名/函数名同名的那批（见 0.3.0 改名）才是真正的符号冲突。
#define SLVBtnTag 20941

// ===================== 设置 / 语音包浮窗 =====================
// v0.4.33：设置页不再用 PageSheet 从底部整页推上来，改成一张固定尺寸的
// 圆角毛玻璃浮窗，浮在陌陌界面中间。尺寸写死，只有窗内内容能滚动。
// v0.4.34：语音包也住进同一个容器（原先还是 PageSheet，跟设置页两套观感）。

// 接口声明在 SLVFloatingBall.h（底包对外暴露），实现见本文件末尾

// ===================== 悬浮球：毛玻璃 + 呼吸光晕 + 胶囊下拉 =====================
// v0.4.36 交互重排（用户定稿）：
//   单击球 → 变成胶囊；再单击胶囊（右端箭头除外）→ 收回成球；
//   单击胶囊右端箭头 → 胶囊正下方展开语音包列表（含「原声」一行）；
//   长按球 → 进设置（长按胶囊不做事）。
// 状态：空闲灰白光晕 2.8s / 录音红 0.9s / 合成蓝 1.4s / 就绪蓝常亮到发送完成。
// 就绪不再自动回空闲，发出去的那一刻外扩一圈涟漪再回空闲。

#define SLVBallSide 48.0

// v0.4.44：下压留白改成 0。
// 之前留 14pt 是为了让搜索栏不压圆角，但导航栏是透明的 —— 那 14pt 成了整张卡片上
// 唯一「没被任何内容盖住」的裸玻璃，比下面被列表染色的区域更亮，就是用户看到的那条白边。
// 改外观、改裁剪都治不了它，因为它根本不是某张图画的，而是「空出来的那块」。
// 现在导航栏贴到卡片顶：44pt 高的内容垂直居中，实际距顶 10pt，26pt 圆角在 y=10 处
// 只向内收 5.5pt，而按钮/搜索胶囊距左右边缘 12~16pt —— 不会压到弧线。
static const CGFloat kSLPanelTopPad = 0.0;

// v0.4.43：1×1 全透明图。
// 老写法 setBackgroundImage:[UIImage new] 传的是 0×0 的空图，UIKit 会**当没设**，
// 于是回落到系统默认的导航栏背景图 —— 那张图是「顶部纯白 → 向下渐隐 + 底部 0.5pt 线」，
// 视觉上就是压不掉的一条顶部白。必须给真图，尺寸 0 的图不算数。
static UIImage *SLVTransparentImage(void) {
    static UIImage *img = nil;
    if (img) return img;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    fmt.scale = 1.0;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(1, 1) format:fmt];
    img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;   // 什么都不画 = 全透明
    }];
    return img;
}

@interface SLVFloatButton : UIButton
@property (nonatomic, assign) SLVFloatState slState;
- (void)sl_loadIcon;
- (void)sl_applyState:(SLVFloatState)state;
/// 0.2.26：叠层图标的两态动画（空闲单框呼吸 / 装填双框错拍）
- (void)sl_layoutFrames;
- (void)sl_updateFrameMotion;
/// v0.4.74：自定义图片的图标动效（四态律动）
- (void)sl_updateIconMotion;
/// v0.4.45：回到前台重挂呼吸光晕（后台期间动画会被系统整条移除）
- (void)sl_restartHalo;
@end

@implementation SLVFloatButton {
    UIView *_glassHost;
    UIVisualEffectView *_chrome;
    CAShapeLayer *_glassMask;
    UIView *_tint;
    UIImageView *_glyph;
    // 0.2.26：叠层图标。两个框各自独立动画 —— 空闲只有前面那个，装填时后面那个浮出来。
    // 原来是 4 根竖条（陌陌的音频波形语义），Vcam 用不上，而且两态只需要两个部件。
    UIView *_frames;
    UIView *_frameCell[2];
    UIImageView *_thumb;
    // v0.4.76：白勾边。原来挂在 _glassHost 的 border 上（在照片下面，被吃掉半截），
    // 现在单独一层放在最顶上，底下是玻璃还是照片都画完整一圈。
    CAShapeLayer *_hairline;
    CAShapeLayer *_haloIn;
    CAShapeLayer *_haloOut;
    UIView *_readyDot;
    CFTimeInterval _longPressAt;
    // 长按期间要临时关掉它，否则手指在扇上滑动会同时把球拖走
    UIPanGestureRecognizer *_pan;
    SLVFanView *_fan;
    // 展开前球停在哪。扇心被推进安全区时球会滑过去，收起要滑回原处，
    // 不然用户拖了半天的位置会被一次长按改掉。
    CGPoint _fanHomePos;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.18;
        self.layer.shadowRadius = 9;
        self.layer.shadowOffset = CGSizeMake(0, 3);

        // v0.4.36：呼吸光晕。两层同心描边，透明度缓慢交替，球和胶囊共用一条路径
        // （胶囊就是「圆角 = 高一半」的矩形，同一份代码两种情况都成立）。
        _haloOut = [CAShapeLayer layer];
        _haloOut.fillColor = nil;
        _haloOut.lineWidth = 2.0;
        _haloOut.opacity = 0.0;
        [self.layer addSublayer:_haloOut];

        _haloIn = [CAShapeLayer layer];
        _haloIn.fillColor = nil;
        _haloIn.lineWidth = 3.0;
        _haloIn.opacity = 0.0;
        [self.layer addSublayer:_haloIn];

        // 玻璃层尺寸固定成最大胶囊，只靠 mask 改外形。
        // 之前让 UIVisualEffectView 跟着 48→196 改宽高，系统按圆形重新采样，
        // 右端会留下一块白圆残影（截图里那个白圆片就是它）。
        _glassHost = [[UIView alloc] initWithFrame:CGRectZero];
        _glassHost.userInteractionEnabled = NO;
        // v0.4.46：材质变透之后，玻璃的「存在感」全靠这圈高光。
        // v0.4.76：border 挪到 _hairline（见下）—— border 画在子视图下面，
        // 照片一盖就只剩被啃过的半截线，这是那条「残线」的直接原因。
        _glassMask = [CAShapeLayer layer];
        _glassHost.layer.mask = _glassMask;
        [self addSubview:_glassHost];

        // v0.4.46：SystemMaterial → SystemUltraThinMaterial。前者在 iOS 15 上已经相当「实」，
        // 铺在聊天背景上基本看不到背后内容；换成超薄材质后是真正的玻璃感（透 + 轻模糊），
        // 玻璃的边界靠 _glassHost 那圈 0.8pt 高光勾出来。
        _chrome = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
        _chrome.frame = CGRectMake(0, 0, SLVBallSide, SLVBallSide);
        [_glassHost addSubview:_chrome];

        _tint = [[UIView alloc] initWithFrame:CGRectZero];
        _tint.userInteractionEnabled = NO;
        _tint.alpha = 0.0;
        [self addSubview:_tint];

        _glyph = [[UIImageView alloc] initWithFrame:CGRectZero];
        _glyph.contentMode = UIViewContentModeScaleAspectFit;
        _glyph.userInteractionEnabled = NO;
        [self addSubview:_glyph];

        // 0.2.26：叠层图标容器。放在 _glyph 之上、_thumb 之下，
        // 位置/显隐跟随 _glyph；用自定义头像时整组隐藏。
        // 加的顺序要紧：先加后框（在下），再加前框 —— 前框的白边压住后框的左边线，
        // 看起来才是「前面那张挡着后面那张」，而不是两条线互相穿过。
        _frames = [[UIView alloc] initWithFrame:CGRectZero];
        _frames.userInteractionEnabled = NO;
        [self addSubview:_frames];
        for (int i = 1; i >= 0; i--) {
            UIView *cell = [[UIView alloc] initWithFrame:CGRectZero];
            cell.userInteractionEnabled = NO;
            [_frames addSubview:cell];
            _frameCell[i] = cell;
        }

        _thumb = [[UIImageView alloc] initWithFrame:CGRectZero];
        _thumb.contentMode = UIViewContentModeScaleAspectFill;
        // v0.4.79：回退 v0.4.76 的「端帽」遮罩（_thumbMask），照片回到正圆。
        // 端帽把照片右缘裁成一条竖直直边，直边走到上下两头被切成直角 ——
        // 用户圈的就是这条「本该顺着椭圆走、却被裁掉一截」的线。
        // 正圆与胶囊左端圆头半径同为 24，天然贴合，右缘是一整圈连续弧，没有断头。
        _thumb.clipsToBounds = YES;
        _thumb.layer.cornerRadius = SLVBallSide / 2.0;
        _thumb.userInteractionEnabled = NO;
        [self addSubview:_thumb];

        // v0.4.76：白勾边。放在 _thumb 之上、其余子视图之下 —— 胶囊边缘没有别的东西压它。
        _hairline = [CAShapeLayer layer];
        _hairline.fillColor = [UIColor clearColor].CGColor;
        _hairline.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.62].CGColor;
        _hairline.lineWidth = 0.8;
        // v0.4.77：必须排在 _thumb 之下 —— 加在最后会盖住所有子视图，
        // 照片上那条「残缺的线」就是它压出来的。放低一层后即使路径溢出 0.x pt
        // 也会被照片吃掉，不会在照片上留边。
        [self.layer insertSublayer:_hairline below:_thumb.layer];


        // 就绪小蓝点：状态常亮时一直在，提醒「这次说的是包里那条」
        _readyDot = [[UIView alloc] initWithFrame:CGRectZero];
        _readyDot.backgroundColor = [UIColor systemGreenColor];   // v0.4.57：就绪态是绿，亮点也跟着绿，别冒出一颗蓝点
        _readyDot.layer.borderWidth = 1.5;
        _readyDot.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.9].CGColor;
        _readyDot.layer.cornerRadius = 4.5;
        _readyDot.hidden = YES;
        _readyDot.userInteractionEnabled = NO;
        [self addSubview:_readyDot];

        [self addTarget:self action:@selector(sl_tap) forControlEvents:UIControlEventTouchUpInside];
        _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(sl_pan:)];
        [self addGestureRecognizer:_pan];
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(sl_longPress:)];
        // 0.45 而不是 0.35：球本身能拖动，按得太浅会在「想拖」的时候误开扇
        lp.minimumPressDuration = 0.45;
        lp.allowableMovement = 12;   // 拖动换位置时不会误触
        [self addGestureRecognizer:lp];

        // v0.4.45：进后台时 CoreAnimation 会把光晕那两条无限循环动画整条摘掉，
        // 图层 opacity 回到 0 —— 切回来就是「呼吸灯没了」，点一下图标（重设状态）才回来。
        // 回到前台必须自己重挂一次。
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(sl_restartHalo)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(sl_restartHalo)
                                                     name:UIApplicationWillEnterForegroundNotification
                                                   object:nil];

        [self sl_loadIcon];
        [self sl_applyState:SLVFloatStateIdle];
    }
    return self;
}

#pragma mark 图标

- (UIImage *)sl_customIconImage {
    NSString *v = SLVFloatIconValue();
    if (![v hasPrefix:@"image:"]) return nil;
    return [UIImage imageWithContentsOfFile:SLVFloatIconImagePath([v substringFromIndex:6])];
}

- (void)sl_loadIcon {
    NSString *v = SLVFloatIconValue();
    _glyph.hidden = YES;
    _thumb.hidden = YES;

    UIImage *img = nil;
    if ([v hasPrefix:@"image:"]) {
        img = [UIImage imageWithContentsOfFile:SLVFloatIconImagePath([v substringFromIndex:6])];
        if (!img) v = kSLFloatIconDefault;
    }
    if (img) {
        _thumb.image = img;
        _thumb.hidden = NO;
    } else {
        // 48pt 里六根条太密，前 3 根 30% 的几乎看不见，糊成一团。
        // 球和胶囊上换成四根（两淡两实）、条更粗；大尺寸仍用六根。
        _glyph.image = [SLVBrandGlyphCompact(44, [UIColor blackColor]) imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        _glyph.tintColor = [UIColor labelColor];
        _glyph.hidden = NO;
        _glyph.alpha = 0.0;   // v0.4.49：静态图不显示，实际由 _frames 逐根绘制 + 动画
    }
    [self setNeedsLayout];
    // v0.4.74：换图标后要按新形态重挂（换成自定义图片才动，换回叠层就清干净）
    [self sl_updateIconMotion];
}

// 描边色是 CALayer 属性，UIView 动画块管不到它 —— 直接赋值会硬切，
// 状态从灰跳到绿时那一下「啪」很显眼。这里手动补一个过渡。
// 颜色没变就直接返回：layoutSubviews 会频繁调过来，不能每次都起一遍动画。
static void SLVSetFrameBorder(CALayer *l, UIColor *c, CGFloat width, NSTimeInterval dur) {
    l.borderWidth = width;
    CGColorRef old = l.borderColor;
    CGColorRef now = c.CGColor;
    if (old && CGColorEqualToColor(old, now)) return;
    l.borderColor = now;
    if (dur <= 0.0 || !old || !now) return;
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"borderColor"];
    a.fromValue = (__bridge id)old;
    a.toValue = (__bridge id)now;
    a.duration = dur;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [l addAnimation:a forKey:@"borderColor"];
}

// 0.2.26：把两个框摆到 _frames 里。几何沿用 SLVBrandGlyphCompact 的 100 单位基准：
// 框 56×92、圆角 17、描边 8.5。用 bounds + center 摆放，锚点天然在正中，
// 缩放就是「绕中心」，不会偏。
//
// 两态的位置差就是动势本身：
//   空闲 → 前框居中（x=22），后框藏起来，只有一个框才不显得偏
//   装填 → 前框让到左边（x=2），后框从右侧（x=42）浮出来
// 不用再叠一层缩放去表达「展开」，位置变化已经把话说完了。
- (void)sl_layoutFrames {
    CGFloat side = CGRectGetWidth(_frames.bounds);
    if (side <= 0.0) return;
    CGFloat u = side / 100.0;
    CGFloat w = 56.0 * u;
    CGFloat h = 92.0 * u;
    CGFloat lw = 8.5 * u;
    CGFloat rad = 17.0 * u;
    BOOL ready = (self.slState == SLVFloatStateReady);
    UIColor *c = _glyph.tintColor ?: [UIColor labelColor];

    CGFloat frontX = ready ? 2.0 * u : 22.0 * u;

    UIView *front = _frameCell[0];
    front.bounds = CGRectMake(0, 0, w, h);
    front.center = CGPointMake(frontX + w / 2.0, side / 2.0);
    front.layer.cornerRadius = rad;
    front.layer.cornerCurve = kCACornerCurveContinuous;
    SLVSetFrameBorder(front.layer, c, lw, 0.26);

    UIView *back = _frameCell[1];
    back.bounds = CGRectMake(0, 0, w, h);
    back.center = CGPointMake(42.0 * u + w / 2.0, side / 2.0);
    back.layer.cornerRadius = rad;
    back.layer.cornerCurve = kCACornerCurveContinuous;
    SLVSetFrameBorder(back.layer, [c colorWithAlphaComponent:0.5], lw, 0.26);
    back.hidden = !ready;
}

// 0.2.26：两态两套节奏。
//
// Vcam 只有「空闲」和「装填」两种形态，陌陌那四套（录音交叉抖 / 合成波推 / 就绪双跳）
// 在这里永远不会触发 —— 那三张错拍表和双跳关键帧已经删掉，不留死代码。
//
//   空闲 → 整组慢呼吸（一轮 2.4s / 0.94）：活着，但不抢注意力
//   装填 → 前框轻呼吸（1.2s / 0.95），后框明暗交替（1.0 → 0.4）：
//          前面那张稳着，后面那张若隐若现，正好是「底下还压着一层」的意思
//
// 只动 transform.scale 和 opacity，几何、点击区域、胶囊形状都不变。
- (void)sl_updateFrameMotion {
    if (!_frames) return;
    [_frames.layer removeAnimationForKey:@"slFrameWrap"];
    for (int i = 0; i < 2; i++) [_frameCell[i].layer removeAnimationForKey:@"slFrame"];
    if (_frames.hidden) return;

    CAMediaTimingFunction *ease =
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];

    if (self.slState == SLVFloatStateReady) {
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        a.fromValue = @0.95;
        a.toValue = @1.0;
        a.duration = 0.6;            // 一轮 1.2s
        a.autoreverses = YES;
        a.repeatCount = HUGE_VALF;
        a.fillMode = kCAFillModeBoth;
        a.timingFunction = ease;
        [_frameCell[0].layer addAnimation:a forKey:@"slFrame"];

        CABasicAnimation *f = [CABasicAnimation animationWithKeyPath:@"opacity"];
        f.fromValue = @1.0;
        f.toValue = @0.4;
        f.duration = 0.6;
        f.autoreverses = YES;
        f.repeatCount = HUGE_VALF;
        f.fillMode = kCAFillModeBoth;
        f.timingFunction = ease;
        [_frameCell[1].layer addAnimation:f forKey:@"slFrame"];
    } else {
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        a.fromValue = @0.94;
        a.toValue = @1.0;
        a.duration = 1.2;            // 一轮 2.4s，跟原来四杠空闲同频
        a.autoreverses = YES;
        a.repeatCount = HUGE_VALF;
        a.fillMode = kCAFillModeBoth;
        a.timingFunction = ease;
        [_frames.layer addAnimation:a forKey:@"slFrameWrap"];
    }
}

// v0.4.74：自定义图标的四态动效。
// 一条铁律：外圈一律不动 —— 光晕（_haloIn/_haloOut）和内层 26% 状态底色原样保留，
// 不再加环、不加弧。原因：光晕本来就在呼吸（2.8 / 0.9 / 1.4 / 1.6s 半周期），
// 再叠一圈不同频的环会拍频，空闲约 16.8 秒才同相一次、录音每 2.3 秒错一拍，看着像抖。
// 所以这里只让「图标自己」动，而且周期全部对齐光晕的 half，绝不另一套节奏。
- (void)sl_updateIconMotion {
    // 只对自定义图片生效。默认叠层图形本来就有自己那套动画，再叠一层会打架。
    UIView *target = nil;
    if (!_thumb.hidden) target = _thumb;

    NSInteger fx = SLVFloatEffectValue();

    // 先无条件清干净：换图标、关动效、切回叠层形态都走这一条
    [_thumb.layer removeAnimationForKey:@"slIconMotion"];

    if (!target || fx <= 0) return;

    SLVFloatState st = self.slState;

    // 半周期与光晕一致：空闲 1.4 / 录音 0.45 / 合成 0.70 / 就绪 0.80
    CGFloat half = 1.4;
    CGFloat lo = 0.96;
    BOOL pump = NO, hop = NO;
    if (st == SLVFloatStateRecording) { half = 0.45; lo = 0.94; }
    else if (st == SLVFloatStateSynthesizing) { half = 0.70; pump = YES; }
    else if (st == SLVFloatStateReady) { half = 0.80; hop = YES; }

    if (pump) {
        // 合成态「泵动」：前一半慢慢蓄到 0.945，14% 的时间急弹到 1.03，再缓落回 1.0。
        // 刻意用不对称曲线 —— 空闲和录音都是正弦来回，合成态一眼就能区分开。
        // 不转、不摇：人像照片旋转或左右晃动都会显得怪。
        CAKeyframeAnimation *k = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
        k.values = @[@1.0, @0.945, @1.03, @1.005, @1.0];
        k.keyTimes = @[@0.0, @0.50, @0.64, @0.80, @1.0];
        k.duration = half * 2.0;
        k.repeatCount = HUGE_VALF;
        k.fillMode = kCAFillModeBoth;
        k.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [target.layer addAnimation:k forKey:@"slIconMotion"];
    } else if (hop) {
        // 就绪：双跳，和四杠同拍同时长（1.1s）
        CAKeyframeAnimation *k = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
        k.values = @[@1.0, @1.06, @1.0, @1.06, @1.02, @1.0];
        k.keyTimes = @[@0.0, @0.18, @0.38, @0.56, @0.78, @1.0];
        k.duration = 1.1;
        k.repeatCount = HUGE_VALF;
        k.fillMode = kCAFillModeBoth;
        k.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [target.layer addAnimation:k forKey:@"slIconMotion"];
    } else {
        // 空闲 0.96 / 录音 0.94：只是「轻重」不同，不靠幅度区分，避免人像呼吸过重
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        a.fromValue = @(lo);
        a.toValue = @1.0;
        a.duration = half;
        a.autoreverses = YES;
        a.repeatCount = HUGE_VALF;
        a.fillMode = kCAFillModeBoth;
        a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [target.layer addAnimation:a forKey:@"slIconMotion"];
    }
}

#pragma mark 状态

- (void)sl_applyState:(SLVFloatState)state {
    SLVFloatState prev = self.slState;
    self.slState = state;

    UIColor *accent = nil;
    // v0.4.52：四种状态各自一个颜色。原来「合成中」和「已装填」都是蓝，肉眼分不出
    // 到底是在生成还是已经就绪 —— 就绪单独用绿。
    if (state == SLVFloatStateRecording) accent = [UIColor systemRedColor];
    else if (state == SLVFloatStateSynthesizing) accent = [UIColor systemBlueColor];
    else if (state == SLVFloatStateReady) accent = [UIColor systemGreenColor];

    // v0.4.77：选了自定义图片时，胶囊底永远只铺图色晕，一点状态色都不掺。
    // 原来状态色一来就把色晕让掉（0.36 → 0），剩下 74% 是超薄毛玻璃自己的白，
    // 在浅色聊天背景上就是一片灰白玻璃 —— 从图色跳到白、再跳到状态色，中间硬断一截，
    // 就是「其他形态的背景会变成白色」的来源。
    // 现在：有图 → 底色恒定，状态只靠字形 / 文字 / 箭头 / 外圈光环（有图时叠层本来就隐藏）；
    // 没图（默认 logo）→ 仍然铺 26% 状态色，否则四态根本没有底色谱可用。
    BOOL hasArt = (_thumb != nil && _thumb.hidden == NO);
    BOOL useTint = (accent != nil) && !hasArt;
    UIColor *fill = useTint ? [accent colorWithAlphaComponent:0.26] : [UIColor clearColor];
    // v0.4.57：所有着色元素（胶囊底、分隔线、字形 tint、四杠、名字）一起做 0.26s 交叉淡入淡出。
    // 原来只有 _tint 在动画块里，四杠/字形/名字是瞬间换色，蓝→绿会「啪」地硬切（录屏确认一帧跳变）。
    // 现在把颜色改动全收进同一个动画块，整颗球颜色平滑过渡；光环描边是 CAShapeLayer 属性，
    // UIView 块管不到，单独用 CATransaction 在 sl_startBreath 之后交叉淡出（见下）。
    [UIView animateWithDuration:0.26 delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self->_tint.backgroundColor = fill;
        self->_tint.alpha = useTint ? 1.0 : 0.0;
        // v0.4.77：色晕不再让位（见上），整块胶囊从头到尾是同一个底，没有「白一下」的过渡。
        self->_glyph.tintColor = accent ?: [UIColor labelColor];
        // 两个框跟着换色：几何不变，只有描边色随动画块交叉淡入淡出
        [self sl_layoutFrames];
    } completion:nil];
    [self sl_updateFrameMotion];
    // 装填时后框「多出来那一块」的渐显不在这里做 —— 后框的 opacity 已经交给
    // sl_updateFrameMotion 的循环动画了，再叠一个 UIView alpha 动画会抢同一个属性，
    // 两个动画互相覆盖，结果是不定时地闪。父层 _frames 下面有 0.18s 淡入，跟着走就够。
    // v0.4.74：图标动效也跟着状态换节奏。注意不能塞进 sl_updateFrameMotion ——
    // 自定义图片时 _frames 是 hidden，那个方法一开始就 return 了，根本走不到这一句。
    [self sl_updateIconMotion];
    // v0.4.57：合成完成→就绪，整颗胶囊轻轻「落定」一下（缩放回弹）。
    // v0.4.60：只在「没有试听面板」时才弹 —— 面板自己有 0.94→1.0 的弹入，
    // 两下缩放同帧叠加会像「球被按了一下」，所以面板路径改走 SLVFloatSetStateQuiet 静音。
    if (!sSLFloatSettleMuted && prev == SLVFloatStateSynthesizing && state == SLVFloatStateReady) {
        [self sl_playCompletionSettle];
    }
    // v0.4.50：四套节奏的幅度差得远（0.30 / 0.55 / 0.86 / 1.15），硬切会「跳一下」。
    // 状态真变了就让图标做一次 0.18s 淡入，把新节奏揉进去，不至于突兀。
    if (prev != state && _frames && !_frames.hidden) {
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue = @(0.45);
        fade.toValue = @(1.0);
        fade.duration = 0.18;
        fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [_frames.layer addAnimation:fade forKey:@"slFade"];
    }
    _readyDot.hidden = (state != SLVFloatStateReady);

    // v0.4.57：光环描边是 CAShapeLayer 属性，UIView 动画块管不到，单独用 CATransaction 交叉淡出。
    // 必须放在 sl_startBreath 之后：后者会 removeAllAnimations，提前加的描边动画会被清掉。
    UIColor *halo = accent ?: [UIColor colorWithWhite:0.55 alpha:1.0];
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.26];
    [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];
    _haloIn.strokeColor = halo.CGColor;
    _haloOut.strokeColor = halo.CGColor;
    [CATransaction commit];
    [self sl_startBreath:state];
    [self setNeedsLayout];
}

- (void)sl_startBreath:(SLVFloatState)state {
    [_haloIn removeAllAnimations];
    [_haloOut removeAllAnimations];

    // 半周期时长：一轮完整呼吸 = 2 倍
    CGFloat half = 1.4;      // 空闲 2.8s
    CGFloat a0 = 0.06, a1 = 0.20;   // 空闲只到 0.20，看着「活」但不抢注意力
    if (state == SLVFloatStateRecording) {
        half = 0.45; a0 = 0.28; a1 = 0.85;   // 0.9s，急促
    } else if (state == SLVFloatStateSynthesizing) {
        half = 0.70; a0 = 0.22; a1 = 0.70;   // 1.4s
    } else if (state == SLVFloatStateReady) {
        half = 0.80; a0 = 0.34; a1 = 0.90;   // 1.6s，一直亮到发出去
    }

    CABasicAnimation *in = [CABasicAnimation animationWithKeyPath:@"opacity"];
    in.fromValue = @(a0);
    in.toValue = @(a1);
    in.duration = half;
    in.autoreverses = YES;
    in.repeatCount = HUGE_VALF;
    in.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_haloIn addAnimation:in forKey:@"breath"];

    CABasicAnimation *out = [CABasicAnimation animationWithKeyPath:@"opacity"];
    out.fromValue = @(a0 * 0.42);
    out.toValue = @(a1 * 0.42);
    out.duration = half;
    out.beginTime = CACurrentMediaTime() + half * 0.45;   // 错开相位，两圈不会同步闪
    out.autoreverses = YES;
    out.repeatCount = HUGE_VALF;
    out.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_haloOut addAnimation:out forKey:@"breath"];
}

// v0.4.45：回到前台后重挂呼吸光晕。
// 进后台时系统会把图层上的动画整条移除（opacity 回落到 0），所以切回来灯就灭了；
// 这一路只有「状态变化」或「点一下球」才会重设，用户看着就是「要点一下才有」。
- (void)sl_restartHalo {
    if (self.window == nil) return;
    // 路径可能已经跟着展开 / 收起变过，先按当前 bounds 重算一遍再挂动画
    [self setNeedsLayout];
    [self layoutIfNeeded];
    [self sl_startBreath:self.slState];
    // 叠层循环动画同样会被系统在后台移除，回前台一并重挂
    [self sl_updateFrameMotion];
    // v0.4.74：图标缩放 / 扫光同样是常驻 CA 动画，一样会被摘掉
    [self sl_updateIconMotion];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// v0.4.57：合成完成→就绪的「落定」反馈。整颗胶囊 0.5s 微涨后回弹
//（1.0 → 1.07 → 1.0），像被轻轻按了一下「好了」，配合绿色淡入，过渡不再硬切。
// 只动 layer.transform.scale，不动 frame，不影响点击区域与布局。
- (void)sl_playCompletionSettle {
    CAKeyframeAnimation *b = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    b.values = @[@1.0, @1.07, @1.0];
    b.keyTimes = @[@0.0, @0.35, @1.0];
    b.duration = 0.5;
    b.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    b.removedOnCompletion = YES;
    [self.layer addAnimation:b forKey:@"slSettle"];
}

#pragma mark 长按扇

/// 0.2.22：长按停在「启用」球上不动 → 松手进预览。定义在文件末尾。
static void SLVShowMediaPreview(void);

// 球贴哪条边：取四个方向里最近的那条。贴角落时上下 / 左右距离接近，
// 取到哪条都不算错 —— SLVFanView 内部会把扇角收窄、半径缩小，保证不出屏。
- (SLVFanEdge)sl_edgeForCenter:(CGPoint)c inSize:(CGSize)sz {
    CGFloat dL = c.x, dR = sz.width - c.x, dT = c.y, dB = sz.height - c.y;
    CGFloat m = MIN(MIN(dL, dR), MIN(dT, dB));
    if (m == dL) return SLVFanEdgeLeft;
    if (m == dR) return SLVFanEdgeRight;
    if (m == dT) return SLVFanEdgeTop;
    return SLVFanEdgeBottom;
}

- (void)sl_showFan {
    UIView *sv = self.superview;
    if (!sv) return;
    if (_fan) {
        [_fan removeFromSuperview];
        _fan = nil;
    }
    // 几何一律按屏幕量。sv 是 SLVKeyWindow() 挑出来的那个窗口，它可能是 QQRTCWindow
    // 这类只覆盖屏幕一块的浮层 —— 拿它的 bounds 当屏幕，扇就会被夹小、位置也偏。
    // 但子视图画不到父视图外面，所以实际可用区域取「屏幕」和「sv」里小的那个：
    // 正常 App 两者相等，退化成屏幕；浮层窗口时至少不会画出界。
    CGSize scr = SLVScreenSize();
    CGSize sz = CGSizeMake(MIN(sv.bounds.size.width, scr.width),
                           MIN(sv.bounds.size.height, scr.height));
    _fanHomePos = self.center;
    _fan = [[SLVFanView alloc] initWithHostSize:sz ballCenter:self.center
                                          edge:[self sl_edgeForCenter:self.center inSize:sz]];
    // 扇压在球下面：手指是从球心出发的，球本身不能被盖住
    [sv insertSubview:_fan belowSubview:self];
    [_fan sl_show];

    // 球贴角落时扇心会被推进安全区（五个球才排得下）。这时候球得跟着走，
    // 否则屏幕上就是「球在一个地方、扇在另一个地方」—— 用户说的「展开后错位」。
    CGPoint fc = _fan.slFanCenter;
    if (!CGPointEqualToPoint(fc, self.center)) {
        [UIView animateWithDuration:0.18 delay:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{ self.center = fc; }
                         completion:nil];
    }
}

- (void)sl_hideFan {
    SLVFanView *f = _fan;
    _fan = nil;
    if (!f) return;
    [f sl_hide];
    // 球滑回展开前的位置
    if (!CGPointEqualToPoint(_fanHomePos, self.center)) {
        [UIView animateWithDuration:0.18 delay:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{ self.center = _fanHomePos; }
                         completion:nil];
    }
    // 等收起动画跑完再摘，直接 remove 会「啪」地消失
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [f removeFromSuperview]; });
}

#pragma mark 手势

- (void)sl_pan:(UIPanGestureRecognizer *)g {
    UIView *sv = self.superview;
    if (!sv) return;
    CGSize sz = SLVHostSizeFor(sv);

    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:sv];
        // 原来只做 center += 位移，没有任何边界判断 → 能整颗拖出屏幕，
        // 存下来的又是绝对坐标，换设备/横屏恢复后就在屏外。
        // 现在实时夹在界内（左右各留 SLVBallEdgeInset，上让状态栏，下让底部安全区）。
        self.center = SLVClampFloatPos(CGPointMake(self.center.x + t.x, self.center.y + t.y), sz);
        [g setTranslation:CGPointZero inView:sv];
    } else if (g.state == UIGestureRecognizerStateEnded
               || g.state == UIGestureRecognizerStateCancelled) {
        // 松手吸附到最近的一条边，避免球卡在屏幕中间挡住内容
        CGFloat half = SLVBallSide / 2.0;
        CGPoint c = self.center;
        c.x = (c.x < sz.width / 2.0) ? (half + SLVBallEdgeInset)
                                     : (sz.width - half - SLVBallEdgeInset);
        c = SLVClampFloatPos(c, sz);
        [UIView animateWithDuration:0.22 delay:0
             usingSpringWithDamping:0.85 initialSpringVelocity:0
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ self.center = c; }
                         completion:nil];
        SLVStoreFloatPos(c, SLVScreenSize());
    }
}

- (void)sl_tap {
    // 长按结束后个别机型还会补一次 touchUpInside，这里挡掉，
    // 否则「长按出扇 → 松手」会顺带把素材库也弹出来。
    if (CFAbsoluteTimeGetCurrent() - _longPressAt < 0.7) return;
    // 关掉「启用」之后球也要能点：素材库跟启用状态无关，
    // 用户常常是「先换素材，再打开开关」，这里不能拦。
    SLVCamHandleArrowTap(self);
}

- (void)sl_longPress:(UILongPressGestureRecognizer *)g {
    UIView *sv = self.superview;
    if (!sv) return;

    if (g.state == UIGestureRecognizerStateBegan) {
        _longPressAt = CFAbsoluteTimeGetCurrent();
        // 扇展开期间手指要在扇上滑动，pan 必须停掉，否则球会跟着手指跑
        _pan.enabled = NO;
        [self sl_showFan];
        return;
    }
    if (g.state == UIGestureRecognizerStateChanged) {
        if (_fan) [_fan sl_trackPoint:[g locationInView:sv]];
        return;
    }
    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled) {
        _longPressAt = CFAbsoluteTimeGetCurrent();
        _pan.enabled = YES;
        if (_fan) {
            NSInteger sw = _fan.slPickedSwitch;
            NSInteger ang = _fan.slPickedAngle;
            // 必须在 sl_hide 之前读 —— 收起时会把这个标志清掉
            BOOL preview = _fan.slWantsPreview;
            [self sl_hideFan];
            if (g.state == UIGestureRecognizerStateEnded) {
                // 停住「启用」球再松手 = 预览素材，不切开关
                if (preview) SLVShowMediaPreview();
                else SLVFanCommit(sw, ang);
            }
        }
    }
}

#pragma mark 布局

// 球态只有一种形状：正圆。原来这里是一整套「球 / 胶囊」两套布局，
// 胶囊移除后 _chrome 不用再铺成 196 宽靠 mask 裁，直接等于 bounds。
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat w = CGRectGetWidth(b);
    CGFloat h = SLVBallSide;

    _glassHost.frame = b;
    _glassHost.layer.cornerRadius = h / 2.0;
    _glassMask.path = [UIBezierPath bezierPathWithRoundedRect:b cornerRadius:h / 2.0].CGPath;
    _chrome.frame = b;

    _glyph.frame = CGRectMake((w - 22.0) / 2.0, (h - 22.0) / 2.0, 22.0, 22.0);
    _glyph.hidden = (_thumb.hidden == NO);
    _frames.frame = _glyph.frame;
    _frames.hidden = _glyph.hidden;
    [self sl_layoutFrames];

    _thumb.frame = b;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _hairline.frame = b;
    _hairline.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, 0.4, 0.4)
                                                cornerRadius:MAX(0.0, h / 2.0 - 0.4)].CGPath;
    [CATransaction commit];

    _tint.frame = b;
    _tint.layer.cornerRadius = h / 2.0;

    _readyDot.frame = CGRectMake(w - 14.0, 3.0, 9.0, 9.0);

    // 光晕路径：胶囊就是「圆角 = 高一半」的矩形，球是它的特例
    _haloIn.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, -2.5, -2.5)
                                              cornerRadius:(h + 5.0) / 2.0].CGPath;
    _haloOut.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, -7.0, -7.0)
                                               cornerRadius:(h + 14.0) / 2.0].CGPath;
}

@end

@interface SLVFloatPanelController ()
@property (nonatomic, strong) UIControl *dim;
@property (nonatomic, strong) UIView *cardWrap;
/// v0.4.44：卡片圆角的硬裁剪（mask 比 clipsToBounds 可靠，contentView 是系统私有类）
@property (nonatomic, strong) CAShapeLayer *cardMask;
@property (nonatomic, strong) UIVisualEffectView *blur;
@property (nonatomic, strong) UINavigationController *nav;
@property (nonatomic, strong) UIViewController *rootVC;
- (void)sl_applyNavTransparency;
- (void)sl_clearOpaqueBackdrops:(UIView *)view depth:(NSInteger)depth;
- (void)sl_fixScrollInsetsIn:(UIView *)view top:(CGFloat)top;
@end

// v0.4.55：记住当前浮窗实例，避免长按球等在设置已开时又叠第二层
static SLVFloatPanelController *sSLFloatPanel = nil;

@implementation SLVFloatPanelController

+ (void)presentFrom:(UIViewController *)host root:(UIViewController *)root {
    if (!host || !root) return;
    // v0.4.55：设置已开时长按球，topViewController 返回的是设置页本身（它没再 present 东西），
    // 旧判断 host.presentedViewController 拦不住，会叠第二层。改用全局实例判断。
    if (sSLFloatPanel && sSLFloatPanel.presentingViewController) return;
    // 已经有浮窗开着就不叠第二层，避免连点两次出现两张卡片
    if (host.presentedViewController) return;
    SLVFloatPanelController *vc = [[SLVFloatPanelController alloc] init];
    sSLFloatPanel = vc;
    vc.rootVC = root;
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    // v0.4.54：浮窗盖上来之后把球重新抬到最上层，别让卡片压住它
    [host presentViewController:vc animated:YES completion:^{
        SLVRaiseFloatButton();
    }];
}

+ (void)presentSettingsFrom:(UIViewController *)host {
    [self presentFrom:host root:[[SLVSettingsPanel alloc] init]];
}

+ (BOOL)isSettingsOpen {
    return sSLFloatPanel && sSLFloatPanel.presentingViewController != nil;
}

+ (void)dismissSettings {
    if (sSLFloatPanel && sSLFloatPanel.presentingViewController) {
        [sSLFloatPanel sl_dismiss];
    }
}

+ (void)presentMediaFrom:(UIViewController *)host {
    [self presentFrom:host root:[[SLVMediaListController alloc] init]];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    // 背板：轻压暗，点空白处收起。不做全黑，背后的聊天内容还要看得见
    self.dim = [[UIControl alloc] initWithFrame:CGRectZero];
    // v0.4.46：0.16 → 0.10。卡片本身变透了，压暗层太重会把透出来的背景压成一片灰。
    self.dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.10];
    [self.dim addTarget:self action:@selector(sl_dismiss) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.dim];

    // 尺寸在 viewWillLayoutSubviews 里算：viewDidLoad 时 bounds 还没定下来
    self.cardWrap = [[UIView alloc] initWithFrame:CGRectZero];
    self.cardWrap.layer.shadowColor = [UIColor blackColor].CGColor;
    self.cardWrap.layer.shadowOpacity = 0.22;
    self.cardWrap.layer.shadowRadius = 24;
    self.cardWrap.layer.shadowOffset = CGSizeMake(0, 10);
    // v0.4.46：材质换成超薄之后整体更透了，玻璃的「厚度」靠这圈边缘高光交代。
    // 0.8pt 而不是 1pt：再粗就成了画框，不像玻璃边。深色下用低透白，否则在暗背景上会发灰。
    self.cardWrap.layer.cornerRadius = 26.0;
    self.cardWrap.layer.cornerCurve = kCACornerCurveContinuous;
    self.cardWrap.layer.borderWidth = 0.8;
    self.cardWrap.layer.borderColor =
        [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
            return tc.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:1.0 alpha:0.16]
                : [UIColor colorWithWhite:1.0 alpha:0.58];
        }].CGColor;
    [self.view addSubview:self.cardWrap];

    // v0.4.46：设置浮窗同样换成超薄材质 —— 三页共用这个容器，一处改完全透。
    self.blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
    self.blur.layer.cornerRadius = 26;
    self.blur.layer.cornerCurve = kCACornerCurveContinuous;
    self.blur.clipsToBounds = YES;
    // v0.4.43：圆角裁剪必须同时设在 contentView 上。
    // UIVisualEffectView 只在「玻璃层」裁，contentView 里的子视图（导航栏、搜索栏、白背板）
    // 照样能画到圆角外面 —— 这就是白条两端变成直角、戳在弧线外的原因。
    self.blur.contentView.clipsToBounds = YES;
    self.blur.contentView.layer.cornerRadius = 26;
    self.blur.contentView.layer.cornerCurve = kCACornerCurveContinuous;
    [self.cardWrap addSubview:self.blur];

    // v0.4.44：兜底裁剪交给 mask。
    // contentView 是系统私有类（_UIVisualEffectContentView），clipsToBounds 不一定听话；
    // mask 是硬约束，卡片里任何东西都出不了这个圆角矩形。
    // 注意 mask 挂在 blur 上而不是 cardWrap 上 —— cardWrap 还要投阴影，mask 会把阴影一起裁掉。
    self.cardMask = [CAShapeLayer layer];
    self.blur.layer.mask = self.cardMask;

    SLVSettingsPanel *root = [[SLVSettingsPanel alloc] init];
    self.nav = [[UINavigationController alloc] initWithRootViewController:(self.rootVC ?: root)];
    self.nav.view.backgroundColor = [UIColor clearColor];
    [self addChildViewController:self.nav];
    [self.blur.contentView addSubview:self.nav.view];
    [self.nav didMoveToParentViewController:self];

    [self sl_applyNavTransparency];
}

// v0.4.40：导航栏透明化收成一个方法，viewDidLoad / viewWillAppear / viewWillLayoutSubviews 各刷一次。
// iOS 15 起导航栏有两套外观：内容贴顶用 scrollEdgeAppearance（透明），一旦下方开始滚动就换成
// standardAppearance（不透明浅底 + 0.5pt 投影线）—— 表现是「一滑顶部冒出一条白」。
// 只在 viewDidLoad 设一次是不够的：系统会在 layout 周期里把它重置回去，所以每次布局都补一遍。
- (void)sl_applyNavTransparency {
    UINavigationBar *nb = self.nav.navigationBar;
    if (!nb) return;
    UIImage *clear1x1 = SLVTransparentImage();
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *ap = [[UINavigationBarAppearance alloc] init];
        [ap configureWithTransparentBackground];
        ap.backgroundColor = [UIColor clearColor];
        ap.backgroundEffect = nil;
        ap.shadowColor = [UIColor clearColor];
        // v0.4.43：必须显式给一张「真」透明背景图。configureWithTransparentBackground 只清
        // backgroundColor，backgroundImage 为 nil 时系统会自己补一张默认图 ——
        // 那张图顶部纯白、向下渐隐，正是「顶部一条白边」的形状。
        ap.backgroundImage = clear1x1;
        nb.standardAppearance = ap;
        nb.compactAppearance = ap;
        nb.scrollEdgeAppearance = ap;
        if (@available(iOS 15.0, *)) nb.compactScrollEdgeAppearance = ap;
    }
    // 老接口一起上：部分页面（自带背景图 / 自定义返回按钮）会走这条路，
    // 新老两条都设成空，哪条生效都不会再有白底。
    nb.translucent = YES;
    nb.backgroundColor = [UIColor clearColor];
    nb.opaque = NO;
    [nb setBackgroundImage:clear1x1 forBarMetrics:UIBarMetricsDefault];
    [nb setBackgroundImage:clear1x1 forBarMetrics:UIBarMetricsCompact];
    nb.shadowImage = clear1x1;
    // v0.4.43：UINavigationController 会在布局周期里把自己的 view 底色刷回 systemBackground，
    // 只在 viewDidLoad 设一次 clear 是不够的 —— 顶部露出的那一条白很可能就是它。
    self.nav.view.backgroundColor = [UIColor clearColor];
    self.nav.view.opaque = NO;
}

// v0.4.43：把导航栏链路上仍不透明的系统背板（_UIBarBackground / TransitionView 之类）清掉。
// 只认类名，不碰表格和滚动视图，避免把页面自己的底色误伤。
- (void)sl_clearOpaqueBackdrops:(UIView *)view depth:(NSInteger)depth {
    if (depth > 4 || !view) return;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UIScrollView class]]) continue;   // 表格 / 地图自己管自己
        NSString *cls = NSStringFromClass([sub class]);
        if ([cls containsString:@"Transition"] || [cls containsString:@"Wrapper"]
            || [cls containsString:@"BarBackground"]) {
            if (sub.backgroundColor && ![sub.backgroundColor isEqual:[UIColor clearColor]]) {
                sub.backgroundColor = [UIColor clearColor];
            }
            sub.opaque = NO;
        }
        [self sl_clearOpaqueBackdrops:sub depth:depth + 1];
    }
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    // 系统在布局周期会重置导航栏外观，这里是必须补刷的一次
    [self sl_applyNavTransparency];
    [self sl_clearOpaqueBackdrops:self.nav.view depth:0];
    CGSize host = self.view.bounds.size;
    if (host.width < 1.0 || host.height < 1.0) return;
    self.dim.frame = self.view.bounds;
    // 尺寸按屏幕算，不按 self.view.bounds —— 后者是呈现容器的 bounds，
    // 不同 App 的容器可能不一样（带 inset、formSheet、被 Scene 改过），
    // 表现就是「设置菜单在每个 App 里大小不同」。
    // 位置仍按容器居中，因为卡片是加在容器上的，坐标基准是容器。
    CGSize scr = SLVScreenSize();
    CGFloat w = MIN(scr.width - 24.0, 380.0);
    CGFloat h = MIN(scr.height * 0.66, 560.0);
    CGRect r = CGRectMake(round((host.width - w) / 2.0), round((host.height - h) / 2.0) - 18.0, w, h);
    if (!CGRectEqualToRect(self.cardWrap.frame, r)) self.cardWrap.frame = r;
    self.blur.frame = self.cardWrap.bounds;
    // v0.4.44：尺寸变了就重画 mask，否则圆角裁在旧尺寸上（会裁掉一侧）
    self.cardMask.frame = self.blur.bounds;
    self.cardMask.path = [UIBezierPath bezierPathWithRoundedRect:self.blur.bounds
                                                   cornerRadius:26.0].CGPath;
    // v0.4.37：导航栏原来紧贴卡片圆角顶（搜索栏顶只低 2pt，压着弧线），
    // 整体下压 14pt；设置页、语音包页、地图页共用这一个容器，顶部留白自动统一。
    CGRect navF = self.blur.contentView.bounds;
    self.nav.view.frame = CGRectMake(navF.origin.x, navF.origin.y + kSLPanelTopPad,
                                     navF.size.width, MAX(0.0, navF.size.height - kSLPanelTopPad));
}

// v0.4.41：顶部那条白的真正根因（这次是真的）。
// 导航栏是透明的，表格一旦滚动，内容会钻到导航栏底下 —— 而列表底色是浅灰白，
// 那块区域于是露出一条实心白带，跟四周的毛玻璃完全不是一种材质，看着就是「冒出一条白」。
// 改外观（四套 UINavigationBarAppearance）治不了它，因为白带根本不是导航栏画的。
// 解法：内容永远不进导航栏区域 —— 表格顶内边距 = 导航栏下沿，并关掉系统的自动内边距
// （否则它会把安全区再算一遍，留白翻倍）。三个页面（设置 / 语音包 / 地图）共用这一处。
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UINavigationBar *nb = self.nav.navigationBar;
    if (!nb || !self.nav.view) return;
    CGFloat top = CGRectGetMaxY(nb.frame);
    if (top < 44.0) top = 44.0;      // 有些状态（转场中）拿到的还是 0
    [self sl_fixScrollInsetsIn:self.nav.view top:top];
}

- (void)sl_fixScrollInsetsIn:(UIView *)view top:(CGFloat)top {
    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *sv = (UIScrollView *)view;
        // 只处理「顶在导航栏底下」的表格。地图页的列表是自己手算 frame 避让过的
        // （从导航栏下沿才开始），再给它塞一份顶内边距只会白空一截。
        CGFloat y = [sv convertPoint:CGPointZero toView:self.nav.view].y;
        if (y > top - 1.0) return;
        if (@available(iOS 11.0, *)) {
            if (sv.contentInsetAdjustmentBehavior != UIScrollViewContentInsetAdjustmentNever) {
                sv.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
            }
        }
        // 幂等：值没变就不写，避免 contentInset 变化引发的布局回环
        UIEdgeInsets in = sv.contentInset;
        if (fabs(in.top - top) > 0.5) {
            in.top = top;
            sv.contentInset = in;
        }
        // 滚动条也跟着让开导航栏。v0.4.42：老接口 scrollIndicatorInsets 在 iOS 13 已弃用，
        // 而这里开着 -Werror → 直接编译失败；改用 verticalScrollIndicatorInsets。
        if (@available(iOS 13.0, *)) {
            UIEdgeInsets si = sv.verticalScrollIndicatorInsets;
            if (fabs(si.top - top) > 0.5) {
                si.top = top;
                sv.verticalScrollIndicatorInsets = si;
            }
        }
        // 底色必须是透的，滚动时露出的是浮窗那层毛玻璃。
        // v0.4.43：表格设了 backgroundView 时 backgroundColor 会被它盖住，
        // 那个 backgroundView 默认就是一块浅白 —— 一并去掉。
        if ([sv isKindOfClass:[UITableView class]]) {
            UITableView *tv = (UITableView *)sv;
            if (tv.backgroundView) tv.backgroundView = nil;
        }
        if (sv.backgroundColor && ![sv.backgroundColor isEqual:[UIColor clearColor]]) {
            sv.backgroundColor = [UIColor clearColor];
        }
        return;   // 不再往列表内部钻：cell 里的横向滚动视图不该被改
    }
    for (UIView *sub in view.subviews) [self sl_fixScrollInsetsIn:sub top:top];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 从地图页 / 语音包页返回时也重刷一遍，防止子页把外观改回去
    [self sl_applyNavTransparency];    self.cardWrap.alpha = 0.0;
    self.cardWrap.transform = CGAffineTransformMakeScale(0.94, 0.94);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [UIView animateWithDuration:0.26 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.cardWrap.alpha = 1.0;
        self.cardWrap.transform = CGAffineTransformIdentity;
    } completion:nil];
    // v0.4.54：卡片进场动画结束时再抬一次球（present 的 completion 有时早于最后一次布局）
    SLVRaiseFloatButton();
}

- (void)sl_dismiss {
    sSLFloatPanel = nil;
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

// 按当前设置把图标套到按钮上
static void SLVApplyFloatIcon(UIButton *btn) {
    if (![btn isKindOfClass:[SLVFloatButton class]]) return;
    [(SLVFloatButton *)btn sl_loadIcon];
}

// v0.4.34：三态入口。Tweak.x 在录音 / 合成钩子里调用，界面只改颜色和环，不做任何业务判断。
static __weak SLVFloatButton *sSLFloatBtn = nil;

void SLVFloatSetState(SLVFloatState state) {
    // 录音 / 合成的钩子不一定在主线程，碰 UI 一律回主队列
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ SLVFloatSetState(state); });
        return;
    }
    SLVFloatButton *b = sSLFloatBtn;
    if (!b) return;
    // v0.4.36：就绪不再 1.6 秒后自己退回空闲 —— 它要一直亮着，
    // 直到语音真正发出去（发送完成那一刻会走 Ready → Idle，顺带外扩一圈涟漪）。
    [b sl_applyState:state];
}

// v0.4.60：同 SLVFloatSetState，但不触发「落定」缩放回弹。
// 用途只有一个：试听面板弹出后把球点成 Ready 绿 —— 那一刻面板自己在弹入，
// 球再缩一下就成了两个动画撞车。静音范围严格限定在这次 apply 之内。
void SLVFloatSetStateQuiet(SLVFloatState state) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ SLVFloatSetStateQuiet(state); });
        return;
    }
    SLVFloatButton *b = sSLFloatBtn;
    if (!b) return;
    BOOL prevMuted = sSLFloatSettleMuted;
    sSLFloatSettleMuted = YES;
    [b sl_applyState:state];
    sSLFloatSettleMuted = prevMuted;
}

// 浮窗内部是子控制器，点「完成」时先向上找真正的呈现者
void SLVCloseHostingPanel(UIViewController *vc) {
    if (!vc) return;
    UIViewController *c = vc;
    while (c && !c.presentingViewController) c = c.parentViewController;
    if (c) [c dismissViewControllerAnimated:YES completion:nil];
    else [vc dismissViewControllerAnimated:YES completion:nil];
    sSLFloatPanel = nil;
}

// 键盘 / 状态栏 / 文本特效这些私有窗口不能挂球：挂上去要么看不见，要么跟着窗口一起消失
static BOOL SLVIsSystemOverlayWindow(UIWindow *w) {
    NSString *cn = NSStringFromClass([w class]);
    if (cn.length == 0) return NO;
    return [cn containsString:@"TextEffects"] || [cn containsString:@"Keyboard"]
        || [cn containsString:@"StatusBar"] || [cn containsString:@"Selection"];
}

// iOS15 SDK 起 -[UIApplication windows] 被弃用，工程开了 -Werror，这里局部抑制并优先走场景 API。
// v0.4.37：不再只认 ForegroundActive + isKeyWindow。陌陌启动早期常是启动页 / 广告窗，
// 球挂上去那窗一关就跟着没了；另一种是球被更高层的窗压住，viewWithTag 还能找到，
// 于是永不重建、也永不可见。现在改成「所有场景里挑最顶层且可见的那个窗」，球永远住最上面。
static UIWindow *SLVKeyWindow(void) {
    NSMutableArray<UIWindow *> *list = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (!w || w.hidden || w.alpha < 0.02) continue;
                if (SLVIsSystemOverlayWindow(w)) continue;
                [list addObject:w];
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (list.count == 0) {
        UIWindow *kw = [UIApplication sharedApplication].keyWindow;
        if (kw && !kw.hidden && !SLVIsSystemOverlayWindow(kw)) [list addObject:kw];
        id del = [UIApplication sharedApplication].delegate;
        if ([del respondsToSelector:NSSelectorFromString(@"window")]) {
            id dw = [del valueForKey:@"window"];
            if ([dw isKindOfClass:[UIWindow class]]) {
                UIWindow *w = (UIWindow *)dw;
                if (!w.hidden && ![list containsObject:w]) [list addObject:w];
            }
        }
    }
#pragma clang diagnostic pop
    UIWindow *best = nil;
    for (UIWindow *w in list) {
        if (!best) { best = w; continue; }
        if (w.windowLevel > best.windowLevel) { best = w; continue; }
        if (w.windowLevel < best.windowLevel) continue;
        // 同层级：先看 keyWindow，再看面积（主窗口总是最大的，别把球挂到某个小浮窗上）
        if (w.isKeyWindow != best.isKeyWindow) {
            if (w.isKeyWindow) best = w;
        } else {
            CGSize a = w.bounds.size, b = best.bounds.size;
            if (a.width * a.height > b.width * b.height) best = w;
        }
    }
    return best;
}

// v0.4.54：把球抬到最上层。
// 设置浮窗与试听卡片都是 OverFullScreen 呈现，直接盖在球上面 —— 用户看到的是
// 「球被卡片压掉一半」。这里在面板每次出现后调一次：球若落在别的窗口就先迁到最顶层窗口，
// 再在同一个窗口里 bringSubviewToFront；转场结束后补抬一次（系统重排图层会把它压回去）。
void SLVRaiseFloatButton(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        SLVFloatButton *btn = sSLFloatBtn;
        if (!btn) {
            UIWindow *w0 = SLVKeyWindow();
            btn = (SLVFloatButton *)[w0 viewWithTag:SLVBtnTag];
        }
        if (!btn) return;

        UIWindow *top = SLVKeyWindow();
        UIWindow *cur = btn.window;
        if (top && cur && top != cur && top.windowLevel >= cur.windowLevel) {
            [btn removeFromSuperview];
            [top addSubview:btn];
        }
        // v0.4.61：present 的呈现容器是在球之后才加到 window 上的，对 window 自己
        // bringSubviewToFront 抬不动球 —— 以前真正生效的是那次 0.4s 补抬，
        // 录屏里就是「卡片先出来、球被压在下层，0.4s 后才窜上去」。改成对球自己的
        // superview 提，并把补抬从 0.4s 提前到 0.05 / 0.18s（仍在系统重排之后）。
        [btn.superview bringSubviewToFront:btn];

        __weak SLVFloatButton *weakBtn = btn;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SLVFloatButton *b = weakBtn;
            if (!b || !b.superview) return;
            [b.superview bringSubviewToFront:b];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SLVFloatButton *b = weakBtn;
            if (!b || !b.superview) return;
            [b.superview bringSubviewToFront:b];
        });
    });
}

void SLVRefreshFloatButton(void) {
    SLVFloatButton *btn = sSLFloatBtn;
    if (!btn) {
        UIWindow *w = SLVKeyWindow();
        btn = (SLVFloatButton *)[w viewWithTag:SLVBtnTag];
    }
    SLVApplyFloatIcon(btn);
    // 0.2.28：绿球 = 「现在正在替换」，两个条件缺一不可。
    //
    // 原来只判 SLVCamArmed()（素材就绪 + 帧源 ready），漏了总开关 —— 关掉「启用」但
    // 素材还留着的时候，球依然是绿的，等于告诉用户「在替换」，其实早就放行了原画面。
    //
    // 关掉就退回 Idle：单框、中性色、42% 透明度，跟「没素材」完全一样。
    // 这两件事对用户的意义本来就是同一个 —— 没在替换，没必要再造第三种颜色。
    BOOL working = SLVCamEnabled() && SLVCamArmed();
    SLVFloatState want = working ? SLVFloatStateReady : SLVFloatStateIdle;
    // 状态没变就别再调 —— sl_applyState 会重挂一遍动画，窗口轮询每 2 秒走一次这里，
    // 每次都重挂的话球上的呼吸会一顿一顿的。
    if (btn && btn.slState != want) [btn sl_applyState:want];
}

// 球/扇能用的那块区域。
//
// 不能直接用 sv.bounds：sv 是 SLVKeyWindow() 挑的窗口，它挑的是 windowLevel 最高的，
// 而 iOS 里最高的常常不是主窗口（QQRTCWindow、键盘窗、Alert 窗都排在前面），
// bounds 只是屏幕的一块。也不能只用屏幕：子视图画不到父视图外面，会裁。
// 取两者较小的一边，正常 App 退化成屏幕，浮层窗口时至少不出界。
static CGSize SLVHostSizeFor(UIView *sv) {
    CGSize scr = SLVScreenSize();
    if (!sv) return scr;
    CGSize s = sv.bounds.size;
    if (s.width <= 0 || s.height <= 0) return scr;
    return CGSizeMake(MIN(s.width, scr.width), MIN(s.height, scr.height));
}

// 把中心点夹在「不会被屏幕边缘切掉」的范围内。
// 原来那版是「越界就重置」—— 拖到边上会突然跳回中间，而且重置值本身也可能越界。
static CGPoint SLVClampFloatPos(CGPoint c, CGSize size) {
    if (size.width <= 0 || size.height <= 0) return c;
    CGFloat half = SLVBallSide / 2.0;
    CGFloat minX = half + SLVBallEdgeInset;
    CGFloat maxX = size.width - half - SLVBallEdgeInset;
    CGFloat minY = half + 56.0;                 // 让开状态栏 / 刘海
    CGFloat maxY = size.height - half - 34.0;   // 让开底部安全区
    if (maxX < minX) { c.x = size.width / 2.0; }
    else { if (c.x < minX) c.x = minX; if (c.x > maxX) c.x = maxX; }
    if (maxY < minY) { c.y = size.height / 2.0; }
    else { if (c.y < minY) c.y = minY; if (c.y > maxY) c.y = maxY; }
    return c;
}

// 位置存「中心点占屏幕的比例」而不是绝对坐标：换设备、横竖屏、分屏之后
// 同样的比例仍然落在同一个相对位置，不会跑到屏外。
//
// 0.2.15：存储从 NSUserDefaults 换到 CFPreferences 全局域。
// tweak 注入进每个 App 后，[NSUserDefaults standardUserDefaults] 解析成该进程
// 自己的 bundle id，落到各自沙盒的 Library/Preferences/<bundleid>.plist ——
// 抖音存一份、QQ 存一份、陌陌存一份，互不可见。这就是「每个 App 里球位置都不一样」。
//
// 这里不能自己用 NSFileManager 拼 /var/mobile/Library/Preferences/xxx.plist 去写：
// tweak 继承的是 App 沙盒，直接写那个路径会被 sandbox 拒掉。CFPreferencesSetAppValue
// 走的是 cfprefsd 的 XPC，落盘由 cfprefsd 以用户身份完成，不在 App 沙盒内，所以能成，
// 顺带也不用判断 rootless 越狱下 /var/jb 的前缀。
static NSString *const kSLSharedDomain = @"com.taylorchen.shenglinvcam";
static NSString *const kSLPosRelKey    = @"SLVFloatPosRel";
static NSString *const kSLPosAbsKey    = @"SLVFloatPos";
// 0.3.0 改名前的旧键。当时和声临陌陌用的是同一串（SLFloatPos / SLFloatPosRel），
// 两个 dylib 同进程时会互相覆盖位置。这里只读不写，读到就立刻搬到新键上，
// 老用户升级后球不会跳回默认位。
static NSString *const kSLPosRelKeyOld = @"SLFloatPosRel";
static NSString *const kSLPosAbsKeyOld = @"SLFloatPos";

static NSString *SLVSharedString(NSString *key) {
    CFStringRef domain = (__bridge CFStringRef)kSLSharedDomain;
    CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, domain);
    if (!v) return nil;
    NSString *s = nil;
    if (CFGetTypeID(v) == CFStringGetTypeID()) s = [(__bridge NSString *)v copy];
    CFRelease(v);
    return s;
}

static void SLVSharedSet(NSString *key, NSString *value) {
    CFStringRef domain = (__bridge CFStringRef)kSLSharedDomain;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)value, domain);
    CFPreferencesAppSynchronize(domain);
}

static void SLVStoreFloatPos(CGPoint c, CGSize size) {
    if (size.width <= 0 || size.height <= 0) return;
    NSString *rel = [NSString stringWithFormat:@"%.4f,%.4f", c.x / size.width, c.y / size.height];
    SLVSharedSet(kSLPosRelKey, rel);
    SLVSharedSet(kSLPosAbsKey, NSStringFromCGPoint(c));   // 兼容旧版读法
    // 本 App 也留一份：万一全局域被拒（个别宿主沙盒更严），下次还能读回自己那份，
    // 不至于每次都跳回默认位置。
    [[NSUserDefaults standardUserDefaults] setObject:rel forKey:kSLPosRelKey];
}

static CGPoint SLVLoadFloatPos(CGSize size) {
    NSString *rel = SLVSharedString(kSLPosRelKey);
    if (!rel.length) rel = SLVSharedString(kSLPosRelKeyOld);   // 0.3.0 改名迁移
    if (!rel.length) {
        // 全局域还是空的（第一次装 0.2.15）→ 从本 App 的旧值迁移过来，
        // 老用户升级后球不会跳位。
        NSString *old = [[NSUserDefaults standardUserDefaults] stringForKey:kSLPosRelKey];
        if (!old.length) old = [[NSUserDefaults standardUserDefaults] stringForKey:kSLPosRelKeyOld];
        if (old.length) {
            SLVSharedSet(kSLPosRelKey, old);
            rel = old;
        }
    }
    if (rel.length) {
        NSArray *p = [rel componentsSeparatedByString:@","];
        if (p.count == 2) {
            double rx = [p[0] doubleValue], ry = [p[1] doubleValue];
            if (rx > 0.03 && rx < 0.97 && ry > 0.03 && ry < 0.97) {
                SLVSharedSet(kSLPosRelKey, rel);   // 从旧键读来的，顺手写进新键
                return CGPointMake(rx * size.width, ry * size.height);
            }
        }
    }
    NSString *abs = SLVSharedString(kSLPosAbsKey);
    if (!abs.length) abs = SLVSharedString(kSLPosAbsKeyOld);
    if (!abs.length) abs = [[NSUserDefaults standardUserDefaults] stringForKey:kSLPosAbsKey];
    if (!abs.length) abs = [[NSUserDefaults standardUserDefaults] stringForKey:kSLPosAbsKeyOld];
    if (abs.length) {
        SLVSharedSet(kSLPosAbsKey, abs);
        return CGPointFromString(abs);
    }
    // 0.3.0：默认落点从 0.55 挪到 0.72。声临陌陌的默认落点也在 0.55 一带，
    // 两边同时装、位置又都没存过时，两个球会叠在一起，看起来像「只有一个」。
    return CGPointMake(size.width - 36.0, size.height * 0.72);
}

void SLVEnsureFloatButton(void) {
    UIWindow *w = SLVKeyWindow();
    if (!w) {
        // 一直拿不到窗口就静默失败了，下次再出现「没有球」根本查不到原因 —— 限频记一条
        static CFAbsoluteTime last = 0;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - last > 30.0) {
            last = now;
            SLVLog(@"SL-VCAM: no host window yet, float button not mounted");
        }
        return;
    }
    SLVFloatButton *btn = (SLVFloatButton *)[w viewWithTag:SLVBtnTag];
    BOOL created = NO;   // 这一轮是不是新建了球（新建的球状态是白的，末尾要补刷一次）
    // tag 是自己独享的 20941，正常不会撞；但万一宿主的某个视图碰巧也用这个值，
    // 强转过去会一路把别人的视图当球使 —— 类型不对就当没找到。
    if (btn && ![btn isKindOfClass:[SLVFloatButton class]]) btn = nil;
    if (!btn) btn = sSLFloatBtn;   // 可能还挂在已经被换下去的旧窗口上
    if (btn && btn.superview != w) {
        // v0.4.37：窗口被换（启动页 / 广告窗关掉、场景重建）时把球迁到新的顶层窗口，
        // 否则球跟着旧窗一起消失，而且在新窗口里找不到 tag、只能等下次冷启动。
        [btn removeFromSuperview];
        btn.center = SLVClampFloatPos(btn.center, SLVHostSizeFor(w));
        [w addSubview:btn];
        // 抖音这类 App 的遮罩窗一秒能换好几次，逐次打日志会把整份日志顶满。
        // 同一类窗口只记第一次，之后每 50 次补一行心跳。
        static NSMutableSet *sSeenWindows = nil;
        static int sMoveCount = 0;
        sMoveCount++;
        if (!sSeenWindows) sSeenWindows = [NSMutableSet set];
        NSString *wn = NSStringFromClass([w class]);
        BOOL firstForWindow = ![sSeenWindows containsObject:wn];
        if (firstForWindow) [sSeenWindows addObject:wn];
        if (firstForWindow || sMoveCount % 50 == 0) {
            SLVLog(@"SL-VCAM: float button moved to top window (%@)%@", wn,
                  firstForWindow ? @"" : [NSString stringWithFormat:@" · 累计 %d 次", sMoveCount]);
        }
    }
    if (!btn) {
        CGPoint c = SLVClampFloatPos(SLVLoadFloatPos(SLVScreenSize()), SLVHostSizeFor(w));
        // 0.3.0：窗口里要是已经有声临陌陌的球（它用 20931）且位置几乎重合，
        // 把我们的往下挪一格。两个球叠在一起，看起来就是「只有一个球」——
        // 这也是「装了 Vcam 却没有 Vcam 的球」最常见的那种现场。
        // 只在首次创建时兜底，用户自己拖过的位置不覆盖。
        UIView *other = [w viewWithTag:20931];
        if (other && other != btn) {
            if (fabs(other.center.x - c.x) < 40.0 && fabs(other.center.y - c.y) < 56.0) {
                CGPoint moved = c;
                moved.y = other.center.y + 64.0;
                moved = SLVClampFloatPos(moved, SLVHostSizeFor(w));
                SLVLog(@"SL-VCAM: momo ball at %@ overlaps ours %@, moved to %@",
                       NSStringFromCGPoint(other.center), NSStringFromCGPoint(c),
                       NSStringFromCGPoint(moved));
                c = moved;
            }
        }
        btn = [[SLVFloatButton alloc] initWithFrame:CGRectMake(0, 0, 48, 48)];
        btn.center = c;
        btn.tag = SLVBtnTag;
        [w addSubview:btn];
        // 球被宿主反复移除重建时位置是一样的，重复打没有信息量
        static CGPoint sLastMountPos;
        static BOOL sHaveMountPos = NO;
        static int sMountCount = 0;
        sMountCount++;
        BOOL posChanged = !sHaveMountPos || !CGPointEqualToPoint(sLastMountPos, c);
        if (posChanged || sMountCount % 50 == 1) {
            SLVLog(@"SL-VCAM: float button mounted at %@%@", NSStringFromCGPoint(c),
                  posChanged ? @"" : [NSString stringWithFormat:@" · 累计 %d 次", sMountCount]);
        }
        sLastMountPos = c;
        sHaveMountPos = YES;
        created = YES;
    }
    sSLFloatBtn = btn;

    // 0.3.5：新建的球必须马上刷一次状态。
    //
    // initWithFrame: 里写死了 sl_applyState:Idle（白），而全项目只有 SLVCamReloadAll
    // 和「换图标」会调 SLVRefreshFloatButton —— 这个每 2 秒跑一次的轮询从来没刷过状态。
    // 于是「已经启用 + 素材也在」的情况下，只要球是新建的（冷启动第一次挂载，
    // 或者被宿主移除后 sSLFloatBtn 这个 __weak 释放、下次重建），它就一直是白的，
    // 直到用户去设置页把开关拨一下才变绿。
    //
    // 只在新建时刷，不进每轮轮询 —— SLVCamArmed() 会走到 [SLVMediaStore allItems]，
    // 那个方法每次都真的扫一遍沙盒目录再逐个 stat，2 秒一次纯属白烧 IO。
    if (created) SLVRefreshFloatButton();
}

// 统一入口：异常不再静默吞掉（限频 30s 一条，避免轮询刷屏）
static void SLVEnsureFloatButtonSafe(NSString *tag) {
    @try {
        SLVEnsureFloatButton();
    } @catch (NSException *e) {
        static CFAbsoluteTime last = 0;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - last > 30.0) {
            last = now;
            SLVLog(@"SL-VCAM: ensure float button failed (%@): %@", tag ?: @"?", e.reason);
        }
    }
}


// 不用 hook UIViewController：主队列定时检查并挂载（低侵入，避免 Logos 多 hook 嵌套坑）
void SLVStartEntryWatcher(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, (uint64_t)(2.0 * NSEC_PER_SEC), (uint64_t)(1.0 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{
            SLVEnsureFloatButtonSafe(@"timer");
        });
        dispatch_resume(timer);

        // v0.4.37：窗口一变就立刻重排，不用干等下一次轮询。
        // 这几种情况就是「球突然没了」的高发时刻：广告窗关掉、回前台换窗口、场景重建。
        void (^kick)(NSNotification *) = ^(NSNotification *n) {
            dispatch_async(dispatch_get_main_queue(), ^{
                SLVEnsureFloatButtonSafe(n.name ?: @"notify");
            });
        };
        for (NSString *name in @[UIWindowDidBecomeVisibleNotification,
                                 UIWindowDidBecomeKeyNotification,
                                 UIApplicationDidBecomeActiveNotification,
                                 UIApplicationWillEnterForegroundNotification]) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:kick];
        }
        if (@available(iOS 13.0, *)) {
            [[NSNotificationCenter defaultCenter] addObserverForName:UISceneDidActivateNotification
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:kick];
        }
        SLVEnsureFloatButtonSafe(@"launch");
    });
}

#pragma mark - 图标选择页

@interface SLVFloatIconController () <PHPickerViewControllerDelegate>
@end

@implementation SLVFloatIconController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"悬浮球图标";
    // v0.4.50：跟设置页统一 —— 毛玻璃底 + 胶囊标题 + 胶囊「完成」
    self.navigationItem.titleView = SLVPillTitleView(@"悬浮球图标");
    SLVInstallPillBack(self);   // v0.4.53：返回键胶囊
    SLVApplyGlassTable(self.tableView);
    self.navigationItem.rightBarButtonItem = SLVPillBarItem(@"完成", self, @selector(sl_done));
}

- (void)sl_done {
    if (self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    (void)tv;
    // v0.4.9：删掉表情预设，只留自定义图片
    // v0.4.80：删掉「图标动效」整段（关闭 / 律动 + 段尾说明）
    return 1;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    (void)tv;
    (void)section;
    return 2;   // 从相册选择 / 恢复默认
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    (void)tv;
    (void)section;
    return @"自定义图标";
}


// v0.4.50：单元格底色统一刷玻璃片（表格透明后不刷就是纯灰行）
- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip {
    (void)tv; (void)ip;
    cell.backgroundColor = SLVGlassCellColor();
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *rid = @"icon";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:rid];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.font = [UIFont systemFontOfSize:16];
    cell.detailTextLabel.text = nil;

    NSString *cur = SLVFloatIconValue();
    if (ip.row == 0) {
        cell.textLabel.text = @"从相册选择图片";
        cell.detailTextLabel.text = [cur hasPrefix:@"image:"] ? @"已设置" : @"";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        cell.textLabel.text = @"恢复默认图标";
        if ([cur isEqualToString:kSLFloatIconDefault]) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];

    if (ip.row == 0) {
        [self sl_pickPhoto];
        return;
    }
    [d setObject:kSLFloatIconDefault forKey:kSLFloatIconKey];
    [d synchronize];
    [[NSFileManager defaultManager] removeItemAtPath:SLVFloatIconImagePath(@"icon.png") error:nil];
    [self sl_applied];
}

- (void)sl_applied {
    SLVRefreshFloatButton();
    [self.tableView reloadData];
    SLVToast(@"已更新");
}

- (void)sl_pickPhoto {
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.filter = [PHPickerFilter imagesFilter];
    cfg.selectionLimit = 1;
    PHPickerViewController *vc = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    vc.delegate = self;
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!results.count) return;
    NSItemProvider *p = results.firstObject.itemProvider;
    if (![p canLoadObjectOfClass:[UIImage class]]) {
        SLVToast(@"图片读不出来");
        return;
    }
    __weak typeof(self) ws = self;
    [p loadObjectOfClass:[UIImage class] completionHandler:^(id<NSItemProviderReading> obj, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImage *img = [obj isKindOfClass:[UIImage class]] ? (UIImage *)obj : nil;
            if (img && SLVSaveFloatIconImage(img)) {
                [ws sl_applied];
            } else {
                SLVToast(@"保存失败");
            }
        });
    }];
}

@end

#pragma mark - 预览入口

// 0.2.22：长按停在「启用」球上再松手 → 预览当前素材。
//
// 两种情况分开走：浮窗已经开着（设置页 / 素材页）就直接推进它自己的导航栈；
// 没开着才新起一层。不能只调 presentFrom: —— 它有「已经开着就不再叠第二层」
// 的守卫，浮窗开着时这次点击会被静默吃掉。
static void SLVShowMediaPreview(void) {
    if (sSLFloatPanel && sSLFloatPanel.presentingViewController && sSLFloatPanel.nav) {
        [sSLFloatPanel.nav pushViewController:[[SLVMediaPreviewController alloc] init] animated:YES];
        return;
    }
    UIViewController *host = SLVTopViewController();
    if (!host) return;
    [SLVFloatPanelController presentFrom:host root:[[SLVMediaPreviewController alloc] init]];
}
