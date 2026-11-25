# AmneziaWG 3.1 命令行管理工具

官方原生 AmneziaWG 3.1 协议的服务端管理工具，没有 WEB 面板，全部用命令行管理。
管理体验模仿 Netmaker：服务端加客户端、改网络都很方便，另有一个全屏彩色 TUI
菜单（上下键选择），也可以用非交互 CLI 命令做脚本化管理。

星型拓扑：服务端是中心，所有客户端之间的流量都经过服务端中转，不做点对点直连。

## 文件说明

仓库里的每个文件是干什么的：

| 文件 | 说明 |
| --- | --- |
| `awgman` | 主管理工具（1321 行 Bash）。不带参数运行时进入全屏 TUI 菜单；带参数时是
非交互 CLI（见下面的 CLI 命令表）。安装后位于服务端 `/usr/local/bin/awgman`，
同时在 `/root/awgman` 留一份备份。所有管理操作（增删客户端、改端口网段、
备份恢复等）都由它完成。 |
| `install.sh` | 服务端一键安装器（510 行 Bash）。在一台全新的 Debian/Ubuntu 服务器上装好
AWG 3.1 服务端：装内核模块与工具、生成服务端密钥与混淆参数、创建初始状态、
做防火墙与 SSH 加固（可选）。支持交互式（whiptail 菜单一步步选）和非交互式
（环境变量）两种模式。 |
| `DESIGN.md` | 设计文档。记录用户最初的需求、架构决策（为什么不用 WEB 面板、为什么用
whiptail、IP 墓碑制的由来）、以及实现与测试状态。想了解这个工具为什么长这样，
先读它。 |
| `README.md` | 本文件：文件说明、使用说明、部署说明。 |
| `tests/test-manager.sh` | 管理流程测试（126 项）。用真实的 `awg` 二进制与 mock 的
systemctl/ufw/qrencode，在沙箱里跑完整的管理流程：添加/删除客户端、墓碑规则、
禁用/备注/模式切换、密钥重生成、端口/网段/域名/DNS 修改、混淆重生成、备份恢复、
配置文件语法（用真实 3.1 解析器 `awg setconf` 校验）、安装脚本生成与转义。 |
| `tests/test-installer.sh` | 安装器测试（34 项）。覆盖版本判断、PPA 源选择（Debian/Ubuntu
各版本对应哪个源）、随机网段/端口生成、环境变量非交互模式。 |
| `tests/test-tui.py` | TUI 冒烟测试。用 pty 驱动真实的 whiptail，验证主菜单能正常渲染、能进拓扑页、
能正常退出。 |
| `tests/capture-tui.py` | TUI 截图工具。通过 SSH 连到服务器，在 pty 里跑 awgman，把终端画面渲染成
PNG（主菜单、拓扑页），用于验证界面效果。不是必需的测试，是开发辅助工具。 |
| `tests/mockbin/` | 测试用的 mock 二进制目录。里面是真实的 `awg` / `awg-quick`（从 PPA 包里
提取，用于真实解析校验），以及 mock 的 `systemctl` / `ufw` / `qrencode`
（测试时不真正操作系统服务）。 |
| `.gitignore` | 排除 `delivered/` 目录（里面是真实客户端配置文件与二维码，含私钥，绝不能
进仓库）以及 Python 缓存。 |

## 部署说明

### 环境要求

- 全新的 Debian 12/13 或 Ubuntu 22.04/24.04 服务器（其他系统安装器会直接拒绝）。
- root 权限运行安装器。
- 服务器能访问互联网（安装器要从 Amnezia PPA 或 GitHub 下载软件包与源码）。
- 内存建议 1GB 以上，磁盘建议 10GB 以上。

### 第一步：获取代码

```bash
git clone https://github.com/David-Li-y6n/awg-manager.git
cd awg-manager
```

### 第二步：运行安装器

```bash
bash install.sh
```

安装器会用 whiptail 菜单一步步问你（每项都有默认值，直接回车就用默认）：

1. **监听端口**：AWG 服务监听的 UDP 端口。可以自定义填一个（如 51820），也可以选随机
   （10000–60000 之间）。端口随时可以在管理工具里改，改完要重新下载全部客户端配置。
2. **内网网段**：隧道内部使用的网段，必须是 CGNAT 范围（100.64.0.0/10）内的一个 /24。
   可以自定义（如 100.64.12.0/24），也可以选随机。服务端固定占用该网段的 .254，
   客户端从 .2 开始分配。
3. **Endpoint 域名**：客户端连接服务端用的地址。默认 `hkg3.nexv.me`，建议填域名而不是
   IP——以后服务器换 IP 只需更新 DNS A 记录，不用重新发配置。域名必须事先解析到
   服务器的公网 IP。
4. **DNS**：全量模式的客户端要推送的 DNS，默认 1.1.1.1。分流模式的客户端不受影响。
5. **MTU**：隧道 MTU，默认 1280。3.1 的混淆会给数据包加填充，1280 是兼顾兼容性的
   安全值，一般不用改。
6. **是否加固**：默认做。加固包括三件事：SSH 端口从 22 改到 22222、fail2ban（3 次登录
   失败永久封禁）、ufw 只放行 SSH 端口与 AWG 端口。加固前安装器会确认，SSH 改端口
   失败时会自动还原，不会把自己锁在外面。

也可以用环境变量非交互安装（适合脚本批量部署）：

```bash
AWG_NONINTERACTIVE=1 AWG_PORT=random AWG_SUBNET=random \
  AWG_ENDPOINT=hkg3.nexv.me AWG_HARDENING=yes bash install.sh
```

环境变量一览：`AWG_PORT`（端口或 random）、`AWG_SUBNET`（网段或 random）、
`AWG_ENDPOINT`（域名或 IP）、`AWG_DNS`、`AWG_MTU`、`AWG_HARDENING`（yes/no）、
`AWG_NONINTERACTIVE=1`（非交互）、`AWG_REINSTALL=1`（已有安装时强制重装）。

### 第三步：安装器做了什么

安装器按三级递进保证装得上，上一级失败自动进下一级：

1. **PPA 安装**（首选）：从 Amnezia 官方 PPA 装 `amneziawg-dkms`（内核模块）与
   `amneziawg-tools`（命令行工具），要求版本不低于 3.1。Debian 13 / Ubuntu 24.04
   用 noble 源，Debian 12 / Ubuntu 22.04 用 jammy 源。Launchpad 偶尔返回 503，
   安装器会重试 3 次并用 `apt-cache policy` 校验源是否真的可用。
2. **源码编译**（PPA 不足时）：从 GitHub 指定 tag 编译安装。内核模块 tag
   v3.1.20261113-02（DKMS 方式），工具 tag v3.1.20260812。
3. **用户态 fallback**（内核模块加载失败或服务启动失败时）：自动改用
   `amneziawg-go`（用户态实现，不用内核模块），并把内核模块列入黑名单防止
   重启后再次加载。`amneziawg-go` 没有预编译包，安装器会从源码编译
   （tag v3.1.20261116，需要 Go 1.25+，Debian 13 自带 Go 只有 1.24，
   安装器会从 go.dev 下载官方工具链）。

装好组件后，安装器会：生成服务端密钥对与 3.1 混淆参数、创建状态文件
`/root/awg/state.json`、生成服务端配置、启动 `awg-quick@awg0` 服务（开机自启）、
配置 ufw 与 fail2ban（如果选了加固）、把 `awgman` 装到 `/usr/local/bin/`。

### 第四步：验证安装

```bash
awgman status        # 服务状态、版本、握手与流量
awgman topology      # 星型拓扑（刚装好时没有客户端）
systemctl status awg-quick@awg0
```

服务正常时 `awgman status` 会显示服务运行中，`awg show awg0` 能看到接口信息。

## 使用说明

### 进入管理界面

```bash
awgman              # 进入全屏 TUI 菜单（上下键选择，回车进入，Esc 返回）
```

TUI 菜单是深色主题，自动铺满整个终端。主菜单顶部显示服务端地址、端口、网段、
客户端数量与服务运行状态。

### TUI 菜单结构

```
主菜单
├── 1 客户端管理
│   ├── 添加客户端（名称 + 备注 + IP + 分流/全量）
│   ├── 删除客户端
│   ├── 启用 / 禁用客户端
│   ├── 修改备注
│   ├── 分流 / 全量切换
│   ├── 重新生成密钥
│   └── 查看客户端配置与安装脚本
├── 2 查看拓扑（星型图：服务端 + 全部客户端在线状态与流量）
├── 3 网络设置
│   ├── 修改监听端口（自定义或随机）
│   ├── 修改内网网段（自定义或随机 CGNAT）
│   ├── 修改 Endpoint（域名或 IP）
│   └── 修改 DNS
├── 4 状态查看（服务状态、组件版本、awg show 输出）
├── 5 备份与恢复
│   ├── 创建备份（状态 + 全部客户端配置打包）
│   ├── 查看已有备份
│   └── 从备份恢复
├── 6 系统工具
│   ├── 重新生成混淆参数（全部配置失效，需重发）
│   ├── 重新生成全部客户端配置
│   ├── 释放墓碑 IP（已删除客户端的 IP 可再次分配）
│   ├── 更新 AWG 组件
│   └── 卸载（先自动备份）
└── 0 退出
```

### CLI 命令（非交互，适合脚本）

不带参数进 TUI，带参数就是 CLI。全部命令也可以用 `awgman help` 查看：

```bash
# 客户端
awgman add office                 # 添加客户端 office（自动分配 IP，分流）
awgman add office "办公室电脑"     # 带中文备注
awgman add office "" 100.64.12.10 # 指定 IP
awgman add office "" auto full    # 全量模式（流量全走隧道，推送 DNS）
awgman add office "" 100.64.12.10 split --force   # 强制用已删除客户端的旧 IP
awgman del office                 # 删除（IP 记入墓碑，不自动复用）
awgman list                       # 列出客户端
awgman show office                # 显示配置与一键安装命令
awgman enable office / awgman disable office      # 启用 / 禁用
awgman remark office "新备注"      # 修改备注
awgman tunnel office full         # 改全量（split 改回分流）
awgman regen-keys office          # 重新生成密钥（配置泄露时用）
awgman regen-all                  # 重新生成全部客户端配置
awgman release-tombstones         # 释放已删除客户端的 IP

# 网络
awgman port 51820                 # 改监听端口（全部配置需重下）
awgman port random                # 随机端口
awgman subnet 100.64.20.0/24      # 改网段（各客户端主机位不变，墓碑清空）
awgman subnet random              # 随机 CGNAT 网段
awgman endpoint awg.example.com   # 改 Endpoint
awgman dns 8.8.8.8                # 改全量客户端 DNS
awgman regen-obfuscation          # 重新生成混淆参数（全部配置失效）

# 查看与维护
awgman topology                   # 星型拓扑
awgman status                     # 接口与握手状态
awgman versions                   # AWG 组件版本
awgman backup                     # 备份状态与配置
awgman restore <备份文件>          # 从备份恢复
awgman update                     # 更新 AWG 组件
awgman uninstall                  # 卸载（先自动备份）
```

### 添加客户端（完整流程）

1. 在 TUI 里选「客户端管理」→「添加客户端」，或用 CLI `awgman add <名>`。
2. 填名称：字母数字开头，只能含字母、数字、下划线、连字符，最长 15 字符。
   名称会成为配置文件名与 Linux 服务名，所以不能有空格或中文。
3. 填备注：支持中文，用于在拓扑里识别这台机器（比如"印尼-雅加达-广播IP"），
   可留空，之后随时能改。
4. 填 IP：直接回车自动分配（取从未分配过的最小 IP）；也可以自定义。
   自定义时如果填的是已删除客户端的旧 IP，会警告并要求确认；
   如果填的是正在用的 IP，直接拒绝并显示占用者。
5. 选分流还是全量：分流只走内网网段（默认），全量全部流量走隧道并推送 DNS。
6. 添加成功后，配置生成在服务端 `/root/awg/clients/<名>.conf`，同时生成
   二维码 `<名>.png` 与安装脚本 `<名>-install.sh`（Linux）和
   `<名>-install.ps1`（Windows）。
7. 把 `.conf` 与对应的安装脚本下载下来，上传到客户端机器上，运行安装脚本即可。
   配置文件不会自动下发，必须手动下载上传。

### 客户端安装

每个客户端目录里都有安装脚本，脚本自动找同目录的 `.conf`，不用手动输路径。

**Linux**（把 `<名>.conf` 与 `<名>-install.sh` 放到同一目录）：

```bash
sudo bash <名>-install.sh
```

脚本会先检测有没有装 `amneziawg-tools`，没装就自动从官方 PPA 安装
（含内核头文件、DKMS 模块）；内核头文件安装限时 5 分钟，内核模块加载
失败时自动改装用户态 `amneziawg-go`（已校验 SHA256，不用改配置）。
然后把配置装到 `/etc/amnezia/amneziawg/`、
启用并启动 `awg-quick@<名>` 服务（开机自启）。装好后 `awg show` 能看到握手。

**Windows**（先装好 AmneziaWG 客户端，再把 `.conf` 与 `.ps1` 放到同一目录，
管理员 PowerShell）：

```powershell
.\<名>-install.ps1
```

脚本调用 `amneziawg.exe /installtunnelservice` 把隧道装成 Windows 服务
（服务名 `AmneziaWGTunnel$<名>`），开机自动启动自动连接。

**Windows 不想装后台服务时**：装官方 AmneziaWG Windows 客户端（3.1.0+，
下载地址 https://github.com/amnezia-vpn/amneziawg-windows-client/releases/latest），
图形界面导入 `.conf` 后点 Activate 即可。程序开着隧道就在，退出程序隧道即断，
不会开机自启。注意：不要用 WireGuard 官方客户端，它读不懂 3.1 的混淆参数。

**手机**：用 AmneziaVPN 扫描 `/root/awg/clients/<名>.png` 二维码导入。

### 改端口 / 改网段

在 TUI「网络设置」里改，或用 CLI `awgman port` / `awgman subnet`。改完后：

- 全部客户端配置立即失效，必须重新下载、重新导入。
- 改网段时各客户端的主机位不变（比如 .2 还是 .2，只是网段变了），墓碑清空。
- 服务会重启 1–2 秒，客户端自动重握手（用新配置后）。

### 备份与恢复

- 备份：`awgman backup` 或 TUI「备份与恢复」→「创建备份」。备份是 tar.gz，
  包含状态文件、全部客户端配置与服务端配置，存在 `/root/awg/backups/`。
- 恢复：`awgman restore <备份文件>`。恢复会覆盖当前状态与配置，服务重启。
- 换服务器时：新服务器上装好 awgman，把备份文件拷过去，`awgman restore` 即可，
  客户端配置不用变（Endpoint 用域名时只需更新 DNS）。

## 关键规则

- **IP 墓碑制**：分配过的 IP 永久记录在状态文件里，删除客户端后也不自动复用。
  防止新客户端拿到旧 IP 后，与还没删配置的旧机器冲突。/24 网段有 247 个客户端
  地址（.1–.253，.254 是服务端），正常使用很难耗尽；真要释放时用
  `awgman release-tombstones`（需确认）。
- **状态文件是唯一事实来源**：`/root/awg/state.json`（0600 权限）记录服务端配置、
  客户端列表、墓碑 IP 与备注。每次改动后，awgman 根据它重新生成服务端配置
  （`/etc/amnezia/amneziawg/awg0.conf`）并重启服务（约 1–2 秒）。不要手动改
  服务端配置文件，会被下一次改动覆盖。
- **混淆参数两端一致**：3.1 的混淆参数（S1–S4、H1–H4、Jc、Jmin、Jmax、I1、
  HeaderProtectionKey、ContentPaddingAddition 等）由服务端生成一次，所有客户端
  共享同一份。重新生成后全部客户端配置失效，必须重新下载。
- **分流默认**：客户端默认只走内网网段（AllowedIPs = 内网网段），上网流量不走隧道；
  需要全量时按客户端单独改，全量时服务端推送 DNS。
- **Endpoint 用域名**：客户端配置里的 Endpoint 默认填域名，服务器换 IP 只需更新
  DNS A 记录，不用重新发配置。

## 服务端目录结构

```
/root/awg/                          管理数据根目录（0700）
├── state.json                      状态文件（0600，唯一事实来源）
├── clients/                        客户端配置目录（0700）
│   ├── <名>.conf                   客户端配置文件（0600）
│   ├── <名>.png                    二维码（手机扫码导入）
│   ├── <名>-install.sh             Linux 一键安装脚本（0755）
│   └── <名>-install.ps1            Windows 一键安装脚本
├── backups/                        备份目录（awgman backup 的产物）
└── .lock                            flock 锁文件（防止两个 awgman 同时改状态）
/etc/amnezia/amneziawg/              awg-quick 配置目录
└── awg0.conf                       服务端配置（由 state.json 生成，不要手改）
/usr/local/bin/awgman               管理工具
/root/awgman                        管理工具备份副本
```

注意：awg-quick 的配置目录是 `/etc/amnezia/amneziawg/`，不是 `/etc/amneziawg/`。
这是 AmneziaWG 与 WireGuard 不同的地方，写错路径服务起不来。

## 测试说明

在沙箱里跑测试（需要 bash、jq、python3、whiptail）：

```bash
bash tests/test-manager.sh    # 126 项管理流程测试
bash tests/test-installer.sh  # 34 项安装器测试（需先 export AWG_NONINTERACTIVE=1）
python3 tests/test-tui.py     # TUI 冒烟测试
```

测试用 `tests/mockbin/` 里的真实 `awg` 二进制做配置解析校验，用 mock 的
systemctl/ufw/qrencode 代替真实系统操作。测试跑完后清理沙箱状态：

```bash
rm -rf /root/awg /etc/amnezia/amneziawg
```

沙箱限制（无法在沙箱验证，须在真实服务器上验证）：内核模块加载、接口拉起、
真实握手（沙箱没有 CAP_NET_ADMIN，建不了 TUN 设备；出站 UDP 也被挡住）。

## 常见问题

**客户端连不上，握手一直没有？**
按顺序查：① 服务端 `awg show awg0` 有没有这个客户端的 peer；② 客户端配置里的
Endpoint 域名解析到的是不是服务端当前 IP；③ 服务端 UDP 端口有没有被防火墙放行
（`ufw status`）；④ 运营商或机房有没有封 UDP（可以在服务端抓包看有没有数据包到）。

**改了端口/网段后客户端全断了？**
正常。改端口或网段后全部客户端配置失效，必须重新下载新配置、重新导入。
改网段时各客户端的主机位不变，只是网段变了。

**TUI 菜单显示不全或提示文字没了？**
终端太小。TUI 会按终端实际尺寸自动调整，但终端至少要 15 行 × 60 列。
把终端窗口拉大，退出重进即可。

**客户端配置里的混淆参数是干什么的？**
3.1 的抗封锁参数：改变握手包的大小、时序与内容，让流量特征不像 WireGuard，
避免被深度包检测识别。服务端与客户端必须用同一份参数，改一边就全断。

**怎么换服务器？**
新服务器上跑一遍 `install.sh`（端口网段可以照旧），把旧服务器的备份文件
（`/root/awg/backups/` 里）拷到新服务器，`awgman restore` 恢复。如果 Endpoint
用的是域名，更新 DNS A 记录指向新 IP 即可，客户端配置不用变。
