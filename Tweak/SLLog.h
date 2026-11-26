// 声临·虚拟摄像头 日志：同时打到 NSLog 和文件，方便在手机/电脑上直接看
//
// 0.3.47 起路径按「真能写进去」挑，顺序是：
//   /var/mobile/Documents/ShenglinVcam/slvcam.log      ← 全设备共享一份
//   /var/jb/var/mobile/Documents/ShenglinVcam/slvcam.log
//   <App 沙盒>/Documents/ShenglinVcam/slvcam.log
//   <App 沙盒>/tmp/ShenglinVcam/slvcam.log
//   /tmp/shenglin-vcam.log
// 运行中写入失败会自动换下一条，并把 errno 记在诊断串里。
//
// 0.3.48：读日志改成「只读尾部 + 行首对齐 + 宽松解码」。
// 之前是整份读、整份按 UTF-8 解，文件开头只要有一个坏字节就整份解不出来，
// 页面全白但诊断行还报「写入正常」—— 坏字节的来源就是超过 1MB 时按 512KB 硬截。

#import <Foundation/Foundation.h>

/// 写一行日志（内部已加时间戳）
void SLVLogWrite(NSString *line);

/// 当前实际选中的日志文件路径（启动时把它打进第一行，避免「日志是空的」还要猜写在哪儿）
NSString *SLVLogCurrentPath(void);

/// 一句诊断：写入是否正常 / 文件多大 / 失败时带 errno。日志页直接显示。
NSString *SLVLogDiagnostics(void);

#define SLVLog(fmt, ...) do { \
    NSString *__sl_m = [NSString stringWithFormat:(fmt), ##__VA_ARGS__]; \
    NSLog(@"SL-VCAM: %@", __sl_m); \
    SLVLogWrite(__sl_m); \
} while (0)

@interface SLVLog : NSObject
+ (NSString *)filePath;
+ (NSString *)diagnostics;
+ (unsigned long long)fileSize;   // 0.3.48：日志页用它区分「真没内容」和「有内容但读不出来」
+ (NSString *)tailLines:(NSInteger)lines;
+ (void)clear;
@end
