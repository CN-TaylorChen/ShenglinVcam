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
//
// 0.3.52：两件事。
//   ① 开关：设置页「诊断 → 记录日志」可以关掉，关掉后连字符串都不拼。
//   ② 音频渲染回调里的日志改走 SLVLogRT —— 不在实时线程上 NSLog、不在实时线程上取时间戳。
//      采集回调每 20ms 必到一次，NSLog 单次 0.5~3ms，撞上系统繁忙就会超时一次，
//      听感是一声「咔」。日志少打一点没关系，把音频线程让出来更重要。

#import <Foundation/Foundation.h>

/// 日志总开关的存储键（BOOL，默认开）。设置页写，这里读。
extern NSString *const SLVLogEnabledKey;

/// 当前是否在记录日志。关掉后 SLVLog / SLVLogRT 直接返回，不做任何格式化。
BOOL SLVLogOn(void);

/// 设置开关并立即生效（同时写 NSUserDefaults，不需重启）
void SLVLogSetEnabled(BOOL on);

/// 写一行日志（内部已加时间戳）。落盘在串行队列，不占调用线程。
void SLVLogWrite(NSString *line);

/// 实时线程专用（音频渲染回调）。与 SLVLogWrite 的区别：不 NSLog、时间戳移进队列里取。
void SLVLogWriteRT(NSString *line);

/// 当前实际选中的日志文件路径（启动时把它打进第一行，避免「日志是空的」还要猜写在哪儿）
NSString *SLVLogCurrentPath(void);

/// 一句诊断：写入是否正常 / 文件多大 / 失败时带 errno。日志页直接显示。
NSString *SLVLogDiagnostics(void);

#define SLVLog(fmt, ...) do { \
    if (SLVLogOn()) { \
        NSString *__sl_m = [NSString stringWithFormat:(fmt), ##__VA_ARGS__]; \
        NSLog(@"SL-VCAM: %@", __sl_m); \
        SLVLogWrite(__sl_m); \
    } \
} while (0)

/// 音频渲染回调里必须用这个 —— 那里每 20ms 一包，不能有任何可能阻塞的调用。
#define SLVLogRT(fmt, ...) do { \
    if (SLVLogOn()) { \
        SLVLogWriteRT([NSString stringWithFormat:(fmt), ##__VA_ARGS__]); \
    } \
} while (0)

@interface SLVLog : NSObject
+ (NSString *)filePath;
+ (NSString *)diagnostics;
+ (unsigned long long)fileSize;   // 0.3.48：日志页用它区分「真没内容」和「有内容但读不出来」
+ (NSString *)tailLines:(NSInteger)lines;
+ (void)clear;
@end
