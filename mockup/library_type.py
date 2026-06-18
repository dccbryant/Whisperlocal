#!/usr/bin/env python3
"""Typographic redesign mockup of Parley's Library list. Braun palette + metrics."""
from PIL import Image, ImageDraw, ImageFont

S = 3                      # @3x render
def u(pt): return round(pt * S)

# ---- Braun palette (from DesignSystem.swift) ----
BG       = (241, 236, 223)
SURFACE  = (232, 226, 210)
FG       = (37, 37, 37)
SECOND   = (111, 106, 97)
DIVIDER  = (199, 190, 170)
ACCENT   = (231, 74, 28)
FAINT    = (165, 158, 143)   # between secondary and divider, for the lightest meta

REG  = "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf"
BOLD = "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf"
def font(path, pt): return ImageFont.truetype(path, u(pt))

f_title  = font(BOLD, 15)
f_prev   = font(REG, 13.5)
f_date   = font(REG, 11)
f_label  = font(BOLD, 10)
f_meta   = font(REG, 10)
f_time   = font(BOLD, 14)
f_search = font(REG, 15)

W, H = u(390), u(852)
img = Image.new("RGB", (W, H), BG)
d = ImageDraw.Draw(img)

L = u(24)            # left margin
R = u(390 - 24)      # right margin
PREV_W = R - L

def tracked(x, baseline, text, fnt, fill, track_pt):
    """Draw text char-by-char with letter-spacing; returns end x."""
    t = u(track_pt)
    cx = x
    for ch in text:
        d.text((cx, baseline), ch, font=fnt, fill=fill, anchor="ls")
        cx += d.textlength(ch, font=fnt) + t
    return cx

def tracked_w(text, fnt, track_pt):
    t = u(track_pt)
    return sum(d.textlength(ch, font=fnt) + t for ch in text) - t

def wrap(text, fnt, max_w, max_lines):
    words, lines, cur = text.split(), [], ""
    for w in words:
        test = (cur + " " + w).strip()
        if d.textlength(test, font=fnt) <= max_w:
            cur = test
        else:
            if cur: lines.append(cur)
            cur = w
            if len(lines) == max_lines: break
    if cur and len(lines) < max_lines: lines.append(cur)
    lines = lines[:max_lines]
    if len(" ".join(lines)) < len(text):       # truncated -> ellipsis
        last = lines[-1]
        while d.textlength(last + "…", font=fnt) > max_w and last:
            last = last.rsplit(" ", 1)[0] if " " in last else last[:-1]
        lines[-1] = last + "…"
    return lines

# ---------- status bar ----------
am, ad = f_time.getmetrics()
d.text((L, u(34)), "9:41", font=f_time, fill=FG, anchor="ls")
# battery
bw, bh = u(24), u(11)
bx, by = R - bw, u(24)
d.rounded_rectangle([bx, by, bx + bw, by + bh], radius=u(3), outline=FG, width=max(1, u(1)))
d.rounded_rectangle([bx + u(2), by + u(2), bx + bw - u(4), by + bh - u(2)], radius=u(1), fill=FG)
d.rectangle([bx + bw, by + u(3), bx + bw + u(2), by + bh - u(3)], fill=FG)

# ---------- nav bar ----------
nav_base = u(86)
# back chevron
cx, cyc, ch_ = L + u(4), nav_base - u(5), u(7)
d.line([(cx + u(6), cyc - ch_), (cx, cyc), (cx + u(6), cyc + ch_)], fill=FG, width=u(1.6))
# centered LIBRARY label
lib = "LIBRARY"
lw = tracked_w(lib, f_label, 2.4)
tracked((W - lw) // 2, nav_base, lib, f_label, SECOND, 2.4)
# import glyph (tray with down arrow) at right
ix, iy = R - u(16), nav_base - u(8)
d.line([(ix + u(8), iy - u(2)), (ix + u(8), iy + u(9))], fill=FG, width=u(1.6))
d.line([(ix + u(4), iy + u(5)), (ix + u(8), iy + u(9)), (ix + u(12), iy + u(5))], fill=FG, width=u(1.6))
d.line([(ix, iy + u(11)), (ix, iy + u(14)), (ix + u(16), iy + u(14)), (ix + u(16), iy + u(11))], fill=FG, width=u(1.6))

# ---------- search field ----------
sy0, sh = u(108), u(46)
d.rounded_rectangle([L, sy0, R, sy0 + sh], radius=u(13), fill=SURFACE)
# magnifier
mx, my, mr = L + u(18), sy0 + sh // 2, u(6)
d.ellipse([mx - mr, my - mr, mx + mr, my + mr], outline=SECOND, width=u(1.4))
d.line([(mx + u(4), my + u(4)), (mx + u(8), my + u(8))], fill=SECOND, width=u(1.4))
sm_a, sm_d = f_search.getmetrics()
d.text((L + u(36), my + sm_a // 2 - u(1)), "Search recordings", font=f_search, fill=FAINT, anchor="lm")

# ---------- helpers for list ----------
def section(y, text):
    a, dd = f_label.getmetrics()
    tracked(L, y + a, text, f_label, SECOND, 2.4)
    return y + a + dd

def hairline(y):
    d.line([(L, y), (R, y)], fill=DIVIDER, width=max(1, u(0.7)))

def row(y, title, date, preview, meta):
    y += u(18)                                    # top padding
    ta, td = f_title.getmetrics()
    base = y + ta
    d.text((L, base), title, font=f_title, fill=FG, anchor="ls")
    d.text((R, base), date, font=f_date, fill=SECOND, anchor="rs")
    y = base + td + u(9)                          # title -> preview
    pa, pd = f_prev.getmetrics()
    for line in wrap(preview, f_prev, PREV_W, 2):
        d.text((L, y + pa), line, font=f_prev, fill=SECOND, anchor="ls")
        y += u(20)                                # consistent leading
    y += u(8)                                     # preview -> meta
    ma, md = f_meta.getmetrics()
    tracked(L, y + ma, meta, f_meta, FAINT, 1.0)
    y = y + ma + md + u(18)                       # bottom padding
    hairline(y)
    return y

# ---------- content ----------
y = u(176)
y = section(y, "YESTERDAY"); y += u(14)
y = row(y, "Model Trade-Off Discussion", "6:33 PM",
        "The speaker discusses a trade-off between model performance and time investment. They illustrate the cost of over-engineering.",
        "2:05   ·   1 SPEAKER")
y = row(y, "Adi Joins the DevOps Team", "11:30 AM",
        "The team discusses weekend coverage and GEOs, and the potential addition of Adi for increased capacity.",
        "27:55   ·   5 SPEAKERS")

y += u(22)
y = section(y, "THIS MONTH"); y += u(14)
y = row(y, "AI Market Shift & Subscription Challenges", "Jun 13",
        "The conversation covers the transition from subscriptions to tokens for pricing AI services, emphasizing margin pressure.",
        "1:09:52   ·   7 SPEAKERS")
y = row(y, "Quantum Tech Event Planning", "Jun 13",
        "A team develops a quantum-focused event, emphasizing a shared vision and a clear go-to-market strategy.",
        "50:50   ·   7 SPEAKERS")

# home indicator
hi_w = u(134)
d.rounded_rectangle([(W - hi_w)//2, H - u(10), (W + hi_w)//2, H - u(6)], radius=u(2), fill=(80,77,70))

img.save("/home/user/Whisperlocal/mockup/library_after.png")
print("saved", img.size)
