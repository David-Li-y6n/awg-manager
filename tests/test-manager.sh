#!/bin/bash
# test-manager.sh — awgman 管理流程测试（沙箱内运行）
# 用真实 awg 二进制（PPA 3.1.20260812）+ mock 的 systemctl/ufw/qrencode，
# 跑通全部 CLI 流程并断言状态、配置与墓碑规则。
# 注意：沙箱无 CAP_NET_ADMIN，无法真正拉起接口；服务启动/握手在 S 上验证。
# 用法：bash tests/test-manager.sh

set -u
export LC_ALL=C.UTF-8

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWGMAN="$DIR/awgman"
INSTALLER="$DIR/install.sh"
MOCKBIN="$DIR/tests/mockbin"
export PATH="$MOCKBIN:$PATH"
export MOCK_LOG=/tmp/awg-test-mock.log

PASS=0; FAIL=0
assert() {
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "PASS: $desc";
    else FAIL=$((FAIL+1)); echo "FAIL: $desc"; fi
}
assert_eq() {
    if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); echo "PASS: $1";
    else FAIL=$((FAIL+1)); echo "FAIL: $1（期望 [$2]，实际 [$3]）"; fi
}
assert_contains() {
    if grep -qF "$3" "$2" 2>/dev/null; then PASS=$((PASS+1)); echo "PASS: $1";
    else FAIL=$((FAIL+1)); echo "FAIL: $1（$2 中未找到 [$3]）"; fi
}
assert_not_contains() {
    if ! grep -qF "$3" "$2" 2>/dev/null; then PASS=$((PASS+1)); echo "PASS: $1";
    else FAIL=$((FAIL+1)); echo "FAIL: $1（$2 中不应出现 [$3]）"; fi
}

OUT=""; RC=0
run_awgman() { OUT=$(bash "$AWGMAN" "$@" 2>&1); RC=$?; }

echo "=== 准备：清理旧状态，创建初始状态 ==="
rm -rf /root/awg /etc/amnezia/amneziawg
rm -f "$MOCK_LOG"
# 复用安装器的 create_state（同时测到密钥与混淆参数生成）
# shellcheck disable=SC1090
source "$INSTALLER"
# shellcheck disable=SC1090
source "$AWGMAN"
PORT=51820 SUBNET="100.64.12.0/24" ENDPOINT="hkg3.nexv.me" DNS="1.1.1.1" MTU=1280 EXT_IF="eth0" DATAPATH="kernel"
create_state
write_server_config
assert_eq "状态文件已创建" "100.64.12.254" "$(jq -r '.server.server_ip' /root/awg/state.json)"
assert_eq "服务端端口" "51820" "$(jq -r '.server.port' /root/awg/state.json)"
assert "服务端配置已生成" test -f /etc/amnezia/amneziawg/awg0.conf
assert_eq "服务端配置权限 600" "600" "$(stat -c %a /etc/amnezia/amneziawg/awg0.conf)"
assert_eq "状态文件权限 600" "600" "$(stat -c %a /root/awg/state.json)"

echo "=== 3.1 混淆参数校验 ==="
S1=$(grep '^S1 = ' /etc/amnezia/amneziawg/awg0.conf | awk '{print $3}')
S2=$(grep '^S2 = ' /etc/amnezia/amneziawg/awg0.conf | awk '{print $3}')
S3=$(grep '^S3 = ' /etc/amnezia/amneziawg/awg0.conf | awk '{print $3}')
S4=$(grep '^S4 = ' /etc/amnezia/amneziawg/awg0.conf | awk '{print $3}')
assert_eq "S1=S2=S3=S4" "$S1" "$S2"
assert_eq "S1=S3" "$S1" "$S3"
assert_eq "S1=S4" "$S1" "$S4"
assert "S1 >= 12" test "$S1" -ge 12
assert "S4 <= 32" test "$S4" -le 32
assert_contains "含 HeaderProtectionKey" /etc/amnezia/amneziawg/awg0.conf "HeaderProtectionKey = "
assert_contains "含 RandomTrailers = on" /etc/amnezia/amneziawg/awg0.conf "RandomTrailers = on"
assert_contains "含 ContentPaddingAddition" /etc/amnezia/amneziawg/awg0.conf "ContentPaddingAddition = "
assert_contains "含 RekeyAfterTime" /etc/amnezia/amneziawg/awg0.conf "RekeyAfterTime = "
assert_contains "含 MaxHandshakeAttempts" /etc/amnezia/amneziawg/awg0.conf "MaxHandshakeAttempts = "
assert_contains "H1=1" /etc/amnezia/amneziawg/awg0.conf "H1 = 1"
assert_contains "H4=4" /etc/amnezia/amneziawg/awg0.conf "H4 = 4"
assert "I1 存在且非空" grep -qE '^I1 = <r [0-9]+>$' /etc/amnezia/amneziawg/awg0.conf
assert_not_contains "无 I2 空行" /etc/amnezia/amneziawg/awg0.conf "I2 = "
assert_not_contains "无 I5 空行" /etc/amnezia/amneziawg/awg0.conf "I5 = "
assert_contains "含 PostUp NAT" /etc/amnezia/amneziawg/awg0.conf "MASQUERADE"

echo "=== 添加客户端 ==="
run_awgman add office "客厅电脑"
assert_eq "add office 成功" 0 "$RC"
assert_eq "office 分到 .2" "100.64.12.2" "$(jq -r '.clients[] | select(.name=="office") | .ip' /root/awg/state.json)"
assert "office 配置存在" test -f /root/awg/clients/office.conf
assert "office Linux 安装脚本存在" test -f /root/awg/clients/office-install.sh
assert "office Windows 安装脚本存在" test -f /root/awg/clients/office-install.ps1
assert "office-install.sh 可执行" test -x /root/awg/clients/office-install.sh
bash -n /root/awg/clients/office-install.sh \
    && { PASS=$((PASS+1)); echo "PASS: office-install.sh 语法正确"; } \
    || { FAIL=$((FAIL+1)); echo "FAIL: office-install.sh 语法错误"; }
assert_contains "office-install.sh 含 awg-quick 服务" /root/awg/clients/office-install.sh "awg-quick@\$NAME"
assert_contains "office-install.sh 自动安装 tools" /root/awg/clients/office-install.sh "amneziawg-tools，正在从官方 PPA 安装"
assert_contains "office-install.sh 含 PPA 源" /root/awg/clients/office-install.sh "ppa.launchpadcontent.net/amnezia/ppa"
assert_contains "office-install.sh 含内核头文件" /root/awg/clients/office-install.sh "linux-headers-"
assert_contains "office-install.sh 头文件安装限时" /root/awg/clients/office-install.sh "timeout 300 apt-get install"
assert_contains "office-install.sh 含 amneziawg-go fallback" /root/awg/clients/office-install.sh "amneziawg-go"
assert_contains "office-install.sh 校验 amneziawg-go 哈希" /root/awg/clients/office-install.sh "AWG_GO_SHA256"
assert_contains "office-install.sh 自动找同目录配置" /root/awg/clients/office-install.sh 'DIR="$(cd "$(dirname "$0")"'
assert_contains "office-install.ps1 含 installtunnelservice" /root/awg/clients/office-install.ps1 "/installtunnelservice"
assert_contains "office-install.ps1 含管理员检查" /root/awg/clients/office-install.ps1 "IsInRole"
assert_contains "office-install.ps1 注释含真实文件名" /root/awg/clients/office-install.ps1 '.\office-install.ps1'
# 直接调用 write_install_scripts（外层无 name 变量）：测 set -u 下 local 展开问题
rm -f /root/awg/clients/office-install.sh /root/awg/clients/office-install.ps1
bash -c "source \"$AWGMAN\"; write_install_scripts office" >/dev/null 2>&1
assert_eq "直接调用 write_install_scripts 成功" 0 "$?"
assert "直接调用后脚本重新生成" test -f /root/awg/clients/office-install.sh -a -f /root/awg/clients/office-install.ps1
run_awgman show office
assert_contains "show 含安装脚本法" <(echo "$OUT") "sudo bash office-install.sh"
assert "office 二维码存在" test -f /root/awg/clients/office.png
assert_contains "office 配置含备注注释" /root/awg/clients/office.conf "# 备注：客厅电脑"
assert_contains "office 分流 AllowedIPs" /root/awg/clients/office.conf "AllowedIPs = 100.64.12.0/24"
assert_not_contains "office 分流无 DNS" /root/awg/clients/office.conf "DNS = "
assert_contains "office Endpoint 用域名" /root/awg/clients/office.conf "Endpoint = hkg3.nexv.me:51820"
assert_contains "服务端配置含 office peer" /etc/amnezia/amneziawg/awg0.conf "AllowedIPs = 100.64.12.2/32"

run_awgman add laptop "出差笔记本" auto full
assert_eq "add laptop(full) 成功" 0 "$RC"
assert_eq "laptop 分到 .3" "100.64.12.3" "$(jq -r '.clients[] | select(.name=="laptop") | .ip' /root/awg/state.json)"
assert_contains "laptop 全量 AllowedIPs" /root/awg/clients/laptop.conf "AllowedIPs = 0.0.0.0/0"
assert_contains "laptop 全量推送 DNS" /root/awg/clients/laptop.conf "DNS = 1.1.1.1"

run_awgman add phone "手机" 100.64.12.10
assert_eq "add phone 自定义 IP 成功" 0 "$RC"
assert_eq "phone IP 为 .10" "100.64.12.10" "$(jq -r '.clients[] | select(.name=="phone") | .ip' /root/awg/state.json)"

echo "=== 添加失败用例 ==="
run_awgman add phone2 "x" 100.64.12.10
assert_eq "占用中 IP 应失败" 1 "$RC"
run_awgman add phone2 "x" 10.0.0.5
assert_eq "非本网段 IP 应失败" 1 "$RC"
run_awgman add "bad name" "x"
assert_eq "非法名称应失败" 1 "$RC"
run_awgman add office "重复"
assert_eq "重名应失败" 1 "$RC"
run_awgman add toolongname12345 "x"
assert_eq "超长名称应失败" 1 "$RC"

echo "=== 列表与拓扑 ==="
run_awgman list
assert_eq "list 成功" 0 "$RC"
echo "$OUT" | grep -q "office" && PASS=$((PASS+1)) && echo "PASS: list 含 office" || { FAIL=$((FAIL+1)); echo "FAIL: list 含 office"; }
run_awgman topology
assert_eq "topology 成功" 0 "$RC"
echo "$OUT" | grep -q "客厅电脑" && PASS=$((PASS+1)) && echo "PASS: 拓扑含中文备注" || { FAIL=$((FAIL+1)); echo "FAIL: 拓扑含中文备注"; }
echo "$OUT" | grep -q "100.64.12.254" && PASS=$((PASS+1)) && echo "PASS: 拓扑含服务端 .254" || { FAIL=$((FAIL+1)); echo "FAIL: 拓扑含服务端 .254"; }
echo "$OUT" | grep -q "★ S" && PASS=$((PASS+1)) && echo "PASS: 拓扑服务端有 ★ 标记" || { FAIL=$((FAIL+1)); echo "FAIL: 拓扑服务端缺 ★ 标记"; }
echo "$OUT" | grep -q "─" && PASS=$((PASS+1)) && echo "PASS: 拓扑含分隔线" || { FAIL=$((FAIL+1)); echo "FAIL: 拓扑缺分隔线"; }
echo "$OUT" | grep -q "在线 0 个" && PASS=$((PASS+1)) && echo "PASS: 拓扑含在线计数" || { FAIL=$((FAIL+1)); echo "FAIL: 拓扑缺在线计数"; }

echo "=== 删除与墓碑规则 ==="
run_awgman del laptop
assert_eq "del laptop 成功" 0 "$RC"
assert "laptop 配置已删除" test ! -f /root/awg/clients/laptop.conf
assert_eq "墓碑记下 .3" "100.64.12.3" "$(jq -r '.tombstones[0].ip' /root/awg/state.json)"
assert_not_contains "服务端配置已去掉 laptop" /etc/amnezia/amneziawg/awg0.conf "100.64.12.3/32"
run_awgman add laptop2 "新笔记本"
assert_eq "add laptop2 成功" 0 "$RC"
assert_eq "laptop2 跳过墓碑 .3，分到 .4" "100.64.12.4" "$(jq -r '.clients[] | select(.name=="laptop2") | .ip' /root/awg/state.json)"
run_awgman add reuse "复用测试" 100.64.12.3
assert_eq "墓碑 IP 无 force 应返回 3" 3 "$RC"
run_awgman add reuse "复用测试" 100.64.12.3 split --force
assert_eq "墓碑 IP 加 force 应成功" 0 "$RC"
assert_eq "reuse 拿到 .3" "100.64.12.3" "$(jq -r '.clients[] | select(.name=="reuse") | .ip' /root/awg/state.json)"
assert_eq "复用后墓碑清空" 0 "$(jq -r '.tombstones | length' /root/awg/state.json)"

echo "=== 启用/禁用/备注/模式/密钥 ==="
run_awgman disable phone
assert_eq "disable phone 成功" 0 "$RC"
assert_not_contains "禁用后服务端无 phone" /etc/amnezia/amneziawg/awg0.conf "100.64.12.10/32"
run_awgman enable phone
assert_eq "enable phone 成功" 0 "$RC"
assert_contains "启用后服务端恢复 phone" /etc/amnezia/amneziawg/awg0.conf "100.64.12.10/32"
run_awgman remark office "新备注-书房电脑"
assert_eq "remark 成功" 0 "$RC"
assert_contains "配置注释更新备注" /root/awg/clients/office.conf "# 备注：新备注-书房电脑"
run_awgman tunnel office full
assert_eq "tunnel full 成功" 0 "$RC"
assert_contains "office 改全量" /root/awg/clients/office.conf "AllowedIPs = 0.0.0.0/0"
run_awgman tunnel office split
assert_eq "tunnel split 成功" 0 "$RC"
assert_contains "office 改回分流" /root/awg/clients/office.conf "AllowedIPs = 100.64.12.0/24"
OLD_PUB=$(jq -r '.clients[] | select(.name=="office") | .public_key' /root/awg/state.json)
run_awgman regen-keys office
assert_eq "regen-keys 成功" 0 "$RC"
NEW_PUB=$(jq -r '.clients[] | select(.name=="office") | .public_key' /root/awg/state.json)
[[ "$OLD_PUB" != "$NEW_PUB" ]] && PASS=$((PASS+1)) && echo "PASS: 密钥已更换" || { FAIL=$((FAIL+1)); echo "FAIL: 密钥已更换"; }

echo "=== 配置文件语法（真实 3.1 解析器） ==="
# awg setconf 先解析文件再调 netlink：解析错报 "Configuration parsing error"，
# 解析通过则报 netlink 错误（沙箱无内核模块）。去掉 awg-quick 专属指令再测。
strip_q() { grep -vE '^(Address|DNS|MTU|PostUp|PostDown|SaveConfig)[[:space:]]*=' "$1"; }
strip_q /etc/amnezia/amneziawg/awg0.conf > /tmp/srv-stripped.conf
PARSE_OUT=$(awg setconf awg0 /tmp/srv-stripped.conf 2>&1 || true)
if echo "$PARSE_OUT" | grep -q "Configuration parsing error"; then
    FAIL=$((FAIL+1)); echo "FAIL: 服务端配置解析失败：$PARSE_OUT"
else
    PASS=$((PASS+1)); echo "PASS: 服务端配置通过 3.1 解析器（$PARSE_OUT）"
fi
strip_q /root/awg/clients/office.conf > /tmp/cli-stripped.conf
PARSE_OUT=$(awg setconf awg0 /tmp/cli-stripped.conf 2>&1 || true)
if echo "$PARSE_OUT" | grep -q "Configuration parsing error"; then
    FAIL=$((FAIL+1)); echo "FAIL: 客户端配置解析失败：$PARSE_OUT"
else
    PASS=$((PASS+1)); echo "PASS: 客户端配置通过 3.1 解析器（$PARSE_OUT）"
fi

echo "=== 服务端/客户端混淆参数一致 ==="
grep -E '^(Jc|Jmin|Jmax|S1|S2|S3|S4|H1|H2|H3|H4|I1|HeaderProtectionKey|ContentPaddingAddition|RekeyAfterTime|RekeyTimeout|RejectAfterTime|KeepaliveTimeout|MaxHandshakeAttempts|RandomTrailers|DisableCookies) = ' /etc/amnezia/amneziawg/awg0.conf | sort > /tmp/obf-server.txt
grep -E '^(Jc|Jmin|Jmax|S1|S2|S3|S4|H1|H2|H3|H4|I1|HeaderProtectionKey|ContentPaddingAddition|RekeyAfterTime|RekeyTimeout|RejectAfterTime|KeepaliveTimeout|MaxHandshakeAttempts|RandomTrailers|DisableCookies) = ' /root/awg/clients/office.conf | sort > /tmp/obf-client.txt
assert "服务端与客户端混淆参数一致" diff -q /tmp/obf-server.txt /tmp/obf-client.txt

echo "=== 网络修改 ==="
run_awgman port 51899
assert_eq "port 修改成功" 0 "$RC"
assert_contains "ufw 删除旧端口" "$MOCK_LOG" "ufw delete allow 51820/udp"
assert_contains "ufw 放行新端口" "$MOCK_LOG" "ufw allow 51899/udp"
assert_contains "客户端配置更新端口" /root/awg/clients/office.conf "Endpoint = hkg3.nexv.me:51899"
run_awgman endpoint awg.example.com
assert_eq "endpoint 修改成功" 0 "$RC"
assert_contains "客户端配置更新域名" /root/awg/clients/office.conf "Endpoint = awg.example.com:51899"
run_awgman dns 8.8.8.8
assert_eq "dns 修改成功" 0 "$RC"
run_awgman subnet 100.99.88.0/24
assert_eq "subnet 修改成功" 0 "$RC"
assert_eq "office 主机位不变 .2" "100.99.88.2" "$(jq -r '.clients[] | select(.name=="office") | .ip' /root/awg/state.json)"
assert_eq "phone 主机位不变 .10" "100.99.88.10" "$(jq -r '.clients[] | select(.name=="phone") | .ip' /root/awg/state.json)"
assert_eq "服务端新 .254" "100.99.88.254" "$(jq -r '.server.server_ip' /root/awg/state.json)"
assert_contains "客户端配置更新网段" /root/awg/clients/office.conf "AllowedIPs = 100.99.88.0/24"
assert_contains "客户端配置更新地址" /root/awg/clients/office.conf "Address = 100.99.88.2/32"
OLD_HPK=$(grep '^HeaderProtectionKey' /etc/amnezia/amneziawg/awg0.conf)
echo "=== 随机端口/网段与无变化提示 ==="
OLD_PORT=$(jq -r '.server.port' /root/awg/state.json)
run_awgman port random
assert_eq "port random 成功" 0 "$RC"
NEW_PORT=$(jq -r '.server.port' /root/awg/state.json)
[[ "$NEW_PORT" != "$OLD_PORT" ]] && [[ "$NEW_PORT" =~ ^[0-9]+$ ]] && (( NEW_PORT >= 10000 && NEW_PORT <= 60000 )) \
    && { PASS=$((PASS+1)); echo "PASS: 随机端口 $NEW_PORT 在 10000-60000 内且已更换"; } \
    || { FAIL=$((FAIL+1)); echo "FAIL: 随机端口未生效（旧 $OLD_PORT，新 $NEW_PORT）"; }
assert_contains "随机端口后 ufw 放行新端口" "$MOCK_LOG" "allow $NEW_PORT/udp"
run_awgman port "$NEW_PORT"
assert_eq "同端口返回 0" 0 "$RC"
echo "$OUT" | grep -q "无需修改" \
    && { PASS=$((PASS+1)); echo "PASS: 同端口提示无需修改"; } \
    || { FAIL=$((FAIL+1)); echo "FAIL: 同端口未提示无需修改：$OUT"; }
OLD_SUBNET=$(jq -r '.server.subnet' /root/awg/state.json)
run_awgman subnet random
assert_eq "subnet random 成功" 0 "$RC"
NEW_SUBNET=$(jq -r '.server.subnet' /root/awg/state.json)
[[ "$NEW_SUBNET" != "$OLD_SUBNET" ]] && [[ "$NEW_SUBNET" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.0/24$ ]] \
    && { PASS=$((PASS+1)); echo "PASS: 随机网段 $NEW_SUBNET 在 CGNAT 内且已更换"; } \
    || { FAIL=$((FAIL+1)); echo "FAIL: 随机网段未生效（旧 $OLD_SUBNET，新 $NEW_SUBNET）"; }
assert_contains "随机网段后客户端配置更新" /root/awg/clients/office.conf "AllowedIPs = $NEW_SUBNET"

run_awgman regen-obfuscation
assert_eq "regen-obfuscation 成功" 0 "$RC"
NEW_HPK=$(grep '^HeaderProtectionKey' /etc/amnezia/amneziawg/awg0.conf)
[[ "$OLD_HPK" != "$NEW_HPK" ]] && PASS=$((PASS+1)) && echo "PASS: 混淆参数已更换" || { FAIL=$((FAIL+1)); echo "FAIL: 混淆参数已更换"; }

echo "=== 备份与恢复 ==="
OFFICE_PUB_BEFORE=$(jq -r '.clients[] | select(.name=="office") | .public_key' /root/awg/state.json)
run_awgman backup
assert_eq "backup 成功" 0 "$RC"
BK=$(ls -t /root/awg/backups/*.tar.gz | head -n1)
assert "备份文件存在" test -f "$BK"
run_awgman del office
assert_eq "del office 成功" 0 "$RC"
assert "office 已删除" test ! -f /root/awg/clients/office.conf
assert "删除时安装脚本一并清理" test ! -f /root/awg/clients/office-install.sh -a ! -f /root/awg/clients/office-install.ps1
run_awgman restore "$BK"
assert_eq "restore 成功" 0 "$RC"
assert "恢复后 office 配置回来" test -f /root/awg/clients/office.conf
OFFICE_PUB_AFTER=$(jq -r '.clients[] | select(.name=="office") | .public_key' /root/awg/state.json)
assert_eq "恢复后 office 密钥不变" "$OFFICE_PUB_BEFORE" "$OFFICE_PUB_AFTER"

echo "=== 释放墓碑与 show ==="
run_awgman del phone
run_awgman release-tombstones
assert_eq "release-tombstones 成功" 0 "$RC"
assert_eq "墓碑已清空" 0 "$(jq -r '.tombstones | length' /root/awg/state.json)"
run_awgman show office
assert_eq "show 成功" 0 "$RC"
echo "$OUT" | grep -q "installtunnelservice" && PASS=$((PASS+1)) && echo "PASS: show 含 Windows 安装命令" || { FAIL=$((FAIL+1)); echo "FAIL: show 含 Windows 安装命令"; }
echo "$OUT" | grep -q "awg-quick@office" && PASS=$((PASS+1)) && echo "PASS: show 含 Linux 安装命令" || { FAIL=$((FAIL+1)); echo "FAIL: show 含 Linux 安装命令"; }

echo "=== 服务重启调用 ==="
RESTARTS=$(grep -c "systemctl restart awg-quick@awg0" "$MOCK_LOG")
assert "服务重启被调用过（>=10 次）" test "$RESTARTS" -ge 10
echo "（实际重启次数：$RESTARTS）"

echo ""
echo "=============================================="
echo "  测试结果：PASS $PASS，FAIL $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]]
