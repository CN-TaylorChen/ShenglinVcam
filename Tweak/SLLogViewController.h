#import <UIKit/UIKit.h>

// 插件内日志查看页（读 /var/mobile/Documents/ShenglinVcam/slvcam.log 尾部）
@interface SLVLogViewController : UIViewController
@end

// 由 Tweak.x 提供：钩子安装情况摘要（设置页「运行日志」那行右侧用）
NSString *SLVHookStatusSummary(void);

// 由 Tweak.x 提供：已装上的钩子数量。
//
// 0.3.10 新增。原来这里靠解析 SLVHookStatusSummary() 的字符串来数个数
// （找「已装钩子：」前缀、再按两个空格切分），但那个函数的返回格式后来改成了
// 「替换中 · N 个方法」，前缀永远对不上 —— 于是数量恒为 0，日志页标题行
// 一直显示「未装上钩子」，跟展开后的内容自相矛盾。
// 现在直接给数字，不再猜字符串。
NSInteger SLVHookCount(void);

// 由 Tweak.x 提供：状态卡的短状态词 —— 替换中 / 待命 / 未命中 / 未装上
NSString *SLVHookStateShort(void);
