## 这一版修了什么

### 1. 「不黑屏，但也没替换成功」

上一版日志里每帧都在刷：

```
注入: CMSampleBuffer 构造失败（fmt 与帧不匹配）
feed 管线就绪 1111970369:1080x1920 (video=Y audio=N)
```

`1111970369` 就是 `BGRA`。也就是说假帧解出来了、格式也对，**卡在最后一步打包**：
`CMSampleBufferCreateReadyWithImageBuffer` 会先跑一次
`CMVideoFormatDescriptionMatchesImageBuffer`，要求格式描述（fmt）的像素格式、
宽高、平面性与 pixelBuffer **三项全等**，差一项就返回错误。

问题在于 fmt 是宿主的，帧是我们自己造的。iOS 17 起 `AVCaptureConnection` 的旋转
会直接作用到 `VideoDataOutput` 的 buffer 上——buffer 变成竖的 `1080x1920`，
而 fmt 还留着传感器尺寸 `1920x1080`。拿这种 fmt 去包任何帧都不可能过。

**改法：**

- 先用 `CMVideoFormatDescriptionMatchesImageBuffer` 判断宿主 fmt 与它**自己的** buffer 是否自洽；
- 假帧与 fmt 不匹配时，用 `CMVideoFormatDescriptionCreateForImageBuffer` 从假帧自建一个 fmt（保证内部自洽）再打包；
- `duration` 改成用 `CMTIME_IS_VALID` + `CMTimeCompare` 判，`indefinite` 的时长同样会让打包以
  `InvalidSampleTimingInfo` 失败，症状和格式错一模一样；
- 失败日志现在打印**真实 OSStatus** + fmt 与帧各自的格式尺寸，不再是一句笼统的「不匹配」。

### 2. 新增：画面旋转

设置 → 画面 → **画面旋转**，可选 不旋转 / 顺时针 90° / 180° / 270°。

渲染同时从「拉伸」改成「铺满取景框 + 居中裁切」，竖屏素材塞进横屏预览不会再被压扁。

### 3. 新增：音频开关

设置 → 声音 → **替换音频**。

- 开：用素材音轨替换麦克风（默认）；
- 关：**输出静音**，不会把环境声录进去。素材本身没有音轨时同样生效。

### 4. 顺手修的

切循环/镜像/旋转/音频开关不再让画面跳回第一帧（以前每次改动都会 `rewind`）。

## 装法

自签注入：把 `ShenglinVcam.dylib` 注入目标 App 的 IPA 后重签安装。
越狱环境直接装 `ShenglinVcam-v*.deb`。

> 本包与底包（声临）**包名和 dylib 名完全一致**，装这个会把底包覆盖掉。
> 两个都要用的话别同时装，等我做改名共存版。

## 验证要点

换素材后打开相机，日志里应该看到：

```
首帧 视频 1080x1920 pf=1111970369(BGRA) · fmt 1920x1080 BGRA · 自洽=N
```

`自洽=N` 说明宿主自己的 fmt 和 buffer 就对不上，这正是这一版要兜的情况。
只要之后**不再出现**「打包失败」，就说明假帧真的进到宿主了。
