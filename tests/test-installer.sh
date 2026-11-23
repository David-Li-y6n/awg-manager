#!/bin/bash
# test-installer.sh — install.sh 纯函数单元测试（不触碰系统）
# 测 version_ge_31、ppa_suite_for、rand_subnet、rand_port、
# 以及 pick_* 的环境变量模式。完整安装流程在 S 上验证。
set -u
export LC_ALL=C.UTF-8

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
t_ok() { PASS=$((PASS+1)); echo "PASS: $1"; }
t_bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# 非交互开关须在 source 之前导出（install.sh 在加载时读取一次）
export AWG_NONINTERACTIVE=1
# shellcheck disable=SC1090
source "$DIR/install.sh"

echo "=== version_ge_31 ==="
version_ge_31 "3.1.20260812" && t_ok "3.1.20260812 >= 3.1" || t_bad "3.1.20260812 >= 3.1"
version_ge_31 "v3.1.20260812" && t_ok "v3.1 前缀处理" || t_bad "v3.1 前缀处理"
version_ge_31 "3.2.0" && t_ok "3.2 >= 3.1" || t_bad "3.2 >= 3.1"
version_ge_31 "4.0.0" && t_ok "4.0 >= 3.1" || t_bad "4.0 >= 3.1"
version_ge_31 "2.0.20240101" && t_bad "2.0 应 < 3.1" || t_ok "2.0 < 3.1"
version_ge_31 "1.0.20210914" && t_bad "1.0 应 < 3.1" || t_ok "1.0 < 3.1"
version_ge_31 "3.0.9" && t_bad "3.0 应 < 3.1" || t_ok "3.0 < 3.1"
version_ge_31 "garbage" && t_bad "非法版本应拒绝" || t_ok "非法版本拒绝"

echo "=== ppa_suite_for ==="
[[ "$(ppa_suite_for trixie)" == "noble" ]] && t_ok "trixie -> noble" || t_bad "trixie -> noble"
[[ "$(ppa_suite_for noble)" == "noble" ]] && t_ok "noble -> noble" || t_bad "noble -> noble"
[[ "$(ppa_suite_for bookworm)" == "jammy" ]] && t_ok "bookworm -> jammy" || t_bad "bookworm -> jammy"
[[ "$(ppa_suite_for jammy)" == "jammy" ]] && t_ok "jammy -> jammy" || t_bad "jammy -> jammy"

echo "=== rand_subnet / rand_port ==="
for _ in 1 2 3 4 5; do
    s=$(rand_subnet)
    [[ "$s" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.0/24$ ]] \
        && t_ok "随机网段 $s 在 CGNAT 内" || t_bad "随机网段 $s 不合法"
done
for _ in 1 2 3; do
    p=$(rand_port)
    (( p >= 10000 && p <= 60000 )) && t_ok "随机端口 $p 在范围内" || t_bad "随机端口 $p 越界"
done

echo "=== pick_* 环境变量模式 ==="
AWG_PORT=51820 pick_port
[[ "$PORT" == "51820" ]] && t_ok "AWG_PORT 生效" || t_bad "AWG_PORT 生效（得 $PORT）"
AWG_PORT=random pick_port
(( PORT >= 10000 && PORT <= 60000 )) && t_ok "AWG_PORT=random 生效" || t_bad "AWG_PORT=random 生效"
AWG_SUBNET=100.64.5.0/24 pick_subnet
[[ "$SUBNET" == "100.64.5.0/24" ]] && t_ok "AWG_SUBNET 生效" || t_bad "AWG_SUBNET 生效"
AWG_SUBNET=random pick_subnet
[[ "$SUBNET" =~ ^100\..*/24$ ]] && t_ok "AWG_SUBNET=random 生效" || t_bad "AWG_SUBNET=random 生效"
AWG_ENDPOINT=awg.example.com pick_endpoint
[[ "$ENDPOINT" == "awg.example.com" ]] && t_ok "AWG_ENDPOINT 生效" || t_bad "AWG_ENDPOINT 生效"
AWG_DNS=8.8.8.8 pick_dns
[[ "$DNS" == "8.8.8.8" ]] && t_ok "AWG_DNS 生效" || t_bad "AWG_DNS 生效"
AWG_MTU=1400 pick_mtu
[[ "$MTU" == "1400" ]] && t_ok "AWG_MTU 生效" || t_bad "AWG_MTU 生效"
AWG_HARDENING=no pick_hardening
[[ "$HARDENING" == "no" ]] && t_ok "AWG_HARDENING 生效" || t_bad "AWG_HARDENING 生效"
# 非交互默认
unset AWG_PORT AWG_SUBNET AWG_ENDPOINT AWG_DNS AWG_MTU AWG_HARDENING
pick_port; (( PORT >= 10000 && PORT <= 60000 )) && t_ok "非交互默认随机端口" || t_bad "非交互默认随机端口"
pick_subnet; [[ "$SUBNET" =~ ^100\..*/24$ ]] && t_ok "非交互默认随机网段" || t_bad "非交互默认随机网段"
pick_endpoint; [[ "$ENDPOINT" == "hkg3.nexv.me" ]] && t_ok "非交互默认 Endpoint" || t_bad "非交互默认 Endpoint"
pick_dns; [[ "$DNS" == "1.1.1.1" ]] && t_ok "非交互默认 DNS" || t_bad "非交互默认 DNS"
pick_mtu; [[ "$MTU" == "1280" ]] && t_ok "非交互默认 MTU" || t_bad "非交互默认 MTU"
pick_hardening; [[ "$HARDENING" == "yes" ]] && t_ok "非交互默认加固" || t_bad "非交互默认加固"

echo ""
echo "=============================================="
echo "  安装器测试：PASS $PASS，FAIL $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]]
