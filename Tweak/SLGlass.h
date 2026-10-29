//
//  SLGlass.h
//  声临 · 虚拟摄像头 —— 全站统一的玻璃外观基座
//
//  v0.4.50：设置页那套材质（超薄毛玻璃底 + 玻璃片单元格 + 发丝高光边）原本只落在
//  设置页和语音包页里，API 凭证 / 音色库 / 运行日志 / 悬浮球图标 / 导入 / 裁剪 / 收藏
//  还是各自的 systemGroupedBackground，点进去立刻从「玻璃卡」掉回「系统灰页」。
//  这里把材质和胶囊控件抽出来，谁 import 谁就自动是同一套观感。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 玻璃片单元格底色（深色 6% 白 / 浅色 34% 白）。设置页、语音包页、全站二级页共用同一个数。
UIColor *SLGlassCellColor(void);

/// 发丝高光边（深色 16% 白 / 浅色 55% 白），0.8pt。玻璃的「厚度」全靠这一圈。
UIColor *SLGlassHairlineColor(void);

/// 导航栏胶囊的底（深色 14% 白 / 浅色 60% 白）。bar item 里毛玻璃不渲染，只能用它顶上。
UIColor *SLGlassPillFillColor(void);

/// 给表格铺玻璃：table 本身透明 + backgroundView 换成超薄毛玻璃（设置页那张）。
void SLApplyGlassTable(UITableView *tv);

/// 给任意 view 铺玻璃底（自绘页面 / 日志页用），返回铺好的 blur，调用方可继续往 contentView 里放东西。
UIVisualEffectView *_Nullable SLInstallGlassBackdrop(UIView *host);

/// 胶囊导航按钮（毛玻璃 + 文字 + 发丝高光），用于「完成 / 保存 / 刷新 / 复制 / 清空」。默认高 32。
UIBarButtonItem *SLPillBarItem(NSString *title, id target, SEL action);

/// 指定高度的胶囊文字按钮（要跟同页搜索框对齐时用，例如地图页返回键 40pt）。
UIBarButtonItem *SLPillBarItemSized(NSString *title, CGFloat height, id target, SEL action);

/// 胶囊图标按钮（返回箭头之类）。icon 为空时退回文字。默认高 32。
UIBarButtonItem *SLPillIconBarItem(NSString *_Nullable systemName,
                                   NSString *_Nullable fallbackTitle,
                                   id target, SEL action);

/// 指定高度的胶囊图标按钮。
UIBarButtonItem *SLPillIconBarItemSized(NSString *_Nullable systemName,
                                        NSString *_Nullable fallbackTitle,
                                        CGFloat height, id target, SEL action);

/// 胶囊标题（二级页复用设置页那套：毛玻璃胶囊 + 15pt 文字）。默认高 32，与「完成」等高。
UIView *SLPillTitleView(NSString *text);

/// 把系统返回键换成胶囊返回键（默认高 32），顺带把侧滑返回手势接回来。
/// 已经自带 leftBarButtonItem 的页面会被跳过（不顶掉「完成」这类按钮）。
void SLInstallPillBack(UIViewController *vc);

/// 同上，可指定高度（地图页要 40pt，跟搜索框等高）。
void SLInstallPillBackSized(UIViewController *vc, CGFloat height);

#pragma mark - 搜索胶囊

/// 玻璃搜索胶囊（超薄毛玻璃 + 发丝边 + 全圆角 + 放大镜 + 输入框）。
///
/// v0.4.54：原来两页各自在「创建时算一次 frame」，宽度一变（表头被重设、旋转、分屏）
/// 就会失配 —— 表现为放大镜压在占位文字上。这里把所有排布收进 layoutSubviews，
/// 图标固定 13pt 起、文字固定接在图标后 7pt，任何宽度都不会重叠。
@interface SLSearchPill : UIView
/// 胶囊固定高度（36pt）。表头高度 = 高度 + 上下各 4pt。
+ (CGFloat)pillHeight;
+ (instancetype)pillWithPlaceholder:(NSString *)placeholder;
@property (nonatomic, strong, readonly) UITextField *field;
@end

NS_ASSUME_NONNULL_END
