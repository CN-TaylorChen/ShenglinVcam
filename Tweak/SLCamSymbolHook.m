//
//  SLCamSymbolHook.m
//  声临 · 虚拟摄像头 —— C 函数 hook（fishhook 精简版）
//
//  踩过的坑（0.2.4 一装就闪退的元凶）：
//    最初用 `header + section->offset` 算指针槽地址。section->offset 是**文件偏移**，
//    只在本镜像的 fileoff 与 vmaddr 一一对应时才等于运行时偏移。系统库全在 dyld
//    共享缓存里，fileoff 与运行时布局毫无关系 —— 照这个公式算出来的指针是垃圾，
//    往里写一个地址就是 EXC_BAD_ACCESS，App 启动即崩。
//    正确做法是用 VM 地址：`imageBase + section->addr`，
//    其中 `imageBase = header - __TEXT.vmaddr`。
//
//  另外三条安全线：
//    · 只扫 App 自己 bundle 里的镜像（路径含 ".app/"），系统库一概不碰；
//    · 读指针槽前先用 vm_region 确认那块内存真的映射过且可读；
//    · mprotect 失败就不写 —— 写只读页一样会崩。
//
//  0.2.6 加了诊断：命中要打镜像名，被认证 GOT 跳过的槽要单独计数。
//  没有这两项，日志上分不清「镜像里没有这个槽」和「槽在 __auth_got 里被我们跳过」——
//  而这两种情况的修法完全不同。
//

#import "SLCamSymbolHook.h"
#import "SLLog.h"

#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach/vm_prot.h>
#import <string.h>
#import <unistd.h>

#define SL_MAX_TARGETS 8

typedef struct {
    const char *name;      // 不带下划线的符号名
    void *replacement;
    void *original;
    void **originalOut;    // 调用方给的传出指针，替换前就写入，避免竞态
} SLTarget;

static SLTarget sTargets[SL_MAX_TARGETS];
static int sTargetCount = 0;

/// 这块地址是否真的映射过、且可读。
/// 共享缓存 / 懒加载 / 计算错误都会让指针落在野区，读一下就崩，
/// 所以每次碰内存之前都先问一遍内核。
static BOOL SLIsReadable(const void *addr, size_t len) {
    if (!addr || len == 0) return NO;
    vm_address_t region = (vm_address_t)addr;
    vm_size_t regionSize = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;

    kern_return_t kr = vm_region_64(mach_task_self(), &region, &regionSize,
                                    VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_t)&info, &count, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    if (kr != KERN_SUCCESS) return NO;

    uintptr_t a = (uintptr_t)addr;
    if (a < (uintptr_t)region || a + len > (uintptr_t)region + regionSize) return NO;
    return (info.protection & VM_PROT_READ) != 0;
}

/// 一段区间是否整段可读。
/// vm_region 只回答「包含这个地址的那个 region」，区间跨页跨 region 时
/// 单点查询会漏判，所以首尾各问一次。
static BOOL SLRangeReadable(const void *addr, size_t len) {
    if (!addr || len == 0) return NO;
    if (!SLIsReadable(addr, 1)) return NO;
    return SLIsReadable((const uint8_t *)addr + len - 1, 1);
}

/// 放开写权限。VM_PROT_COPY 是必须的：iOS 的 COW 页不改它直接写会崩。
static BOOL SLMakeWritable(void *addr, size_t len) {
    vm_size_t pageSize = (vm_size_t)getpagesize();
    uintptr_t start = (uintptr_t)addr & ~(uintptr_t)(pageSize - 1);
    uintptr_t end = ((uintptr_t)addr + len + pageSize - 1) & ~(uintptr_t)(pageSize - 1);
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)start,
                                  (vm_size_t)(end - start), false,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    return kr == KERN_SUCCESS;
}

/// 这个指针表 section 有多少个槽（已按间接符号表长度裁过）。
static uint32_t SLSectionSlotCount(const struct section_64 *sect,
                                   const struct dysymtab_command *dysymtab) {
    if (sect->size < sizeof(void *)) return 0;
    if (sect->reserved1 == 0) return 0;
    if (sect->reserved1 >= dysymtab->nindirectsyms) return 0;
    uint32_t count = (uint32_t)(sect->size / sizeof(void *));
    if (sect->reserved1 + count > dysymtab->nindirectsyms) {
        count = dysymtab->nindirectsyms - sect->reserved1;
    }
    return count;
}

/// 把间接符号表里的下标翻成符号名（已去掉前导下划线）。
/// remainOut 给出这条字符串在字符串表里还剩多少字节，供调用方做边界判断。
static const char *SLNameAtIndex(uint32_t symIdx, const struct nlist_64 *syms,
                                 const char *strtab, uint32_t strtabSize,
                                 uint32_t nsyms, size_t *remainOut) {
    if (symIdx == INDIRECT_SYMBOL_LOCAL || symIdx == INDIRECT_SYMBOL_ABS) return NULL;
    if (symIdx >= nsyms) return NULL;

    uint32_t strx = syms[symIdx].n_un.n_strx;
    // n_strx 越界时 strtab + strx 落在 __LINKEDIT 外，读一下就崩
    if (strx == 0 || strx >= strtabSize) return NULL;

    const char *s = strtab + strx;
    if (!*s) return NULL;

    uint32_t off = 0;
    if (s[0] == '_') { s++; off = 1; if (!*s) return NULL; }   // Mach-O 符号带前导下划线

    if (remainOut) *remainOut = (size_t)(strtabSize - strx - off);
    return s;
}

/// 这个名字是不是我们注册过的目标？是就返回下标。
static int SLTargetIndexForName(const char *sname, size_t remain) {
    if (!sname) return -1;
    for (int t = 0; t < sTargetCount; t++) {
        size_t need = strlen(sTargets[t].name);
        // 剩余长度装不下名字（含结尾 NUL）就说明这条字符串不完整，别比
        if (remain <= need) continue;
        if (strcmp(sname, sTargets[t].name) == 0) return t;
    }
    return -1;
}

static int SLScanImage(const struct mach_header_64 *hdr, const char *imgName,
                       int *authSkipped) {
    // ---- 第一遍：找 __TEXT 的 vmaddr、__LINKEDIT、符号表命令 ----
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    uintptr_t textVM = 0;
    BOOL hasText = NO;
    uintptr_t imgVMLo = UINTPTR_MAX, imgVMHi = 0;

    uintptr_t cur = (uintptr_t)(hdr + 1);
    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cur;
        if (lc->cmdsize == 0) break;                  // 结构异常，别死循环
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            // __PAGEZERO 的 vmaddr 是 0、vmsize 是 4GB，把下限拉成 0 等于白框，
            // 算范围时先把它排掉
            if (strcmp(seg->segname, "__PAGEZERO") != 0 && seg->vmsize > 0) {
                if ((uintptr_t)seg->vmaddr < imgVMLo) imgVMLo = (uintptr_t)seg->vmaddr;
                if ((uintptr_t)seg->vmaddr + (uintptr_t)seg->vmsize > imgVMHi) {
                    imgVMHi = (uintptr_t)seg->vmaddr + (uintptr_t)seg->vmsize;
                }
            }
            if (strcmp(seg->segname, "__TEXT") == 0) { textVM = (uintptr_t)seg->vmaddr; hasText = YES; }
            else if (strcmp(seg->segname, "__LINKEDIT") == 0) { linkedit = seg; }
        } else if (lc->cmd == LC_SYMTAB) {
            symtab = (const struct symtab_command *)lc;
        } else if (lc->cmd == LC_DYSYMTAB) {
            dysymtab = (const struct dysymtab_command *)lc;
        }
        cur += lc->cmdsize;
    }
    if (!hasText || !linkedit || !symtab || !dysymtab) return 0;
    if (imgVMHi <= imgVMLo) return 0;
    if (symtab->nsyms == 0 || dysymtab->nindirectsyms == 0) return 0;

    // header 指向的就是「vmaddr = __TEXT.vmaddr」那一处，反推出镜像基址
    uintptr_t imageBase = (uintptr_t)hdr - textVM;

    // __LINKEDIT 里 symoff/stroff/indirectsymoff 都是文件偏移，
    // 换成运行时地址要减去 fileoff 再加上 vmaddr
    uintptr_t linkBase = imageBase + (uintptr_t)linkedit->vmaddr;
    // symoff 必须落在 __LINKEDIT 里，否则下面的减法会回绕成天文数字
    if (symtab->symoff < linkedit->fileoff) return 0;
    if (symtab->stroff < linkedit->fileoff) return 0;
    if (dysymtab->indirectsymoff < linkedit->fileoff) return 0;

    const struct nlist_64 *syms = (const struct nlist_64 *)(linkBase + (symtab->symoff - linkedit->fileoff));
    const char *strtab = (const char *)(linkBase + (symtab->stroff - linkedit->fileoff));
    const uint32_t *indirect = (const uint32_t *)(linkBase + (dysymtab->indirectsymoff - linkedit->fileoff));
    const uint32_t strtabSize = symtab->strsize;

    if (strtabSize < 2) return 0;
    if (!SLRangeReadable(syms, (size_t)symtab->nsyms * sizeof(struct nlist_64)) ||
        !SLRangeReadable(strtab, strtabSize) ||
        !SLRangeReadable(indirect, (size_t)dysymtab->nindirectsyms * sizeof(uint32_t))) {
        return 0;
    }

    // ---- 第二遍：遍历指针表段 ----
    int hits = 0;
    cur = (uintptr_t)(hdr + 1);
    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cur;
        if (lc->cmdsize == 0) break;
        cur += lc->cmdsize;
        if (lc->cmd != LC_SEGMENT_64) continue;

        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        // arm64e 的认证指针（__AUTH / __AUTH_CONST）写入裸地址会被 PAC 校验拦下，
        // 直接崩。这类段整个跳过 —— 宁可漏挂，不能把宿主搞崩。
        // 但「本来能命中、却被跳过」的槽数必须记下来：不记的话，日志上
        // 「镜像里没这个槽」和「槽在认证段里」长得一模一样，修法却完全不同。
        BOOL isAuthSeg = (strstr(seg->segname, "AUTH") != NULL);

        const struct section_64 *sect = (const struct section_64 *)(seg + 1);
        for (uint32_t s = 0; s < seg->nsects; s++, sect++) {
            uint32_t type = sect->flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;

            uint32_t count = SLSectionSlotCount(sect, dysymtab);
            if (count == 0) continue;

            if (isAuthSeg) {
                // 只读符号表，一个字节都不碰指针槽本身
                for (uint32_t k = 0; k < count; k++) {
                    size_t remain = 0;
                    const char *sname = SLNameAtIndex(indirect[sect->reserved1 + k],
                                                      syms, strtab, strtabSize,
                                                      symtab->nsyms, &remain);
                    if (SLTargetIndexForName(sname, remain) >= 0) (*authSkipped)++;
                }
                continue;
            }

            // sect->addr 必须落在本镜像的 VM 区间内。
            // 图片被裁过 / 结构损坏时这个字段可能是垃圾，落进堆里也照样「可读可写」，
            // 只靠 SLIsReadable 拦不住，所以先用镜像自身的段范围框一遍。
            if ((uintptr_t)sect->addr < imgVMLo) continue;
            if ((uintptr_t)sect->addr + (uintptr_t)sect->size > imgVMHi) continue;

            // 关键：用 VM 地址（sect->addr），不是文件偏移（sect->offset）
            void **slots = (void **)(imageBase + (uintptr_t)sect->addr);
            if (!SLRangeReadable(slots, (size_t)count * sizeof(void *))) continue;

            for (uint32_t k = 0; k < count; k++) {
                size_t remain = 0;
                const char *sname = SLNameAtIndex(indirect[sect->reserved1 + k],
                                                  syms, strtab, strtabSize,
                                                  symtab->nsyms, &remain);
                int t = SLTargetIndexForName(sname, remain);
                if (t < 0) continue;

                void *curAddr = slots[k];
                // 注意：这里到循环体末尾都用 continue，不能用 break ——
                // 一个 section 里可能有多个我们要的符号，break 会漏掉后面的槽
                if (!curAddr || curAddr == sTargets[t].replacement) continue;

                // 先把原函数地址交出去，再改槽 —— 顺序反了会出现
                // 「已经走我们的实现，但 gOrig 还是 NULL」的窗口
                BOOL tookOrig = NO;
                if (!sTargets[t].original) {
                    sTargets[t].original = curAddr;
                    if (sTargets[t].originalOut) *sTargets[t].originalOut = curAddr;
                    tookOrig = YES;
                }

                if (!SLMakeWritable(&slots[k], sizeof(void *))) {
                    // 只读页放不开就放弃，写下去就是闪退。
                    // 只有「这个槽是原函数的来源」时才回收 —— 别的镜像已经成功挂上的话，
                    // 把 original 清空会让我们的实现拿不到原函数，等于把宿主搞坏。
                    if (tookOrig) {
                        if (sTargets[t].originalOut) *sTargets[t].originalOut = NULL;
                        sTargets[t].original = NULL;
                    }
                    SLLog(@"符号: %s 的指针槽不可写，已放弃（%s）", sTargets[t].name, imgName);
                    continue;
                }
                slots[k] = sTargets[t].replacement;
                hits++;
                // 打镜像名：只命中 1 处时，得知道这 1 处在哪个二进制里
                SLLog(@"符号: 命中 %s ← %s", sTargets[t].name, imgName);
            }
        }
    }
    return hits;
}

int SLSymbolHookRescan(void) {
    if (sTargetCount == 0) return 0;

    static int sLogCount = 0;
    int hits = 0;
    int scanned = 0;
    int authSkipped = 0;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const struct mach_header *h = _dyld_get_image_header(i);
        if (!h || h->magic != MH_MAGIC_64) continue;

        // 只扫 App 自己的镜像（主程序 + 内嵌 framework/SDK）。
        // 系统库在 dyld 共享缓存里，布局跟文件偏移对不上，碰它只会崩。
        const char *path = _dyld_get_image_name(i);
        if (!path || !strstr(path, ".app/")) continue;

        const char *slash = strrchr(path, '/');
        const char *base = slash ? slash + 1 : path;

        scanned++;
        hits += SLScanImage((const struct mach_header_64 *)h, base, &authSkipped);
    }
    // 每次会话加输出都会补扫一次，别把日志刷满：有命中/有认证槽跳过就必记，
    // 什么都没有的只记前三次
    if (hits > 0 || authSkipped > 0 || sLogCount++ < 3) {
        SLLog(@"符号: 扫过 %d 个 App 镜像，命中 %d 处，认证 GOT 跳过 %d 处",
              scanned, hits, authSkipped);
    }
    return hits;
}

int SLSymbolHook(const char *name, void *replacement, void **original) {
    if (!name || !replacement) return 0;

    for (int i = 0; i < sTargetCount; i++) {
        if (strcmp(sTargets[i].name, name) == 0) {
            // 已注册过：只补扫（后加载的镜像可能刚进来）
            int hits = SLSymbolHookRescan();
            if (original) *original = sTargets[i].original;
            return hits;
        }
    }

    if (sTargetCount >= SL_MAX_TARGETS) return 0;

    SLTarget *t = &sTargets[sTargetCount++];
    t->name = name;
    t->replacement = replacement;
    t->original = NULL;
    t->originalOut = original;

    int hits = SLSymbolHookRescan();
    if (original) *original = t->original;
    return hits;
}
