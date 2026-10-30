//
//  SLMediaListController.h
//  声临 · 虚拟摄像头 —— 素材列表页（住在玻璃浮窗里）
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 底包自带的素材页：导入视频 / 图片、选中、左滑删除。
/// 业务侧想换一套（比如分成多个文件夹），自己写一个控制器替换
/// SLFloatPanelController +presentMediaFrom: 里的类即可。
@interface SLMediaListController : UITableViewController

/// 弹出「添加素材」菜单：相册视频 / 相册图片 / 文件导入。
///
/// 设置页和素材页都用它，免得两处各写一份。
/// @param completion 导入结束后回调（YES = 加进去了，包括「已在库里所以直接选中」）
+ (void)presentAddMenuFrom:(UIViewController *)host
                completion:(nullable void (^)(BOOL added))completion;

@end

NS_ASSUME_NONNULL_END
