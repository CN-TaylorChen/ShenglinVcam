//
//  SLCamFeed.m
//  声临 · 虚拟摄像头 —— 帧源（底包空实现）
//

#import "SLCamFeed.h"
#import "SLUtil.h"
#import "SLLog.h"

@implementation SLCamFeed

+ (instancetype)shared {
    static SLCamFeed *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[SLCamFeed alloc] init]; });
    return s;
}

- (void)setSourcePath:(NSString *)sourcePath {
    _sourcePath = [sourcePath copy];
    // TODO(套用): 这里换掉 AVAssetReader，按头文件里的五步走
    SLLog(@"feed source -> %@", sourcePath.lastPathComponent ?: @"(nil)");
}

- (CVPixelBufferRef)copyNextFrame {
    return NULL;   // 骨架：没有帧，注入层会原样放行真实摄像头
}

- (void)rewind {
    // TODO(套用): reader 归零重读
}

- (CGSize)frameSize {
    return CGSizeZero;   // TODO(套用): 从 track 的 naturalSize 读
}

- (BOOL)isReady {
    return self.sourcePath.length > 0
        && [[NSFileManager defaultManager] fileExistsAtPath:self.sourcePath];
}

@end
