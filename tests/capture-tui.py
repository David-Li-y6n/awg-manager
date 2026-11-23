#!/usr/bin/env python3
# capture-tui.py — 连上 S 跑 awgman TUI，抓主菜单与拓扑两屏渲染成 PNG
# 用法：~/workspace/.tui-venv/bin/python capture-tui.py
import os
import pty
import re
import select
import struct
import sys
import time

import fcntl
import termios

import pyte
from PIL import Image, ImageDraw, ImageFont

SSH_CMD = [
    "ssh", "-tt",
    "-i", os.path.expanduser("~/.ssh/id_ed25519"),
    "-o", "ProxyCommand=nc -X connect -x hatch-egress-proxy:3128 %h %p",
    "-o", "IdentitiesOnly=yes",
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "ConnectTimeout=20",
    "-p", "22222",
    "root@107.151.244.14",
    "awgman",
]

COLS, ROWS = 140, 40
OUT_DIR = os.path.expanduser("~/workspace/awg-manager/delivered")

# 标准 16 色调色板（xterm）
PALETTE = {
    "black": (0, 0, 0), "red": (205, 0, 0), "green": (0, 205, 0),
    "brown": (205, 205, 0), "blue": (0, 0, 238), "magenta": (205, 0, 205),
    "cyan": (0, 205, 205), "white": (229, 229, 229),
    "brightblack": (127, 127, 127), "brightred": (255, 0, 0),
    "brightgreen": (0, 255, 0), "yellow": (255, 255, 0),
    "brightblue": (92, 92, 255), "brightmagenta": (255, 0, 255),
    "brightcyan": (0, 255, 255), "brightwhite": (255, 255, 255),
    "lightgray": (229, 229, 229), "gray": (127, 127, 127),
    "darkgray": (127, 127, 127),
}
DEFAULT_FG = (229, 229, 229)
DEFAULT_BG = (0, 0, 238)  # whiptail 根背景是蓝色


def color_of(name, default):
    if not name or name == "default":
        return default
    return PALETTE.get(name.lower().replace(" ", ""), default)


def snapshot(screen):
    """复制当前屏幕状态：每行是 [(char, fg_rgb, bg_rgb, bold)]"""
    grid = []
    for y in range(screen.lines):
        row = []
        for x in range(screen.columns):
            ch = screen.buffer[y][x]
            row.append((ch.data, color_of(ch.fg, DEFAULT_FG),
                        color_of(ch.bg, DEFAULT_BG), ch.bold))
        grid.append(row)
    return grid


def is_wide(ch):
    import unicodedata
    return unicodedata.east_asian_width(ch) in ("W", "F")


def render(grid, path, title):
    cell_w, cell_h = 10, 20
    font_lat = ImageFont.truetype(
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 15)
    font_lat_b = ImageFont.truetype(
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf", 15)
    font_cjk = ImageFont.truetype(
        "/usr/share/fonts/opentype/noto/NotoSerifCJK-Regular.ttc", 15)
    img = Image.new("RGB", (COLS * cell_w, ROWS * cell_h + 30), (30, 30, 30))
    d = ImageDraw.Draw(img)
    d.text((8, 5), title, fill=(255, 255, 255), font=font_lat)
    for y, row in enumerate(grid):
        x = 0
        while x < len(row):
            ch, fg, bg, bold = row[x]
            d.rectangle([x * cell_w, y * cell_h + 30,
                         (x + 1) * cell_w, (y + 1) * cell_h + 30], fill=bg)
            if ch and ch != " ":
                if is_wide(ch):
                    # 宽字符占两格
                    d.rectangle([(x + 1) * cell_w, y * cell_h + 30,
                                 (x + 2) * cell_w, (y + 1) * cell_h + 30],
                                fill=bg)
                    d.text((x * cell_w, y * cell_h + 30), ch,
                           fill=fg, font=font_cjk)
                    x += 2
                    continue
                d.text((x * cell_w + 1, y * cell_h + 30), ch, fill=fg,
                       font=font_lat_b if bold else font_lat)
            x += 1
    img.save(path)
    print(f"saved {path}")


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    screen = pyte.Screen(COLS, ROWS)
    stream = pyte.Stream(screen)
    pid, fd = pty.fork()
    if pid == 0:
        env = dict(os.environ)
        env["TERM"] = "xterm-256color"
        os.execve("/usr/bin/ssh", SSH_CMD, env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

    def drain(seconds):
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.2)
            if r:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    return
                if not data:
                    return
                stream.feed(data.decode("utf-8", "replace"))

    def send(b):
        os.write(fd, b)

    drain(5.0)  # SSH 连接 + 主菜单渲染
    menu = snapshot(screen)
    send(b"\x1b[B")  # Down：移到「查看拓扑」
    drain(0.5)
    send(b"\r")  # Enter
    drain(2.5)  # 拓扑 textbox
    topo = snapshot(screen)
    send(b"\r")  # 关闭 textbox
    drain(1.0)
    send(b"\x1b")  # ESC 退出
    drain(1.0)
    try:
        os.close(fd)
    except OSError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass

    # 文本检查：菜单与拓扑是否真的渲染了
    menu_text = "".join(c for row in menu for c, *_ in row)
    topo_text = "".join(c for row in topo for c, *_ in row)
    print("menu has 客户端管理:", "客户端管理" in menu_text)
    print("menu has 查看拓扑:", "查看拓扑" in menu_text)
    print("topo has 星型拓扑:", "星型拓扑" in topo_text)
    print("topo has win11:", "win11" in topo_text)
    render(menu, os.path.join(OUT_DIR, "tui-menu.png"), "awgman 主菜单（S 实机）")
    render(topo, os.path.join(OUT_DIR, "tui-topology.png"), "awgman 星型拓扑（S 实机）")


if __name__ == "__main__":
    sys.exit(main())
