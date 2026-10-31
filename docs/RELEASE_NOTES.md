## 0.3.4 —— 竖视频不再被压成邮票；点画面进全屏

### 一、扇上改旋转，设置页「画面旋转」不跟着动

上一版加的通知是对的，问题出在**接收端只认带开关的行**：

```objc
// 0.3.3 的写法
for (UITableViewCell *cell in self.tableView.visibleCells) {
    if (![cell.accessoryView isKindOfClass:[UISwitch class]]) continue;   // ← 非开关行整段跳过
    ...
}
```

「画面旋转」「悬浮球图标」「钩子状态」这几行**没有 `UISwitch`**，右侧摘要走的是
`detailTextLabel`，于是一进循环就被 `continue` 掉了。旋转明明写进了同一个
`NSUserDefaults` 键，界面却停在旧值 —— 看起来就是「不跟着动」。

改成按 `indexPath` 逐行分派：开关行只改 `on`（不动 cell 结构，免得打断用户
正在拨的那颗开关的动画），其余行各自回填右侧文字。

```objc
if (ip.section == 0 && ip.row == 1) {
    cell.detailTextLabel.text = SLVFloatIconSummary();
} else if (ip.section == 1 && ip.row == 0) {
    // 走的是自绘跑马灯，不是 detailTextLabel
    if ([cell isKindOfClass:[SLVScrollValueCell class]]) {
        ((SLVScrollValueCell *)cell).valueView.text = SLVCamStatusSummary();
    }
} else if (ip.section == 2 && ip.row == 2) {
    cell.detailTextLabel.text = SLVRotationSummary();
}
```

### 二、竖视频预览看不清

预览台原来固定 156 高，画面按 `ResizeAspect` 等比缩进去。同样的框，占位面积差 3 倍：

| 素材 | 框 | 实际画面 | 面积 |
|---|---|---|---|
| 竖 9:16 | 358 × 156 | 88 × 156 | 13,689 |
| 横 16:9 | 358 × 156 | 277 × 156 | 43,264 |
| 方形 1:1 | 358 × 156 | 156 × 156 | 24,336 |

竖拍素材两边各留 135pt 黑边，等于在看一张邮票。
（预览页 0.2.25 修过同一个坑，搬预览台的时候漏掉了。）

现在高度按素材宽高比算，clamp 在 156…280：

```objc
static CGFloat SLVStageHeightFor(CGFloat boxW, CGFloat aspect) {
    CGFloat h = kSLStageMaxH;
    if (aspect > 0.01 && boxW > 0.0) h = boxW / aspect;
    if (h < kSLStageMinH) h = kSLStageMinH;   // 156：横视频 / 超宽素材
    if (h > kSLStageMaxH) h = kSLStageMaxH;   // 280：再高就把列表挤没了
    return kSLStageTop + h + kSLStageGap + kSLStageBarH;
}
```

改完的实测：

| 素材 | 舞台 | 画面 | 面积变化 |
|---|---|---|---|
| 竖 9:16 | 358 × 280 | 158 × 280 | 3.2× |
| 横 16:9 | 358 × 201 | 358 × 201 | 1.3× |
| 方形 1:1 | 358 × 280 | 280 × 280 | 3.2× |

**宽高比必须过 `preferredTransform`**：直接读 `naturalSize` 拿到的是传感器坐标，
竖拍是 1920×1080（看着像横的），只有过一遍 transform 才是眼睛看到的 1080×1920。

```objc
CGSize d = CGSizeApplyAffineTransform(vt.naturalSize, vt.preferredTransform);
d.width = fabs(d.width); d.height = fabs(d.height);
return d.width / d.height;
```

副作用：表头高度**随素材变化**（切横视频 201、切竖视频 280，跳 79pt）。
换高度时给 `tableHeaderView` 包了一层 0.2s 动画，让它滑过去而不是「啪」一下。

### 三、点画面进全屏

只调高度的话，竖视频最多也就 158 宽，细节还是看不清；
只加全屏的话，列表里连「这是横的还是竖的」都看不出来。两个一起才完整。

舞台挂了个 `UITapGestureRecognizer`，点画面 push 独立预览页（就是原来设置页那个）。
按钮要能先拿到 touch，所以 `shouldReceiveTouch:` 里碰到 `UIControl` 一律不接：

```objc
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    UIView *v = t.view;
    while (v && v != _box) {
        if ([v isKindOfClass:[UIControl class]]) return NO;   // 播放 / 喇叭
        v = v.superview;
    }
    return YES;
}
```

那边读的也是 `[SLVMediaStore currentItem]`，跟舞台放的是同一个素材，不会对不上。

---

## 0.3.3 —— 预览搬进素材页；设置页开关不再掉队

### 一、设置页开关不同步

现象：设置页开着的时候，长按悬浮球用扇上的开关改「替换」，
设置页那颗「启用虚拟摄像头」还停在旧状态，退出去再进来才对。

不是存了两份 —— 两边读写的都是同一个 `NSUserDefaults`。问题是**界面不会刷新**：

- 开关的值只在 `cellForRowAtIndexPath` 创建 cell 时读一次；
- 全项目只有 `viewWillAppear` 和「选完旋转」两处会 `reloadData`；
- 扇上的开关走 `SLVFanCommit`，写完偏好直接 `SLVCamReloadAll()` 就返回，
  **没有任何东西通知设置页**。

改法：`SLVCamReloadAll()` 里统一 post 一个 `SLVCamConfigChangedNotification`，
所有改配置的入口（设置页开关 / 扇 / 素材切换 / 旋转）都会走到它。
设置页收到后**只把可见 cell 里开关的 `on` 同步过来，不调 `reloadData`** ——
`reloadData` 会重建 cell，把用户正在拨的那颗开关的动画打断。

顺带填了个坑：「启用」那颗开关原来**没设 tag**，默认就是 0，跟「循环播放」撞了。
现在统一成 `10 启用 / 11 循环 / 12 镜像 / 13 音频`。

### 二、预览搬进素材页

原来要看另一段素材：退出设置页 → 换选中 → 再进预览页，比较两段要来回四趟，
而且预览页只能看**当前选中**的那一个。

现在素材页顶部有一块预览台，**点哪行就放哪行**：

- 播放器全局只有一个，切素材只换 `AVPlayerItem`。每个素材建一个 `AVPlayer`
  的话，来回点几下就是十几个解码器，内存和 IO 都扛不住。
- 挂成 `tableHeaderView` 而不是固定压在列表上方：`UITableViewController` 的
  tableView 铺满整个 view，要固定就得改 `contentInset`、滚动指示器位置和
  `contentOffset`，一处算错整页错位。header 跟着列表滚，列表短时看不出区别，
  长了正好把空间让出来。
- **默认静音**，点右上角喇叭才出声。静音播放完全不碰 `AVAudioSession` ——
  宿主的会话类别不是我们说了算（抖音/QQ 常用 Ambient），动了就会互相抢声音。
- 音轨结论复用 `SLVProbeMediaAudio`，跟独立预览页共用缓存，两边结论不会打架。

点击语义跟着变了：**点行 = 切过去 + 播放**，「取消替换」挪到左滑菜单。
同一个点击既要「换片」又要「取消」，两者会打架 —— 点了想预览，结果把替换取消了。

设置页的「预览素材」那一行撤了，只留「当前素材」。留着的话点进去还是那个
只能看当前素材的旧页面，两个入口两套行为。悬浮球长按 → 预览的入口保持不变。

---

## 0.3.2 —— 图标缩进黑圆内；当前素材不再压箭头

### 一、标题栏图标：白框戳出圆外

上一版把黑底圆找回来了，但圆里的图形还是按 **100 单位的正方形画布**铺的
（y 从 4 到 96，几乎顶满）。底色是**圆**，不是方块 —— 在 y=4 那个高度，
圆的宽度只有 39 单位，而框有 56 单位宽。**框比圆还宽，白框的角自然露在外面**，
看着像一张白色贴纸没裁好。

算一下：图形最外点（圆角弧 + 描边外扩）离圆心 63.5 单位，圆半径只有 50。
所以**最多只能缩到 78%** 才刚好贴边，一点余量都没有。

取 **66%**：四周留出 8.1% 的黑边，像素对齐抖一下也不会擦到边。

```objc
static const CGFloat kSLVBrandGlyphScale = 0.66;
CGContextTranslateCTM(c, side * (1.0 - k) * 0.5, side * (1.0 - k) * 0.5);
CGContextScaleCTM(c, k, k);
```

缩放在底色画完之后改坐标系，圆本身不受影响；描边宽度跟着一起缩 —— 这正是想要的，
不然缩完线条会显得过粗。

### 二、当前素材：文字压到箭头上

0.3.1 把文字区的右边界算成 `contentView 宽度 - 6`。问题在于：**系统那个箭头不在
contentView 里面** —— 这个版本里 contentView 是满宽的，箭头单独盖在上层画。
减掉 6pt 之后，文字区实际伸到箭头底下去了，最后一个字符被啃掉一半。

改成先判断 contentView 到底有没有给箭头让位：

```objc
CGFloat reserve = (cellW - cvW > 1.0) ? 14.0 : 38.0;
```

- 让了位 → 在 contentView 里留 14pt
- 没让位 → 从 cell 右边直接留 38pt（箭头本身约 24pt + 14pt 净空）

这样不管哪个 iOS 版本算得对不对，都不会再压上去。

---

## 0.3.1 —— 标题栏 logo 回到黑底 22pt；当前素材改滚动

0.3.0 的两处「修过头」，这一版按实际观感收回来。

### 一、标题栏 logo

0.3.0 把它换成了无底色的紧凑版，还放大到 24pt。结果有两个问题：

- **黑底没了**。球和标题栏本来就该是同一张图（黑圆 + 白色叠层），去掉圆底之后
  两边长得不一样，标题栏那枚看着像个孤零零的线条符号。
- **24pt 偏大**。原来带黑底是 22pt，换成无底色之后图形直接铺满 24pt 的框，
  视觉重量一下上去了，比旁边的胶囊文字还抢眼。

现在退回 `SLVBrandIconImage(22)`：黑底圆 + 22pt，跟 0.2.28 一致。
只保留 0.3.0 里那处几何修正 —— **后框裁到前框右边线以右**。
那个才是「乱」的真原因：后框整条画出来时，它的左边线落在前框内部，
两条竖线只隔 7.5 单位，22pt 下糊成 `|||`。

### 二、「当前素材」改成滚动

0.3.0 用 `UITableViewCellStyleSubtitle` 把值挪到第二行。重叠是没有了，
但一行信息配一整行高度，观感太散，跟上下几行的节奏对不上。

回到 0.3.0 之前的单行（左边标题、右边值），重叠换个方式解决：
右侧不再用 `detailTextLabel`，改成一块**会被裁切的容器**，放不下就往左滚。

- 放得下 → 右对齐，跟原生 Value1 完全一样，也不加渐隐
- 放不下 → 停 1.1s → 26pt/s 滚完 → 停 1.1s → 回到开头
- 两端 13pt 渐隐（`CAGradientLayer` 当 mask）。硬切在标题边上会像「字从标题里长出来」

26pt/s 是「看得清每个字」和「不用等太久」之间的折中：一行 30 来个字符，
滚完 3～4 秒。箭头仍然是系统那个（`accessoryType`），没有自己画。

---

## 0.3.0 —— 和「声临·陌陌」同装时球不出现；标题栏 logo / 当前素材重叠

这一版是三件事捆在一起发的：**改掉和陌陌的符号冲突**、**修设置页两个显示 bug**。

---

### 一、两个 tweak 一起装，只看得见陌陌的球

#### 症状

同一台机器上装了「声临·陌陌」和「声临·虚拟摄像头」，进陌陌只看到一颗球 ——
长得是陌陌那套四根声波条，Vcam 的叠层球根本没出现。

#### 四层冲突，一层比一层深

| 层 | 冲突点 | 后果 |
|---|---|---|
| 1 | 注入范围 | `ShenglinVcam.plist` 写的是 `com.apple.UIKit`（全平台），陌陌进程里两个 dylib 同时加载 |
| 2 | **tag 撞车** | 两边都 `#define SLBtnTag 20931`，`viewWithTag:` 直接拿到对方的球 |
| 3 | ObjC 类同名 | 9 个类（`SLAlignBox` / `SLFloatButton` / `SLFloatIconController` / `SLFloatPanelController` / `SLLog` / `SLLogViewController` / `SLPopGestureKeeper` / `SLSearchPill` / `SLSettingsPanel`） |
| 4 | 偏好键同名 | `SLFloatPos` / `SLFloatPosRel` / `SLFloatIcon` / `SLFloatEffect` |

第 3 层是最阴的：ObjC 类表是**进程全局**的，9 个同名类只有一份生效，
后注册的那份被静默丢弃，只在控制台留一行 `Class X is implemented in both...`。
所以光改 tag 没用 —— 球能建出来，但跑的是陌陌那份实现。

#### 为什么「永远是 Vcam 输」

不是 dylib 加载顺序的问题，是**建球时机差了 1.2 秒**：

```objc
// 陌陌：%ctor → dispatch_async(main) → 0 秒建球
// Vcam：%ctor → dispatch_after 1.2s
```

所以这是**确定的**，不是「有时候有有时候没有」。谁先建，`viewWithTag:` 就归谁。

#### 改法

1. **全局标识符统一加 `V`**：`SLXxx` → `SLVXxx`。
   范围是 9 个 ObjC 类、11 个非 `static` 全局函数
   （`SLVApplyGlassTable` / `SLVCloseHostingPanel` / `SLVEnsureFloatButton` /
   `SLVFloatSetState` / `SLVFloatSetStateQuiet` / `SLVInstallPillBack` /
   `SLVInstallPillBackSized` / `SLVLogWrite` / `SLVRaiseFloatButton` /
   `SLVRefreshFloatButton` / `SLVStartEntryWatcher`）。
   另外 40 个函数本来就是 `static`，不导出、不会冲突，一起改名只为读起来一致。
2. **tag 20931 → 20941**。改名字不够，值必须换。
3. **默认落点错开**：`size.height * 0.55` → `* 0.72`。两边默认都在 0.55 一带，
   位置又都没存过时两个球会叠在一起。
4. **首次创建时避让**：窗口里已经有 tag 20931 的球、且位置几乎重合，
   我们的往下挪 64pt。只做兜底，用户自己拖过的位置不覆盖。
5. **偏好键迁移**：新键读不到时读旧键，读到就搬到新键。
   不迁的话 —— `kSLCamEnabledKey` 改名后 `SLCamEnabled()` 读不到旧值、兜底 `YES`，
   **用户关过的开关会自己打开**；`SLCamTargets` 读不到 → 空数组 = 全域生效，
   **白名单被静默重置**。

#### 没动的

- 文件名一律不改（`#import "SLXxx.h"` 还是原名）。
- 沙盒目录 `Documents/ShenglinVcam/`、日志 `/var/mobile/Documents/ShenglinVcam/slvcam.log`。
- `Makefile` 的 `_FILES` 清单。

---

### 二、标题栏 logo 乱了

标题栏那个 22pt 图标用的是 `SLVBrandIconImage(44)` —— 那张图**带一圈黑色圆底**，
是给悬浮球用的。缩到 22pt，圆底 + 两个框叠在一起，就是一坨黑块。

改成无底色的紧凑版 `SLVBrandGlyphImage(side, color)`，线条跟 `labelColor` 走。

顺带修了同一个函数里的一个几何问题：后框整条画出来时，它的左边线（x=42）落在
前框内部（2..58），两条竖线只隔 7.5 单位 —— 22pt 下糊成 `|||`，像三根柱子。
现在把后框**裁到前框右边线以右**，只剩右侧露出的那一截，语义回到「前面这张挡着后面那张」。
小尺寸（< 32pt）描边 8.5→6.5、圆角 17→15，否则前框的洞会被描边吃掉。

### 三、「当前素材」文字重叠

右侧详情是 `"1 个 · 抖音号_3...-10-29 23_56_2"` 这种长字符串，
`UITableViewCellStyleValue1` 在详情过宽时只保证「放得下才避让」，
右对齐的标签一旦被压窄，文字会从左边溢出到标题上，两段字叠在一起。

这一行改用 `UITableViewCellStyleSubtitle`：值单独占第二行，怎么长都不会撞。
行高 62，其余行仍 44。

---

## 0.2.28 —— 关掉「启用」后球退回默认态

### 症状

关掉设置页的「启用」开关，球还是绿的 —— 绿是「正在替换」的信号，关掉了还亮着
等于在骗人。

### 根因：漏判了总开关

`SLRefreshFloatButton` 只判 `SLCamArmed()`：

```objc
if (btn) [btn sl_applyState:(SLCamArmed() ? SLFloatStateReady : SLFloatStateIdle)];
```

而 `SLCamArmed()` 只看素材：

```objc
return [SLMediaStore currentItem] != nil && [[SLCamFeed shared] isReady];
```

**它不含总开关。** 关掉「启用」但素材还留着时，这个条件依然成立，球照旧发绿。
注入层其实早就放行原画面了（`SLCamSetInjecting(SLCamEnabled() && 有素材路径)`），
只有球的显示没跟上。

### 改法

```objc
BOOL working = SLCamEnabled() && SLCamArmed();
SLFloatState want = working ? SLFloatStateReady : SLFloatStateIdle;
if (btn && btn.slState != want) [btn sl_applyState:want];
```

关掉之后球直接退回 Idle：**单框、中性色、42% 透明度**，跟「没素材」完全一样。
这两件事对用户的意义本来就是同一个 —— 没在替换，不需要再为它造第三种颜色。

没有把 `SLCamEnabled()` 塞进 `SLCamArmed()` 本身：那个函数的语义是「素材就绪」，
注入层拿它当保险（`SLCamInject.m` 三处），混进总开关会让那几处判断变味。

### 顺带加的守卫

`btn.slState != want` 才调 `sl_applyState`。`SLEnsureFloatButton` 的窗口轮询每 2 秒
走一次刷新，而 `sl_applyState` 会重挂一遍动画 —— 不判的话球上的呼吸会一顿一顿的。

---

## 0.2.27 —— 贴边时外圈光晕被切掉一条

球拖到屏幕边缘松手吸附之后，靠边那一侧的光晕少了一截，看起来像球被啃掉一块。

### 原因：留白装不下光晕

贴边留白是从陌陌继承的，写死 4pt：

```objc
CGFloat minX = half + 4.0;
CGFloat maxX = size.width - half - 4.0;
```

但外圈光晕是 `CGRectInset(b, -7, -7)` 再加 2pt 描边 —— 它比球本身还要向外多出
**8pt**。留 4pt 装 8pt 的东西，超出的那 4pt 落在屏幕外，就被切掉了。

被切的是光晕，球本身没被裁（球边距屏幕还有 4pt）。

### 改法

留白提到 10pt（光晕 8pt + 2pt 余量）：

```objc
static const CGFloat SLBallEdgeInset = 10.0;
```

提成常量是因为这个 4 原来**散在两处**：`SLClampFloatPos` 里一份（拖动实时夹取），
松手贴边那一份（`c.x = ... ? half + 4.0 : sz.width - half - 4.0`）。只改一处的话，
松手瞬间会先吸到 4pt 再被夹回 8pt，球会抖一下。

顺带把阴影也容下了 —— `shadowRadius = 9`、`shadowOffset = (0, 3)`，右侧原本也超 1pt。

### 不受影响的方向

上下两边留白本来就远大于 8pt：`minY = half + 56`（让状态栏 / 刘海）、
`maxY = height - half - 34`（让底部安全区）。只有左右会裁。

### 旧位置会被自动纠正

球位存的是中心点占屏幕的比例，读回来仍然走 `SLClampFloatPos`。
之前存在贴边（4pt）的位置，下次启动会被夹到 10pt，不用手动挪。

---

## 0.2.26 —— 换掉陌陌那套竖条图标：改成「叠层」

### 一、为什么必须换

球的默认图形是从 ShenglinMomo 抄过来的四根竖条（左两根 30% 白 = 被替换的原声，
右两根纯白 = 合成声）。那是**音频波形**的语义，装在虚拟摄像头上说不通。

更实际的问题是：两个 tweak 同时装时，球长得一模一样，分不出哪个是哪个。

新图形是「叠层」—— 两个错开的圆角框，前面一张完整，后面一张从右侧透出来。
语义是「你看到的这一层，底下还压着另一层」，正好对上虚拟摄像头的实际行为：
送去编码的是素材，不是现场。

几何仍然走 100 单位基准，`48pt 球`和`44pt 标题栏图标`是同一套比例：

| 项 | 值 |
|---|---|
| 框尺寸 | 56 × 92 |
| 圆角 | 17 |
| 描边 | 8.5 |
| 空闲位置 | 前框居中 x=22，后框隐藏 |
| 装填位置 | 前框 x=2，后框 x=42 |

### 二、四态收成两态

`SLFloatState` 那个枚举有四档（空闲 / 录音 / 合成 / 就绪），是陌陌留下的。
Vcam 只会出现两种形态，另外两档永远不会传进来 —— 对应的三张错拍表
（`kStagRec` / `kStagSyn` / `kStagRdy`）和「上冲 + 双跳」关键帧已经删掉。

现在的两套节奏：

- **空闲** → 整组慢呼吸，一轮 2.4s、缩到 0.94。活着，但不抢注意力。
- **装填** → 前框轻呼吸（1.2s / 0.95），后框明暗交替（1.0 → 0.4）。
  前面那张稳着、后面那张若隐若现，正好是「底下还压着一层」的意思。

两态的位置差本身就是动势：空闲单框居中，装填时前框让到左边、后框从右侧浮出，
不用再叠一层缩放去表达「展开」。

### 三、描边色的过渡

描边是 `CALayer.borderColor`，**UIView 动画块管不到它** —— 直接赋值就是硬切，
状态从灰跳到绿时那一下很显眼。补了一个 `SLSetFrameBorder`：颜色变了才起
0.26s 的 `CABasicAnimation`，没变直接返回（`layoutSubviews` 会频繁调过来，
不能每次都起一遍动画）。

### 四、顺带纠正一个判断

之前以为「状态从没接上」，其实是错的：`SLRefreshFloatButton` 里就有

```objc
if (btn) [btn sl_applyState:(SLCamArmed() ? SLFloatStateReady : SLFloatStateIdle)];
```

`SLCamArmed()` 也早就在 `SLCamBridge.h` 里写好了（`[SLMediaStore currentItem] != nil
&& [[SLCamFeed shared] isReady]`）。没接上的只是 `SLFloatSetState` 这个公开入口，
它确实一次都没被调用过 —— 但那不是唯一路径，状态一直是好的。

### 五、没做的

后框「多出来那一块」的渐显没有单独做动画。它的 `opacity` 已经交给装填态的循环
动画了，再叠一个 `UIView` alpha 动画会抢同一个属性，两个动画互相覆盖，结果是不
定时地闪。父层 `_frames` 本来就有 0.18s 淡入，跟着走已经够。

---

## 0.2.25 —— 预览页：按素材比例出画 + 可拖动进度

### 一、竖视频不再是一张邮票

画面区高度原来写死 `宽 × 9/16`。竖拍的视频（9:16）塞进横框里按 `aspectFit` 一缩，
宽度只剩一百出头，等于在看一张邮票。

现在读素材自己的宽高比来定高度：

```objc
CGSize s = vt.naturalSize;
CGSize d = CGSizeApplyAffineTransform(s, vt.preferredTransform);   // 必须过一遍
```

`naturalSize` 是**传感器坐标** —— 竖拍的视频报的是 1920×1080，直接拿它算比例
等于没算。必须过 `preferredTransform` 才是眼睛看到的宽高。

高度按 `宽 / 比例` 算出来，再夹在 `[140, 剩余空间]` 之间。竖视频从 196 高、
110 宽的邮票，变成 314 高、177 宽。

图片也走同一套：读 `UIImage.size` 当比例。

### 二、进度条可以拖

底部加了一条进度条 + `0:03 / 0:12` 的时间。

- 每 0.1s 由 `addPeriodicTimeObserverForInterval:` 推一次位置
- 拖动时只更新时间字，**不 seek** —— 手指每挪一下 seek 一次会把解码器拖垮
- 松手才 `seekToTime:toleranceBefore:0 toleranceAfter:0`，然后接着播
- 拖到最右端会夹到 `duration - 0.05`：正好落在末尾会立刻触发「播完」通知，
  循环回 0，看起来像没拖成

周期性观察者必须在 `dealloc` 里自己摘掉，player 释放之后再调会崩。

---

## 0.2.24 —— 素材保留原始文件名

以前导入一律用 Unix 秒当文件名（`1793354943.mp4`），素材页和设置页「当前素材」
显示的就是这串数字 —— 三四个素材摆在一起，完全分不清哪段是哪段。

### 一、新导入的用原名

拿 `url.lastPathComponent` 去扩展名，清洗后直接用：`IMG_1234.MOV` → `IMG_1234.mov`，
文件导入的 `口播-第二版.mp4` 就是 `口播-第二版.mp4`。

清洗掉的是 `/ \ : * ? " < > |` 和控制字符（iOS 实际只禁 `/` 和 NUL，但别的字符在
日志、URL 里会出事），开头的点也要去掉 —— 那会让文件变成隐藏文件，
`allItems` 按扩展名过滤时就看不到它了。

重名不覆盖，加 `-2`、`-3` 后缀。

### 二、机器名才退回时间戳

相册偶尔给的是纯数字或 UUID 的临时名。这种名字拿来当显示名跟时间戳一样没法看，
所以判定成「机器名」退回 `20261030-192001` 这种时间格式：

- 全是数字
- 长度 ≥ 32 且去掉连字符后全是十六进制（UUID）

### 三、老素材显示成日期

库里已有的时间戳命名素材不改名（改名会连带去重指纹表、当前选中项一起失效），
只在**显示层**把 10 位 Unix 秒翻译成 `2026-10-30 19:20`。

### 四、顺手修了排序

`copyItemAtURL` 会连源文件的修改时间一起搬过来，而列表是按修改时间排「最新在前」的。
不重置的话，刚导入的一段老视频会沉到列表最底下，看起来像「没导入成功」。
现在拷完显式把修改时间设成当前时间。

---

## 0.2.23 —— 去掉重复入口 / 去掉菜单箭头

### 一、设置页不再有「添加素材」

素材页右上角的「＋」已经是添加入口，设置页那一行是同一件事的第二个入口，
点下去弹的还是同一个菜单。删掉。

现在「素材」组只剩两行：**当前素材**（点进去是素材库）、**预览素材**（右侧直接显示
有没有声音）。要加素材就进素材库点「＋」，路径只有一条。

### 二、菜单的小三角删掉

原来在面板上画了一枚指向锚点的三角尖，两个问题：

- **颜色对不上。** 面板是近白实色，尖也是近白，叠在浅色玻璃上就是一块白疙瘩，
  而且尖和面板之间那道 0.5pt 的缝反而把它勾了出来。
- **位置对不上。** 尖的横坐标按 `midX - x` 算，但菜单靠到屏幕边缘时 `x` 会被夹过，
  算出来的尖就偏离按钮了 —— 截图里它歪在面板左边。

系统的 `UIMenu` / 上下文菜单本来就没有箭头，靠位置和弹出动画表达「从哪儿来的」就够了。
现在改成：面板的 `anchorPoint` 落在「对着按钮的那条边」上（往下开取顶边、往上开取底边），
弹出时从那一侧缩放展开。

顺带把摆放方式从 `frame` 换成 `bounds + anchorPoint + position` ——
改完 `anchorPoint` 之后 `frame` 会自己变形，写 `frame` 等于白写。

---

## 0.2.22 —— 相册合并 / 批量导入 / 素材预览 / 加号弹出框

### 一、「＋」改成锚在按钮下方的小框

素材页的「＋」在导航栏右上角，原来的 action sheet 却是从屏幕底下升起来的 ——
点哪儿、弹哪儿完全对不上。现在是一个贴着按钮下沿展开的小框，带一枚指向锚点的三角尖，
点空白处收起。

小框只有两项：**从相册选择** / **从文件导入**，不带副标题。

两个实现细节：

**菜单挂在导航控制器的视图上，不挂在表格上**。设置页和素材页都是
`UITableViewController`，`self.view` 就是那张表，菜单加进去会跟着内容一起滚走。

**锚点用 bar item 的 `customView`**。`SLPillIconBarItem` 返回的是自定义视图，
`convertRect:fromView:` 能直接把它的位置换算到容器坐标，不用去猜导航栏的布局。

### 二、相册入口合并成一个，支持批量

以前「从相册选视频」和「从相册选图片」是两个入口，因为代码里把 `filter` 写死成二选一。
实际上 `PHPickerFilter` 支持求并集：

```objc
cfg.filter = [PHPickerFilter anyFilterMatchingSubfilters:
              @[[PHPickerFilter imagesFilter], [PHPickerFilter videosFilter]]];
```

相册本来就是一屏混排，没必要让用户先做一次分类。`selectionLimit` 从 1 放开到 0，
一次能选一批，逐个导入，**最后导入的那个成为当前素材**。

类型判定不能再靠 `wantsVideo` 这个状态位了，改成问 provider 自己注册了什么：
**先问图片再问视频** —— 实况照片两种表示都有，先问图片能拿到那张静态帧，
比拿一段 3 秒的 MOV 更符合「图片定格」的预期。

批量导入是串行的，不是并行：`loadFileRepresentation` 给的临时文件**只在回调里有效**，
必须当场拷走；并发拷还会同时改 `media/.hashes.plist`。文件导入那条路走后台串行队列，
因为算 SHA-256 加解码体检对 4K 素材是秒级的，一次选五个会把主线程堵死。

### 三、素材预览

设置页「素材」组多一行**预览素材**，右侧直接给结论（有声音 / 无声音 / 图片），
点进去是一个真播放的预览页。另外长按悬浮球展开的扇里，**停在「启用」球上不动 0.55 秒**
再松手也会进预览，不切开关 —— 图标会从电源变成播放，配一次轻震，松手前就知道会发生什么。

预览页给三件事：

- 视频循环播放，图片定格
- 音轨结论：`有声音` / `无声音` / `有音轨 · 解不了`，带编码名（AAC / ALAC / Opus…）
  和 `44.1 kHz · 2 声道`
- 一句后果说明：没有音轨时录制会输出静音，不会放行真麦克风

**没有做跳动的电平条**。要画真电平得挂 `MTAudioProcessingTap`，那玩意儿一旦没挂对，
最坏的后果是预览反而没声音 —— 正好毁掉这个功能存在的意义。所以只做静态体检
（音轨在不在 + 能不能解成 PCM）+ 真播放，结论是确定的。体检判据和 `SLCamFeed`
建 reader 时完全一致，避免「预览说能出声、录制时却静音」。

预览期间会把音频会话临时设成 `Playback + mixWithOthers`：宿主 App（抖音 / QQ）可能把
类别设成 Ambient，手机一开静音键预览就没声，用户会当成「素材坏了」。退出时
`NotifyOthersOnDeactivation` 还给别人。

### 四、提示语砍短

所有 toast 只留结论：「导入中」「已添加」「已添加 5 个」「已在库中」「导入失败」
「已切换」「已取消」「声音：开」「不旋转」。以前那种「已加入图片，画面已定格」
「已关闭，点球不再展开」的长句全部去掉 —— toast 只活 1.2 秒，写长了根本读不完。

### 五、0.2.21 补记

上一版没写说明，补在这里：

- **图片导入必失败** —— `importItemAtURL:` 把裸扩展名喂给了吃文件名的 `isImageFileName:`，
  而 `@"png".pathExtension` 是空串，于是所有图片被当成视频去体检。拆出 `sl_isImageExt:`。
- **两个 toast 叠在一起** —— 每条都 `addSubview`，没有互斥。现在全局只留一条。
- **长按菜单「不旋转」没有图标** —— 四档画的是环形进度弧，0° 那档 `strokeEnd = 0`
  什么都不画。补一圈 alpha 0.20 的底环。
- **导入的视频有时是原声** —— `sl_audioLocked:` 在没有音轨时 `return nil`，
  注入层就把真麦克风放行了。改成返回全零静音。

---

## 0.2.20 —— 图片素材 / 内容去重 / 文件导入 / 缩略图 · 日志回归干净

### 一、素材库支持图片

以前素材库只认 `mp4 / mov / m4v`，现在 PNG / JPG / HEIC / WebP / BMP / TIFF 也能进。

图片的处理方式和视频**不是两套**：解码线程读到图片时，把图解一次、按宿主当前要的
像素格式和尺寸渲成一张 `CVPixelBuffer`，塞进 `_latestVideo` —— 之后和视频帧走同一条路。
所以下面这些一行代码都没改，图片自动就有：

- 预览出帧（`copyFrameForPixelFormat:size:`）
- 拍照（`copyOrientedFrameForPixelFormat:` / `renderIntoPixelBuffer:`）
- 旋转 / 镜像（下游每帧按设置实时做）
- 抖音的 `AVCapturePhoto.pixelBuffer` 原地改写

两个实现细节：

**竖拍照片会躺着**。`CIImage` 读文件时保留 EXIF 方向但不套用，得自己补：
读 `kCGImagePropertyOrientation`，2~8 就 `imageByApplyingOrientation:`。不补的话
手机拍的竖图进画面会横过来。

**不会每帧重算**。静态图按宿主当前的 `格式:宽x高` 渲一次就缓存住（`_stillKey` 记着
是按哪个目标渲的），宿主换分辨率才重渲。不这么做的话每帧都要做一次 CI 缩放，
30fps 下等于白烧一个核。

### 二、导入按内容去重

同一份文件加两次，以前会变成两条（文件名是时间戳，天然不重名）。现在导入前先算
**SHA-256**，跟库里已有的比：

- 命中 → 不复制，直接切到已有的那条，提示「这份素材已经在库里」
- 没命中 → 正常导入

指纹存在 `media/.hashes.plist`（隐藏名 + plist 后缀，`allItems` 的扩展名过滤看不到它）。
0.2.20 之前导入的素材没有指纹记录，第一次导入时补算一次，之后走缓存。

分块读（1MB 一块）算哈希，4K 素材动辄上百 MB，一次读进内存会直接吃掉几百 MB。

### 三、列表最新在上 + 导入后自动选中

`allItems` 原来按文件名升序 —— 文件名就是时间戳，等于**最早的排最上面**。
改成按修改时间降序。同时删掉 `importFileAtURL:` 里那句 `if (![self currentItem])`：
以前只有库里空着才自动选中，加第二个素材还得再点一次；现在每次导入都自动选中。

### 四、文件管理导入

`UIDocumentPickerViewController`，类型放开到 `UTType.movie` + `UTType.image`，
`asCopy:YES` —— 系统先拷到我们沙盒的临时目录，不用处理 security scoped 权限，
也不碰用户的原文件。

添加入口收成一个菜单（相册视频 / 相册图片 / 文件导入），设置页和素材页共用
`+[SLMediaListController presentAddMenuFrom:completion:]`。三个按钮并排会把整组撑满，
所以收进菜单里。

### 五、缩略图

每行左边 40pt 圆角缩略图：图片用 `CGImageSourceCreateThumbnailAtIndex`（顺带把 EXIF
方向摆正），视频用 `AVAssetImageGenerator` 抽第 0 帧（`appliesPreferredTrackTransform`）。

异步生成跑在一条**串行**队列上 —— 并发抽帧会跟宿主自己的解码抢 IO。结果进 `NSCache`
（上限 64 张，一张约 70KB）。异步回来时靠 `cell.boundFile` 判断这一格是不是已经滚走、
绑到别的素材上了，避免图错位。

### 六、日志回到干净状态

0.2.19 那批探针已经结案（QQ 录制的麦克风不经过任何客户端可见的音频 API），全删：

- 6 个录制探针（`AVAudioRecorder` 三个变体、`AVAudioEngine`、`AVAudioSinkNode`、音频会话）
- `SLSymbolHookAudit()` 只读审计
- `SLScanImage` 的 `dryRun` 参数

**补扫的启动洪水也修了**。`_dyld_register_func_for_add_image` 注册那一刻，dyld 会把
当前已加载的**每一个**镜像都回调一遍 —— 一个 QQ 进程实测 1047 个，每个都排一次全量
重扫，启动瞬间白烧上千次扫描，还把日志配额吃光（0.2.19 的日志里，17:20:33 之后
所有补扫都是静音的，就是这个原因）。

现在加了个「已排队」标志：第一个进来的排一个 0.25s 后的任务，后面几百个直接返回。
标志只在后台串行队列上读写，不需要额外加锁。

日志配额也换了判据：从「无命中只记前 3 次」改成「**扫过的镜像数变了**才记」。
这样启动只出一行，之后每次有新 framework 加载再出一行 —— 既安静，又不会漏掉
「录制开始时到底有没有新镜像」这个关键信息。

---

## 0.2.19 —— 查 QQ 录制原声：自动补扫 + 只读审计 + 第二批探针

### 一、先把 0.2.18 的结论钉住

0.2.18 的心跳改对了，QQ 那段日志给出了决定性的一行：

```
音频: 心跳 调用 1500 / bus=1 累计 979（本轮 +0）
```

录制期间 `AudioUnitRender` 的总调用数从 1000 涨到 1500（**unit 还活着、还在被渲染**），
但 `bus=1`（麦克风输入方向）**一次都没增加**。

一句话：**录制的麦克风不经过我们替换过的那个 `AudioUnitRender`。**
不是「替换了但没生效」，是「根本没走到这里」。

那么只剩两种可能：

| # | 假设 | 判据 |
|---|---|---|
| A | 录制的采集模块是启动之后才 `dlopen` 的，它的符号槽没被扫到 | 审计能报出「引用了 `AudioUnitRender` 但没打补丁」 |
| B | 录制走的是另一条完全不同的路径（`AVAudioEngine` / `AVAudioSinkNode` / 另一个会话） | 审计报 0 处，但探针命中 |

0.2.19 同时覆盖这两条，**全部只读**，不改任何函数指针、不改任何行为。

### 二、为什么之前会漏扫

`SLSymbolHookRescan` 只扫路径里含 `.app/` 的镜像。QQ 的日志一直是：

```
符号: 扫过 6 个 App 镜像
```

而抖音是 30 个 —— 说明 QQ 在启动那一刻只加载了 6 个 App 内镜像，
它的拍摄模块是**点开拍摄页之后**才 `dlopen` 进来的，
那时启动那一遍扫描早就跑完了，那份 framework 里的 `AudioUnitRender` 引用自然是原样的。

新增 `SLSymbolHookInstallAutoRescan()`：

```objc
_dyld_register_func_for_add_image(SLCamImageAdded);
```

之后每个新镜像加载都会触发一次补扫。

**关键细节**：这个回调是在 dyld 持锁的状态下被调用的，里面不能做重活
（遍历 load command、`mprotect` 都算重活，轻则卡顿重则死锁），
所以回调体里只有一句 `dispatch_async`，真正的补扫丢到自己的后台串行队列：

```objc
static void SLCamImageAdded(const struct mach_header *mh, intptr_t slide) {
    dispatch_async(q, ^{
        int hits = SLSymbolHookRescan();
        if (hits > 0) SLLog(@"符号: 新镜像补扫命中 %d 处", hits);
    });
}
```

### 三、只读审计：一个字节都不写

光补扫还不够 —— 万一补扫也命不中，得知道「到底有没有东西漏了」。
新增 `SLSymbolHookAudit()`：把**非 App 包内**的镜像也过一遍，
报出「引用了目标符号、但我们没打补丁」的有哪些。

给 `SLScanImage` 加了 `dryRun` 参数，审计模式下命中就 `continue`，不写槽：

```objc
if (!curAddr || curAddr == sTargets[t].replacement) continue;
// 审计模式：只数、不写
if (dryRun) { hits++; continue; }
```

**这里有一条不能碰的红线**：系统库一律跳过。

```objc
if (strstr(path, "/System/") || strstr(path, "/usr/lib/")) { systemCount++; continue; }
```

系统库在 dyld 共享缓存里，`__LINKEDIT` 的 `fileoff` 跟运行时内存布局对不上，
`SLScanImage` 算出来的指针槽是垃圾地址 —— 即使是只读，读垃圾地址一样会炸。
0.2.4 那次崩溃就是这么来的。所以审计只扫第三方 framework
（`/var/containers/Bundle/Application/.../Frameworks/`），系统的一个都不碰。

触发时机：第一次「会话加输出」（也就是拍摄页打开）时做一次，只做一次。

### 四、第二批探针（6 个，只打日志）

第一批探针（`installTapOnBus:` / `AVAudioRecorder record` / `AVCaptureMovieFileOutput`）
0.2.15–0.2.18 一个都没命中。这次补第二批，覆盖剩下的可能：

| 挂点 | 命中说明什么 |
|---|---|
| `AVAudioRecorder recordForDuration:` | 录制走写文件路径，麦克风在 AVFAudio 内部 |
| `AVAudioRecorder recordAtTime:` | 同上，定时变体 |
| `AVAudioRecorder recordAtTime:forDuration:` | 同上 |
| `AVAudioEngine startAndReturnError:` | 麦克风在 `AVAudioEngine` 内部渲染 —— **这是最可能的一条** |
| `AVAudioSinkNode initWithReceiverBlock:` | 宿主用 sink node 直接拿 PCM，这是个可以接管的口子 |
| `AVAudioSession setCategory:mode:options:error:` | 当作录制开始/结束的时间戳用 |

最后那个会话探针只在 `category/mode/options` 真的变化时才打一行，
不会刷屏，但能把「几点几分进的录制模式」标在日志上。

布点完成会打一行确认：

```
探测: 录制链路已布点 tap=? recorder=? movie=? engine=? sink=? session=?
```

### 五、这版怎么读日志

拍完一段带声音的录制，按顺序找这三行：

1. `审计: 非 App 包内镜像 N 个（系统 M 个已跳过）· 其中 K 处引用目标符号但没打补丁 → 列表`
   - **K > 0 且列表里有 QQ 自己的 framework** → 就是漏扫，自动补扫已经修了，下一版验证声音
   - **K = 0** → 录制根本不走 `AudioUnitRender`，看第 3 行
2. `符号: 新镜像补扫命中 X 处` —— 有没有在拍摄页打开时补上
3. `探测: 宿主启动了 AVAudioEngine` / `探测: 宿主用 AVAudioSinkNode 取 PCM` /
   `探测: 音频会话 → playAndRecord/...`

三条都空、审计也报 0 —— 那说明 QQ 的录制采集在我们完全看不到的地方（很可能是它自己
独立的音频进程或更低层的 HAL 接口），得换思路，不能再在 `AudioUnitRender` 上加东西。

---

## 0.2.18 —— 抖音拍照补 90° / 音频心跳加密

### 一、抖音拍照角度

0.2.17 的日志：

```
注入: 拍照已接管（AVCapturePhoto.pixelBuffer 原地改写）· 3840x2160 · 0° / 镜像关
```

接管成功了，但**照片缓冲是 3840x2160 横屏，预览缓冲是 1080x1920 竖屏** ——
两者差 90°。原因是两条路拿到的根本不是同一个东西：

| 来源 | 缓冲 | 说明 |
|---|---|---|
| `AVCaptureVideoDataOutput` | 1080x1920 | 已经按 `videoRotationAngle` 转过向 |
| `AVCapturePhoto.pixelBuffer` | 3840x2160 | 传感器原始方向，没转 |

所以素材按「设置里的 0°」画进照片缓冲，等于被塞进一个转了 90° 的框里。
3840x2160 正好是 1080x1920 转 90° 再放大 2 倍 —— 数字对得很齐。

补多少度、往哪个方向补，由**照片自己的 EXIF 方向**决定：
EXIF 说「要顺时针转 90° 才正」（=6），我们就先逆时针转 90°（=270°），
等宿主把它转回来正好抵消。

新增 `-[SLCamFeed latestFrameSize]` 拿预览缓冲尺寸，`renderIntoPixelBuffer:`
加 `extraRotation:` 参数。日志改成一次把三个数都打出来：

```
注入: 拍照已接管（pixelBuffer 原地改写）· 照片 3840x2160 / 预览 1080x1920 · 设置 0° + 补偿 270° / 镜像关
```

方向要是还不对，看这一行就知道该把补偿翻成 90 还是 270，不用再猜。

### 二、音频心跳加密（为了查 QQ 录制）

原来心跳是 `sCalls % 3000 == 0` 才打一条，而 `sCalls` 是 bus=0 + bus=1 的总和。
一次几十秒的录制根本攒不到 3000，日志上完全看不出录制期间麦克风有没有走这条路 ——
这是「QQ 录制原声」查不下去的直接原因。

改成每 500 次一条，并且报**本轮增量**：

```
音频: 心跳 调用 1500 / bus=1 累计 320（本轮 +160）
```

判读方法：

- `本轮 +N`（N>0）→ 麦克风走的是我们挂住的 AudioUnit，问题在替换环节；
- `本轮 +0` 但确实在录 → 走的是别的路，那就是「后加载 framework 漏扫符号」的锅，
  下一步上 `_dyld_register_func_for_add_image` 补扫。

## 0.2.17 —— 抖音拍照改走 pixelBuffer

0.2.16 的日志把范围缩小到了一行：

```
16:31:21 注入: 命中 AVCapturePhotoOutput 拍照 · delegate=IESMMCaptureKit
（之后没有「拍照已接管（AVCapturePhotoOutput）」）
```

`capturePhotoWithSettings:delegate:` 命中了，`fileDataRepresentation` 没被调用。
说明抖音（IESMMCaptureKit，字节自家采集 SDK）拍完**不向 AVCapturePhoto 要文件字节**，
而是直接读 `-pixelBuffer` 拿像素去跑它自己的处理链。只挂 `fileDataRepresentation`
对它无效。

### 为什么不能直接返回自己 new 的 buffer

`-pixelBuffer` 返回的是**借用**引用（buffer 归 AVCapturePhoto 所有，调用方不负责释放）。
如果我们返回自己 new 的：

- 调用方不会 `CFRelease` → 每次拍照泄一张 8MB；
- 尺寸/格式跟真照片对不上 → 宿主按 `resolvedSettings` 算出的宽高会跟 buffer 打架。

### 改法：原地改写

新增 `-[SLCamFeed renderIntoPixelBuffer:]`：拿宿主那个 buffer，把素材帧
**按当前旋转/镜像摆好后直接画进去**。指针、尺寸、格式全是宿主熟悉的那个，
调用方完全无感。

顺带把 `sl_render:` 里那套「旋转 → 铺满裁切 → 镜像」的数学抽成
`sl_image:toWidth:height:mirror:rotation:`，两条出图路径共用一份 ——
各写一遍迟早会不一致。

日志会打一行 `拍照已接管（AVCapturePhoto.pixelBuffer 原地改写）· 宽x高 · 角度 / 镜像`，
下次一眼就能确认走的是哪条路。

## 0.2.16 —— 拍照方向 / 抖音拍照 / toast 收短

0.2.15 上机后的三项。抖音导航栏那层多出来的胶囊**本版不动**（结论见文末附录）。

### 一、拍照跟着旋转 / 镜像设置走

`SLCamCaptureStill` 里取帧用的是 `copyNextFrame` —— 那是解码器吐的**原始帧**，
既没转角度也没镜像。预览画面是走 `sl_render:` 转正的，所以出现
「预览正、拍出来歪」。

不能直接把这里换成 `copyFrameForPixelFormat:size:`：那个方法会写
`_pipelineKey` / `_reconfigRequested`，让解码线程按新格式**重建管线**。
拍一张照片就把预览管线换掉，紧接着几帧取不到数据（返回 NULL → 放行真画面），
画面上会闪一下真实摄像头。

新增 `-[SLCamFeed copyOrientedFrameForPixelFormat:size:]`：同样按当前
旋转/镜像摆好，但**一根手指都不碰管线状态**。`size` 传 `CGSizeZero` 表示按素材
自身尺寸出图（转 90/270 时宽高互换），1:1 直出、不做铺满裁切，拍出来就是素材
原始分辨率。代价是每次拍照现场做一次 CI 渲染（十几毫秒），拍照是低频操作，
拿这点开销换「预览不闪」值得。

### 二、抖音拍照补上 AVCapturePhotoOutput

QQ 和抖音的拍照是**两条完全独立的路**：

| App | 类 | 我们的钩子 |
|---|---|---|
| QQ | `AVCaptureStillImageOutput` | 0.2.15 已接 |
| 抖音 | `AVCapturePhotoOutput` | 本版新增 |

只挂 `StillImageOutput` 对抖音一点作用都没有 —— 它的日志里那句
「会话加输出: AVCapturePhotoOutput」就是证据。

接法不走 delegate（delegate 是宿主私有类，每次启动可能不同，还得处理中途被替换），
改成直接挂在 `-[AVCapturePhoto fileDataRepresentation]` 和
`fileDataRepresentationWithCustomizer:` 上：宿主不管怎么拍、委托给谁、
要 HEIC 还是 JPEG，最后总得向 `AVCapturePhoto` 要字节，那一刻换成我们的。
一个方法覆盖所有调用方式，也不用管它内部编码格式。

另加一条探针 `capturePhotoWithSettings:delegate:`，只打一行日志记录 delegate 类。
下次再出「拍了没换」，看日志就能分清卡在哪一步：

- 有 `命中 AVCapturePhotoOutput 拍照`、没有 `拍照已接管（AVCapturePhotoOutput）`
  → 宿主读的是 `photo.pixelBuffer` 而不是 `fileDataRepresentation`，要换挂点；
- 两条都有但照片还是真的 → 宿主把 `photo.metadata` 里的 EXIF 方向又套了一遍。

### 三、扩展球 toast 收成一行

原来每条都带解释（「替换已开启 · 摄像头画面换成素材」），松手后弹一大段反而看不清
到底切成什么状态。改成只报状态：

| 开关 | toast |
|---|---|
| 替换 | `替换：开` / `替换：关` |
| 声音 | `声音：开` / `声音：关` |
| 方向 | `方向：不旋转` / `方向：90°` / `方向：180°` / `方向：270°` |
| 镜像 | `镜像：开` / `镜像：关` |
| 循环 | `循环：开` / `循环：关` |

### 附录：抖音导航栏那层多出来的胶囊（本版未改）

结论是**系统画的，不是我们的**。iOS 26 给 `UIBarButtonItem` 加了
`sharesBackground`（默认 `YES`）—— 一个导航栏里有多个 item 时，系统会把它们
框进同一个液态玻璃胶囊；单个 item（返回键）则拿到一颗自己的玻璃圆。我们在
`customView` 里已经画了胶囊，于是叠成两层。

只有抖音有，是因为液态玻璃**按宿主 App 的构建 SDK 决定**：用 iOS 26 SDK 编、
且 Info.plist 没写 `UIDesignRequiresCompatibility = YES` 的 App 才走新设计。
QQ/陌陌是老 SDK 编的，系统完全不画按钮背景。

我们这边代码在每个 App 里完全一样（全工程只有 `SLGlass.m` 两处创建
`UIBarButtonItem`，没有任何按 App 分支的判断），所以这不是「没统一」。

以后要改的话：在这两个构造函数里给每个 item 设 `hidesSharedBackground = YES`。
CI 的 Theos SDK 没有 iOS 26 头文件，得用 `respondsToSelector` + KVC 探测着设。

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
