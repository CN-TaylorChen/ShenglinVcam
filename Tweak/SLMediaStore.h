//
//  SLMediaStore.h
//  声临 · 虚拟摄像头 —— 素材库（相册导入的视频）
//
//  只做「文件怎么放、哪个算当前素材」这一件事，不碰解码和注入。
//  素材文件统一放在 Documents/ShenglinVcam/media/ 下，文件名即主键，
//  这样重启、换设备（同一份 Documents 备份）都能对上。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SLMediaItem : NSObject
@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, copy) NSString *path;
/// 去掉扩展名的显示名
@property (nonatomic, copy) NSString *displayName;
@end

@interface SLMediaStore : NSObject

/// 素材目录（不存在会建）
+ (NSString *)mediaDir;

/// 全部素材，按文件名排序（新导入的时间戳文件名天然排在后面）
+ (NSArray<SLMediaItem *> *)allItems;

/// 当前选中的素材；没选或文件已经不存在时返回 nil
+ (nullable SLMediaItem *)currentItem;

/// 选中某个素材（只存文件名）
+ (void)setCurrentItem:(nullable SLMediaItem *)item;

/// 从外部 URL 导入（相册给的是临时文件，必须复制进来）
+ (BOOL)importFileAtURL:(NSURL *)url error:(NSError *_Nullable *_Nullable)error;

/// 删除某个素材；删的正好是当前素材时顺手清空选中
+ (void)removeItem:(SLMediaItem *)item;

@end

NS_ASSUME_NONNULL_END
