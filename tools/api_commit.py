#!/usr/bin/env python3
"""通过 GitHub Git Data API 提交多个文件改动（本机 git push 被代理阻断时的替代路径）。

用法：
  python tools/api_commit.py "提交说明" 文件1 文件2 ...
  删除文件用前缀 DEL:，例如 DEL:path/to/gone.txt
"""
import base64
import json
import os
import subprocess
import sys

REPO = "CN-TaylorChen/ShenglinVcam"
GH = r"D:\tools\gh\bin\gh.exe"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def api(method, path, payload=None):
    cmd = [GH, "api", "-X", method, path]
    data = None
    if payload is not None:
        cmd += ["--input", "-"]
        data = json.dumps(payload)
    r = subprocess.run(cmd, input=data, capture_output=True, text=True)
    if r.returncode != 0:
        print("FAILED:", method, path)
        print(r.stderr)
        sys.exit(1)
    out = r.stdout.strip()
    return json.loads(out) if out else {}


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    message = sys.argv[1]
    targets = sys.argv[2:]

    ref = api("GET", "/repos/%s/git/ref/heads/main" % REPO)
    parent = ref["object"]["sha"]
    base_tree = api("GET", "/repos/%s/git/commits/%s" % (REPO, parent))["tree"]["sha"]
    print("parent:", parent)

    tree = []
    for t in targets:
        if t.startswith("DEL:"):
            rel = t[4:]
            tree.append({"path": rel, "mode": "100644", "type": "blob", "sha": None})
            print("delete", rel)
            continue
        rel = t
        full = os.path.join(ROOT, rel.replace("/", os.sep))
        with open(full, "rb") as f:
            content = f.read().replace(b"\r\n", b"\n")
        blob = api("POST", "/repos/%s/git/blobs" % REPO,
                   {"content": base64.b64encode(content).decode(), "encoding": "base64"})
        tree.append({"path": rel, "mode": "100644", "type": "blob", "sha": blob["sha"]})
        print("blob %-32s %7d  %s" % (rel, len(content), blob["sha"][:8]))

    new_tree = api("POST", "/repos/%s/git/trees" % REPO, {"base_tree": base_tree, "tree": tree})
    commit = api("POST", "/repos/%s/git/commits" % REPO, {
        "message": message,
        "tree": new_tree["sha"],
        "parents": [parent],
    })
    api("PATCH", "/repos/%s/git/refs/heads/main" % REPO, {"sha": commit["sha"], "force": False})
    print("new commit:", commit["sha"])


if __name__ == "__main__":
    main()
