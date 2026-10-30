## 0.2.15 —— 坐标系收口 / 扇几何重做 / 拍照接管 / 音频布点

0.2.14 上机后的一批问题。这一版有两条是**功能新增**（拍照替换、录制链路探测），
其余是几何与交互修正。

### 一、所有尺寸改从屏幕取，不再信宿主视图

根因一句话：`SLKeyWindow()` 挑的是 **windowLevel 最高**的窗口，而 iOS 里最高的
往往不是主窗口 —— `QQRTCWindow`（通话浮层）、`UITextEffectsWindow`（键盘）、
Alert 窗、状态栏窗都排在主窗口前面。这些窗口的 `bounds` 只是屏幕的一块。

于是同一个 `self.bounds` 在不同 App 里量出不同结果：

| 用到的地方 | 症状 |
|---|---|
| `SLFan` 的 `_hostSize` | 扇半径被夹到 74，五个球挤成一团 |
| `SLClampFloatPos` 的 `size` | 球被夹在浮层里，拖不到屏幕边 |
| `self.view.bounds`（面板） | 设置菜单在每个 App 里大小不同 |

新增 `SLScreenRect()` / `SLScreenSize()`（`SLUtil.m`），取所有活跃 `UIWindowScene`
里最大的 `coordinateSpace.bounds`，origin 归零。面板尺寸、扇几何、球夹取全部走它。

扇仍然铺在父视图上（子视图画不到父视图外面），所以 `SLHostSizeFor(sv)` 取
「屏幕」和「sv」里小的那个：正常 App 退化成屏幕，浮层窗口时至少不会画出界。

### 二、扇贴角落时不再被压扁

0.2.13/0.2.14 是「越界就缩半径，缩到下限 74 就停，剩下的逐球夹取」。
球贴角落时，一侧两三个球会被推到**同一条竖线上** —— 弧被压成一条直线，
看起来就是「展开后错位」。收扇角也不行：相邻夹角 `2*half/4`，收 `half`
会让弦长一起变小，五个球直接叠在一起。

改成**扇心内推**：球心不动，把扇心沿垂直于张开方向的那一维推进安全区，
最多推到「整扇刚好贴住安全区边缘」。弧线形状完全不变，只是整体平移。
只有屏幕比整扇还窄时才按比例缩半径，下限仍是 74，最后留一道逐球兜底。

扇心被推走后主球跟着滑过去（0.18s），收起时滑回原处 —— 否则屏幕上就是
「球在一处、扇在另一处」。

### 三、配色与图标

- `sl_accent`：`systemIndigoColor`（偏紫）→ `systemBlueColor`。选中 pill、弧、
  光晕、角度图标都跟着这个走，改一处全变。
- 镜像图标：`arrow.left.and.right` → `flip.horizontal`（iOS 15+，退回原图标）。
  前者就是两根箭头，没有「翻转」语义，摆在旋转球旁边更像「左右移动」。

### 四、素材可以取消勾选了

`SLMediaStore setCurrentItem:` 本来就支持传 `nil` 清空（内部走 `removeObjectForKey`），
只是 `didSelectRow` 从来没给过 `nil` —— 点已勾选的行只会再选一次，永远取消不掉。
现在点已选中的行 = 取消替换，并弹一句「已取消替换 · 恢复真实摄像头」。

### 五、球的位置跨 App 共享

`[NSUserDefaults standardUserDefaults]` 在 tweak 注入后解析成**该进程自己的
bundle id**，落到各自沙盒的 `Library/Preferences/<bundleid>.plist` ——
抖音存一份、QQ 存一份，互不可见。这就是「每个 App 里球位置都不一样」。

改用 `CFPreferencesSetAppValue` 写全局域 `com.taylorchen.shenglinvcam`。
**不能自己用 `NSFileManager` 拼 `/var/mobile/Library/Preferences/xxx.plist`**：
tweak 继承的是 App 沙盒，直接写那个路径会被拒。CFPreferences 走的是 `cfprefsd`
的 XPC，落盘由 cfprefsd 以用户身份完成，不在 App 沙盒内 —— 顺带也不用判断
rootless 越狱下 `/var/jb` 的前缀。

首次读不到全局域时回落到本 App 的旧值并迁移过去，老用户升级不会跳位。

### 六、开关提交后有 toast 了

松开手指那一刻扇已经收了，屏幕上什么反馈都没有。现在每个开关都给一句：
「替换已开启 · 摄像头画面换成素材」「素材声音：关 · 对方听到你的真麦克风」
「画面方向：顺时针 90°」……

### 七、拍照接管（新功能）

`-[AVCaptureStillImageOutput captureStillImageAsynchronouslyFromConnection:completionHandler:]`
是「对象 + block」两个参数，被注入层「单指针参数」的启发式规则直接跳过 ——
所以拍照出来永远是真实画面。QQ 的日志里明确有
`会话加输出: AVCaptureStillImageOutput`，就是它。

接法：把 `completionHandler` 包一层，收到真 buffer 后不往下传，改传我们自己
构造的假 JPEG —— 素材当前帧转 JPEG，再按 JPEG 宽高建
`CMVideoFormatDescriptionCreate(kCMVideoCodecType_JPEG)` + `CMBlockBuffer` 拼成
`CMSampleBufferCreateReady`。素材那一帧没解出来时退回真画面，不给黑图。

### 八、录制音频布点（只为定位，不接管）

0.2.14 的日志显示：QQ 拍摄页期间 `AudioUnitRender bus=1` 为 0 次、
`AVCaptureAudioDataOutput` 没被加进会话、`AudioQueueNewInput` 没触发、
连新加的「放行真麦克风」都没打 —— 说明 `audioForFormat:` 根本没被调用，
声音是从 capture session 外面进来的。

新增三个探测点，命中即打一行日志：

| 探测点 | 命中说明 |
|---|---|
| `-[AVAudioInputNode installTapOnBus:bufferSize:format:block:]` | 走 AVAudioEngine，可以直接接管 |
| `-[AVAudioRecorder record]` | 走写文件路径，需要另一套接管 |
| `-[AVCaptureMovieFileOutput startRecordingToOutputFileURL:recordingDelegate:]` | 画面会绕过 VideoDataOutput |

这一版**只打日志不接管**：tap 能直接改 PCM buffer，Recorder 是往文件里写，
两套接管方式完全不同，没确认走哪条就写大概率白做。

---

## 0.2.14 —— 扇的图标 / 动画 / 命中 / 视觉，加音频诊断（本地改动，尚未构建发布）

0.2.13 上机之后暴露的一批问题，逐条修。**音频替换的内容一行没改**，只加了日志。

### 一、图标换 SF Symbols，手绘整套删掉

0.2.13 的五个图标是手绘的，上机发现两个是错的：

| 球 | 实际渲染 | 应该是 |
|---|---|---|
| 启用 | `Ɑ` 竖线 + 开口朝右的弧 | 缺口朝上的环 + 竖线 |
| 静音 | 喇叭 + × | ✅ |
| 旋转 | `↻` 钩子 | 缺口圆环 + 箭头 |
| 镜像 | 实心菱形 + 竖虚线 | 两个三角 + 虚线轴 |
| 循环 | `⇄` | ✅ 勉强能认 |

根因在 `CGContextAddArc(c, 10, 10.6, 6.2, M_PI*0.42, -M_PI*0.42, 1)`：
`UIGraphicsImageRenderer` 的 CTM 是 **y 向下**的，`clockwise=1` 在这个坐标系里
视觉上是**逆时针**，而角度从 `+0.42π` 递减到 `-0.42π` 正好经过 `0°`（正右方）——
**缺口落在了左边，不是顶部**，整个图标转了 90°。启用和旋转共用这段代码，一起错。
镜像那条则是两个三角形竖直边只差 3.6pt，20pt 画布上糊成一个菱形。

改用系统符号：`power` / `speaker.slash.fill` / `rotate.right` /
`arrow.left.and.right` / `repeat`，配 `pointSize:17 weight:semibold`，
`AlwaysTemplate` 走 `tintColor`。形状、粗细、光学对齐都是 Apple 调过的。

### 二、弧上的点走的是「弦」，不是弧

逐帧量过：环半径 25pt，点实际落在约 19pt —— 点在环内侧抄近路。

`_arcLive.strokeEnd` 和 `_arcTip.position` 都是独立 `CAShapeLayer` 的属性，
**默认带 0.25s 隐式动画**。拖拽时每帧改目标值：`strokeEnd` 沿路径插值（对的），
`position` 却是**两点之间直线插值** —— 走的是弦。快速来回滑时点明显离开圆环。

修法：跟手期间 `[CATransaction setDisableActions:YES]`，让弧和点同一帧更新，
点的位置每帧按 `(c + R·sin θ, c − R·cos θ)` 解析算出，严格落在圆上。

### 三、二级菜单：命中改并集，视觉重做

**「一滑就没」** 的根因是命中区没有过渡带：旋转球的命中半径是 `19+8 = 27pt`，
而角度列的左边缘正好也在离球心 27pt 处 —— 两者只在一个点相接。
手指从球往列滑，抖一下 `hit` 就变 `-1`，`if (hit != 旋转) 收列` 立刻执行。

改成「安全带」并集：球（外扩 14）∪ 列（外扩 10）∪ 球到列的走廊。
只要手指还在这块区域里就保持展开，只有回到弧上或走远才收。

另外两处：命中判定从 `_col.frame` 改成 `center` 推矩形 —— 列展开动画里带着
`(-10, 0)` 平移，那 0.24 秒里 `frame` 是偏的，命中区和看到的对不上；
4 个 pill 的命中框纵向外扩 8pt，掉在间隙里也能吸附最近一档。

**「看不清」**：pill 背景原来是 `colorWithWhite:0.5 alpha:0.16`，在白色聊天页上
就是一层灰雾，文字又是 `secondaryLabelColor`。改成毛玻璃材质
（`SystemThinMaterial`）+ 0.5pt 白色 hairline + `labelColor` 13.5pt；
选中项 accent 填充 0.22 + accent 加粗文字；整列加柔光阴影；
pill 高度 30 → 34、间隙 6 → 8，更好按。

顺带补了边界夹取 —— 原来 `sl_buildColumn` 完全没判断，贴顶 / 贴底时整列会出屏。

### 四、小球视觉对齐主球

两套东西放在一起很明显：

| | 主球 | 0.2.13 的小球 |
|---|---|---|
| 描边 | 0.8pt 白色 hairline | 1.6pt 状态色细环 |
| 阴影 | `black 0.18 / r9 / (0,3)` | 没有 |
| 尺寸 | 48pt | 38pt |

现在小球补上同参数的 hairline 和阴影（必须给 `shadowPath`，这一层没有背景色，
光靠 `shadowColor` 画不出影子），尺寸 38 → 44。

选中态原来是 `transform` 放大 1.14，看起来像「这个球尺寸跟别的不一样」——
改成向外扩一圈同色光晕，用 `opacity` 动画。

球径变大后几何也调了：半径下限 74（按「相邻弦长 ≥ 44」算出来的），
**不再收扇角** —— 收 half 会让弦长一起变小，五个球直接叠在一起；
角上剩下的越界改成逐个夹回安全区。

### 五、音频诊断（只加日志，不改行为）

QQ 报「自己用摄像机录制时素材音乐没被替换」，但日志停在拍摄页刚打开那一刻，
录制那段一行都没有。三条路径各有指纹，全部可以对照：

- AudioUnit → `unit 就绪 bus=1 …` + `已接管 AudioUnit 麦克风输入`
- AVCapture → `首帧 音频 …`
- AudioQueue → `已接管 AudioQueue 录音（…）`

为了下次一眼定位，加了三处：

1. **`SLTryASBD` 不再一票否决。** 原来 `hasASBD` 一旦为 YES 就再也不重读格式。
   宿主会复用同一个 AudioUnit 换场景（通话 16kHz/1ch → 录制 44.1kHz/2ch），
   格式变了我们还在按旧格式要 PCM，而 `pcm.length == mDataByteSize` 依然成立，
   `memcpy` 照做、不报错、不打日志。现在每 500 次调用（约 5 秒）比对一次，
   变了就更新并打一行 `音频: unit 格式变化 16000Hz 1ch 4B/帧 → 44100Hz 2ch 8B/帧`。
2. **「放行真麦克风」不再静默。** 以前 `sl_audioLocked` 拿不到数据就 `return nil`，
   而 `nil` 在三条链路里都等于「用真麦克风」，日志上完全看不见。现在两个出口
   各打一次：`放行真麦克风 —— 目标格式还没配置` / `放行真麦克风 —— 素材没有音轨`。
3. **`已接管` 改成按 unit 打。** 原来是全局一次性标志，第二个 unit（通话结束、
   拍摄页新建的那个）接管时日志上是空的，看起来像没接管。

ASBD 比较用逐字段比对而不是 `memcmp` —— 结构里有 `mReserved` 这种保留字段，
万一系统没清零会一直判「变了」，转换器被反复重建，声音一顿一顿。

---

## 0.2.13 —— 悬浮球交互重做：五球半圆扇（本地改动，尚未构建发布）

纯 UI / 交互改版，采集与注入链路一行没动。

### 一、胶囊形态整体移除

原来单击球会横向展开一条胶囊，上面挂着「素材 / 设置 / 收起」几个按钮。实际用起来
这条胶囊的处境很尴尬：它占屏、会盖住 App 自己的 UI，而它承载的功能其实都能挪走。
这一版把它整套删掉（`_nameClip` / `_haze` / `_name` / `_menuBtn` / `_midBtn` /
`_chev` / `_homeBtn` / `_homeHit` 全部下线），球的形态回到一个纯粹的圆。

功能重新分配：

| 操作 | 行为 |
|---|---|
| 单击 | 打开素材库 |
| 长按 0.45s | 展开五球半圆扇 |
| 拖动 | 换位置（照旧） |

设置面板的入口挪到**素材库左上角的齿轮**。放左边是因为右上角「完成 / ＋」两个位置
都占满了，而「完成」必须留在最右。

### 二、五球半圆扇

球永远贴在屏幕边缘，所以扇口一定朝屏幕内侧。五个开关按弧长均分，跨度 144°（±72°），
半径 88pt，球径 38pt，顺序：

```
启用 ── 静音 ── 旋转 ── 镜像 ── 循环
```

**旋转放正中**，正好落在主球正前方，手指从球心滑过去是纯直线，不用拐弯。

球体风格跟主球统一：深色底 + 2pt 描边，开 = 紫描边 + 亮图标，关 = 灰描边 + 暗图标。
球内不放文字，五个 20×20 的线性图标（缺口圆环 / 喇叭+叉 / 圆环+箭头 / 左右三角+虚线轴 /
上下反向箭头），全部 1.8pt 线宽、圆头圆角，颜色走 `tintColor`。

### 三、跟手扫动，不用点两下

长按展开后**手指不抬起**，直接滑到目标球上松手即生效：

- `UILongPressGestureRecognizer` 一个手势跑完 `Began → Changed → Ended`，
  不需要再加 pan；
- 扇展开期间必须 `_pan.enabled = NO`，否则手指在扇上滑动会同时把球拖走；
- 滑到旋转球停 0.16s 才展开角度列 —— 手指快速掠过时不误开；
- 松手位置不在任何球上 = 回退，什么都不改。

### 四、旋转的四档用连续弧，不用四等分

旋转是四态（0° / 90° / 180° / 270°），不是开关。滑到旋转球后展开一列四档，
每档带一段迷你环。

环用**连续弧**画：`strokeEnd = 角度 / 360`，缺口永远是一整块，端点加一颗亮圆点当指针。

早先试过四等分（270° 亮三段、留一段暗），问题是**270° 时环上会有一个角永远不亮**，
孤立暗段夹在中间，看着像坏了一格。连续弧没有这个问题。

角度列跟手实时扫动：手指纵向位移映射到 0 → 0.75 圈，松手弹簧吸附到最近的档位。
不用 `transform.rotation` 做动画 —— 起点会跑，0° 缺口位置会错乱。

### 五、几何自适应

球贴到角落时，扇很容易出屏。这里做了两级收缩，最多跑 30 轮：

1. 先缩半径：88 → 62，步长 5；
2. 半径缩到头再收扇角：72° → 26°，步长 6。

每一轮都算一遍五个球的外接矩形，全部落在安全区内才停。四个方向（左 / 右 / 上 / 下）
各有一套方向角，`flip` 标志保证下标 0 的「启用」始终落在上侧或右侧，视觉顺序一致。

### 六、其它

- `SLFan.h` / `SLFan.m` 独立成文件，不再往 1900 行的 `SLFloatingBall.m` 里堆；
- `Makefile` 的 `ShenglinVcam_FILES` 加了 `Tweak/SLFan.m`（漏加会链接失败）；
- 素材库和设置页住的是同一个浮窗容器，不能「浮窗里再叠浮窗」——推设置页前
  先 dismiss 素材页；`dismiss` 带 0.3s 动画，`host.presentedViewController` 在动画
  跑完前一直为真，所以不用固定 delay，改成每 0.1s 轮询一次（最多 1.5s）；

---

## 0.2.12 —— 缓存自建 fmt（本地改动，尚未构建发布）

纯性能优化，不改行为。

0.2.11 真机日志暴露了一件事：`CMVideoFormatDescriptionMatchesImageBuffer(宿主 fmt, 假帧)`
**每帧都为假** —— 宿主 fmt 带着自己的 `CVBytesPerRow`，和我们的帧天生对不上。所以每帧都
会走进自建分支，而自建分支里要建两个 fmt（一个带宿主扩展的试一次、一个帧反推的兜底），
30fps 下每秒 120 次分配，全在采集队列上。

这一版按 `(子类型, 宽, 高, 帧的色彩矩阵哈希)` 缓存自建 fmt，格式不变就一直复用。
4 个槽位轮换，覆盖「前后摄 / 不同分辨率 / 换素材后色彩标注变了」这几种情况。

顺带 `带宿主扩展建 fmt 不自洽` 那行日志从「每帧一次」降到「每种格式一次」。

---

## 0.2.11 —— 修 0.2.10 的视频替换失效

0.2.10 修闪退，结果把画面换坏了：**装上之后视频完全不被替换，画面就是真实摄像头**。
QQ、陌陌、抖音三家一起中招。

### 一、现场

```
注入: 打包失败 #1 st=-12743 · fmt 1920x1080 420f · 帧 1920x1080 420f · 自洽=Y · 兜底fmt=Y
```

`-12743` = `kCMSampleBufferError_InvalidMediaFormat`。每一帧都失败 → 假帧是 NULL →
走「放行真帧」分支 → 画面当然还是摄像头。

三种尺寸、两种像素格式全都挂在同一个码上：

| App | 真帧 | 结果 |
|---|---|---|
| QQ | 1920×1080 `420f` | -12743 |
| 陌陌 | 1080×1920 `BGRA` | -12743 |
| 抖音 | 1080×1920 `420f` | -12743 |

跟格式无关，只跟 fmt 里的某一项有关。

### 二、根因

0.2.10 把宿主 fmt 的 5 个 extensions **整包**塞进了 `CMVideoFormatDescriptionCreate`：

```
CVImageBufferYCbCrMatrix, CVImageBufferTransferFunction, Version, CVBytesPerRow, CVImageBufferColorPrimaries
```

问题出在 **`CVBytesPerRow`**。它描述的是缓冲区**怎么摆放**，必须由帧自己决定。
宿主的 BPR 是它自己采集 buffer 的（IOSurface 按 32/64 字节对齐），我们的假帧是
`CVPixelBufferCreate` 造的（CoreVideo 取最小对齐），两者不一样 → 校验不过。

判断依据很硬：真帧那行是 `自洽=Y`，说明宿主 fmt 和宿主自己的 buffer 是配的；而假帧
尺寸、子类型和宿主 fmt 完全相同却仍被判「不匹配」—— 唯一可能不同的就是 bytesPerRow。
这也说明 `CMVideoFormatDescriptionMatchesImageBuffer` **确实在比 BPR**。

0.2.9 从没出过这个错，因为它是用 `CreateForImageBuffer` 从帧反推的，BPR 天生自洽。

### 三、这一版怎么改

1. **只搬色彩类扩展，剔除布局类** —— 去掉 `CVBytesPerRow` / `CVFieldCount`。
2. **建完立刻自检** —— `CMVideoFormatDescriptionMatchesImageBuffer` 不过就丢掉，
   退回 `CreateForImageBuffer`。有了这道自检，任何扩展组合导致的 -12743 都不可能漏出去。
3. **打包失败前再兜一层** —— 自建 fmt 万一仍被拒，换成帧反推 fmt 重试一次。
   宁可丢扩展，也不能整帧放弃：打包失败是最坏的降级。
4. **日志补自建 fmt 的扩展 key 列表** —— 万一抖音那边还崩，能直接看出它取不取得到内参。

### 四、一个必须说清楚的遗留

0.2.10 的抖音日志里**没崩**，但那不代表闪退修好了 —— 是因为每帧打包都失败，
假帧根本没交出去。0.2.9 是打包成功 → 假帧被交付 → AwemeCore 代理 `CFRelease(NULL)` 崩。

所以 0.2.11 装上后请重点看抖音：**如果点开录制又闪退，那就是 CFRelease 那一条还没修好**，
日志里的 `自建扩展 N 项` 会告诉我们 fmt 里到底有什么。

### 装上之后验证

1. QQ / 陌陌 / 抖音，**画面是素材**（这是本版重点）
2. 抖音点开录制**不闪退**
3. 日志里不该再有「打包失败」
4. 声音速度正常，没有「丢弃」行

---

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
