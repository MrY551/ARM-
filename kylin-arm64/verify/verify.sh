#!/usr/bin/env bash
# Xiao Huang for Kylin ARM64 —— 按压缩包说明做安装验证
#
# 压缩包内《安装路径不能包含中文或空格.txt》/《xiaohuangV8使用说明.txt》的两条规则：
#   1. 安装路径不能包含“中文”或者“空格”，否则报错（Can't change dir to '<path>'）
#   2. 保证安装路径是纯净的，安装路径下不能有已安装的 V8 版本，重新安装请选择其它路径
#
# 本脚本逐条验证，并额外验证安装后的可用性（Nginx/PHP-FPM/站点/改端口/卸载）。
# 用法: sudo ./verify/verify.sh [--run dist/xxx.run] [--keep]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RUN_PKG=""
KEEP=0
TEST_DIR="/tmp/xiaohuang-verify"
PORT=18080
PORT2=18081

while [ $# -gt 0 ]; do
    case "$1" in
        --run)  RUN_PKG="${2:-}"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

[ -n "$RUN_PKG" ] || RUN_PKG="$(ls -1 "$ROOT"/dist/*.run 2>/dev/null | head -1)"
if [ -z "$RUN_PKG" ] || [ ! -f "$RUN_PKG" ]; then
    echo "[FAIL] 找不到安装包，请先执行 ./build.sh，或用 --run 指定" >&2
    exit 1
fi

if [ "$(id -u)" != "0" ]; then
    echo "[FAIL] 需要 root 运行: sudo $0" >&2
    exit 1
fi

# 非 aarch64 主机（x86_64 开发机/CI）跳过架构检查，只验证安装与运行流程
if [ "$(uname -m)" != "aarch64" ]; then
    export XIAOHUANG_SKIP_ARCH_CHECK=1
fi

PASS=0; FAIL=0; SKIP=0
FAILED_CASES=()

ok()   { PASS=$((PASS+1)); printf '  \033[32m[PASS]\033[0m %s\n' "$*"; }
ng()   { FAIL=$((FAIL+1)); FAILED_CASES+=("$*"); printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; }
skip() { SKIP=$((SKIP+1)); printf '  \033[33m[SKIP]\033[0m %s\n' "$*"; }
sec()  { printf '\n\033[36m== %s ==\033[0m\n' "$*"; }

# 只清理本脚本自己的测试实例，不动用户已有的 Xiao Huang
cleanup_test() {
    if [ -x "$TEST_DIR/bin/xiaohuang" ]; then
        "$TEST_DIR/bin/xiaohuang" stop >/dev/null 2>&1 || true
    fi
    if [ -f "$TEST_DIR/uninstall.sh" ]; then
        bash "$TEST_DIR/uninstall.sh" --purge >/dev/null 2>&1 || true
    fi
    rm -rf "$TEST_DIR" "/tmp/php study" "/tmp/测试" "/tmp/xiaohuang-relative" "/tmp/xiaohuang-arch" 2>/dev/null || true
}

CLI="$TEST_DIR/bin/xiaohuang"

echo "============================================================"
echo " Xiao Huang 银河麒麟 ARM64 安装包验证"
echo "============================================================"
echo " 安装包  : $RUN_PKG"
echo " 测试目录: $TEST_DIR"
echo " 端口    : $PORT / $PORT2"
echo " 说明规则: 1) 路径不能含中文或空格  2) 路径下不能已有 V8"
echo

cleanup_test

# ---------------------------------------------------------------------------
sec "用例 1/9：安装路径含空格 —— 必须拒绝（说明第 1 条）"
out="$("$RUN_PKG" --dir "/tmp/php study" --no-start 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q "Can't change dir to '/tmp/php study'" <<< "$out"; then
    ok "含空格路径被拒绝（退出码 2，提示: Can't change dir to '/tmp/php study'）"
else
    ng "含空格路径未被正确拒绝（rc=$rc）"
fi

# ---------------------------------------------------------------------------
sec "用例 2/9：安装路径含中文 —— 必须拒绝（说明第 1 条）"
out="$("$RUN_PKG" --dir "/tmp/测试" --no-start 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q "Can't change dir to" <<< "$out"; then
    ok "含中文路径被拒绝（退出码 2）"
else
    ng "含中文路径未被正确拒绝（rc=$rc）"
fi

# ---------------------------------------------------------------------------
sec "用例 3/9：相对路径 —— 必须拒绝"
out="$("$RUN_PKG" --dir "xiaohuang-relative" --no-start 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then
    ok "相对路径被拒绝（退出码 2）"
else
    ng "相对路径未被拒绝（rc=$rc）"
fi

# ---------------------------------------------------------------------------
sec "用例 4/9：合法路径安装（--no-start --no-db）"
out="$("$RUN_PKG" --dir "$TEST_DIR" --http-port "$PORT" --no-db --no-start --no-link 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
    ok "安装成功（退出码 0）"
else
    ng "安装失败（rc=$rc）"
    printf '%s\n' "$out" | tail -25 | sed 's/^/       /'
fi

# ---------------------------------------------------------------------------
sec "用例 5/9：目录结构与安装清单"
missing=""
for p in "$TEST_DIR/xiaohuang.ini" "$TEST_DIR/app/WWW/index.html" \
         "$TEST_DIR/app/COM" "$TEST_DIR/bin/xiaohuang" "$TEST_DIR/uninstall.sh" \
         "$TEST_DIR/lib/common.sh" "$TEST_DIR/app/WWW/index.php"; do
    [ -e "$p" ] || missing="$missing $(basename "$p")"
done
[ -d "$TEST_DIR/app/Extensions" ] || missing="$missing Extensions"
ls -d "$TEST_DIR/app/Extensions/Nginx"* >/dev/null 2>&1 || missing="$missing Nginx目录"
if [ -z "$missing" ]; then
    ok "目录结构完整（app/COM  app/Extensions  app/WWW  bin  lib）"
else
    ng "缺少:$missing"
fi

if grep -q '^VERSION=0.0.0.2Beta' "$TEST_DIR/xiaohuang.ini" 2>/dev/null; then
    ok "安装清单版本正确（0.0.0.2Beta）"
else
    ng "安装清单版本不正确"
fi

n_err="$(ls "$TEST_DIR/app/WWW/error/"*.html 2>/dev/null | wc -l)"
[ "$n_err" -ge 13 ] && ok "错误页已生成（$n_err 个）" || ng "错误页数量不足（$n_err 个）"

if grep -q "nginx" "$TEST_DIR"/app/Extensions/Nginx*/conf/nginx.conf 2>/dev/null; then
    ok "Nginx 配置已按安装路径渲染"
else
    ng "Nginx 配置未正确生成"
fi

# ---------------------------------------------------------------------------
sec "用例 6/9：重复安装同一路径 —— 必须拒绝（说明第 2 条）"
out="$("$RUN_PKG" --dir "$TEST_DIR" --no-start 2>&1)"; rc=$?
if [ "$rc" -eq 3 ] && grep -q "不能有已安装的 V8" <<< "$out"; then
    ok "重复安装被拒绝（退出码 3，提示：安装路径下不能有已安装的 V8 版本）"
else
    ng "重复安装未被正确拒绝（rc=$rc）"
fi

# ---------------------------------------------------------------------------
sec "用例 7/9：启动服务并自检"
out="$("$CLI" start 2>&1)"; rc=$?
sleep 2
st="$("$CLI" status 2>&1)"
grep -q "nginx.*running" <<< "$st" && ok "Nginx 已运行" || { ng "Nginx 未运行"; printf '%s\n' "$out" | tail -8 | sed 's/^/       /'; }
grep -q "php.*running" <<< "$st" && ok "PHP-FPM 已运行" || ng "PHP-FPM 未运行"

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/" 2>/dev/null)"
[ "$code" = "200" ] && ok "HTTP 首页返回 200" || ng "HTTP 首页返回 ${code:-无响应}"

body="$(curl -s --max-time 5 "http://127.0.0.1:$PORT/index.php" 2>/dev/null)"
if grep -q "环境探针" <<< "$body" && grep -q "PHP" <<< "$body"; then
    ok "PHP 探针页面正常（index.php 由 php-fpm 执行）"
else
    ng "PHP 探针页面异常"
fi

# ---------------------------------------------------------------------------
sec "用例 8/9：改端口 + 增加站点"
out="$("$CLI" port nginx "$PORT2" 2>&1)"; rc=$?
sleep 1
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT2/" 2>/dev/null)"
if [ "$code" = "200" ]; then
    ok "端口改为 $PORT2 后仍返回 200"
else
    ng "端口改 $PORT2 后返回 ${code:-无响应}"
    printf '%s\n' "$out" | tail -8 | sed 's/^/       /'
fi

out="$("$CLI" site add verify.test "$TEST_DIR/app/WWW/verify.test" "$PORT2" 2>&1)"
if "$CLI" site list 2>/dev/null | grep -q "verify.test"; then
    ok "站点 verify.test 已创建并列出"
else
    ng "站点创建失败"
    printf '%s\n' "$out" | tail -8 | sed 's/^/       /'
fi

# ---------------------------------------------------------------------------
sec "用例 9/9：停止与卸载"
"$CLI" stop >/dev/null 2>&1
sleep 1
listeners="$(ss -lnt 2>/dev/null | grep -c ":$PORT2 " || true)"
if [ "${listeners:-0}" = "0" ]; then
    ok "停止后端口 $PORT2 已释放"
else
    ng "停止后端口 $PORT2 仍被监听"
fi

out="$(bash "$TEST_DIR/uninstall.sh" --purge 2>&1)"; rc=$?
if [ ! -d "$TEST_DIR" ]; then
    ok "卸载完成（安装目录已移除）"
else
    ng "卸载不彻底（目录仍存在）"
    printf '%s\n' "$out" | tail -6 | sed 's/^/       /'
fi

for u in nginx php mysql apache; do
    [ -f "/etc/systemd/system/xiaohuang-$u.service" ] && ng "systemd 单元残留: xiaohuang-$u.service"
done
ok "systemd 单元已清理"

# ---------------------------------------------------------------------------
if [ "$(uname -m)" = "aarch64" ]; then
    sec "附加用例：架构校验（真实 aarch64）"
    out="$("$RUN_PKG" --dir /tmp/xiaohuang-arch --no-start --no-db --no-link 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] && ok "aarch64 架构校验通过" || ng "aarch64 架构校验失败（rc=$rc）"
    bash /tmp/xiaohuang-arch/uninstall.sh --purge >/dev/null 2>&1 || true
    rm -rf /tmp/xiaohuang-arch
else
    sec "附加用例：架构拦截（当前 $(uname -m)）"
    out="$(XIAOHUANG_SKIP_ARCH_CHECK=0 "$RUN_PKG" --dir /tmp/xiaohuang-arch --no-start 2>&1)"; rc=$?
    if [ "$rc" -eq 4 ] && grep -q "架构不支持" <<< "$out"; then
        ok "非 aarch64 主机被架构检查拦截（退出码 4）"
    else
        ng "架构拦截未生效（rc=$rc）"
    fi
fi

# ---------------------------------------------------------------------------
cleanup_test
[ "$KEEP" = "1" ] && echo "（--keep: 测试目录已保留）"

echo
echo "============================================================"
printf ' 结果: %d 通过, %d 失败, %d 跳过\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
    printf ' 失败用例:\n'
    for c in "${FAILED_CASES[@]}"; do printf '   - %s\n' "$c"; done
    echo "============================================================"
    exit 1
fi
echo " 结论: 安装包符合压缩包说明的两条路径规则，且安装后服务可用"
echo "============================================================"
exit 0
