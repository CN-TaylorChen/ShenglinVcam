//
//  SLCamSymbolHook.m
//  声临 · 虚拟摄像头 —— C 函数 hook（fishhook 精简版）
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

/// 指针表所在的页多半是只读的（__DATA_CONST），改之前先放开写权限。
/// VM_PROT_COPY 是必须的：iOS 的 COW 页不改它直接写会崩。
static void SLMakeWritable(void *addr, size_t len) {
    vm_size_t pageSize = (vm_size_t)getpagesize();
    uintptr_t start = (uintptr_t)addr & ~(uintptr_t)(pageSize - 1);
    uintptr_t end = ((uintptr_t)addr + len + pageSize - 1) & ~(uintptr_t)(pageSize - 1);
    vm_protect(mach_task_self(), (vm_address_t)start, (vm_size_t)(end - start), false,
               VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
}

static int SLScanImage(const struct mach_header_64 *hdr) {
    const uint8_t *base = (const uint8_t *)hdr;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;

    uintptr_t cur = (uintptr_t)(hdr + 1);
    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cur;
        if (lc->cmd == LC_SYMTAB) {
            symtab = (const struct symtab_command *)lc;
        } else if (lc->cmd == LC_DYSYMTAB) {
            dysymtab = (const struct dysymtab_command *)lc;
        }
        cur += lc->cmdsize;
    }
    if (!symtab || !dysymtab) return 0;

    const char *strtab = (const char *)(base + symtab->stroff);
    const struct nlist_64 *syms = (const struct nlist_64 *)(base + symtab->symoff);
    const uint32_t *indirect = (const uint32_t *)(base + dysymtab->indirectsymoff);

    int hits = 0;
    cur = (uintptr_t)(hdr + 1);
    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cur;
        cur += lc->cmdsize;
        if (lc->cmd != LC_SEGMENT_64) continue;

        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        // arm64e 的认证指针（__AUTH / __AUTH_CONST）写入裸地址会被 PAC 校验拦下，
        // 直接崩。这类段整个跳过 —— 宁可漏挂，不能把宿主搞崩。
        if (strstr(seg->segname, "AUTH") != NULL) continue;

        const struct section_64 *sect = (const struct section_64 *)(seg + 1);
        for (uint32_t s = 0; s < seg->nsects; s++, sect++) {
            uint32_t type = sect->flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;

            uint32_t count = (uint32_t)(sect->size / sizeof(void *));
            void **slots = (void **)(base + sect->offset);

            for (uint32_t k = 0; k < count; k++) {
                uint32_t symIdx = indirect[sect->reserved1 + k];
                if (symIdx == INDIRECT_SYMBOL_LOCAL || symIdx == INDIRECT_SYMBOL_ABS) continue;
                if (symIdx == 0) continue;

                const char *sname = strtab + syms[symIdx].n_un.n_strx;
                if (!sname || !*sname) continue;
                if (sname[0] == '_') sname++;      // Mach-O 符号带前导下划线

                for (int t = 0; t < sTargetCount; t++) {
                    if (strcmp(sname, sTargets[t].name) != 0) continue;

                    void *curAddr = slots[k];
                    if (curAddr == sTargets[t].replacement) break;   // 已经换过了
                    if (!curAddr) break;

                    // 先把原函数地址交出去，再改槽 —— 顺序反了会出现
                    // 「已经走我们的实现，但 gOrig 还是 NULL」的窗口
                    if (!sTargets[t].original) {
                        sTargets[t].original = curAddr;
                        if (sTargets[t].originalOut) *sTargets[t].originalOut = curAddr;
                    }

                    SLMakeWritable(&slots[k], sizeof(void *));
                    slots[k] = sTargets[t].replacement;
                    hits++;
                    break;
                }
            }
        }
    }
    return hits;
}

int SLSymbolHookRescan(void) {
    if (sTargetCount == 0) return 0;
    int hits = 0;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const struct mach_header *h = _dyld_get_image_header(i);
        if (!h || h->magic != MH_MAGIC_64) continue;
        hits += SLScanImage((const struct mach_header_64 *)h);
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
