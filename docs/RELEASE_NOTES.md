## 0.2.7 —— 打开那道挡住麦克风的门

### 0.2.6 的日志把问题钉死了

一次 QQ 视频通话，数据非常干净：

```
符号: 命中 AudioUnitRender ← QQ
符号: 扫过 6 个 App 镜像，命中 1 处，认证 GOT 跳过 0 处    ← 不是 arm64e 认证槽
音频: AudioUnitRender 首次被调用 bus=0 frames=1014          ← hook 确实被调用
音频: 心跳 调用 3000 次 / bus=1 2436 次                     ← 麦克风方向大量经过我们
音频: 跳过 —— 这个 unit 的输入元素没开，不是麦克风采集        ← 唯一拒绝点
feed 素材音轨: 有（1793274336.mp4）                          ← 素材也有音轨
```

之前怀疑的三个方向 —— dlsym 绕过、认证 GOT、调用点够不着 —— **全部排除**。
3000 次调用里 2436 次是 bus=1（麦克风方向），数据明明流经我们的 hook，
只是被一道判断全部放行了。

### 那道门错在哪

原来的 `SLCacheFor` 把 `EnableIO` 当硬门：

```c
if (AudioUnitGetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                         kAudioUnitScope_Input, 1, &enabled, &sz) == noErr && enabled) {
    c->isInput = YES;          // 查询失败 和 enabled=0 被合并成同一个否定结果
}
if (c->isInput && AudioUnitGetProperty(... StreamFormat, Output, bus ...)) {
    c->hasASBD = YES;          // 被 isInput 短路，连试都没试过
}
sUnitCacheCount++;             // 否定结果永久缓存，再也不重查
```

三个缺陷叠在一起：

1. **「查询失败」和「输入没开」被当成一回事**。返回错误码和返回 `enabled=0` 在我们眼里一样。
2. **否定结果被永久缓存**。第一次 bus=1 调用发生在麦克风 unit 刚启动的时刻，
   属性查不到很正常 —— 但一旦失败就被钉死，后面 2436 次调用全都直接放行。
3. **ASBD 查询被短路**。因为 `isInput` 是 NO，连「这个 bus 的格式是什么」都没问过，
   所以 `hasASBD` 永远是 NO，`拿不到 ASBD` 那行也就永远打不出来。

### 这一版怎么改

**把 `EnableIO` 从硬门降级为参考信息。**

判断「这是不是麦克风方向」其实只需要两个条件：

- `bus == 1` —— RemoteIO / VoiceProcessingIO 的输入元素固定是 1，bus 0 是播放（已排除）
- `Output scope, bus 1` 能拿到有效的 PCM 格式 —— 拿得到就说明这条 bus 确实在往外送音频数据

`EnableIO` 只是「App 有没有显式打开输入」的旁证，不该一票否决。

| 改动 | 说明 |
|---|---|
| `isInput` 不再参与判断 | 只把 `EnableIO` 的返回码和值写进日志 |
| ASBD 无条件查询 | 不再被 `isInput` 短路 |
| ASBD 失败不钉死 | 前 200 次密集重试（约 2 秒），之后每 3000 次补一次 |
| ASBD 字段自洽校验 | `sampleRate` / `channels` / `bytesPerFrame` 必须非零，全零当失败 |
| 新增 unit 就绪日志 | 一次看清 `EnableIO` 和 `ASBD` 两个查询的真实返回值 |

保留的护栏一个没动：`bus != 1` 一律不碰（播放安全）、替换开关、`AVCaptureAudioSeen` 让路、
必须是线性 PCM 且 `mBytesPerFrame > 0`。

### 装上之后看这几行

```
音频: unit 就绪 bus=1 EnableIO st=0 val=1 · ASBD st=0 fmt=1819304813 16000Hz 1ch 4B/帧 交错=Y
音频: 已接管 AudioUnit 麦克风输入
```

第一行说明这条 bus 的格式拿到了；第二行说明素材 PCM 真的写进去了。

如果仍然没有第二行，把第一行发我 —— `EnableIO` 的 st/val 和 `ASBD` 的 st/fmt
会直接告诉我们卡在哪一步，不用再猜。

## 装法

自签注入：把 `ShenglinVcam-v<版本>.dylib` 注入目标 App 的 IPA 后重签安装。
越狱环境直接装 `ShenglinVcam-v<版本>.deb`。

> 本包与底包（声临）**包名和 dylib 名完全一致**，装这个会把底包覆盖掉。
> 两个都要用的话别同时装。
