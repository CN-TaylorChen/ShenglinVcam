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

/// 在 anchorView 下方弹出「添加素材」小框：从相册选择 / 从文件导入。
///
/// 0.2.22 起不再用 action sheet —— 素材页的「＋」在导航栏右上角，
/// sheet 从屏幕底下升起来，跟点的那颗按钮没有任何位置关系；
/// 改成锚在按钮下方的小框，点哪儿弹哪儿。
///
/// @param host      弹框的宿主控制器（浮窗里的素材页 / 设置页）
/// @param anchorView 锚点视图，小框贴着它的下沿展开；传 nil 则退回 host.view 顶部居中
/// @param completion 导入结束后回调（YES = 加进去了，包括「已在库里所以直接选中」）
+ (void)presentAddMenuFrom:(UIViewController *)host
                    anchor:(nullable UIView *)anchorView
                completion:(nullable void (^)(BOOL added))completion;

@end

NS_ASSUME_NONNULL_END
