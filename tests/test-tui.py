#!/usr/bin/env python3
# test-tui.py — awgman TUI 冒烟测试
# 用 pty 驱动真实 whiptail 菜单：主菜单 -> 查看拓扑 -> 返回 -> 退出，
# 断言拓扑内容正确渲染（星型图、客户端名、中文备注）。
# 前置：需先跑过 test-manager.sh（留下有效状态文件）。
import json
import os
import pty
import re
import select
import struct
import subprocess
import sys
import time

import fcntl
import termios

AWGMAN = os.path.expanduser("~/workspace/awg-manager/awgman")
MOCKBIN = os.path.expanduser("~/workspace/awg-manager/tests/mockbin")
STATE = "/root/awg/state.json"


def main():
    if not os.path.exists(STATE):
        print("SKIP: 状态文件不存在，请先跑 test-manager.sh")
        return 0
    with open(STATE, encoding="utf-8") as f:
        st = json.load(f)
    clients = st.get("clients", [])
    if not clients:
        print("SKIP: 状态中无客户端")
        return 0
    c0 = clients[0]
    expected = ["星型拓扑", c0["name"], c0["ip"]]
    if c0.get("remark"):
        expected.append(c0["remark"])

    env = dict(os.environ)
    env["PATH"] = MOCKBIN + ":" + env["PATH"]
    env["MOCK_LOG"] = "/tmp/awg-test-mock.log"
    env["TERM"] = "xterm-256color"

    pid, fd = pty.fork()
    if pid == 0:
        os.execve("/bin/bash", ["/bin/bash", AWGMAN], env)
    # 设终端尺寸 100x30，避免 whiptail 因太小报错
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))

    output = b""

    def drain(seconds):
        nonlocal output
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.2)
            if r:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    break
                if not data:
                    break
                output += data

    def send(b):
        os.write(fd, b)

    drain(2.0)  # 主菜单出现
    send(b"\x1b[B")  # Down：移到「查看拓扑」
    drain(0.5)
    send(b"\r")  # Enter：打开拓扑
    drain(2.0)  # 拓扑 textbox
    send(b"\r")  # Enter：关闭 textbox
    drain(1.0)  # 回到主菜单
    send(b"\x1b")  # ESC：退出
    drain(1.0)
    try:
        os.close(fd)
    except OSError:
        pass
    try:
        _, status = os.waitpid(pid, 0)
    except ChildProcessError:
        status = 0

    text = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", output).decode("utf-8", "replace")
    text = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", text)

    fails = 0
    for e in expected:
        if e in text:
            print(f"PASS: TUI 拓扑含 [{e}]")
        else:
            print(f"FAIL: TUI 拓扑缺 [{e}]")
            fails += 1
    if "客户端管理" in text:
        print("PASS: TUI 主菜单渲染")
    else:
        print("FAIL: TUI 主菜单未渲染")
        fails += 1
    if os.waitstatus_to_exitcode(status) == 0:
        print("PASS: TUI 正常退出")
    else:
        print(f"FAIL: TUI 退出码 {os.waitstatus_to_exitcode(status)}")
        fails += 1
    if fails:
        print("---- TUI 输出（去转义后，前 2000 字）----")
        print(text[:2000])
    print(f"TUI 测试：{'全部通过' if fails == 0 else f'{fails} 项失败'}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
