//
//  SLCamBridge.h
//  声临 · 虚拟摄像头 —— 外壳与业务之间唯一的接口
//
//  底包的悬浮球 / 设置页 / 胶囊只认这几个函数。套用新插件时：
//    1. 在 SLCamCore.m 里实现它们（底包已给可编译的最小实现）；
//    2. 业务逻辑想怎么改就怎么改，外壳一行不用动。
//
//  想加新的交互（比如胶囊上再显示一个分辨率角标），在这里加一个函数，
//  外壳调它，业务实现它 —— 别让外壳直接 import 业务头文件。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 总开关。设置页「启用」那一行的值；关掉后点球不展开。
BOOL SLCamEnabled(void);

/// 素材是否已就绪。true → 球亮绿色（Ready），false → 灰（Idle）。
BOOL SLCamArmed(void);

/// 胶囊上显示的那行字。底包默认返回「未选素材」。
NSString *SLCamCurrentName(void);

/// 设置页「当前素材」行右侧的摘要。
NSString *SLCamStatusSummary(void);

/// 点胶囊右端箭头。底包默认弹素材列表；业务想做别的事就换掉实现。
void SLCamHandleArrowTap(UIView *anchor);

/// 设置改动后统一刷新（壳 + 业务自己缓存的东西）。
void SLCamReloadAll(void);

/// 开关的存储键（设置页与业务共用，别各存一份）
extern NSString *const kSLCamEnabledKey;

/// 画面设置：循环播放 / 水平镜像 / 旋转角度。设置页负责写，帧源负责读。
extern NSString *const kSLCamLoopKey;
extern NSString *const kSLCamMirrorKey;

/// 旋转角度，NSInteger，顺时针，只认 0 / 90 / 180 / 270（默认 0）
extern NSString *const kSLCamRotateKey;

/// 是否用素材音频替换麦克风，BOOL，默认 YES；NO = 静音输出
extern NSString *const kSLCamAudioKey;

NS_ASSUME_NONNULL_END
