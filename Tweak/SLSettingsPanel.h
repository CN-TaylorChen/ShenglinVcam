#import <UIKit/UIKit.h>

/// 设置页（住在 SLVFloatPanelController 的玻璃浮窗里）
/// 底包只保留四组：基本设置 / 素材 / 画面 / 诊断。
/// 加新开关：在 numberOfRowsInSection + cellForRowAtIndexPath + didSelectRow 三处各加一条，
/// 存值统一走 NSUserDefaults，业务侧自己读。
@interface SLVSettingsPanel : UITableViewController
@end
