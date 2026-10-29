#!/usr/bin/env python3
# precheck.py - local gate run before every push, and again in CI (with --skip-version).
# Goal: catch the deterministic -Werror failures we kept shipping, so each push maps to
# exactly one build and the Actions history stays clean.
import re, sys, os, json, base64, subprocess

GH = r"D:/tools/gh/bin/gh.exe"
REPO = "CN-TaylorChen/ShenglinVcam"
BASE = os.path.dirname(os.path.abspath(__file__))
SKIP_VERSION = "--skip-version" in sys.argv

errors = []
def fail(rule, where, detail):
    errors.append("[FAIL] %-22s %-40s %s" % (rule, where, detail))

def src_files():
    out = []
    d = os.path.join(BASE, "Tweak")
    if os.path.isdir(d):
        for f in os.listdir(d):
            if f.endswith((".m", ".h", ".x")):
                out.append(os.path.join(d, f))
    return out

def strip_comments_strings(s):
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    s = re.sub(r"//[^\n]*", "", s)
    s = re.sub(r'"(?:\\.|[^"\\])*"', '""', s)
    s = re.sub(r"'(?:\\.|[^'\\])*'", "''", s)
    return s

# 1) ARC copy/alloc/new/init/mutableCopy/autorelease method-family property names.
#    A property named e.g. copyBtn makes ARC synthesize a getter `copyBtn` that collides
#    with the copy method family -> compile error under -Werror.
COPY_FAMILY = ("copy", "mutableCopy", "autorelease", "new", "alloc", "init")
for fp in src_files():
    for i, line in enumerate(open(fp, encoding="utf-8", errors="ignore"), 1):
        if "@property" not in line:
            continue
        m = re.search(r"(\w+)\s*;", line)
        # ARC method families require the keyword to be followed by an uppercase letter
        # or end-of-name (e.g. copyBtn -> "copyB" collides; initialCoord -> "initi" does not).
        if m and re.match(r"^(init|copy|mutableCopy|new|alloc|autorelease)(?=[A-Z]|$)", m.group(1)):
            fail("ARC-copy-family", "%s:%d" % (os.path.basename(fp), i),
                 "property '%s' collides with an ARC method family" % m.group(1))

# 2) @available(...) missing the trailing '*' (common copy-paste break).
for fp in src_files():
    for i, line in enumerate(open(fp, encoding="utf-8", errors="ignore"), 1):
        for m in re.finditer(r"@available\(([^)]*)\)", line):
            if "*" not in m.group(1):
                fail("@available-star", "%s:%d" % (os.path.basename(fp), i),
                     "@available(%s) missing '*'" % m.group(1))

# 5) version gate: only on the local machine, never in CI (CI already has the new version
#    on main by the time it runs, so comparing against main would always "fail").
def local_version():
    for line in open(os.path.join(BASE, "control"), encoding="utf-8"):
        m = re.match(r"^Version:\s*(\S+)", line)
        if m:
            return m.group(1)
    return None

def main_version():
    try:
        r = subprocess.run([GH, "api", "repos/%s/contents/control?ref=main" % REPO],
                           capture_output=True, text=True)
        if r.returncode != 0:
            return None
        j = json.loads(r.stdout)
        txt = base64.b64decode(j["content"]).decode("utf-8")
        m = re.search(r"^Version:\s*(\S+)", txt, re.M)
        return m.group(1) if m else None
    except Exception:
        return None

def ver_tuple(v):
    return tuple(int(x) for x in v.split("."))

if not SKIP_VERSION:
    lv, mv = local_version(), main_version()
    if lv is None:
        fail("version", "control", "cannot read local version")
    elif mv is not None:
        try:
            if ver_tuple(lv) <= ver_tuple(mv):
                fail("version-bump", "control",
                     "local %s <= main %s - bump the version before pushing" % (lv, mv))
        except Exception:
            pass

if errors:
    print("\n".join(errors))
    print("\nPRECHECK FAILED (%d issue(s)). Push aborted." % len(errors))
    sys.exit(1)
print("PRECHECK OK")
sys.exit(0)
