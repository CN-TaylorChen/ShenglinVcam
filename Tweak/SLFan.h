//
//  SLFan.h
//  声临 · 虚拟摄像头 —— 长按展开的五个开关球
//
//  几何：球永远贴在屏幕某条边上，扇口朝屏幕内侧张开。
//  五个球排在 144° 的弧上（±72°），半径 88pt；球贴角落时自动收窄扇角、
//  同时缩小半径，保证一个球都不会出屏。
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

/// host 是扇要铺满的那个容器（球的 superview）；center 是主球在 host 里的中心
- (instancetype)initWithHostSize:(CGSize)hostSize
                      ballCenter:(CGPoint)center
                            edge:(SLFanEdge)edge;

/// 展开 / 收起（自带错开动画）
- (void)sl_show;
- (void)sl_hide;

/// 手指位置（host 坐标）。内部负责 hover、角度列的展开与弧的跟手扫动。
- (void)sl_trackPoint:(CGPoint)p;

/// 松手时的结果：选中的开关球，-1 = 没选
@property (nonatomic, readonly) NSInteger slPickedSwitch;
/// 选中的角度档位 0..3，-1 = 没选（只有停在旋转球上才有值）
@property (nonatomic, readonly) NSInteger slPickedAngle;

/// 用当前设置初始化各球的状态（进扇之前调一次）
- (void)sl_reloadStates;

@end

/// 把一次选择写进设置并刷新帧源。
/// sw 传 SLFanSwitch 下标；angle 只有旋转用得上（0..3，-1 当 0）。
void SLFanCommit(NSInteger sw, NSInteger angle);
