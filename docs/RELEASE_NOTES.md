## 0.2.4 —— 补上「不经过 AVCapture 的麦克风」

### 两份日志对比出来的结论

| | 陌陌 | QQ |
|---|---|---|
| 音频输出 | `AVCaptureAudioDataOutput` | **没有** |
| 会话里的输出 | Video + Audio | Video + StillImage + Metadata |
| 音频是否被拦 | ✅ `_handleSampleBufferEventForSampleBuffer:` | ❌ 从来没有音频流过 |
| 结果 | 能换、能静音 | 只能录入原声 |

也就是说：**音频能不能换，取决于 App 用不用 `AVCaptureAudioDataOutput`。**
陌陌用，所以 0.2.3 一挂就通；QQ 的语音走自己的音频栈（RTC SDK 那套），
`AVCapture` 这条链路对它完全无效。

### 这一版新增：AudioUnit 链路

自签环境没有 CydiaSubstrate，`MSHookFunction` 用不了，所以自己实现了一个
fishhook 精简版（`SLCamSymbolHook`）：遍历已加载镜像的
`__la_symbol_ptr` / `__got`，按符号名把指针换成我们的实现。

挂的是 `AudioUnitRender` —— 所有用 RemoteIO / VoiceProcessingIO 采麦克风的 App
都要经过它：

- **只处理输入元素（bus 1）**，而且该单元必须确实开了麦克风输入。
  bus 0 是播放方向，碰一下就会把对方的声音也改掉。
- **让路机制**：一旦发现宿主音频已经在走 AVCapture（`SLCamAVCaptureAudioSeen`），
  AudioUnit 链路立刻退出。两条链路同时消费同一个 PCM 池，声音会被撕成两半。
- 按 `(unit, bus)` 缓存格式与「是否输入」的判断，不在 10ms 的采集回调里反复查属性。
- 先让宿主把数据拿到手，再就地覆盖内容 —— 时间戳、错误码、静音标志一概不动。

顺带挂了 `AudioQueueNewInput` 的探针（**只记日志不接管**）。AudioQueue 是另一套
回调机制，AudioUnitRender 覆盖不到；万一哪个 App 用它，日志里能直接看出来，
不用再猜。

### 装了之后看这几行

```
音频: AudioUnitRender 已接管（N 处符号槽）      ← 链路装上了
音频: AudioUnit 输入 48000Hz 1ch 4B/帧 ...      ← 宿主的麦克风格式
音频: 已接管 AudioUnit 麦克风输入                ← 真的替换进去了
音频: 宿主使用 AudioQueue 录音（...）            ← 如果出现这行，说明还得再补一条链路
```

陌陌那边应该仍然只看到 AVCapture 那条（AudioUnit 会静默让路），属正常。

## 装法

自签注入：把 `ShenglinVcam-v<版本>.dylib` 注入目标 App 的 IPA 后重签安装。
越狱环境直接装 `ShenglinVcam-v<版本>.deb`。

> 本包与底包（声临）**包名和 dylib 名完全一致**，装这个会把底包覆盖掉。
> 两个都要用的话别同时装。
