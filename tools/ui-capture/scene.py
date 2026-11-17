#!/usr/bin/env python3
"""Needs a throw-away crate in tools/ui-capture/crate (see docs/comparison/screenshots/ui/README.md).
scene.py NAME CFG(before|after) COLS ROWS [--file F] [--keys 'k1|k2'] [--wait 'text'] [--env K=V ...] [--cmd 'nvim args']
Starts nvim in a private tmux server, waits for text, sends keys, captures ANSI + text, renders PNG."""
import subprocess, sys, time, os, argparse, shutil
HERE = os.path.dirname(os.path.abspath(__file__))
ap = argparse.ArgumentParser()
ap.add_argument("name"); ap.add_argument("cfg"); ap.add_argument("cols", type=int); ap.add_argument("rows", type=int)
ap.add_argument("--file", default="src/main.rs"); ap.add_argument("--keys", default="")
ap.add_argument("--wait", action="append", default=[]); ap.add_argument("--env", action="append", default=[])
ap.add_argument("--after-keys", default=""); ap.add_argument("--wait2", action="append", default=[])
ap.add_argument("--timeout", type=int, default=100); ap.add_argument("--out", default=HERE + "/out")
ap.add_argument("--nvimargs", default=""); ap.add_argument("--dir", default="crate")
a = ap.parse_args()
os.makedirs(a.out, exist_ok=True)
sock = "uicap-" + a.name.replace("/", "_")
def tm(*args, **kw):
    return subprocess.run(["tmux", "-L", sock, *args], capture_output=True, text=True, **kw)
xdg = f"{HERE}/xdg-{a.cfg}"
os.makedirs(xdg + "/cfg", exist_ok=True)
for d in ("state", "cache"):
    shutil.rmtree(f"{xdg}/{d}", ignore_errors=True); os.makedirs(f"{xdg}/{d}")
link = xdg + "/cfg/nvim"
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
target = f"{HERE}/before" if a.cfg == "before" else REPO  # "before": git archive <commit> | tar -x -C tools/ui-capture/before
if os.path.islink(link): os.unlink(link)
os.symlink(target, link)
proj = f"{HERE}/{a.dir}"
env = {"XDG_CONFIG_HOME": xdg + "/cfg", "XDG_STATE_HOME": xdg + "/state", "XDG_CACHE_HOME": xdg + "/cache",
       "TERM": "tmux-256color", "COLORTERM": "truecolor"}
for e in a.env:
    k, v = e.split("=", 1); env[k] = v
envs = " ".join(f"{k}={v}" for k, v in env.items())
tm("kill-server")
r = tm("-f", "/dev/null", "new-session", "-d", "-x", str(a.cols), "-y", str(a.rows), "-c", proj)
if r.returncode: print(r.stderr); sys.exit(1)
tm("set", "-g", "status", "off"); tm("set", "-g", "escape-time", "0")
tm("set", "-as", "terminal-features", ",*:RGB:usstyle")
tm("send-keys", "-t", "0", f"cd {proj} && env {envs} nvim {a.nvimargs} {a.file}", "Enter")
def cap(ansi=False):
    args = ["capture-pane", "-p", "-t", "0"] + (["-e"] if ansi else [])
    return tm(*args).stdout
def wait_for(needles, timeout):
    t0 = time.time()
    while time.time() - t0 < timeout:
        txt = cap()
        if all(n in txt for n in needles): return True
        time.sleep(1)
    return False
ok = True
if a.wait: ok = wait_for(a.wait, a.timeout)
print("wait1", ok, file=sys.stderr)
if a.keys:
    for k in a.keys.split("|"):
        if k.startswith("S:"): time.sleep(float(k[2:]))
        else: tm("send-keys", "-t", "0", *k.split(" "))
        time.sleep(0.4)
if a.wait2: ok2 = wait_for(a.wait2, a.timeout); print("wait2", ok2, file=sys.stderr)
time.sleep(2.5)
ansi = cap(True)
open(f"{a.out}/{a.name}.ansi", "w").write(ansi)
open(f"{a.out}/{a.name}.txt", "w").write(cap())
tm("kill-server")
subprocess.run(["python3", HERE + "/render.py", f"{a.out}/{a.name}.ansi", f"{a.out}/{a.name}.png", "#1e1f22", str(a.cols)])
