## 0.2.10 —— 修抖音闪退，修声音加速

两个独立的 bug，一个是崩溃，一个是听感。

### 一、抖音点开录制就闪退

崩溃日志（`Aweme-2026-10-30-111449.ips`）给得很清楚：

```
exception : EXC_BREAKPOINT / SIGTRAP
asi       : {"CoreFoundation": ["*** CFRelease() called with NULL ***"]}

CMCapture    __rqReceiverSetSource_block_invoke
AVFCapture   -[AVCaptureVideoDataOutput _updateRemoteQueue:]_block_invoke
ShenglinVcam SLCamProcessSampleBuffer          ← 我们
AVFCapture   -[AVCaptureVideoDataOutput _processSampleBuffer:]
AwemeCore    ? + 135303880                     ← 抖音的代理
CoreFoundation CFRelease                        ← 崩在这
```

`CFRelease(NULL)` 在 CoreFoundation 里是**硬断言**，不是野指针 —— 说明抖音从我们给的
假帧上取某个对象，拿到 NULL，然后没判空直接 Release 了。

**假帧缺两样东西：**

| 缺的 | 谁造成 | 抖音读它的方式 |
|---|---|---|
| sample buffer 附件 | `CMSampleBufferCreateReadyWithImageBuffer` 只传播**像素缓冲区上**的附件，真帧自己带的一条都不过去 | `CMGetAttachment` / `CMCopyDictionaryOfAttachments` |
| format description 扩展 | 自建 fmt 走的是 `CMVideoFormatDescriptionCreateForImageBuffer`，它从像素缓冲区**反推**扩展，而我们的帧是干净造的 → 反推出来是空字典 | `CMFormatDescriptionGetExtension` |

真机采集帧这两样**一定有值**，所以抖音那边根本没写判空。

### 二、这一版怎么改

1. **自建 fmt 时把宿主的 extensions 整包搬过去**
   换成 `CMVideoFormatDescriptionCreate(subType, 帧宽, 帧高, 宿主扩展)`。
   造不出来（个别 key 和尺寸不自洽）才退回原来那套，并记一行日志。

2. **真帧的附件搬到假帧上**
   `CMCopyDictionaryOfAttachments` → `CMSetAttachments`。相机内参、色彩矩阵、
   时间戳对齐信息都回来了。音频帧同样处理。

3. **渲染出来的帧带上源帧的色彩附件**
   `CVPixelBufferCreate` 造的是干净缓冲，YCbCr 矩阵 / 色彩空间一个都没有，
   现在从源帧拷过去 —— 顺带让色彩转换更准。

4. **加一行诊断**
   首次注入时把两边的 key 列表打出来：

   ```
   注入: 真帧附件 9 项 (…, CameraIntrinsicMatrix, …) · 宿主 fmt 扩展 12 项 (…)
   ```

   万一还崩在这个位置，这一行能直接指出缺哪个 key，不用再猜。

### 三、声音加速

0.2.9 修完「没声音」，又引入了「2 倍速」。

原因还是水位逻辑。0.2.9 里除了 0.6 秒硬切，还有一条：

```c
} else if (avail > target + numBytes * 4) {   // ← 稳态下天天成立
    drop = MIN(numBytes, avail - target);     // 每次回调丢一包
}
```

想的是「一次最多丢一包，2× 速度慢慢追，人耳听不出来」。但**稳态水位本来就长期高于
target**（生产端按 `HIGH` 补，`HIGH` 必然大于 `TARGET`），这条分支每次回调都成立：
每 20ms 丢一包 20ms → 内容以 40ms/20ms 前进 → **2 倍速**。

> 任何在稳态下会成立的丢包条件都是错的。「追赶」只有在能判断「确实落后」时才有意义，
> 而水位高不等于延迟大。

所以整条删掉，只剩 0.6 秒硬切。同时把高水位从 0.14s 压到 0.12s。

| 项 | 0.2.9 | 0.2.10 |
|---|---|---|
| 生产端高水位 | 0.14s | **0.12s** |
| 2× 追赶丢包 | 稳态下每次回调都触发 | **删除** |
| 硬切 | > 0.6s | > 0.6s（不变，正常永远够不着） |

### 装上之后验证

1. 抖音点开录制 → **不闪退**，录出来的画面是素材
2. QQ / 陌陌 / 抖音，声音**速度正常**、不加速
3. 日志里不该再出现「缓冲…偏高」，应该只有 `水位 xxx ms · 丢 0 字节`
4. 日志里应该有 `注入: 真帧附件 N 项 … · 宿主 fmt 扩展 N 项 …`

---

## 0.2.9 —— 把 0.2.8 丢掉的音频捡回来

0.2.8 有个硬伤：**装上之后 QQ 和陌陌都没声音了**。这一版就是修它，外加抖音录像卡死。

### 一、没声音：水位比例写错了

0.2.8 引入的两个水位常量差了 3.5 倍：

| 常量 | 0.2.8 | 作用 |
|---|---|---|
| `SL_AUDIO_HIGH_SEC` | 0.35s | 解码线程填到这个水位就停 |
| `SL_AUDIO_TARGET_SEC` | 0.10s | 消费端超过就把多余的丢到 0.10s |

于是稳态变成：

```
解码线程把缓冲填到 350ms
      ↓
消费端下一次回调：350ms 远超阈值，一口气砍到 100ms
      ↓
只播了 20ms，缓冲又被填满，再砍 250ms
      ↓
每 270ms 只播 20ms ≈ 7% 的音频
```

听感不是「不同步」，是**几乎没声音，只剩咔哒**。

日志里那两行就是现场：

```
QQ   : 丢弃 23296 字节拉回 100ms   → 16000Hz×4B = 64000B/s，364 毫秒
陌陌 : 丢弃 29156 字节拉回 100ms   → 48000Hz×2B = 96000B/s，304 毫秒
```

两个 App 同时哑，是因为这段逻辑在 `SLCamFeed audioForFormat:` 里 —— 陌陌走 AVCapture、
QQ 走 AudioUnit，**共用同一段代码**。

### 二、这一版怎么改

**把生产端的高水位压到目标附近，让「丢弃」退回成兜底。**

| 项 | 0.2.8 | 0.2.9 |
|---|---|---|
| 生产端高水位 | 0.35s | **0.14s**（目标 + 2 个包） |
| 丢弃触发 | 超过 0.12s 就砍到 0.10s | 超过 **0.18s** 才动手，每次**最多丢一包**（2× 速度追平） |
| 硬切 | 无 | 超过 **0.6s** 才硬切回目标（切素材、重建管线这类中途卡顿） |

原来那个「恒定 2 秒延迟」，靠**压低高水位**这一条就够了 —— 根本不需要靠丢弃去救。
正常运行时丢弃逻辑一次都不该触发。

新增一行水位心跳，下次有问题不用再靠推算：

```
音频: 水位 118ms · 丢 0 字节 · 第 3000 包
```

### 三、抖音录像卡死

抖音的录音走 `AudioQueueNewInput`，0.2.8 开始接管。但接管时同步做了一件重活：

```c
OSStatus st = gSLAQOrig(fmt, SLCamAudioQueueInputCallback, ctx, ...);
[[SLCamFeed shared] primeAudioFormat:fmt];   // ← 在宿主线程上建 AVAudioConverter
```

抖音是在**打开录像页的主线程**上调这个函数的，`AVAudioConverter` 初始化是几十毫秒的活，
赶上解码线程正在重建 reader，就是肉眼可见的卡住。

改法是三条：

1. **`primeAudioFormat:` 挪到后台队列** —— 不在宿主线程上建任何东西。
2. **音频回调只走 `tryAudioForFormat:`** —— 抢不到锁立刻放行这一包真麦克风，
   绝不阻塞宿主。宁可漏一包，也不能把音频线程（可能就是主线程的 runloop）卡住。
3. **回调里不再建转换器** —— 格式没登记好就直接放行，交给后台的 `primeAudioFormat:`。

另外新增一行诊断，能直接确认回调有没有活过来：

```
音频: AudioQueue 回调首次触发 2048B
```

### 四、顺手修一个「画面停在最后一帧」

解码循环原来只按 `gotAny` 判断这一轮结束。音轨比视频轨长一点点时（很常见），
视频读完了但音频还在出数据，`gotAny` 一直是 YES → 永远不会重建 reader →
**画面永远停在最后一帧**，从外面看就是卡死，而且随素材概率出现。

现在视频读完就算这一轮结束，哪怕音轨还有剩。

### 装上之后验证

1. QQ / 陌陌通话，**对方能听到素材音**（0.2.8 是完全没声）
2. 唇音基本对得上（延迟约 100ms）
3. 抖音进录像页**不卡**，录出来的声音是素材音
4. 日志里**不该再出现**「缓冲…偏高，丢弃…」，正常应该只有 `水位 xxx ms · 丢 0 字节`

## 装法

自签注入：把 `ShenglinVcam-v<版本>.dylib` 注入目标 App 的 IPA 后重签安装。
越狱环境直接装 `ShenglinVcam-v<版本>.deb`。

> 本包与底包（声临）**包名和 dylib 名完全一致**，装这个会把底包覆盖掉。
> 两个都要用的话别同时装。
