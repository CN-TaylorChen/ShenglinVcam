## 0.2.3 —— 音频探测版

画面替换已经确认可用（陌陌真机：`自洽=Y`，打包零失败）。这一版不碰画面逻辑，
只做两件事：**把音频为什么没被拦查清楚**，以及**把日志降噪**。

### 日志里发现的两件事

**1. 只挂上了 1 个方法，而且是 `AVCaptureVideoDataOutput` 自己的**

```
hook -[AVCaptureVideoDataOutput _processSampleBuffer:] types=v24@0:8^{opaqueCMSampleBuffer=}16
注入: 共 hook 1 个方法
```

也就是说 `AVCaptureOutput` 基类上并没有这个方法，音频输出类也没有自己的同名方法。
**音频这条路目前完全没有被拦**（日志里从来没有出现过「首帧 音频」）。素材带音轨也换不了声。

**2. 上一版的归因错了一半**

```
首帧 视频 1080x1920 pf=1111970369(BGRA) · fmt 1080x1920 BGRA · 自洽=Y
```

`自洽=Y` 说明宿主自己的 fmt 和 buffer 完全一致——**「旋转导致 fmt 与 buffer 尺寸不符」
这个推测对陌陌不成立**。真正让打包失败的是时间戳：采集帧的 `duration` 不是
`kCMTimeInvalid`（旧代码拦得住）而是「有效位为真、但不是正常数值」的形态，
旧代码的 `CMTIME_IS_INVALID` 判不出来，`CMSampleBufferCreateReady` 就报
`InvalidSampleTimingInfo`。这一版会把**原始的 duration/dts 打出来**，下次就能坐实。

### 这一版新增的诊断

- `探测: AVCaptureAudioDataOutput → ...`：列出音频输出类上所有名字带 sample/buffer 的方法
- `会话加输出: <类名>`：App 往 `AVCaptureSession` 里加了哪些输出（看音频到底走哪条路）
- `注入: 真帧 duration 非法（value=... scale=... flags=...）`：时间戳归一化时记下原值
- 扫描挂点从「名字含 processSampleBuffer」放宽到「名字含 samplebuffer」，
  但**只挂 `void` + 单个指针参数**的方法——签名不符的会打印「跳过」而不是硬挂
  （硬挂会把多余参数丢掉，宿主当场行为异常）

### 顺手降噪

`feed 管线就绪` 不再每轮循环都刷（11 秒一条 → 只在首次/格式变化/每 20 轮打一次）。

### 下一步

把这一版装上跑一次，日志里那三行探测结果发我，就能确定音频该挂哪个方法，
然后 0.2.4 把「带语音」补齐。

## 装法

自签注入：把 `ShenglinVcam.dylib` 注入目标 App 的 IPA 后重签安装。
越狱环境直接装 `ShenglinVcam-v*.deb`。

> 本包与底包（声临）**包名和 dylib 名完全一致**，装这个会把底包覆盖掉。
> 两个都要用的话别同时装。
