//
//  SLVCamBridge.h
//  声临 · 虚拟摄像头 —— 外壳与业务之间唯一的接口
//
//  底包的悬浮球 / 设置页 / 胶囊只认这几个函数。套用新插件时：
//    1. 在 SLVCamCore.m 里实现它们（底包已给可编译的最小实现）；
//    2. 业务逻辑想怎么改就怎么改，外壳一行不用动。
//
//  想加新的交互（比如胶囊上再显示一个分辨率角标），在这里加一个函数，
//  外壳调它，业务实现它 —— 别让外壳直接 import 业务头文件。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 总开关。设置页「启用」那一行的值；关掉后点球不展开。
BOOL SLVCamEnabled(void);

/// 素材是否已就绪。true → 球亮绿色（Ready），false → 灰（Idle）。
BOOL SLVCamArmed(void);

/// 胶囊上显示的那行字。底包默认返回「未选素材」。
NSString *SLVCamCurrentName(void);

/// 设置页「当前素材」行右侧的摘要。
NSString *SLVCamStatusSummary(void);

/// 点胶囊右端箭头。底包默认弹素材列表；业务想做别的事就换掉实现。
void SLVCamHandleArrowTap(UIView *anchor);

/// 设置改动后统一刷新（壳 + 业务自己缓存的东西）。
void SLVCamReloadAll(void);

/// 配置变了（开关 / 旋转 / 素材切换）就发这个通知，SLVCamReloadAll 里统一 post。
///
/// 设置页开着的时候，用户还能长按悬浮球改开关 —— 那条路径只写 NSUserDefaults，
/// 设置页的 cell 是创建时读一次值，不会自己刷新，看起来就是「开关不同步」。
/// 监听这个通知，把可见 cell 里的开关值同步回来即可。
extern NSString *const SLVCamConfigChangedNotification;

/// 开关的存储键（设置页与业务共用，别各存一份）
extern NSString *const kSLCamEnabledKey;

/// 画面设置：循环播放 / 水平镜像 / 旋转角度。设置页负责写，帧源负责读。
extern NSString *const kSLCamLoopKey;
extern NSString *const kSLCamMirrorKey;

/// 旋转角度，NSInteger，顺时针，只认 0 / 90 / 180 / 270（默认 0）
extern NSString *const kSLCamRotateKey;

/// 是否用素材音频替换麦克风，BOOL，默认 YES；NO = 静音输出
extern NSString *const kSLCamAudioKey;

/// 陌陌「实拍时刻」是否按中间正方形裁切（不放大），BOOL，默认 NO。
/// NO = 铺满整帧（0.3.10 的老行为）；YES = 只裁一刀，方图 1:1 落进方块。
/// 只对陌陌进程有意义，别的 App 判断不过去。
extern NSString *const kSLCamSquareCropKey;

NS_ASSUME_NONNULL_END
