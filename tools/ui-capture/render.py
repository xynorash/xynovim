#!/usr/bin/env python3
"""ANSI (tmux capture-pane -ep) -> PNG with the installed JetBrainsMono Nerd Font Mono.
usage: render.py in.ansi out.png [default_bg_hex]"""
import sys, re, unicodedata, math
from PIL import Image, ImageDraw, ImageFont
inp, out = sys.argv[1], sys.argv[2]
DEF_BG = sys.argv[3] if len(sys.argv) > 3 else "#1e1f22"
DEF_FG = "#bcbec4"
D = "/usr/share/fonts/TTF/JetBrainsMonoNerdFontMono-"
SZ = 16
fonts = {(b, i): ImageFont.truetype(D + {(0,0):"Regular",(1,0):"Bold",(0,1):"Italic",(1,1):"BoldItalic"}[(b,i)] + ".ttf", SZ) for b in (0,1) for i in (0,1)}
CW = round(fonts[(0,0)].getlength("M")); asc, desc = fonts[(0,0)].getmetrics(); CH = asc + desc + 2
def hexrgb(h): return tuple(int(h[i:i+2],16) for i in (1,3,5))
ANSI16 = ["#1e1f22","#fa6675","#5fad65","#e5c07b","#56a8f5","#c77dba","#2aacb8","#bcbec4","#4b5059","#fa6675","#5fad65","#e5c07b","#56a8f5","#c77dba","#2aacb8","#ffffff"]
def c256(n):
    if n < 16: return hexrgb(ANSI16[n])
    if n < 232:
        n -= 16; r,g,b = n//36, (n//6)%6, n%6
        f = lambda x: 0 if x==0 else 55+40*x
        return (f(r),f(g),f(b))
    v = 8+10*(n-232); return (v,v,v)
lines = open(inp, encoding="utf-8").read().split("\n")
while lines and lines[-1] == "": lines.pop()
rows = []
sgr = re.compile(r"\x1b\[([0-9:;]*)m")
for ln in lines:
    st = dict(fg=None,bg=None,b=0,i=0,u=0,uc=None,rev=0,dim=0)
    cells = []
    pos = 0
    for m in re.finditer(r"\x1b\[([0-9:;]*)m|([^\x1b]+)|\x1b\[[0-9;?]*[A-Za-z]", ln):
        if m.group(2) is not None:
            for ch in m.group(2):
                w = 2 if unicodedata.east_asian_width(ch) in ("W","F") else (0 if unicodedata.combining(ch) or ch in "︎️‍" else 1)
                if w == 0:
                    continue
                cells.append((ch, dict(st), w))
            continue
        if m.group(1) is None: continue
        p = m.group(1)
        if p == "": p = "0"
        parts = p.split(";")
        k = 0
        while k < len(parts):
            a = parts[k]
            if ":" in a:
                sub = a.split(":")
                if sub[0] == "4": st["u"] = int(sub[1]) if len(sub)>1 and sub[1] else 1
                elif sub[0] in ("38","48","58"):
                    vals = [int(x) for x in sub[1:] if x != ""]
                    if vals and vals[0] == 2:
                        rgb = tuple(vals[-3:])
                    elif vals and vals[0] == 5: rgb = c256(vals[1])
                    else: rgb = None
                    key = {"38":"fg","48":"bg","58":"uc"}[sub[0]]; st[key] = rgb
                k += 1; continue
            n = int(a)
            if n == 0: st = dict(fg=None,bg=None,b=0,i=0,u=0,uc=None,rev=0,dim=0)
            elif n == 1: st["b"] = 1
            elif n == 2: st["dim"] = 1
            elif n == 3: st["i"] = 1
            elif n == 4: st["u"] = 1
            elif n == 7: st["rev"] = 1
            elif n == 9: pass
            elif n == 21: st["u"] = 2
            elif n in (22,): st["b"] = 0; st["dim"] = 0
            elif n == 23: st["i"] = 0
            elif n == 24: st["u"] = 0
            elif n == 27: st["rev"] = 0
            elif 30 <= n <= 37: st["fg"] = hexrgb(ANSI16[n-30])
            elif 90 <= n <= 97: st["fg"] = hexrgb(ANSI16[n-90+8])
            elif 40 <= n <= 47: st["bg"] = hexrgb(ANSI16[n-40])
            elif 100 <= n <= 107: st["bg"] = hexrgb(ANSI16[n-100+8])
            elif n == 39: st["fg"] = None
            elif n == 49: st["bg"] = None
            elif n == 59: st["uc"] = None
            elif n in (38,48,58):
                if parts[k+1] == "2": rgb = tuple(int(x) for x in parts[k+2:k+5]); k += 4
                else: rgb = c256(int(parts[k+2])); k += 2
                st[{38:"fg",48:"bg",58:"uc"}[n]] = rgb
                k += 1; k -= 0
            k += 1
    rows.append(cells)
W = max((sum(c[2] for c in r) for r in rows), default=1)
W = max(W, int(sys.argv[4]) if len(sys.argv) > 4 else 1)
img = Image.new("RGB", (W*CW, len(rows)*CH), hexrgb(DEF_BG))
dr = ImageDraw.Draw(img)
for y, r in enumerate(rows):
    x = 0
    for ch, st, w in r:
        fg = st["fg"] or hexrgb(DEF_FG); bg = st["bg"] or hexrgb(DEF_BG)
        if st["rev"]: fg, bg = bg, fg
        if st["dim"]: fg = tuple((a+b)//2 for a,b in zip(fg,bg))
        X, Y = x*CW, y*CH
        if bg != hexrgb(DEF_BG) or st["rev"]:
            dr.rectangle([X, Y, X+w*CW-1, Y+CH-1], fill=bg)
        if ch != " ":
            dr.text((X, Y+1), ch, font=fonts[(st["b"], st["i"])], fill=fg)
        if st["u"]:
            col = st["uc"] or fg
            yy = Y + CH - 3
            s = st["u"]
            if s == 3:
                for dx in range(w*CW):
                    dr.point((X+dx, yy + round(1.5*math.sin(dx*2*math.pi/6))), fill=col)
            elif s == 5:
                for dx in range(w*CW):
                    if (dx // 4) % 2 == 0: dr.point((X+dx, yy), fill=col)
            elif s == 4:
                for dx in range(w*CW):
                    if dx % 3 == 0: dr.point((X+dx, yy), fill=col)
            elif s == 2:
                dr.line([X, yy, X+w*CW-1, yy], fill=col); dr.line([X, yy-2, X+w*CW-1, yy-2], fill=col)
            else:
                dr.line([X, yy, X+w*CW-1, yy], fill=col)
        x += w
img.save(out)
print(out, img.size)
