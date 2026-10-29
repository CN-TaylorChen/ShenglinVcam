// 分区标题 / footer 的统一左基线盒子
//
// 背景：以前把「表格坐标系里量到的单元格文字 x」直接当成「盒子内部 label 的 x」，
// 但 insetGrouped 下 header/footer 的盒子被摆在卡片左缘（约 16pt），
// 于是真实位置 = 盒子 origin + 量到的 x，边距被算了两次，标题和 footer 一起右移。
//
// 这里不再假设盒子摆在哪：layoutSubviews 时把自己换算到表格坐标系量出真实 origin，
// 再反推 label 该在盒子内偏多少。盒子摆在 0 还是 16，结果都落在同一条线上。

#import <UIKit/UIKit.h>

@interface SLAlignBox : UIView

/// 目标左基线，单位是「表格坐标系」的 x（即单元格文字的绝对位置）
@property (nonatomic, assign) CGFloat targetLeading;

@end

/// 分组标题（固定 22pt 高，单行）
UIView *SLAlignHeader(NSString *text, CGFloat targetLeading, CGFloat width);

/// 分组说明（多行，高度由调用方按文本实算）
UIView *SLAlignFooter(NSString *text, CGFloat targetLeading, CGFloat width);
