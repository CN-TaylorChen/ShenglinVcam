#import <UIKit/UIKit.h>

// 插件内日志查看页（读 /var/mobile/Documents/ShenglinVcam/slvcam.log 尾部）
@interface SLLogViewController : UIViewController
@end

// 由 Tweak.x 提供：钩子安装情况摘要
NSString *SLHookStatusSummary(void);
