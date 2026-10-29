//
//  SLMediaListController.h
//  声临 · 虚拟摄像头 —— 素材列表页（住在玻璃浮窗里）
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 底包自带的素材页：从相册导入视频、选中、左滑删除。
/// 业务侧想换一套（比如分成多个文件夹），自己写一个控制器替换
/// SLFloatPanelController +presentMediaFrom: 里的类即可。
@interface SLMediaListController : UITableViewController
@end

NS_ASSUME_NONNULL_END
