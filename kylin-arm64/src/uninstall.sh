#!/usr/bin/env bash
# Xiao Huang for Kylin ARM64 —— 卸载器
# 用法: uninstall.sh [--purge]
#   --purge  同时删除站点数据(WWW 下用户站点)与 MySQL data 目录
set -uo pipefail

SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
INSTALL_DIR="${XIAOHUANG_HOME:-$SELF_DIR}"
[ -f "$INSTALL_DIR/xiaohuang.ini" ] || INSTALL_DIR="$(cd "$SELF_DIR/.." && pwd)"

MANIFEST="$INSTALL_DIR/xiaohuang.ini"
if [ ! -f "$MANIFEST" ]; then
    printf '[FAIL] 未找到安装清单: %s\n' "$MANIFEST" >&2
    exit 1
fi
# shellcheck source=lib/common.sh
. "$INSTALL_DIR/lib/common.sh"

PURGE=0
case "${1:-}" in
    --purge) PURGE=1 ;;
    -h|--help) printf '用法: %s [--purge]\n' "$0"; exit 0 ;;
esac

m() { manifest_get "$INSTALL_DIR" "$1" 2>/dev/null || true; }

SUPERVISOR="$(m SUPERVISOR)"; SUPERVISOR="${SUPERVISOR:-pidfile}"
NGINX_HOME="$(m NGINX_HOME)"; NGINX_BIN="$(m NGINX_BIN)"
PHP_HOME="$(m PHP_HOME)"; PHP_FPM_BIN="$(m PHP_FPM_BIN)"
APACHE_HOME="$(m APACHE_HOME)"; APACHE_BIN="$(m APACHE_BIN)"
MYSQL_HOME="$(m MYSQL_HOME)"; MYSQLD_BIN="$(m MYSQLD_BIN)"
RUN_DIR="$INSTALL_DIR/run"

log_step "停止服务"
for svc in nginx apache php mysql ftp panel; do
    unit="xiaohuang-${svc}.service"
    if [ "$SUPERVISOR" = "systemd" ] && has_systemd && [ -f "/etc/systemd/system/$unit" ]; then
        systemctl stop "$unit" >/dev/null 2>&1 || true
        systemctl disable "$unit" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$unit"
        log_info "已移除 $unit"
    fi
done
# 兜底：目录里任何残留的 xiaohuang-* 单元一并清掉
for u in /etc/systemd/system/xiaohuang-*.service; do
    [ -f "$u" ] || continue
    systemctl stop "$(basename "$u")" >/dev/null 2>&1 || true
    systemctl disable "$(basename "$u")" >/dev/null 2>&1 || true
    rm -f "$u"
    log_info "已移除 $(basename "$u")"
done
# PAM 配置（FTP 用）
rm -f /etc/pam.d/xiaohuang-vsftpd 2>/dev/null || true
# pidfile 模式下兜底按 pid 文件停止
for pf in "$NGINX_HOME/logs/nginx.pid" "$RUN_DIR/php-fpm.pid" "$RUN_DIR/httpd.pid" "$RUN_DIR/mysqld.pid"; do
    [ -f "$pf" ] || continue
    pid="$(cat "$pf" 2>/dev/null || true)"
    [ -n "${pid:-}" ] && kill "$pid" 2>/dev/null || true
done
[ "$SUPERVISOR" = "systemd" ] && has_systemd && systemctl daemon-reload

log_step "清理解除接管提示"
if [ -f "$INSTALL_DIR/.disabled-system-services" ]; then
    log_warn "安装时停用的系统服务（需手动恢复）:"
    sed 's/^/       /' "$INSTALL_DIR/.disabled-system-services"
    log_warn "恢复命令示例: systemctl enable --now nginx"
fi

log_step "删除文件"
if [ "$PURGE" != "1" ]; then
    # 保留用户站点与数据库
    if [ -n "$MYSQL_HOME" ] && [ -d "$MYSQL_HOME/data" ]; then
        log_warn "保留数据库数据: $MYSQL_HOME/data"
    fi
fi
if [ -L /usr/local/bin/xiaohuang ] && [ "$(readlink -f /usr/local/bin/xiaohuang)" = "$INSTALL_DIR/bin/xiaohuang" ]; then
    rm -f /usr/local/bin/xiaohuang
fi

if [ "$PURGE" = "1" ]; then
    log_warn "删除整个安装目录（含站点与数据库数据）: $INSTALL_DIR"
    rm -rf "$INSTALL_DIR"
else
    # 只删除程序与配置，保留 WWW 下用户站点、MySQL data
    log_info "删除程序文件，保留站点与数据库数据"
    for d in app/COM app/Extensions app/WWW/error bin lib conf templates run logs uninstall.sh; do
        rm -rf "$INSTALL_DIR/$d"
    done
    find "$INSTALL_DIR" -maxdepth 1 -type f ! -name "$MANIFEST_NAME" -delete 2>/dev/null || true
    printf '# 已卸载，保留站点与数据库数据\nUNINSTALLED=1\nUNINSTALL_TIME=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$MANIFEST"
    log_warn "安装目录仍保留: $INSTALL_DIR（站点与数据库）。彻底删除请执行: rm -rf $INSTALL_DIR"
fi

log_ok "卸载完成"
exit 0
