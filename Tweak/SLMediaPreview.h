//
//  SLMediaPreview.h
//  声临 · 虚拟摄像头 —— 素材预览
//
//  0.2.22：
//    · 设置页多一行「预览素材」，右侧直接显示当前素材有没有声音
//    · 悬浮球长按 → 停在「启用」球上不动 0.55s → 松手进预览（不切开关）
//    · 预览里真的把素材放出来：有音轨就能听见，没音轨就是静音，不猜
//
//  为什么不用「跳动的电平条」：
//  想画真电平得挂 MTAudioProcessingTap，那玩意儿一旦没挂对，最坏的后果是
//  **预览反而没声音** —— 正好毁掉这个功能存在的意义。所以这里只做静态体检
//  （音轨在不在 + 能不能解成 PCM）+ 真播放，结论是确定的。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SLMediaAudioInfo : NSObject

/// 素材里有没有音轨
@property (nonatomic, assign) BOOL hasAudio;
/// 音轨能不能解成 16bit PCM（跟 SLCamFeed 建 reader 的判据一致）
@property (nonatomic, assign) BOOL decodable;
/// 「AAC」「Opus」「PCM」这类可读名；没有音轨时为空串
@property (nonatomic, copy) NSString *codec;
/// 「44.1 kHz · 2 声道」；没有音轨时为空串
@property (nonatomic, copy) NSString *detail;

@end

/// 探一次音轨。文件不存在 / 不是素材时返回 nil。
/// 结果按「文件名 + 修改时间」缓存，设置页反复刷 cell 也不会反复解析。
SLMediaAudioInfo *_Nullable SLProbeMediaAudio(NSString *_Nullable path);

/// 设置页「预览素材」行右侧那一小截字：有声音 / 无声音 / 图片 / 未选素材
NSString *SLMediaAudioSummary(void);

/// 预览页。推进导航栈（从设置页）或直接当浮窗根页（从悬浮球）都行。
@interface SLMediaPreviewController : UIViewController
@end

NS_ASSUME_NONNULL_END
