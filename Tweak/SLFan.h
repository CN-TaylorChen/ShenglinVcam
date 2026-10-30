//
//  SLFan.h
//  声临 · 虚拟摄像头 —— 长按展开的五个开关球
//
//  几何：球永远贴在屏幕某条边上，扇口朝屏幕内侧张开。
//  五个球排在 144° 的弧上（±72°），半径 92pt，球径 44pt。
//
//  0.2.15：球贴角落时不再「逐球夹取」——那样会把一侧两三个球压到同一条竖线上，
//  看起来就是「展开后错位」。现在改成**扇心内推**：球心不动，把扇心沿垂直于
//  张开方向的那一维推进安全区；真的放不下（屏幕比整扇还窄）才按比例缩半径。
//  扇心可能不等于球心，调用方用 slFanCenter 把主球滑过去，保持「球带扇走」。
//
//  顺序（从上到下 / 从右到左）：启用 · 静音 · 旋转 · 镜像 · 循环
//  旋转是四态（0/90/180/270），滑到它上面会再展开一列角度，弧跟着手指扫。
//

#import <UIKit/UIKit.h>

/// 球贴在哪条边 —— 决定扇口朝哪开
typedef NS_ENUM(NSInteger, SLFanEdge) {
    SLFanEdgeLeft = 0,
    SLFanEdgeRight,
    SLFanEdgeTop,
    SLFanEdgeBottom,
};

/// 开关顺序下标，和 SLFanView 内部一致
typedef NS_ENUM(NSInteger, SLFanSwitch) {
    SLFanSwitchEnabled = 0,   // 启用
    SLFanSwitchMute    = 1,   // 静音
    SLFanSwitchRotate  = 2,   // 旋转（四态）
    SLFanSwitchMirror  = 3,   // 镜像
    SLFanSwitchLoop    = 4,   // 循环
};

@interface SLFanView : UIView

/// host 是扇要铺满的那个容器（球的 superview）；center 是主球在 host 里的中心。
/// hostSize 传**屏幕尺寸**（SLScreenSize()），不要传 superview.bounds.size。
- (instancetype)initWithHostSize:(CGSize)hostSize
                      ballCenter:(CGPoint)center
                            edge:(SLFanEdge)edge;

/// 展开 / 收起（自带错开动画）
- (void)sl_show;
- (void)sl_hide;

/// 手指位置（host 坐标）。内部负责 hover、角度列的展开与弧的跟手扫动。
- (void)sl_trackPoint:(CGPoint)p;

/// 扇心（host 坐标）。球贴角时它会被推进安全区，和主球球心不同 ——
/// 调用方拿它把主球滑过来，否则会出现「球在一处、扇在另一处」。
@property (nonatomic, readonly) CGPoint slFanCenter;

/// 松手时的结果：选中的开关球，-1 = 没选
@property (nonatomic, readonly) NSInteger slPickedSwitch;
/// 选中的角度档位 0..3，-1 = 没选（只有停在旋转球上才有值）
@property (nonatomic, readonly) NSInteger slPickedAngle;

/// 0.2.22：手指停在「启用」球上不动 0.55s 再松手 = 想预览素材，不切开关。
/// 松手时要先读这个值再调 sl_hide，hide 会把它清掉。
@property (nonatomic, readonly) BOOL slWantsPreview;

/// 用当前设置初始化各球的状态（进扇之前调一次）
- (void)sl_reloadStates;

@end

/// 把一次选择写进设置并刷新帧源。
/// sw 传 SLFanSwitch 下标；angle 只有旋转用得上（0..3，-1 当 0）。
void SLFanCommit(NSInteger sw, NSInteger angle);
