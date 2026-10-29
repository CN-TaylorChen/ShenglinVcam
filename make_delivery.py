#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 deliveries/vX/ShenglinVcam-vX/ 里的产物整理成带版本号的交付文件。

约定（用户 2026-10-27 提出）：分享出去的 dylib 文件名必须带版本号，
避免多版本混在一起分不清。plist 必须与 dylib 同名配对，substrate
按同名反查，所以两者一起带版本号，可直接丢进 DynamicLibraries。

用法:
    python make_delivery.py            # 版本从 control 读
    python make_delivery.py 0.4.23     # 指定版本
"""
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
CTRL = os.path.join(ROOT, "control")


def read_version():
    with open(CTRL, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            m = re.match(r"\s*Version:\s*(\S+)", line)
            if m:
                return m.group(1)
    raise SystemExit("control 里找不到 Version:")


def main():
    ver = sys.argv[1] if len(sys.argv) > 1 else read_version()
    src_dir = os.path.join(ROOT, "deliveries", "v%s" % ver, "ShenglinVcam-v%s" % ver)
    if not os.path.isdir(src_dir):
        raise SystemExit("产物目录不存在: %s" % src_dir)

    out_dir = os.path.join(ROOT, "deliveries", "v%s" % ver, "share")
    os.makedirs(out_dir, exist_ok=True)

    pairs = [("ShenglinVcam.dylib", "ShenglinVcam-v%s.dylib" % ver),
             ("ShenglinVcam.plist", "ShenglinVcam-v%s.plist" % ver),
             ("ShenglinVcam-v%s.deb" % ver, "ShenglinVcam-v%s.deb" % ver)]

    made = []
    for src_name, dst_name in pairs:
        src = os.path.join(src_dir, src_name)
        if not os.path.isfile(src):
            print("  跳过（不存在）: %s" % src_name)
            continue
        dst = os.path.join(out_dir, dst_name)
        shutil.copy2(src, dst)
        made.append((dst, os.path.getsize(dst)))

    print("版本 %s 交付文件 -> %s" % (ver, out_dir))
    for p, sz in made:
        print("  %-34s %8.1f KB" % (os.path.basename(p), sz / 1024.0))
    print("\n安装：dylib 与 plist 同名配对，两个一起放进")
    print("  /Library/MobileSubstrate/DynamicLibraries/")
    print("  然后 respring。deb 仍是完整包（推荐用 deb 装）。")


if __name__ == "__main__":
    main()
