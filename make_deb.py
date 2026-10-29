#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 theos 构建产物（dylib + filter plist + control）打包成 iOS 越狱 deb。
不依赖 dpkg / theos，纯 Python 生成 ar + tar.gz。

用法:
  python make_deb.py --control <control文件> --name <dylib名> \
      --dylib <dylib路径> --plist <plist路径> --out <输出deb>
"""
import argparse
import io
import os
import tarfile

MAGIC = b"!<arch>\n"


def _ar_member(name: str, data: bytes) -> bytes:
    header = (
        name.ljust(16)
        + "0".ljust(12)      # mtime
        + "0".ljust(6)       # uid
        + "0".ljust(6)       # gid
        + "100644".ljust(8)  # mode
        + str(len(data)).ljust(10)
        + "`\n"
    ).encode("ascii")
    out = header + data
    if len(out) % 2:
        out += b"\n"
    return out


def _make_tar(entries) -> bytes:
    """entries: list of (arcname, local_path, mode)"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz", format=tarfile.GNU_FORMAT) as tf:
        dirs = set()
        for arcname, path, mode in entries:
            parent = os.path.dirname(arcname)
            while parent and parent not in dirs:
                dirs.add(parent)
                parent = os.path.dirname(parent)
        for d in sorted(dirs):
            ti = tarfile.TarInfo("./" + d)
            ti.type = tarfile.DIRTYPE
            ti.mode = 0o755
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            ti.mtime = 0
            tf.addfile(ti)
        for arcname, path, mode in entries:
            ti = tarfile.TarInfo("./" + arcname)
            ti.size = os.path.getsize(path)
            ti.mode = mode
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            ti.mtime = 0
            with open(path, "rb") as f:
                tf.addfile(ti, f)
    return buf.getvalue()


def build_deb(control_path, entries, out_path):
    with open(control_path, "r", encoding="utf-8") as f:
        control = f.read().rstrip("\n") + "\n"

    ctl_buf = io.BytesIO()
    with tarfile.open(fileobj=ctl_buf, mode="w:gz", format=tarfile.GNU_FORMAT) as tf:
        data = control.encode("utf-8")
        ti = tarfile.TarInfo("./control")
        ti.size = len(data)
        ti.mode = 0o644
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = "root"
        ti.mtime = 0
        tf.addfile(ti, io.BytesIO(data))

    deb = MAGIC
    deb += _ar_member("debian-binary", b"2.0\n")
    deb += _ar_member("control.tar.gz", ctl_buf.getvalue())
    deb += _ar_member("data.tar.gz", _make_tar(entries))

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "wb") as f:
        f.write(deb)
    return out_path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--control", required=True)
    ap.add_argument("--dylib", required=True)
    ap.add_argument("--plist", required=True)
    ap.add_argument("--dylib-name", required=True, help="安装后的 dylib 文件名(含后缀)")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    base = "Library/MobileSubstrate/DynamicLibraries"
    entries = [
        (f"{base}/{args.dylib_name}", args.dylib, 0o755),
        (f"{base}/{os.path.splitext(args.dylib_name)[0]}.plist", args.plist, 0o644),
    ]
    path = build_deb(args.control, entries, args.out)
    print(f"[OK] {path}  ({os.path.getsize(path)} bytes)")


if __name__ == "__main__":
    main()
