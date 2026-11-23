# AmneziaWG 3.1 命令行管理工具

官方原生 AWG 3.1，无 WEB 面板；服务端管理用全屏彩色 TUI 菜单，体验模仿
Netmaker。

## 文件

| 文件 | 说明 |
| --- | --- |
| `install.sh` | 服务端一键安装器（Debian 12/13、Ubuntu 22.04/24.04） |
| `awgman` | 管理工具（安装后位于 `/usr/local/bin/awgman`） |
| `DESIGN.md` | 设计文档 |
| `tests/` | 测试脚本与 mock |

## 安装（服务端）

```bash
bash install.sh
```

按提示选择：监听端口（自定义/随机）、内网网段（自定义/随机 CGNAT）、
Endpoint 域名（默认 `hkg3.nexv.me`）、DNS、MTU、是否加固
（SSH 22222 + fail2ban 3 次永久封禁）。

安装器三级递进保证装得上：

1. Amnezia PPA 装 `amneziawg-dkms` + `amneziawg-tools`（要求 >= 3.1；
   已实测 PPA 提供 `v3.1.20260812`）；
2. PPA 不足时从 GitHub 指定 tag 源码编译；
3. 内核模块加载失败或启动失败时，自动 fallback 到用户态 `amneziawg-go`
   （`awg-quick` 内置该逻辑；模块会被黑名单防止重启后再次加载）。

非交互模式（环境变量）：

```bash
AWG_NONINTERACTIVE=1 AWG_PORT=random AWG_SUBNET=random \
  AWG_ENDPOINT=hkg3.nexv.me AWG_HARDENING=yes bash install.sh
```

## 日常管理

```bash
awgman              # 进入全屏 TUI 菜单
awgman add office   # 命令行快速添加客户端
awgman topology     # 查看星型拓扑
awgman list         # 列出客户端
awgman help         # 全部 CLI 命令
```

## 关键规则

- **客户端 IP 墓碑制**：分配过的 IP 永久记录，删除后也不自动复用；
  自定义 IP 时若填已删除客户端的旧 IP 会警告并要求确认。
- **备注支持中文**：拓扑视图显示 IP + 名称 + 备注 + 状态。
- **配置目录**：`/root/awg/clients/`，每个客户端一个 `.conf` + 二维码 `.png` +
  安装脚本 `<名>-install.sh`（Linux）/ `<名>-install.ps1`（Windows）；
  用户自行下载并上传到客户端，再运行安装脚本即可。
- **分流默认**：仅内网网段走隧道；可按客户端改全量（推送 DNS）。
- **混淆参数**：服务端生成一次，两端一致；重新生成后全部配置失效，需重下。
- **状态文件**：`/root/awg/state.json` 是唯一事实来源，服务端配置由它生成；
  每次改动后服务重启约 1-2 秒，客户端自动重握手。
- **备份**：`awgman backup` 打包状态 + 全部客户端配置，换服务器时 `awgman restore`。

## 客户端一键安装（配置与脚本已上传到客户端后本地执行）

每个客户端目录里都有安装脚本，脚本自动找同目录的 `.conf`，不用手动输路径：

Linux（脚本会自动检测并安装 amneziawg-tools，未装时从官方 PPA 安装）：

```bash
sudo bash office-install.sh
```

Windows（管理员 PowerShell，先装好 AmneziaWG 客户端）：

```powershell
.\office-install.ps1
```

不想装后台服务时：装官方 AmneziaWG Windows 客户端（3.1.0+），图形界面导入
`.conf` 后点 Activate 即可，退出程序隧道即断。

手机：用 AmneziaVPN 扫描 `/root/awg/clients/<名>.png` 二维码。

## 测试（沙箱内，2026-11-23 全部通过）

- `tests/test-manager.sh`：126 项，覆盖添加/删除/墓碑/禁用/备注/模式/
  密钥/端口/网段/域名/DNS/混淆重生成/备份恢复/配置语法（真实 3.1 解析器）、
  安装脚本生成与转义。
- `tests/test-installer.sh`：34 项，覆盖版本判断、PPA 源选择、随机网段/端口、
  环境变量模式。
- `tests/test-tui.py`：pty 驱动真实 whiptail，验证主菜单与拓扑渲染。

沙箱限制（无法在沙箱验证，须在 S 上验证）：内核模块加载、接口拉起、
真实握手（沙箱无 CAP_NET_ADMIN，`ip tuntap` 被拒）。
