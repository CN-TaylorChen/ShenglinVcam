// 声临·虚拟摄像头 日志：同时打到 NSLog 和文件，方便在手机/电脑上直接看
// 文件位置：/var/mobile/Documents/ShenglinVcam/slvcam.log（拿不到权限时退回 App 沙盒）

#import <Foundation/Foundation.h>

/// 写一行日志（内部已加时间戳）
void SLLogWrite(NSString *line);

#define SLLog(fmt, ...) do { \
    NSString *__sl_m = [NSString stringWithFormat:(fmt), ##__VA_ARGS__]; \
    NSLog(@"SL-VCAM: %@", __sl_m); \
    SLLogWrite(__sl_m); \
} while (0)

@interface SLLog : NSObject
+ (NSString *)filePath;
+ (NSString *)tailLines:(NSInteger)lines;
+ (void)clear;
@end
