## 0.2.5 —— 修「装上就闪退」，App 打不开了

### 症状

装 0.2.4 之后，陌陌和 QQ **启动即闪退**，连启动页都看不到。
不是替换功能出问题，是 App 根本进不去。

### 根因：`section->offset` 是文件偏移，不是运行时偏移

0.2.4 为了接管 QQ 那种不走 `AVCapture` 的麦克风，自己写了个 fishhook 精简版，
遍历已加载镜像的 `__la_symbol_ptr` / `__got` 找 `AudioUnitRender`。
算指针槽地址时用的是：

```c
void **slots = (void **)(base + sect->offset);   // ❌
```

`section->offset` 是**文件内偏移**。只有「本镜像的 fileoff 恰好等于 vmaddr」时
它才等于运行时偏移 —— App 自己的主二进制满足这个条件，所以本地看着像没问题。

但 `_dyld_image_count()` 返回的是**所有**已加载镜像，其中绝大多数是系统库。
iOS 的系统库全在 dyld 共享缓存里，fileoff 和运行时布局毫无关系。
照这个公式算出来的指针是野指针，`slots[k]` 一读就是 `EXC_BAD_ACCESS`，
而这段代码跑在 `%ctor`（dylib 加载时），所以是**启动即崩**。

### 修法

```c
uintptr_t imageBase = (uintptr_t)hdr - textVM;      // textVM = __TEXT.vmaddr
void **slots = (void **)(imageBase + sect->addr);   // ✅ VM 地址
```

`__LINKEDIT` 里的 `symoff` / `stroff` / `indirectsymoff` 同样是文件偏移，
换成运行时地址要 `linkBase + (off - linkedit->fileoff)`。

顺带补了五道防线，每一道都是「宁可漏挂，不能把宿主搞崩」：

| 防线 | 拦的是什么 |
|---|---|
| 只扫路径含 `.app/` 的镜像 | 系统库在 dyld 共享缓存里，碰它必崩 |
| 跳过 `__AUTH` / `__AUTH_CONST` 段 | arm64e PAC 认证指针，写裸地址会被校验拦下 |
| `sect->addr` 必须落在本镜像 VM 区间内 | 结构损坏时字段是垃圾，落进堆里也「可读可写」，光查可读性拦不住 |
| `SLRangeReadable()` 首尾各查一次 `vm_region` | 区间跨页跨 region 时单点查询会漏判 |
| `n_strx` / `reserved1 + count` 越界检查 | 字符串表、间接符号表读越界 |
| `vm_protect` 失败就放弃写入 | 只读页写下去一样崩 |

### 再加一道「崩溃哨兵」

万一以后还有别的地方算错，绝不能再让用户面对「App 打不开、只能卸载」。

装符号钩子之前先往 App 的 tmp 目录落一个哨兵文件，装完立刻撤掉：

```
正常启动：  落哨兵 → 装钩子 → 撤哨兵
崩在这里：  落哨兵 → 装钩子 → 💥（哨兵留在磁盘上）
下次启动：  看到哨兵 → 本次不装 C 函数 hook → App 正常打开
```

画面替换走的是 `method_setImplementation`，跟符号扫描无关，**照常工作**。
日志里会有一行：

```
守护: 上次启动在扫描符号表时崩溃过，本次跳过 C 函数 hook（画面不受影响）
```

看到这行就说明踩到兜底了，把日志发我，我再修真正的原因。

### 这一版能用的功能

- 视频替换：正常（陌陌已验证）
- 音频替换 / 静音：陌陌正常；QQ 待验证 —— 装好 0.2.5 后开一次语音，
  看日志有没有 `音频: 已接管 AudioUnit 麦克风输入`
- 旋转（0/90/180/270）、镜像、循环、音频开关：都在设置里

## 装法

自签注入：把 `ShenglinVcam-v<版本>.dylib` 注入目标 App 的 IPA 后重签安装。
越狱环境直接装 `ShenglinVcam-v<版本>.deb`。

> 本包与底包（声临）**包名和 dylib 名完全一致**，装这个会把底包覆盖掉。
> 两个都要用的话别同时装。
