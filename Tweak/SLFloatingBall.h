//
//  SLVFloatingBall.h
//  声临 · 虚拟摄像头 —— 悬浮球公开接口
//
//  底包外壳：球 / 胶囊 / 设置浮窗 / 图标设置页。业务侧只依赖这里 + SLVCamBridge.h，
//  不直接碰 SLVFloatButton 内部实现，换插件时这一层完全不用改。
//

#import <UIKit/UIKit.h>

/// 挂球（幂等，可以在任何时机反复调）
void SLVEnsureFloatButton(void);

/// 启动监听：每 1.2s 补一次 + 收几个系统通知。
/// 宿主 app 的窗口可能被启动页 / 广告页替换，球要能跟着搬家。
void SLVStartEntryWatcher(void);

/// 改完设置后立刻刷新已挂载的按钮（图标、名字、颜色一起走）
void SLVRefreshFloatButton(void);

/// 设置页右侧显示的当前图标摘要
NSString *SLVFloatIconSummary(void);

/// 把球抬到最上层（浮窗 / 卡片呈现后调，否则球会被压在下层）
void SLVRaiseFloatButton(void);

/// 品牌图形：黑底圆 + 六根声波条，代码绘制不依赖图片。
UIImage *SLVBrandIconImage(CGFloat side);
UIImage *SLVBrandIconImageTinted(CGFloat side, UIColor *bg);

/// 无底色的品牌图形（线条用传入的颜色）。标题栏 / 列表缩略图这类小尺寸场合用这个：
/// SLVBrandIconImage 带一圈黑色圆底，缩到 20 多 pt 会糊成一坨黑。
UIImage *SLVBrandGlyphImage(CGFloat side, UIColor *color);

/// 悬浮球四态。底包只负责「长什么样」，什么时候切由业务调。
typedef NS_ENUM(NSInteger, SLVFloatState) {
    SLVFloatStateIdle = 0,           // 灰：待命
    SLVFloatStateRecording = 1,      // 红：采集中
    SLVFloatStateSynthesizing = 2,   // 蓝：处理中
    SLVFloatStateReady = 3,          // 绿：素材已就绪
};

void SLVFloatSetState(SLVFloatState state);

/// 同上，但不触发「落定」缩放回弹（面板自己在弹入时用，避免两个动画撞车）
void SLVFloatSetStateQuiet(SLVFloatState state);

/// 浮窗内部是子控制器，点「完成」要向上找到真正的呈现者
void SLVCloseHostingPanel(UIViewController *vc);

/// 玻璃浮窗容器：设置页 / 素材页 / 任何自定义页都住在里面
@interface SLVFloatPanelController : UIViewController
+ (void)presentFrom:(UIViewController *)host root:(UIViewController *)root;
+ (void)presentSettingsFrom:(UIViewController *)host;
/// 素材列表（底包自带一个空壳页，业务可以换成自己的）
+ (void)presentMediaFrom:(UIViewController *)host;
+ (BOOL)isSettingsOpen;
+ (void)dismissSettings;
@end

/// 悬浮球图标设置页（从相册选图 / 恢复默认 / 动效随图开启）
@interface SLVFloatIconController : UITableViewController
@end
