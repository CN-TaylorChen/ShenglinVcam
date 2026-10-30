//
//  SLVMediaStore.h
//  声临 · 虚拟摄像头 —— 素材库（相册 / 文件导入的视频和图片）
//
//  只做「文件怎么放、哪个算当前素材」这一件事，不碰解码和注入。
//  素材文件统一放在 Documents/ShenglinVcam/media/ 下，文件名即主键，
//  这样重启、换设备（同一份 Documents 备份）都能对上。
//
//  0.2.20 起：
//    · 支持图片（PNG / JPG / HEIC…），图片和视频在同一个池子里；
//    · 按文件内容的 SHA-256 去重，同一份文件不会进来两次；
//    · 列表按添加时间倒序（最新的在最上面）；
//    · 导入完成后自动选中新素材。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SLVMediaItem : NSObject
@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, copy) NSString *path;
/// 去掉扩展名的显示名
@property (nonatomic, copy) NSString *displayName;
/// 图片（定格画面）还是视频
@property (nonatomic, assign) BOOL isImage;
/// 添加时间，列表倒序用
@property (nonatomic, strong) NSDate *addedAt;
@end

@interface SLVMediaStore : NSObject

/// 素材目录（不存在会建）
+ (NSString *)mediaDir;

/// 全部素材，**最新的在前**
+ (NSArray<SLVMediaItem *> *)allItems;

/// 当前选中的素材；没选或文件已经不存在时返回 nil
+ (nullable SLVMediaItem *)currentItem;

/// 选中某个素材（只存文件名）
+ (void)setCurrentItem:(nullable SLVMediaItem *)item;

/// 从外部 URL 导入（相册 / 文件 App 给的都是临时文件，必须复制进来）。
///
/// 导入成功后**自动选中**这个素材。
/// @param duplicate 传出「库里已经有同样内容的文件」——此时不复制，直接返回已有的那条
/// @return 素材条目；失败返回 nil
+ (nullable SLVMediaItem *)importItemAtURL:(NSURL *)url
                                    error:(NSError *_Nullable *_Nullable)error
                                duplicate:(BOOL *_Nullable)duplicate;

/// 老接口，等价于 ignore duplicate
+ (BOOL)importFileAtURL:(NSURL *)url error:(NSError *_Nullable *_Nullable)error;

/// 删除某个素材；删的正好是当前素材时顺手清空选中
+ (void)removeItem:(SLVMediaItem *)item;

/// 文件名是不是我们认的图片格式
+ (BOOL)isImageFileName:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
