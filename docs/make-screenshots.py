#!/usr/bin/env python3
"""Render the README screenshots from statusline.sh's real output.

The script runs against synthetic data only: a throwaway HOME and config
directory, a fresh usage cache (so no API call is made), and a fake transcript
with two compactions and an ultracode record. Its ANSI output is drawn cell by
cell into a PNG with a pixel font and no anti-aliasing, the way a terminal
without anti-aliasing draws it.

  docs/make-screenshots.py [path/to/font.ttf]

Without an argument it uses the first unscii TTF fontconfig finds: unscii-mod
(mod-16-full, the font the published screenshots were made with), then the
stock unscii 16-full.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unicodedata
from datetime import datetime, timedelta, timezone
from pathlib import Path

from fontTools.pens.pointInsidePen import PointInsidePen
from fontTools.ttLib import TTFont
from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "statusline.sh"
CELL_W, CELL_H, PX = 8, 16, 16
SCALE = 2
PAD = 8
BG = (35, 35, 38)
FG = (204, 204, 204)


def find_font():
    if len(sys.argv) > 1:
        return sys.argv[1]
    for pattern in ("unscii\\-mod:style=mod-16-full", "unscii:style=16-full"):
        r = subprocess.run(["fc-match", "-f", "%{file}", pattern], capture_output=True, text=True)
        if r.stdout.endswith((".ttf", ".otf")) and "unscii" in r.stdout:
            return r.stdout
    sys.exit("unscii TTF not found; pass a font path")


def xterm256(n):
    base16 = [(0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0), (0, 0, 238), (205, 0, 205),
              (0, 205, 205), (229, 229, 229), (127, 127, 127), (255, 0, 0), (0, 255, 0),
              (255, 255, 0), (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255)]
    if n < 16:
        return base16[n]
    if n < 232:
        n -= 16
        steps = [0, 95, 135, 175, 215, 255]
        return steps[n // 36], steps[n // 6 % 6], steps[n % 6]
    v = 8 + (n - 232) * 10
    return v, v, v


def parse(ansi):
    """ANSI text -> list of cells (char, fg, bg); wide characters take two."""
    cells, fg, bg = [], FG, BG
    for tok in re.split(r"(\x1b\[[0-9;]*m)", ansi):
        m = re.fullmatch(r"\x1b\[([0-9;]*)m", tok)
        if m:
            p = [int(x) if x else 0 for x in m.group(1).split(";")]
            i = 0
            while i < len(p):
                if p[i] == 0:
                    fg, bg = FG, BG
                elif p[i] in (38, 48) and p[i + 1] == 5:
                    c = xterm256(p[i + 2])
                    fg, bg = (c, bg) if p[i] == 38 else (fg, c)
                    i += 2
                elif p[i] in (38, 48) and p[i + 1] == 2:
                    c = tuple(p[i + 2:i + 5])
                    fg, bg = (c, bg) if p[i] == 38 else (fg, c)
                    i += 4
                i += 1
            continue
        for ch in tok:
            wide = unicodedata.east_asian_width(ch) in ("W", "F")
            cells.append((ch, fg, bg, 2 if wide else 1))
            if wide:
                cells.append(("", fg, bg, 0))
    return cells


class Glyphs:
    """Glyph masks sampled from the outline at pixel centres.

    unscii is an outline font made of pixel squares whose grid sits a quarter
    pixel off the baseline; rasterizers (even FreeType's monochrome mode) get
    some glyphs wrong, a terminal without anti-aliasing does not.
    """

    def __init__(self, path):
        self.font = TTFont(path, lazy=True)
        self.gs, self.cmap = self.font.getGlyphSet(), self.font.getBestCmap()
        self.unit = self.font["head"].unitsPerEm / PX
        self.top = self.font["hhea"].ascent
        self.cache = {}

    def mask(self, ch, cells):
        key = (ch, cells)
        if key not in self.cache:
            img = Image.new("1", (cells * CELL_W, CELL_H), 0)
            name = self.cmap.get(ord(ch))
            if name:
                glyph = self.gs[name]
                for y in range(CELL_H):
                    for x in range(cells * CELL_W):
                        pen = PointInsidePen(self.gs, ((x + 0.5) * self.unit, self.top - (y + 0.5) * self.unit))
                        glyph.draw(pen)
                        if pen.getResult():
                            img.putpixel((x, y), 1)
            self.cache[key] = img
        return self.cache[key]


def render(lines, glyphs, path, crops=None):
    rows = [parse(l) for l in lines]
    if crops:
        rows = [r[:c] for r, c in zip(rows, crops)]
    width = max(len(r) for r in rows)
    img = Image.new("RGB", (width * CELL_W + 2 * PAD, len(rows) * CELL_H + 2 * PAD), BG)
    d = ImageDraw.Draw(img)
    for y, row in enumerate(rows):
        for x, (ch, fg, bg, w) in enumerate(row):
            if w == 0:
                continue
            x0, y0 = PAD + x * CELL_W, PAD + y * CELL_H
            d.rectangle([x0, y0, x0 + w * CELL_W - 1, y0 + CELL_H - 1], fill=bg)
            if ch.strip():
                d.bitmap((x0, y0), glyphs.mask(ch, w), fill=fg)
    img = img.resize((img.width * SCALE, img.height * SCALE), Image.NEAREST)
    img.save(path, optimize=True)
    print(path, img.size)


def main():
    glyphs = Glyphs(find_font())
    tmp = Path(tempfile.mkdtemp(prefix="statusline-shots-"))
    try:
        make(glyphs, tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def make(glyphs, tmp):
    home, conf = tmp / "home", tmp / "config"
    home.mkdir(); conf.mkdir()
    now = datetime.now(timezone.utc)
    iso = lambda dt: dt.strftime("%Y-%m-%dT%H:%M:%S.000Z")
    (tmp / "usage.json").write_text(json.dumps({
        "cached_at": int(time.time()), "ok": True, "five_hour": 14, "seven_day": 4,
        "five_hour_resets_at": iso(now + timedelta(hours=2, minutes=24, seconds=30)),
        "week_resets_at": iso(now + timedelta(days=6, hours=4, minutes=30)),
    }))
    boundary = {"type": "system", "subtype": "compact_boundary", "content": "Conversation compacted"}
    transcript = tmp / "session.jsonl"
    transcript.write_text("".join(json.dumps(r, separators=(",", ":")) + "\n" for r in [
        boundary, boundary,
        {"parentUuid": None, "isSidechain": False,
         "attachment": {"type": "ultra_effort_enter", "reminderType": "full"},
         "type": "attachment", "timestamp": iso(now + timedelta(seconds=5))},
    ]))
    env = {
        "PATH": os.environ["PATH"], "HOME": str(home), "CLAUDE_CONFIG_DIR": str(conf),
        "STATUSLINE_LABEL": "you@example.com", "STATUSLINE_ORG": "Acme Inc",
        "STATUSLINE_ACCOUNT_COLORS": "you@example.com=152",
        "STATUSLINE_CACHE_FILE": str(tmp / "usage.json"),
    }

    def run(cols, effort, model="Opus 5.5"):
        data = {"model": {"display_name": model}, "transcript_path": str(transcript),
                "workspace": {"project_dir": str(tmp)}, "effort": {"level": effort},
                "context_window": {"used_percentage": 42, "total_input_tokens": 57000,
                                   "total_output_tokens": 0, "context_window_size": 200000}}
        # A state dir per run: the script remembers the latest ultracode record per
        # process, and the rows here must not depend on each other.
        state = tempfile.mkdtemp(dir=tmp, prefix="state-")
        r = subprocess.run(["bash", str(SCRIPT)], input=json.dumps(data), capture_output=True,
                           text=True, env={**env, "STATUSLINE_COLS": str(cols), "STATUSLINE_STATE_DIR": state})
        # Missing tools (jq) do not make the script fail, they make it print a
        # degraded line, so the output is checked for the model as well.
        if r.returncode != 0 or model.split()[-1] not in r.stdout:
            sys.exit(f"statusline.sh failed (exit {r.returncode}):\n{r.stdout}\n{r.stderr}")
        return r.stdout

    layouts = [run(120, "high"), run(80, "high"), run(60, "high")]
    efforts = ["low", "medium", "high", "xhigh", "max", "ultracode"]
    lines = []
    for e in efforts:
        if e == "ultracode":
            lines.append(run(120, "xhigh"))
        else:
            # Without the ultracode record the latest state is "off".
            with open(transcript, "a") as t:
                # Compact like Claude Code's own JSONL, or the script's pattern will not match.
                t.write(json.dumps({"type": "attachment", "attachment": {"type": "ultra_effort_exit"},
                                    "timestamp": iso(datetime.now(timezone.utc) + timedelta(seconds=10))},
                                   separators=(",", ":")) + "\n")
            lines.append(run(120, e))
            with open(transcript) as t:
                kept = t.readlines()[:-1]
            transcript.write_text("".join(kept))
    # The badge also depends on settings outside the sandbox (managed settings
    # can turn workflows off); never publish a picture that silently lacks it.
    if "ultracode" not in lines[-1]:
        sys.exit("the ultracode row rendered without its badge; check workflow settings")
    # Crop each line right after its effort label.
    crops = []
    for l in lines:
        visible = "".join(c[0] or "\0" for c in parse(l))
        crops.append(re.search(r"5\.5 \S+", visible).end())
    # Written only once every line has rendered and passed the checks above.
    render(layouts, glyphs, HERE / "layouts.png")
    render(lines, glyphs, HERE / "effort.png", crops=crops)


if __name__ == "__main__":
    main()
