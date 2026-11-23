#!/bin/bash
# install.sh — AmneziaWG 3.1 服务端一键安装器
# 目标系统：全新 Debian 13（首选）/ Debian 12 / Ubuntu 24.04 / Ubuntu 22.04，root 运行。
# 安装内容：官方原生 AWG 3.1（内核模块优先，用户态 fallback）+ awgman 管理工具。
#
# 交互模式：直接运行，按 whiptail 提示选择端口/网段/域名等。
# 非交互模式：设置环境变量后运行（供脚本与测试使用）：
#   AWG_PORT=51820|random  AWG_SUBNET=100.64.12.0/24|random
#   AWG_ENDPOINT=hkg3.nexv.me  AWG_DNS=1.1.1.1  AWG_MTU=1280
#   AWG_HARDENING=yes|no  AWG_NONINTERACTIVE=1
#
# 安装策略（三级递进，保证装得上）：
#   1) Amnezia PPA 安装 amneziawg-dkms + amneziawg-tools，要求版本 >= 3.1；
#   2) PPA 版本不足或安装失败时，从 GitHub 指定 tag 源码编译（DKMS + tools）；
#   3) 内核模块加载失败时，下载 amneziawg-go 二进制，awg-quick 自动 fallback
#      到用户态（无需改配置，awg-quick 内置该逻辑）。

set -u
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# 钉住的 3.1 版本（源码编译 fallback 用）
AWG_MODULE_TAG="v3.1.20261113-02"
AWG_TOOLS_TAG="v3.1.20260812"
# amneziawg-go 仓库不发布预编译二进制，只能源码编译；go.mod 要求 Go >= 1.25，
# Debian 13 的 apt golang 只有 1.24，所以从 go.dev 下载官方工具链
AWG_GO_TAG="v3.1.20261116"
GO_VERSION="1.26.11"
PPA_KEY_URL="https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x75C9DD72C799870E310542E24166F2C257290828"
PPA_BASE="https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/root/awg"
STATE_FILE="$STATE_DIR/state.json"
CLIENT_DIR="$STATE_DIR/clients"

log() { echo "[*] $*"; }
ok() { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
die() { echo "[x] $*" >&2; exit 1; }

# run_capture <日志文件> <命令...>：运行命令，输出记入日志，返回真实退出码；
# 失败时打印日志末尾 10 行。不要用 `cmd | tail` 判断成败——管道退出码是 tail 的，
# 会把失败掩盖成成功（2026-11-23 S 上真实踩坑）。
run_capture() {
    local logfile=$1; shift
    "$@" >"$logfile" 2>&1
    local rc=$?
    if (( rc != 0 )); then
        warn "命令失败（退出码 $rc）：$*"
        tail -n 10 "$logfile" >&2
    fi
    return $rc
}

[[ $EUID -eq 0 ]] || die "请用 root 运行（sudo bash install.sh）"

# ---------- 系统检测 ----------
detect_os() {
    # 输出：<id> <codename>，如 debian trixie / ubuntu noble
    . /etc/os-release
    local id=${ID:-} code=${VERSION_CODENAME:-}
    case "$id:$code" in
        debian:trixie|debian:bookworm|ubuntu:noble|ubuntu:jammy) echo "$id $code" ;;
        *) die "不支持的系统：$id $code（仅支持 Debian 12/13、Ubuntu 22.04/24.04）" ;;
    esac
}

ppa_suite_for() {
    # Debian 13 / Ubuntu 24.04 用 noble 源；Debian 12 / Ubuntu 22.04 用 jammy 源
    # （Debian 12 的 glibc 2.36 装不了 noble 包要求的 libc6 >= 2.38）
    case "$1" in
        trixie|noble) echo noble ;;
        bookworm|jammy) echo jammy ;;
    esac
}

# ---------- 版本判断 ----------
awg_tools_version() {
    # 输出 amneziawg-tools 的版本号（如 3.1.20260812），未安装则为空
    command -v awg >/dev/null 2>&1 || return 1
    awg --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1
}

version_ge_31() {
    # version_ge_31 <版本号>：主次版本 >= 3.1 返回 0
    local v=${1#v} maj min rest
    maj=${v%%.*}; rest=${v#*.}; min=${rest%%.*}
    [[ "$maj" =~ ^[0-9]+$ && "$min" =~ ^[0-9]+$ ]] || return 1
    (( maj > 3 || (maj == 3 && min >= 1) ))
}

module_loaded() { lsmod 2>/dev/null | grep -q '^amneziawg'; }

# ---------- 基础依赖 ----------
install_base_deps() {
    log "安装基础依赖（curl / whiptail / qrencode / jq / ufw / fail2ban / nftables / 编译工具 / 内核头文件）..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || die "apt update 失败，请检查网络与软件源"
    # 内核头文件可能不存在（如容器内 uname -r 是宿主机内核），失败不致命
    apt-get install -y -qq curl whiptail qrencode jq ufw fail2ban nftables git \
        iptables iproute2 build-essential dkms pkg-config libmnl-dev libelf-dev \
        "linux-headers-$(uname -r)" 2>&1 | tail -n 3 || true
    # 头文件装不上时上面整条命令可能非零退出，单独重试一次不含头文件的集合
    for p in curl whiptail qrencode jq ufw fail2ban nftables iptables build-essential dkms git; do
        dpkg -s "$p" >/dev/null 2>&1 || apt-get install -y -qq "$p" || die "依赖安装失败：$p"
    done
    ok "基础依赖就绪"
}

# ---------- AWG 安装：PPA ----------
install_awg_ppa() {
    local suite=$1
    log "添加 Amnezia PPA（$suite）..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL --retry 3 --retry-delay 5 "$PPA_KEY_URL" -o /etc/apt/keyrings/amnezia.asc || { warn "PPA 密钥下载失败"; return 1; }
    echo "deb [signed-by=/etc/apt/keyrings/amnezia.asc] $PPA_BASE $suite main" \
        > /etc/apt/sources.list.d/amnezia.list
    # Launchpad 间歇性 503（apt update 只报 W: 警告仍返回 0），用 apt-cache
    # 确认 PPA 索引真的下载下来了，最多重试 3 次
    local i
    for i in 1 2 3; do
        apt-get update -qq >/dev/null 2>&1 || true
        if apt-cache policy amneziawg-tools 2>/dev/null | grep -q "ppa.launchpadcontent"; then
            break
        fi
        [[ $i -lt 3 ]] && { warn "PPA 索引未下载成功（第 $i/3 次），10 秒后重试..."; sleep 10; }
    done
    apt-cache policy amneziawg-tools 2>/dev/null | grep -q "ppa.launchpadcontent" \
        || { warn "PPA 索引下载失败（Launchpad 503？）"; return 1; }
    log "从 PPA 安装 amneziawg-dkms + amneziawg-tools..."
    local aptlog
    aptlog=$(mktemp)
    if ! apt-get install -y -qq amneziawg-dkms amneziawg-tools >"$aptlog" 2>&1; then
        warn "PPA 包安装失败"
        tail -n 5 "$aptlog" >&2
        rm -f "$aptlog"
        return 1
    fi
    rm -f "$aptlog"
    local v
    v=$(awg_tools_version) || { warn "awg 未安装成功"; return 1; }
    log "PPA 提供的 amneziawg-tools 版本：$v"
    version_ge_31 "$v" || { warn "PPA 版本 $v 低于 3.1"; return 1; }
    ok "PPA 安装成功（amneziawg-tools $v）"
    return 0
}

# ---------- AWG 安装：源码编译 ----------
install_awg_source() {
    local tmp
    tmp=$(mktemp -d) || die "无法创建临时目录"
    log "从源码编译 AWG 3.1（内核模块 $AWG_MODULE_TAG + tools $AWG_TOOLS_TAG）..."
    # 1) 内核模块（DKMS）
    curl -fsSL --retry 3 --retry-delay 5 -o "$tmp/module.tar.gz" \
        "https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/archive/refs/tags/$AWG_MODULE_TAG.tar.gz" \
        || { warn "内核模块源码下载失败"; rm -rf "$tmp"; return 1; }
    mkdir -p "$tmp/module" /usr/src
    tar -xzf "$tmp/module.tar.gz" -C "$tmp/module" --strip-components=1 \
        || { warn "内核模块源码解压失败"; rm -rf "$tmp"; return 1; }
    # dkms.conf 在 src/ 下，DKMS 要求它在模块目录根部；用官方 dkms-install
    # 目标铺源码（debian/rules 同款做法）。DKMS 版本号取自 dkms.conf 的
    # PACKAGE_VERSION（当前为 1.0.0），与 -v 不一致时 dkms add 会拒绝。
    local dkms_ver
    dkms_ver=$(grep -oP 'PACKAGE_VERSION="\K[^"]+' "$tmp/module/src/dkms.conf" 2>/dev/null || echo "1.0.0")
    rm -rf "/usr/src/amneziawg-$dkms_ver"
    if ! run_capture "$tmp/dkms-install.log" make -C "$tmp/module/src" DKMSDIR="/usr/src/amneziawg-$dkms_ver" dkms-install; then
        warn "DKMS 源码铺设失败（稍后将 fallback 到用户态）"
    elif ! run_capture "$tmp/dkms.log" dkms add -m amneziawg -v "$dkms_ver" \
        || ! run_capture "$tmp/dkms.log" dkms build -m amneziawg -v "$dkms_ver" \
        || ! run_capture "$tmp/dkms.log" dkms install -m amneziawg -v "$dkms_ver"; then
        warn "内核模块 DKMS 编译失败（稍后将 fallback 到用户态）"
        dkms remove -m amneziawg -v "$dkms_ver" --all 2>/dev/null || true
    else
        ok "内核模块 DKMS 编译安装成功"
    fi
    # 2) tools
    curl -fsSL --retry 3 --retry-delay 5 -o "$tmp/tools.tar.gz" \
        "https://github.com/amnezia-vpn/amneziawg-tools/archive/refs/tags/$AWG_TOOLS_TAG.tar.gz" \
        || { warn "tools 源码下载失败"; rm -rf "$tmp"; return 1; }
    mkdir -p "$tmp/tools"
    tar -xzf "$tmp/tools.tar.gz" -C "$tmp/tools" --strip-components=1 \
        || { warn "tools 源码解压失败"; rm -rf "$tmp"; return 1; }
    # tools 构建在 src/ 子目录（顶层没有 Makefile），装出 awg + awg-quick +
    # systemd 单元（awg-quick@.service）
    if ! run_capture "$tmp/tools.log" make -C "$tmp/tools/src" \
        || ! run_capture "$tmp/tools.log" make -C "$tmp/tools/src" install PREFIX=/usr; then
        warn "tools 编译安装失败"; rm -rf "$tmp"; return 1
    fi
    systemctl daemon-reload 2>/dev/null || true
    rm -rf "$tmp"
    local v
    v=$(awg_tools_version) || { warn "源码编译后 awg 仍不可用"; return 1; }
    version_ge_31 "$v" || { warn "源码编译出的 tools 版本 $v 低于 3.1"; return 1; }
    ok "源码编译成功（amneziawg-tools $v）"
    return 0
}

# ---------- 用户态 fallback ----------
install_amneziawg_go() {
    # 从源码编译 amneziawg-go（仓库无预编译包；需 Go >= 1.25）
    log "编译 amneziawg-go（源码，tag $AWG_GO_TAG）..."
    local tmp goroot
    tmp=$(mktemp -d) || { warn "无法创建临时目录"; return 1; }
    goroot=/usr/local/go
    if [[ ! -x "$goroot/bin/go" ]] || ! "$goroot/bin/go" version 2>/dev/null | grep -q "go1\.2[56]"; then
        log "下载 Go $GO_VERSION 官方工具链..."
        curl -fsSL --retry 3 --retry-delay 5 -o "$tmp/go.tgz" \
            "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
            || { warn "Go 工具链下载失败"; rm -rf "$tmp"; return 1; }
        rm -rf "$goroot"
        tar -xzf "$tmp/go.tgz" -C /usr/local \
            || { warn "Go 工具链解压失败"; rm -rf "$tmp"; return 1; }
    fi
    export PATH="$goroot/bin:$PATH"
    command -v git >/dev/null 2>&1 || apt-get install -y -qq git >/dev/null 2>&1 || true
    if ! run_capture "$tmp/go.log" git clone --depth 1 --branch "$AWG_GO_TAG" \
            https://github.com/amnezia-vpn/amneziawg-go "$tmp/amneziawg-go" \
        || ! run_capture "$tmp/go.log" make -C "$tmp/amneziawg-go" install PREFIX=/usr; then
        warn "amneziawg-go 编译失败"; rm -rf "$tmp"; return 1
    fi
    rm -rf "$tmp"
    command -v amneziawg-go >/dev/null 2>&1 || { warn "amneziawg-go 安装失败"; return 1; }
    ok "amneziawg-go 已安装（$(amneziawg-go --version 2>/dev/null | head -1)）"
    return 0
}

# 设置全局变量 DATAPATH=kernel|userspace（直接调用，不用命令替换，
# 否则内部的 die 只退出子 shell）
ensure_datapath() {
    # 内核模块能加载则用内核模式；否则下载 amneziawg-go，awg-quick 自动 fallback
    modprobe amneziawg 2>/dev/null || true
    if module_loaded; then
        ok "内核模块已加载（内核模式）"
        DATAPATH="kernel"
        return 0
    fi
    warn "内核模块无法加载，改用用户态 amneziawg-go"
    install_amneziawg_go || die "amneziawg-go 安装失败，无法继续"
    DATAPATH="userspace"
}

# 服务启动失败时 fallback 到用户态（模块可能太旧、拒绝 3.1 参数）：
# 卸载模块、黑名单防止重启后再次自动加载、装 amneziawg-go、重试启动
fallback_to_userspace() {
    warn "内核模式启动失败，尝试用户态 fallback..."
    systemctl stop awg-quick@awg0 2>/dev/null || true
    if module_loaded; then
        rmmod amneziawg 2>/dev/null || true
        echo "blacklist amneziawg" > /etc/modprobe.d/amneziawg-blacklist.conf
        log "已黑名单内核模块（防止重启后再次自动加载）"
    fi
    command -v amneziawg-go >/dev/null 2>&1 || install_amneziawg_go || die "amneziawg-go 安装失败"
    DATAPATH="userspace"
    state_set --arg d "userspace" '.server.datapath = $d'
    systemctl enable --now awg-quick@awg0 || die "用户态模式启动也失败，请查看：journalctl -u awg-quick@awg0"
    ok "用户态模式启动成功"
}

# ---------- 安装参数 ----------
rand_port() { shuf -i 10000-60000 -n 1 2>/dev/null || echo $((10000 + RANDOM % 50001)); }
rand_subnet() { echo "100.$((64 + RANDOM % 64)).$((RANDOM % 256)).0/24"; }

NONINTERACTIVE=${AWG_NONINTERACTIVE:-0}

pick_port() {
    if [[ -n "${AWG_PORT:-}" ]]; then
        if [[ "$AWG_PORT" == "random" ]]; then PORT=$(rand_port); else PORT=$AWG_PORT; fi
    elif (( NONINTERACTIVE == 1 )); then
        PORT=$(rand_port)
    else
        local mode
        mode=$(whiptail --title "AmneziaWG 3.1 安装" --menu "监听端口（UDP）：\n随机端口更难被扫描发现" 12 60 2 \
            "random" "随机端口（10000-60000）" \
            "custom" "自定义端口" 3>&1 1>&2 2>&3) || die "已取消安装"
        if [[ "$mode" == "random" ]]; then PORT=$(rand_port);
        else
            PORT=$(whiptail --title "AmneziaWG 3.1 安装" --inputbox "自定义监听端口（1-65535，不能是 SSH 端口）：\n" 10 60 "51820" 3>&1 1>&2 2>&3) || die "已取消安装"
        fi
    fi
    [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "端口不合法：$PORT"
    [[ "$PORT" == "22" || "$PORT" == "22222" ]] && die "端口 $PORT 与 SSH 冲突，请换一个"
}

pick_subnet() {
    if [[ -n "${AWG_SUBNET:-}" ]]; then
        if [[ "$AWG_SUBNET" == "random" ]]; then SUBNET=$(rand_subnet); else SUBNET=$AWG_SUBNET; fi
    elif (( NONINTERACTIVE == 1 )); then
        SUBNET=$(rand_subnet)
    else
        local mode
        mode=$(whiptail --title "AmneziaWG 3.1 安装" --menu "内网网段（/24，服务端默认为 .254）：\n随机网段取自 CGNAT 100.64.0.0/10" 12 60 2 \
            "random" "随机 CGNAT 网段" \
            "custom" "自定义网段" 3>&1 1>&2 2>&3) || die "已取消安装"
        if [[ "$mode" == "random" ]]; then SUBNET=$(rand_subnet);
        else
            SUBNET=$(whiptail --title "AmneziaWG 3.1 安装" --inputbox "自定义网段（格式 x.y.z.0/24）：\n" 10 60 "100.64.0.0/24" 3>&1 1>&2 2>&3) || die "已取消安装"
        fi
    fi
    [[ "$SUBNET" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.0/24$ ]] || die "网段格式须为 x.y.z.0/24：$SUBNET"
}

pick_endpoint() {
    if [[ -n "${AWG_ENDPOINT:-}" ]]; then
        ENDPOINT=$AWG_ENDPOINT
    elif (( NONINTERACTIVE == 1 )); then
        ENDPOINT="hkg3.nexv.me"
    else
        ENDPOINT=$(whiptail --title "AmneziaWG 3.1 安装" --inputbox "客户端连接用的域名或 IP（写进客户端配置的 Endpoint；用域名时以后换 IP 不用重发配置）：\n" 12 60 "hkg3.nexv.me" 3>&1 1>&2 2>&3) || die "已取消安装"
    fi
    [[ -n "$ENDPOINT" ]] || die "Endpoint 不能为空"
}

pick_dns() {
    if [[ -n "${AWG_DNS:-}" ]]; then DNS=$AWG_DNS
    elif (( NONINTERACTIVE == 1 )); then DNS="1.1.1.1"
    else
        DNS=$(whiptail --title "AmneziaWG 3.1 安装" --inputbox "全量客户端推送的 DNS（分流客户端不用）：\n" 10 60 "1.1.1.1" 3>&1 1>&2 2>&3) || die "已取消安装"
    fi
    [[ "$DNS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "DNS 须为 IPv4 地址：$DNS"
}

pick_mtu() {
    if [[ -n "${AWG_MTU:-}" ]]; then MTU=$AWG_MTU
    elif (( NONINTERACTIVE == 1 )); then MTU=1280
    else
        MTU=$(whiptail --title "AmneziaWG 3.1 安装" --inputbox "MTU（1280 最稳妥，混淆填充多时避免分片）：\n" 10 60 "1280" 3>&1 1>&2 2>&3) || die "已取消安装"
    fi
    [[ "$MTU" =~ ^[0-9]+$ ]] && (( MTU >= 1280 && MTU <= 1420 )) || die "MTU 须为 1280-1420 的数字：$MTU"
}

pick_hardening() {
    if [[ -n "${AWG_HARDENING:-}" ]]; then HARDENING=$AWG_HARDENING
    elif (( NONINTERACTIVE == 1 )); then HARDENING="yes"
    else
        if whiptail --title "AmneziaWG 3.1 安装" --yesno "是否做服务器加固？\n\n加固内容：\n- SSH 端口改为 22222\n- fail2ban：3 次失败永久封禁\n- ufw 只放行 SSH 与 AWG 端口" 13 60; then HARDENING="yes"; else HARDENING="no"; fi
    fi
}

# ---------- 加固与网络 ----------
setup_hardening() {
    local ssh_port=22
    if [[ "$HARDENING" == "yes" ]]; then
        log "加固：SSH 端口改为 22222..."
        if grep -qE '^#?Port ' /etc/ssh/sshd_config; then
            sed -i -E 's/^#?Port .*/Port 22222/' /etc/ssh/sshd_config
        else
            echo "Port 22222" >> /etc/ssh/sshd_config
        fi
        if sshd -t 2>/dev/null && systemctl restart sshd 2>/dev/null \
            && sleep 1 && ss -tln 2>/dev/null | grep -q ':22222'; then
            ssh_port=22222
            ok "SSH 已改到 22222 端口"
        else
            warn "SSH 端口修改失败，保持 22 端口"
            sed -i -E 's/^Port 22222/Port 22/' /etc/ssh/sshd_config
            systemctl restart sshd 2>/dev/null || true
            ssh_port=22
        fi
        log "加固：配置 fail2ban（3 次失败永久封禁）..."
        cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = -1
findtime = 600
maxretry = 3
[sshd]
enabled = true
port = $ssh_port
EOF
        systemctl enable --now fail2ban 2>/dev/null || warn "fail2ban 启动失败，请手动检查"
        sleep 1
        systemctl is-active --quiet fail2ban && ok "fail2ban 已启动" || warn "fail2ban 未运行，请手动检查：systemctl status fail2ban"
    fi
    SSH_PORT=$ssh_port
}

setup_network() {
    log "开启 IP 转发..."
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-awg.conf
    sysctl -p /etc/sysctl.d/99-awg.conf >/dev/null 2>&1 || sysctl -w net.ipv4.ip_forward=1 >/dev/null
    EXT_IF=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [[ -n "$EXT_IF" ]] || die "无法检测外网网卡"
    ok "外网网卡：$EXT_IF"
    log "配置 ufw（放行 SSH $SSH_PORT/tcp 与 AWG $PORT/udp）..."
    ufw allow "$SSH_PORT/tcp" >/dev/null 2>&1
    ufw allow "$PORT/udp" >/dev/null 2>&1
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        ok "ufw 已是 active，规则已添加"
    else
        ufw --force enable >/dev/null 2>&1 || warn "ufw 启用失败，请手动检查"
        ok "ufw 已启用"
    fi
}

# ---------- 状态与配置 ----------
create_state() {
    local keys priv pub obf prefix server_ip
    keys=$(gen_keypair) || die "密钥生成失败"
    priv=$(head -n1 <<<"$keys")
    pub=$(tail -n1 <<<"$keys")
    obf=$(gen_obfuscation_json) || die "混淆参数生成失败"
    prefix=$(echo "$SUBNET" | cut -d. -f1-3)
    server_ip="$prefix.254"
    mkdir -p "$STATE_DIR" "$CLIENT_DIR"
    chmod 700 "$STATE_DIR" "$CLIENT_DIR"
    jq -n \
        --arg iface awg0 --argjson port "$PORT" --arg subnet "$SUBNET" --arg sip "$server_ip" \
        --arg endpoint "$ENDPOINT" --arg dns "$DNS" --argjson mtu "$MTU" \
        --arg ext_if "$EXT_IF" --arg priv "$priv" --arg pub "$pub" \
        --argjson obf "$obf" --arg dp "$DATAPATH" \
        '{version:1,
          server:{interface:$iface, port:$port, subnet:$subnet, server_ip:$sip,
                  endpoint:$endpoint, dns:$dns, mtu:$mtu, ext_if:$ext_if,
                  private_key:$priv, public_key:$pub, obfuscation:$obf, datapath:$dp},
          clients:[], tombstones:[]}' > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
    ok "状态文件已创建：$STATE_FILE"
}

# ---------- 主流程 ----------
main() {
    # 重新读取非交互开关（source 时读过一次，这里再确认）
    NONINTERACTIVE=${AWG_NONINTERACTIVE:-0}
    echo "=============================================="
    echo "  AmneziaWG 3.1 服务端安装器"
    echo "=============================================="
    local os_info os_id os_code suite
    os_info=$(detect_os) || exit 1
    os_id=${os_info%% *}; os_code=${os_info##* }
    suite=$(ppa_suite_for "$os_code")
    log "系统：$os_id $os_code（PPA 源：$suite）"

    # 已安装检测
    if [[ -f "$STATE_FILE" ]]; then
        if [[ "${AWG_REINSTALL:-}" == "yes" ]]; then
            log "检测到已有安装，AWG_REINSTALL=yes，重新安装..."
        elif (( NONINTERACTIVE == 1 )); then
            die "检测到已有安装（$STATE_FILE）。重新安装请设置 AWG_REINSTALL=yes"
        elif whiptail --title "AmneziaWG 3.1 安装" --yesno "检测到已有安装（$STATE_FILE）。\n\n重新安装将删除现有状态、客户端与配置（先自动备份）。\n是否继续？" 11 60; then
            log "重新安装..."
        else
            die "已取消安装"
        fi
        systemctl stop awg-quick@awg0 2>/dev/null || true
        local bk
        bk="/root/awg-backup-before-reinstall-$(date +%Y%m%d-%H%M%S).tar.gz"
        tar -czf "$bk" -C / root/awg etc/amnezia/amneziawg 2>/dev/null || true
        echo "旧状态已备份到 $bk"
        rm -rf "$STATE_DIR" /etc/amnezia/amneziawg
    fi

    install_base_deps

    # 三级安装
    if ! install_awg_ppa "$suite"; then
        warn "PPA 安装未达到 3.1，改用源码编译"
        install_awg_source || die "源码编译也失败了，无法继续"
    fi
    ensure_datapath

    # 安装参数
    pick_port
    pick_subnet
    pick_endpoint
    pick_dns
    pick_mtu
    pick_hardening
    log "安装参数：端口 $PORT/udp，网段 $SUBNET，Endpoint $ENDPOINT，DNS $DNS，MTU $MTU，加固 $HARDENING"

    setup_hardening
    setup_network

    # 安装 awgman 并复用其函数生成状态与配置
    [[ -f "$SCRIPT_DIR/awgman" ]] || die "找不到 awgman（应与 install.sh 在同一目录）"
    install -m 755 "$SCRIPT_DIR/awgman" /usr/local/bin/awgman
    # shellcheck disable=SC1091
    source /usr/local/bin/awgman
    create_state
    write_server_config
    if ! systemctl enable --now awg-quick@awg0 2>/dev/null; then
        fallback_to_userspace
    fi
    sleep 2
    systemctl is-active --quiet awg-quick@awg0 || die "awg-quick@awg0 未能保持运行"
    awg show awg0 >/dev/null 2>&1 || die "awg show 失败，接口未正常建立"
    ok "AWG 服务已启动（$DATAPATH 模式）"

    echo ""
    echo "=============================================="
    echo "  安装完成"
    echo "=============================================="
    echo "  服务端内网地址：$(server_ip)"
    echo "  内网网段：$SUBNET"
    echo "  监听端口：$PORT/udp"
    echo "  客户端 Endpoint：$ENDPOINT:$PORT"
    echo "  数据面：$DATAPATH"
    echo "  SSH 端口：$SSH_PORT"
    echo ""
    echo "  下一步：运行 awgman 添加客户端"
    echo "    awgman            # 进入管理菜单"
    echo "    awgman add office # 命令行快速添加"
    echo ""
    echo "  客户端配置保存在：$CLIENT_DIR"
    echo "=============================================="
}

# 直接执行时进入主流程；被 source 时只加载函数（供测试复用）
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
