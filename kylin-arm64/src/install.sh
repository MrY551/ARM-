#!/usr/bin/env bash
# Xiao Huang for Kylin ARM64 —— 安装器主程序
# 与 Windows 版 xiaohuang_x64_0.0.0.1Beta.exe 的安装契约对齐：
#   目录布局 app/COM app/Extensions app/WWW
#   路径规则：不允许中文/空格；安装路径必须纯净（不能已有 V8）
#   组件：Nginx / Apache / PHP(php-cgi/FPM) / MySQL / FTP / ErrorPages
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SELF_DIR/lib/common.sh"

DEFAULT_DIR="/opt/xiaohuang"
INSTALL_DIR=""
HTTP_PORT=""
DB_PORT=""
DO_START=1
DO_DB=1
# Nginx 与 Apache 不能同时占用同一端口：默认只装 Nginx，
# Apache 作为可切换组件由 --with-apache 安装，安装后默认不启动（xiaohuang switch apache 切换）
DO_APACHE=0
DO_FTP=1
FTP_PORT=""
FTP_HOME=""; FTP_BIN=""; FTP_VER=""; PASV_MIN=""; PASV_MAX=""
DO_PHP=1
SUPERVISOR="auto"
OFFLINE_DIR=""
LINK_CLI=1
FORCE=0
DEFAULT_ROOT_PASS="root"

usage() {
    cat <<EOF
Xiao Huang ${XIAOHUANG_VERSION} (${XIAOHUANG_BUILD})

用法: $0 [选项]

  --dir PATH            安装路径，必须纯英文无空格（默认 $DEFAULT_DIR）
  --http-port PORT      Nginx/Apache 监听端口（默认 80，被占用时自动递增）
  --db-port PORT        MySQL 端口（默认 3306）
  --no-db               不安装/不启动 MySQL
  --with-apache         额外安装 Apache（默认只装 Nginx；用 xiaohuang switch apache 切换）
  --ftp-port PORT       FTP 端口（默认 21，被占用自动 +1；--no-ftp 跳过 FTP）
  --no-php              不安装 PHP（纯静态站点）
  --no-start            安装完成后不启动服务
  --supervisor MODE     systemd | pidfile | auto（默认 auto）
  --offline DIR         离线组件目录（含 components/*.tar.gz）
  --no-link             不创建 /usr/local/bin/xiaohuang 软链
  --force               忽略非致命警告
  -h, --help            显示帮助
  -v, --version         显示版本

退出码: 0 成功 | 2 路径含中文或空格 | 3 路径已有 V8 | 4 架构不符 | 5 非 root | 6 依赖缺失
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dir)        INSTALL_DIR="${2:-}"; shift 2 ;;
        --http-port)  HTTP_PORT="${2:-}"; shift 2 ;;
        --db-port)    DB_PORT="${2:-}"; shift 2 ;;
        --ftp-port)   FTP_PORT="${2:-}"; shift 2 ;;
        --no-ftp)     DO_FTP=0; shift ;;
        --no-db)      DO_DB=0; shift ;;
        --with-apache) DO_APACHE=1; shift ;;
        --no-php)     DO_PHP=0; shift ;;
        --no-start)   DO_START=0; shift ;;
        --supervisor) SUPERVISOR="${2:-auto}"; shift 2 ;;
        --offline)    OFFLINE_DIR="${2:-}"; shift 2 ;;
        --no-link)    LINK_CLI=0; shift ;;
        --force)      FORCE=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        -v|--version) printf 'Xiao Huang %s (%s)\n' "$XIAOHUANG_VERSION" "$XIAOHUANG_BUILD"; exit 0 ;;
        *) die "$E_GENERIC" "未知参数: $1（--help 查看用法）" ;;
    esac
done

[ -n "$INSTALL_DIR" ] || INSTALL_DIR="$DEFAULT_DIR"

# ===========================================================================
# 0. 环境检查
# ===========================================================================
log_step "环境检查"
require_root
check_arch
detect_distro
log_info "系统: $DISTRO_NAME ($DISTRO_ID $DISTRO_VER) / 包管理器: $PKG_FAMILY"

# ===========================================================================
# 1. 安装路径校验（对应压缩包说明第 1、2 条）
# ===========================================================================
log_step "安装路径校验"
validate_install_path "$INSTALL_DIR"
INSTALL_DIR="$INSTALL_DIR_NORM"
log_ok "路径合法: $INSTALL_DIR"

check_path_pure "$INSTALL_DIR"
log_ok "路径纯净检查通过"

# 磁盘空间：按组件规模粗估 800MB
if have_cmd df; then
    avail_kb="$(df -Pk "$(dirname "$INSTALL_DIR")" 2>/dev/null | awk 'NR==2{print $4}')"
    if [ -n "${avail_kb:-}" ] && [ "$avail_kb" -lt 819200 ]; then
        log_warn "剩余空间 ${avail_kb}KB 偏小，完整组件约需 800MB"
    fi
fi

# ===========================================================================
# 2. 目录骨架（与 Windows 版一致）
# ===========================================================================
log_step "创建目录结构"
APP_DIR="$INSTALL_DIR/app"
EXT_DIR="$APP_DIR/Extensions"
COM_DIR="$APP_DIR/COM"
WWW_DIR="$APP_DIR/WWW"
LOG_DIR="$INSTALL_DIR/logs"
TMP_DIR="$EXT_DIR/tmp/tmp"
BIN_DIR="$INSTALL_DIR/bin"
RUN_DIR="$INSTALL_DIR/run"
CONF_DIR="$INSTALL_DIR/conf"

mkdir -p "$EXT_DIR" "$COM_DIR" "$WWW_DIR" "$LOG_DIR" "$TMP_DIR" "$BIN_DIR" "$RUN_DIR" "$CONF_DIR"
mkdir -p "$EXT_DIR/ErrorPages"
chmod 755 "$INSTALL_DIR"
log_ok "已创建: app/Extensions app/COM app/WWW logs bin run conf"

# ===========================================================================
# 3. 默认站点与错误页
# ===========================================================================
log_step "部署默认站点 app/WWW"
mkdir -p "$WWW_DIR/error"

render "$SELF_DIR/www/index.html" "$WWW_DIR/index.html" \
       "@XIAOHUANG_VERSION@" "$XIAOHUANG_VERSION" \
       "@BUILD@" "$XIAOHUANG_BUILD" \
       "@WWW_ROOT@" "$WWW_DIR" \
       "@HTTP_PORT@" "${HTTP_PORT:-80}" \
       "@WEB_SERVER@" "Nginx / Apache" \
       "@PHP_VER@" "PHP" \
       "@DB_VER@" "MySQL"

if [ "$DO_PHP" = "1" ]; then
    render "$SELF_DIR/www/index.php" "$WWW_DIR/index.php" \
           "@XIAOHUANG_VERSION@" "$XIAOHUANG_VERSION" \
           "@BUILD@" "$XIAOHUANG_BUILD"
fi

# 错误页：一套模板按状态码生成（对齐 Windows 版 WWW/error/*.html）
for code in 400 403 404 500 501 502 503 504 505 506 507 509 510; do
    case "$code" in
        400) title="请求错误" ;;
        403) title="禁止访问" ;;
        404) title="页面不存在" ;;
        500) title="服务器内部错误" ;;
        501) title="未实现" ;;
        502) title="网关错误" ;;
        503) title="服务不可用" ;;
        504) title="网关超时" ;;
        505) title="HTTP 版本不受支持" ;;
        506) title="变体协商失败" ;;
        507) title="存储空间不足" ;;
        509) title="带宽超限" ;;
        510) title="扩展不支持" ;;
    esac
    render "$SELF_DIR/www/error/_template.html" "$WWW_DIR/error/$code.html" \
           "@CODE@" "$code" \
           "@TITLE@" "$title"
done
cp -f "$WWW_DIR/error/_template.html" "$EXT_DIR/ErrorPages/_template.html" 2>/dev/null || true
cp -f "$WWW_DIR/error/"*.html "$EXT_DIR/ErrorPages/" 2>/dev/null || true
rm -f "$WWW_DIR/error/_template.html"
log_ok "默认站点与 13 个错误页已生成"

# ===========================================================================
# 4. 组件准备
# ===========================================================================
log_step "组件准备"

NGINX_BIN=""; NGINX_VER=""; NGINX_HOME=""
PHP_FPM_BIN=""; PHP_CLI_BIN=""; PHP_VER=""; PHP_HOME=""
APACHE_BIN=""; APACHE_VER=""; APACHE_HOME=""; APACHE_MODDIR=""
MYSQLD_BIN=""; MYSQL_VER=""; MYSQL_HOME=""

# 4.1 离线组件包（若提供）
unpack_offline() {
    local name="$1" dst="$2"
    [ -n "$OFFLINE_DIR" ] || return 1
    local tgz="$OFFLINE_DIR/components/$name.tar.gz"
    [ -f "$tgz" ] || return 1
    mkdir -p "$dst"
    log_info "解包离线组件: $name"
    tar -xzf "$tgz" -C "$dst" || return 1
    return 0
}

# 4.2 Nginx
resolve_nginx() {
    if unpack_offline nginx "$EXT_DIR/_nginx_tmp"; then
        local v; v="$(bin_version "$EXT_DIR/_nginx_tmp/bin/nginx" nginx)"
        v="${v:-1.24.0}"
        NGINX_HOME="$EXT_DIR/Nginx$v"
        mkdir -p "$NGINX_HOME"
        cp -a "$EXT_DIR/_nginx_tmp/." "$NGINX_HOME/"
        rm -rf "$EXT_DIR/_nginx_tmp"
        NGINX_BIN="$NGINX_HOME/bin/nginx"
        NGINX_VER="$v"
    else
        NGINX_BIN="$(find_nginx || true)"
        if [ -z "$NGINX_BIN" ]; then
            log_warn "未找到 nginx，尝试通过系统源安装"
            pkg_install nginx || true
            NGINX_BIN="$(find_nginx || true)"
        fi
        if [ -z "$NGINX_BIN" ]; then
            die "$E_DEP" "缺少 nginx。请先安装: apt-get install -y nginx（或使用 --offline 提供离线组件）"
        fi
        NGINX_VER="$(bin_version "$NGINX_BIN" nginx)"; NGINX_VER="${NGINX_VER:-system}"
        NGINX_HOME="$EXT_DIR/Nginx$NGINX_VER"
        mkdir -p "$NGINX_HOME/bin"
        ln -sfn "$NGINX_BIN" "$NGINX_HOME/bin/nginx"
    fi
    log_ok "Nginx $NGINX_VER -> $NGINX_HOME"
}
resolve_nginx

# 4.3 PHP (FPM + CLI)
resolve_php() {
    [ "$DO_PHP" = "1" ] || return 0
    if unpack_offline php-fpm "$EXT_DIR/_php_tmp"; then
        local v; v="$(bin_version "$EXT_DIR/_php_tmp/bin/php" php)"
        v="${v:-8.3}"
        PHP_HOME="$EXT_DIR/php/php$v"
        mkdir -p "$PHP_HOME"
        cp -a "$EXT_DIR/_php_tmp/." "$PHP_HOME/"
        rm -rf "$EXT_DIR/_php_tmp"
        PHP_FPM_BIN="$PHP_HOME/bin/php-fpm"
        PHP_CLI_BIN="$PHP_HOME/bin/php"
        PHP_VER="$v"
    else
        PHP_FPM_BIN="$(find_php_fpm || true)"
        PHP_CLI_BIN="$(find_php_cli || true)"
        if [ -z "$PHP_FPM_BIN" ] || [ -z "$PHP_CLI_BIN" ]; then
            log_warn "未找到 PHP-FPM，尝试通过系统源安装"
            pkg_install php-fpm || true
            pkg_install php-mysql php-curl php-gd php-mbstring php-xml php-zip php-sqlite3 2>/dev/null || true
            PHP_FPM_BIN="$(find_php_fpm || true)"
            PHP_CLI_BIN="$(find_php_cli || true)"
        fi
        if [ -z "$PHP_FPM_BIN" ] || [ -z "$PHP_CLI_BIN" ]; then
            die "$E_DEP" "缺少 php-fpm/php。请先安装: apt-get install -y php-fpm（或使用 --offline）"
        fi
        PHP_VER="$(bin_version "$PHP_CLI_BIN" php)"; PHP_VER="${PHP_VER:-system}"
        PHP_HOME="$EXT_DIR/php/php$PHP_VER"
        mkdir -p "$PHP_HOME/bin" "$PHP_HOME/sbin"
        ln -sfn "$PHP_CLI_BIN" "$PHP_HOME/bin/php"
        ln -sfn "$PHP_FPM_BIN" "$PHP_HOME/sbin/php-fpm"
    fi
    log_ok "PHP $PHP_VER -> $PHP_HOME"
}
resolve_php

# PHP 扩展目录：内置组件的扩展在 <PHP_HOME>/lib/php/<api日期>/，
# 系统 PHP 则读编译期的 extension_dir
PHP_EXT_DIR=""
if [ -n "${PHP_HOME:-}" ] && [ -d "$PHP_HOME/lib/php" ]; then
    _api="$(find "$PHP_HOME/lib/php" -maxdepth 1 -mindepth 1 -type d | head -1 | xargs -r basename)"
    [ -n "$_api" ] && PHP_EXT_DIR="$PHP_HOME/lib/php/$_api"
fi
if [ -z "$PHP_EXT_DIR" ] && [ -n "${PHP_CLI_BIN:-}" ]; then
    PHP_EXT_DIR="$("$PHP_CLI_BIN" -r 'echo ini_get("extension_dir");' 2>/dev/null || true)"
    [ -n "$PHP_EXT_DIR" ] || PHP_EXT_DIR="/usr/lib/php/$( "$PHP_CLI_BIN" -r 'echo PHP_MAJOR_VERSION.".";' 2>/dev/null)$( "$PHP_CLI_BIN" -r 'echo PHP_MINOR_VERSION;' 2>/dev/null)"
fi
[ -n "$PHP_EXT_DIR" ] && log_ok "PHP 扩展目录: $PHP_EXT_DIR"

# 4.4 Apache
resolve_apache() {
    [ "$DO_APACHE" = "1" ] || return 0
    if unpack_offline apache "$EXT_DIR/_apache_tmp"; then
        local v; v="$(bin_version "$EXT_DIR/_apache_tmp/bin/httpd" apache)"
        v="${v:-2.4}"
        APACHE_HOME="$EXT_DIR/Apache$v"
        mkdir -p "$APACHE_HOME"
        cp -a "$EXT_DIR/_apache_tmp/." "$APACHE_HOME/"
        rm -rf "$EXT_DIR/_apache_tmp"
        APACHE_BIN="$APACHE_HOME/bin/httpd"
        APACHE_VER="$v"
        APACHE_MODDIR="$APACHE_HOME/modules"
        return 0
    fi
    APACHE_BIN="$(find_apache || true)"
    if [ -z "$APACHE_BIN" ]; then
        log_warn "未找到 Apache，尝试通过系统源安装"
        pkg_install apache2 2>/dev/null || pkg_install httpd 2>/dev/null || true
        APACHE_BIN="$(find_apache || true)"
    fi
    if [ -z "$APACHE_BIN" ]; then
        log_warn "没有可用的 Apache，跳过（仅提供 Nginx）"
        DO_APACHE=0
        return 0
    fi
    APACHE_VER="$(bin_version "$APACHE_BIN" apache)"; APACHE_VER="${APACHE_VER:-system}"
    APACHE_HOME="$EXT_DIR/Apache$APACHE_VER"
    APACHE_MODDIR="$(apache_module_dir "$APACHE_BIN")"
    mkdir -p "$APACHE_HOME/bin"
    ln -sfn "$APACHE_BIN" "$APACHE_HOME/bin/apache2"
    log_ok "Apache $APACHE_VER -> $APACHE_HOME (modules: $APACHE_MODDIR)"
}
resolve_apache

# 4.5 MySQL
resolve_mysql() {
    [ "$DO_DB" = "1" ] || return 0
    if unpack_offline mysql "$EXT_DIR/_mysql_tmp"; then
        local v; v="$(bin_version "$EXT_DIR/_mysql_tmp/bin/mysqld" mysql)"
        v="${v:-8.0}"
        MYSQL_HOME="$EXT_DIR/MySQL$v"
        mkdir -p "$MYSQL_HOME"
        cp -a "$EXT_DIR/_mysql_tmp/." "$MYSQL_HOME/"
        rm -rf "$EXT_DIR/_mysql_tmp"
        MYSQLD_BIN="$MYSQL_HOME/bin/mysqld"
        MYSQL_VER="$v"
        return 0
    fi
    MYSQLD_BIN="$(find_mysqld || true)"
    if [ -z "$MYSQLD_BIN" ]; then
        log_warn "未找到 mysqld，尝试通过系统源安装"
        pkg_install mysql-server 2>/dev/null || pkg_install mariadb-server 2>/dev/null || true
        MYSQLD_BIN="$(find_mysqld || true)"
    fi
    if [ -z "$MYSQLD_BIN" ]; then
        log_warn "没有可用的 MySQL/MariaDB，跳过数据库组件"
        DO_DB=0
        return 0
    fi
    MYSQL_VER="$(bin_version "$MYSQLD_BIN" mysql)"; MYSQL_VER="${MYSQL_VER:-system}"
    MYSQL_HOME="$EXT_DIR/MySQL$MYSQL_VER"
    mkdir -p "$MYSQL_HOME/bin"
    ln -sfn "$MYSQLD_BIN" "$MYSQL_HOME/bin/mysqld"
    log_ok "MySQL $MYSQL_VER -> $MYSQL_HOME"
}
resolve_mysql


# 4.5 FTP（vsftpd，等价原版 FileZilla Server）
resolve_ftp() {
    [ "$DO_FTP" = "1" ] || return 0
    if unpack_offline ftp "$EXT_DIR/_ftp_tmp"; then
        FTP_HOME="$EXT_DIR/FTP0.9.60"
        mkdir -p "$FTP_HOME"
        cp -a "$EXT_DIR/_ftp_tmp/." "$FTP_HOME/"
        rm -rf "$EXT_DIR/_ftp_tmp"
        FTP_BIN="$FTP_HOME/bin/vsftpd"
        FTP_VER="3.0.3"
        log_ok "FTP 服务 vsftpd $FTP_VER -> $FTP_HOME"
        return 0
    fi
    FTP_BIN="$(first_bin /usr/sbin/vsftpd /usr/local/sbin/vsftpd || true)"
    if [ -z "$FTP_BIN" ]; then
        log_warn "未找到 vsftpd，尝试通过系统源安装"
        pkg_install vsftpd 2>/dev/null || true
        FTP_BIN="$(first_bin /usr/sbin/vsftpd /usr/local/sbin/vsftpd || true)"
    fi
    if [ -z "$FTP_BIN" ]; then
        log_warn "没有可用的 vsftpd，跳过 FTP 组件"
        DO_FTP=0
        return 0
    fi
    FTP_VER="$(bin_version "$FTP_BIN" vsftpd)"; FTP_VER="${FTP_VER:-system}"
    FTP_HOME="$EXT_DIR/FTP$FTP_VER"
    mkdir -p "$FTP_HOME/bin"
    ln -sfn "$FTP_BIN" "$FTP_HOME/bin/vsftpd"
    log_ok "FTP 服务 vsftpd $FTP_VER -> $FTP_HOME"
}
resolve_ftp

# 4.6 运行身份（worker/子进程降权）
detect_run_user() {
    local u
    for u in www-data nginx apache nobody; do
        if id "$u" >/dev/null 2>&1; then printf '%s' "$u"; return 0; fi
    done
    printf 'nobody'
}
RUN_USER="$(detect_run_user)"
RUN_GROUP="$(id -gn "$RUN_USER" 2>/dev/null || echo nogroup)"
log_ok "运行身份: $RUN_USER:$RUN_GROUP"

# 站点、临时、日志目录交给运行用户，否则 PHP 无法写文件/上传
if [ -d "$WWW_DIR" ]; then
    chown -R "$RUN_USER:$RUN_GROUP" "$WWW_DIR" 2>/dev/null || true
fi
chown -R "$RUN_USER:$RUN_GROUP" "$TMP_DIR" "$LOG_DIR" 2>/dev/null || true

# 4.7 端口分配
if [ -z "$HTTP_PORT" ]; then
    if port_in_use 80; then
        HTTP_PORT="$(pick_free_port 8080 || echo 8080)"
        log_warn "80 端口已被占用，改用 $HTTP_PORT"
    else
        HTTP_PORT=80
    fi
fi
if [ -z "$DB_PORT" ]; then
    if port_in_use 3306; then
        DB_PORT="$(pick_free_port 3307 || echo 3307)"
        log_warn "3306 端口已被占用，改用 $DB_PORT"
    else
        DB_PORT=3306
    fi
fi
PHP_FPM_PORT="$HTTP_PORT"
# PHP-FPM 固定 127.0.0.1:9000（与 Windows 版 fastcgi_pass 127.0.0.1:9000 对齐）
if port_in_use 9000; then
    PHP_FPM_PORT="$(pick_free_port 9001 || echo 9001)"
    log_warn "9000 端口已被占用，PHP-FPM 改用 $PHP_FPM_PORT"
else
    PHP_FPM_PORT=9000
fi
[ "$DO_PHP" = "1" ] || PHP_FPM_PORT=""

# FTP 端口
if [ "$DO_FTP" = "1" ]; then
    if [ -n "$FTP_PORT" ]; then
        if port_in_use "$FTP_PORT"; then
            log_warn "指定的 FTP 端口 $FTP_PORT 已被占用，改用 $(pick_free_port 2121 || echo 2121)"
            FTP_PORT="$(pick_free_port 2121 || echo 2121)"
        fi
    elif port_in_use 21; then
        FTP_PORT="$(pick_free_port 2121 || echo 2121)"
        log_warn "21 端口已被占用，FTP 改用 $FTP_PORT"
    else
        FTP_PORT=21
    fi
    PASV_MIN=$(( 30000 + (FTP_PORT % 500) * 20 ))
    PASV_MAX=$(( PASV_MIN + 20 ))
fi

# 4.8 接管系统服务：停用同名系统服务，避免端口冲突与双实例
takeover_system_service() {
    local svc="$1" units was
    has_systemd || return 0
    units="$(systemctl list-unit-files "$svc.service" 2>/dev/null || true)"
    case "$units" in
        *"$svc.service"*)
            was="$(systemctl is-active "$svc" 2>/dev/null || true)"
            systemctl stop "$svc" >/dev/null 2>&1 || true
            systemctl disable "$svc" >/dev/null 2>&1 || true
            log_info "已停用系统服务 $svc（原状态: ${was:-unknown}），由 Xiao Huang 独立实例接管"
            printf '%s\n' "$svc" >> "$INSTALL_DIR/.disabled-system-services"
            ;;
    esac
}

if [ "$DO_START" = "1" ]; then
    takeover_system_service nginx
    [ "$DO_APACHE" = "1" ] && takeover_system_service apache2 && takeover_system_service httpd
    [ "$DO_PHP" = "1" ] && takeover_system_service "php${PHP_VER}-fpm" && takeover_system_service php-fpm 2>/dev/null || true
    [ "$DO_DB" = "1" ] && { takeover_system_service mysql; takeover_system_service mariadb; }
fi

# ===========================================================================
# 5. 生成配置文件
# ===========================================================================
log_step "生成配置"

mkdir -p "$NGINX_HOME/conf/vhosts" "$NGINX_HOME/conf/ssl" "$NGINX_HOME/logs" \
         "$NGINX_HOME/temp/client_body_temp" "$NGINX_HOME/temp/proxy_temp" \
         "$NGINX_HOME/temp/fastcgi_temp" "$NGINX_HOME/temp/uwsgi_temp" "$NGINX_HOME/temp/scgi_temp"

# mime.types / fastcgi_params：优先用系统 nginx 的，缺失则用安装包自带的
NGX_CONF_SRC=""
for d in /etc/nginx /usr/local/nginx/conf /usr/share/nginx; do
    [ -f "$d/mime.types" ] && { NGX_CONF_SRC="$d"; break; }
done
if [ -n "$NGX_CONF_SRC" ] && [ ! -f "$NGINX_HOME/conf/mime.types" ]; then
    cp -f "$NGX_CONF_SRC/mime.types" "$NGINX_HOME/conf/mime.types" 2>/dev/null || true
    [ -f "$NGX_CONF_SRC/fastcgi_params" ] && cp -f "$NGX_CONF_SRC/fastcgi_params" "$NGINX_HOME/conf/fastcgi_params" 2>/dev/null || true
    [ -f "$NGX_CONF_SRC/fastcgi.conf" ] && cp -f "$NGX_CONF_SRC/fastcgi.conf" "$NGINX_HOME/conf/fastcgi.conf" 2>/dev/null || true
    [ -f "$NGX_CONF_SRC/uwsgi_params" ] && cp -f "$NGX_CONF_SRC/uwsgi_params" "$NGINX_HOME/conf/uwsgi_params" 2>/dev/null || true
    [ -f "$NGX_CONF_SRC/scgi_params" ] && cp -f "$NGX_CONF_SRC/scgi_params" "$NGINX_HOME/conf/scgi_params" 2>/dev/null || true
fi
[ -f "$NGINX_HOME/conf/mime.types" ] || cp -f "$SELF_DIR/templates/nginx/mime.types" "$NGINX_HOME/conf/mime.types"
[ -f "$NGINX_HOME/conf/fastcgi_params" ] || cp -f "$SELF_DIR/templates/nginx/fastcgi_params" "$NGINX_HOME/conf/fastcgi_params"
# 站点模板留一份在组件目录，供 xiaohuang site add / repair 使用
cp -f "$SELF_DIR/templates/nginx/vhost.conf.tpl" "$NGINX_HOME/conf/vhost.tpl"
cp -f "$SELF_DIR/templates/nginx/vhost.conf.tpl" "$CONF_DIR/vhost.nginx.tpl"

render "$SELF_DIR/templates/nginx/nginx.conf" "$NGINX_HOME/conf/nginx.conf" \
       "@INSTALL_DIR@" "$INSTALL_DIR" \
       "@NGINX_HOME@" "$NGINX_HOME" \
       "@WWW_ROOT@" "$WWW_DIR" \
       "@HTTP_PORT@" "$HTTP_PORT" \
       "@PHP_FPM_PORT@" "${PHP_FPM_PORT:-9000}" \
       "@RUN_DIR@" "$RUN_DIR" \
       "@RUN_USER@" "$RUN_USER" \
       "@LOG_DIR@" "$LOG_DIR"

# Nginx 的监听端口写在每个 server 块里（nginx 没有独立 Listen 配置文件）；
# 这里记录一个纯文本端口文件供控制台读取，注意不能放进 vhosts/*.conf（会被 nginx 当指令解析）
printf '%s\n' "$HTTP_PORT" > "$NGINX_HOME/conf/listen.port"
: > "$NGINX_HOME/conf/vhosts/default-default.conf"

# 默认站点 vhost（等价于面板里的"默认站点"）
render "$SELF_DIR/templates/nginx/vhost.conf.tpl" "$NGINX_HOME/conf/vhosts/localhost-$HTTP_PORT.conf" \
       "@DOMAIN@" "localhost" \
       "@PORT@" "$HTTP_PORT" \
       "@ROOT@" "$WWW_DIR" \
       "@PHP_FPM_PORT@" "${PHP_FPM_PORT:-9000}" \
       "@LOG_DIR@" "$LOG_DIR" \
       "@SSL_CERT@" "" \
       "@SSL_KEY@" ""

# PHP
if [ "$DO_PHP" = "1" ]; then
    mkdir -p "$PHP_HOME/etc" "$PHP_HOME/log"
    render "$SELF_DIR/templates/php/php.ini" "$PHP_HOME/etc/php.ini" \
           "@PHP_HOME@" "$PHP_HOME" \
           "@PHP_EXT_DIR@" "$PHP_EXT_DIR" \
           "@TMP_DIR@" "$TMP_DIR" \
           "@LOG_DIR@" "$LOG_DIR"

    # php-fpm 主配置 + pool
    render "$SELF_DIR/templates/php/php-fpm.conf" "$PHP_HOME/etc/php-fpm.conf" \
           "@PHP_HOME@" "$PHP_HOME" \
           "@RUN_DIR@" "$RUN_DIR" \
           "@RUN_USER@" "$RUN_USER" \
           "@RUN_GROUP@" "$RUN_GROUP" \
           "@LOG_DIR@" "$LOG_DIR" \
           "@PHP_FPM_PORT@" "$PHP_FPM_PORT" \
           "@WWW_ROOT@" "$WWW_DIR" \
           "@TMP_DIR@" "$TMP_DIR"

    # 内置 PHP 没有系统 conf.d 扫描目录，扩展必须在 php.ini 里显式加载
    case "${PHP_EXT_DIR:-}" in
        "$PHP_HOME"/*)
            # 顺序敏感：pdo 与 mysqlnd 必须先于 mysqli / pdo_mysql / pdo_sqlite
            _loaded=""
            for _e in pdo mysqlnd mysqli pdo_mysql pdo_sqlite sqlite3 \
                      ctype tokenizer json iconv phar \
                      curl fileinfo gd mbstring zip dom simplexml xmlreader xmlwriter xsl \
                      bcmath intl exif posix sockets; do
                [ -f "$PHP_EXT_DIR/$_e.so" ] || continue
                printf 'extension=%s\n' "$_e" >> "$PHP_HOME/etc/php.ini"
                _loaded="$_loaded $_e"
            done
            if [ -f "$PHP_EXT_DIR/opcache.so" ]; then
                printf 'zend_extension=%s\n' "$PHP_EXT_DIR/opcache.so" >> "$PHP_HOME/etc/php.ini"
                _loaded="$_loaded opcache"
            fi
            log_ok "PHP 扩展已启用:${_loaded:- 无}"
            ;;
    esac

    # 内置扩展目录与 session 目录交给运行用户
    [ -d "$PHP_HOME/lib/php" ] && chmod -R a+rX "$PHP_HOME/lib/php" 2>/dev/null || true
fi

# Apache
APACHE_HTTP_PORT=""
if [ "$DO_APACHE" = "1" ]; then
    mkdir -p "$APACHE_HOME/conf/vhosts" "$APACHE_HOME/conf/extra" "$APACHE_HOME/logs" "$APACHE_HOME/conf/ssl"
    APACHE_HTTP_PORT="$HTTP_PORT"

    # mime.types：Debian/Ubuntu 在 /etc/apache2，RHEL 系在 /etc/httpd/conf
    APACHE_MIME=""
    for f in /etc/apache2/mime.types /etc/httpd/conf/mime.types "$APACHE_HOME/conf/mime.types" \
             /etc/mime.types; do
        [ -f "$f" ] && { APACHE_MIME="$f"; break; }
    done
    [ -n "$APACHE_MIME" ] || APACHE_MIME="/etc/mime.types"

    # MPM：优先 event，其次 prefork
    MPM_MOD="mpm_event"
    [ -f "$APACHE_MODDIR/mod_mpm_event.so" ] || MPM_MOD="mpm_prefork"

    render "$SELF_DIR/templates/apache/httpd.conf" "$APACHE_HOME/conf/httpd.conf" \
           "@INSTALL_DIR@" "$INSTALL_DIR" \
           "@APACHE_HOME@" "$APACHE_HOME" \
           "@MODULE_DIR@" "$APACHE_MODDIR" \
           "@MIME_TYPES@" "$APACHE_MIME" \
           "@MPM_MODULE@" "$MPM_MOD" \
           "@WWW_ROOT@" "$WWW_DIR" \
           "@HTTP_PORT@" "$HTTP_PORT" \
           "@PHP_FPM_PORT@" "${PHP_FPM_PORT:-9000}" \
           "@RUN_DIR@" "$RUN_DIR" \
           "@RUN_USER@" "$RUN_USER" \
           "@RUN_GROUP@" "$RUN_GROUP" \
           "@LOG_DIR@" "$LOG_DIR"

    # 按实际存在的 .so 关闭缺失模块行（不同发行版模块集不同）
    while read -r line; do
        case "$line" in
            LoadModule*) ;;
            *) continue ;;
        esac
        so="$(printf '%s' "$line" | awk '{print $3}')"
        if [ ! -f "$so" ]; then
            mod="$(printf '%s' "$line" | awk '{print $2}')"
            sed -i "s#^LoadModule ${mod} #\#LoadModule ${mod} #" "$APACHE_HOME/conf/httpd.conf"
            # Debian/Ubuntu 把 log_config、unixd 编进核心，没有独立 .so；属正常情况
            case "$mod" in
                log_config_module|unixd_module)
                    log_info "模块内建于 Apache 核心，无需 LoadModule: $mod" ;;
                *)
                    log_warn "模块缺失，已禁用: $mod ($so)" ;;
            esac
        fi
    done < <(grep -E '^LoadModule' "$APACHE_HOME/conf/httpd.conf")

    printf 'Listen %s\n' "$HTTP_PORT" > "$APACHE_HOME/conf/vhosts/Listen.conf"
    cp -f "$SELF_DIR/templates/apache/vhost.conf.tpl" "$APACHE_HOME/conf/vhost.tpl"
    cp -f "$SELF_DIR/templates/apache/vhost.conf.tpl" "$CONF_DIR/vhost.apache.tpl"
    render "$SELF_DIR/templates/apache/vhost.conf.tpl" "$APACHE_HOME/conf/vhosts/localhost-$HTTP_PORT.conf" \
           "@DOMAIN@" "localhost" \
           "@PORT@" "$HTTP_PORT" \
           "@ROOT@" "$WWW_DIR" \
           "@PHP_FPM_PORT@" "${PHP_FPM_PORT:-9000}" \
           "@LOG_DIR@" "$LOG_DIR"
fi

# MySQL
if [ "$DO_DB" = "1" ]; then
    MYSQL_DATA="$MYSQL_HOME/data"
    mkdir -p "$MYSQL_DATA" "$MYSQL_HOME/log" "$MYSQL_HOME/etc" "$MYSQL_HOME/tmp" "$MYSQL_HOME/upload"
    # basedir：系统包的 mysqld 用 /usr；离线自带组件用组件目录
    case "$MYSQLD_BIN" in
        "$MYSQL_HOME"/*) MYSQL_BASEDIR="$MYSQL_HOME" ;;
        *) MYSQL_BASEDIR="/usr" ;;
    esac
    render "$SELF_DIR/templates/mysql/my.cnf" "$MYSQL_HOME/etc/my.cnf" \
           "@MYSQL_HOME@" "$MYSQL_HOME" \
           "@MYSQL_DATA@" "$MYSQL_DATA" \
           "@MYSQL_BASEDIR@" "$MYSQL_BASEDIR" \
           "@DB_PORT@" "$DB_PORT" \
           "@RUN_DIR@" "$RUN_DIR" \
           "@TMP_DIR@" "$TMP_DIR" \
           "@LOG_DIR@" "$LOG_DIR"
    printf 'port=%s\n' "$DB_PORT" > "$MYSQL_HOME/etc/client-port.ini"
    # MariaDB 的错误消息目录（内置组件在 <MYSQL_HOME>/share，系统包在 /usr/share/mysql）
    if [ -d "$MYSQL_HOME/share/english" ]; then
        printf 'lc-messages-dir=%s\n' "$MYSQL_HOME/share" >> "$MYSQL_HOME/etc/my.cnf"
    fi
fi

# 首页写入真实组件版本（组件探测在第 4 节完成，此处覆盖第 3 节的占位内容）
WEB_LABEL="Nginx ${NGINX_VER}"
[ "$DO_APACHE" = "1" ] && [ -n "$APACHE_VER" ] && WEB_LABEL="Nginx ${NGINX_VER} / Apache ${APACHE_VER}"
DB_LABEL="未安装"
[ "$DO_DB" = "1" ] && [ -n "$MYSQL_VER" ] && DB_LABEL="MySQL ${MYSQL_VER}"
PHP_LABEL="未安装"
[ "$DO_PHP" = "1" ] && [ -n "$PHP_VER" ] && PHP_LABEL="PHP ${PHP_VER}"
render "$SELF_DIR/www/index.html" "$WWW_DIR/index.html" \
       "@XIAOHUANG_VERSION@" "$XIAOHUANG_VERSION" \
       "@BUILD@" "$XIAOHUANG_BUILD" \
       "@WWW_ROOT@" "$WWW_DIR" \
       "@HTTP_PORT@" "$HTTP_PORT" \
       "@WEB_SERVER@" "$WEB_LABEL" \
       "@PHP_VER@" "$PHP_LABEL" \
       "@DB_VER@" "$DB_LABEL"


# FTP
if [ "$DO_FTP" = "1" ]; then
    mkdir -p "$FTP_HOME/etc" "$FTP_HOME/logs" "$FTP_HOME/empty"
    chmod 755 "$FTP_HOME/empty"
    # PAM：独立服务名 xiaohuang-vsftpd；优先用组件自带的 pam_unix.so（绝对路径）
    FTP_PAM="$FTP_HOME/lib/security/pam_unix.so"
    if [ -f "$FTP_PAM" ]; then
        {
            printf 'auth     required %s\n' "$FTP_PAM"
            printf 'account  required %s\n' "$FTP_PAM"
            printf 'session  required %s\n' "$FTP_PAM"
            printf 'password required %s\n' "$FTP_PAM"
        } > /etc/pam.d/xiaohuang-vsftpd
    elif [ -f "$FTP_HOME/conf/pam.vsftpd" ]; then
        cp -f "$FTP_HOME/conf/pam.vsftpd" /etc/pam.d/xiaohuang-vsftpd
    else
        printf 'auth     required pam_unix.so\naccount  required pam_unix.so\nsession  required pam_unix.so\n' \
            > /etc/pam.d/xiaohuang-vsftpd
    fi
    chmod 644 /etc/pam.d/xiaohuang-vsftpd
    # 账号白名单（空 = 谁都登不进；由 xiaohuang ftp user add 维护）
    [ -f "$FTP_HOME/etc/userlist" ] || : > "$FTP_HOME/etc/userlist"
    chmod 600 "$FTP_HOME/etc/userlist"

    render "$SELF_DIR/templates/ftp/vsftpd.conf" "$FTP_HOME/etc/vsftpd.conf" \
           "@FTP_PORT@" "$FTP_PORT" \
           "@FTP_HOME@" "$FTP_HOME" \
           "@PASV_MIN@" "$PASV_MIN" \
           "@PASV_MAX@" "$PASV_MAX"
    log_ok "FTP 配置已生成（端口 $FTP_PORT，被动 $PASV_MIN-$PASV_MAX）"
fi

log_ok "配置已生成"

# ===========================================================================
# 6. MySQL 数据目录初始化
# ===========================================================================
if [ "$DO_DB" = "1" ]; then
    log_step "初始化 MySQL 数据目录"
    if [ -d "$MYSQL_DATA/mysql" ]; then
        log_info "数据目录已存在，跳过初始化"
    else
        # MariaDB 没有 --initialize-insecure，用官方 install-db 脚本；
        # MySQL 5.7/8.0 用 --initialize-insecure
        MARIA_INSTALLER=""
        for c in "$MYSQL_HOME/bin/mariadb-install-db" "$MYSQL_HOME/bin/mysql_install_db"; do
            [ -x "$c" ] && { MARIA_INSTALLER="$c"; break; }
        done

        if [ -n "$MARIA_INSTALLER" ]; then
            log_info "MariaDB 初始化: $(basename "$MARIA_INSTALLER")（首次约 10-30 秒）"
            if "$MARIA_INSTALLER" \
                    --defaults-file="$MYSQL_HOME/etc/my.cnf" \
                    --basedir="$MYSQL_HOME" \
                    --datadir="$MYSQL_DATA" \
                    --user=root \
                    --auth-root-authentication-method=normal \
                    --lc-messages-dir="$MYSQL_HOME/share" \
                    --skip-test-db \
                    >>"$MYSQL_HOME/log/init.log" 2>&1; then
                log_ok "数据目录初始化完成（MariaDB）"
            else
                log_warn "初始化失败，日志: $MYSQL_HOME/log/init.log"
                tail -8 "$MYSQL_HOME/log/init.log" 2>/dev/null | sed 's/^/       /' >&2
                [ "$FORCE" = "1" ] && { log_warn "--force：跳过数据库组件"; DO_DB=0; } \
                    || die "$E_DEP" "MariaDB 初始化失败。修复后重试，或加 --no-db 跳过数据库组件。"
            fi
        else
            log_info "mysqld --initialize-insecure（首次约 10-30 秒）"
            if "$MYSQLD_BIN" --defaults-file="$MYSQL_HOME/etc/my.cnf" \
                            --initialize-insecure --user=root \
                            --log-error="$MYSQL_HOME/log/init.log" >/dev/null 2>&1; then
                log_ok "数据目录初始化完成"
            else
                log_warn "初始化失败，日志: $MYSQL_HOME/log/init.log"
                tail -5 "$MYSQL_HOME/log/init.log" 2>/dev/null | sed 's/^/       /' >&2
                if [ "$FORCE" = "1" ]; then
                    log_warn "--force 已指定，继续安装（MySQL 将不可用，可稍后执行 xiaohuang repair）"
                    DO_DB=0
                else
                    die "$E_DEP" "MySQL 初始化失败。修复后重试，或加 --no-db 跳过数据库组件。"
                fi
            fi
        fi
    fi
fi

# ===========================================================================
# 7. 服务管理：systemd unit 或 pidfile
# ===========================================================================
log_step "注册服务"
if [ "$SUPERVISOR" = "auto" ]; then
    if has_systemd; then SUPERVISOR="systemd"; else SUPERVISOR="pidfile"; fi
fi
[ "$SUPERVISOR" = "systemd" ] && ! has_systemd && die "$E_DEP" "当前系统没有运行 systemd，请使用 --supervisor pidfile"
log_info "服务管理方式: $SUPERVISOR"

# 单实例约束：unit 名固定，若已被别的安装目录占用则拒绝，避免互相覆盖
check_unit_conflict() {
    [ "$SUPERVISOR" = "systemd" ] || return 0
    local u
    for u in xiaohuang-nginx xiaohuang-php xiaohuang-mysql xiaohuang-apache xiaohuang-panel; do
        [ -f "/etc/systemd/system/$u.service" ] || continue
        if ! grep -q -- "$INSTALL_DIR/" "/etc/systemd/system/$u.service"; then
            log_error "系统里已注册另一套 Xiao Huang 服务: /etc/systemd/system/$u.service"
            log_error "同一台机器同时只能运行一个 Xiao Huang 实例：请先卸载旧实例，或换一个安装路径。"
            exit "$E_NOT_CLEAN"
        fi
    done
}

install_unit() {
    # install_unit <unit-name> <unit-template> [enable=1]
    local unit="$1" tpl="$2" enable="${3:-1}"
    [ "$SUPERVISOR" = "systemd" ] || return 0
    render "$SELF_DIR/systemd/$tpl" "/etc/systemd/system/$unit" \
           "@INSTALL_DIR@" "$INSTALL_DIR" \
           "@NGINX_HOME@" "$NGINX_HOME" \
           "@NGINX_BIN@" "$NGINX_BIN" \
           "@PHP_HOME@" "$PHP_HOME" \
           "@PHP_FPM_BIN@" "${PHP_FPM_BIN:-}" \
           "@APACHE_HOME@" "$APACHE_HOME" \
           "@APACHE_BIN@" "${APACHE_BIN:-}" \
           "@MYSQL_HOME@" "${MYSQL_HOME:-}" \
           "@MYSQLD_BIN@" "${MYSQLD_BIN:-}" \
           "@RUN_DIR@" "$RUN_DIR"
    systemctl daemon-reload
    if [ "$enable" = "1" ]; then
        systemctl enable "$unit" >/dev/null 2>&1 || true
    fi
}

check_unit_conflict
install_unit "xiaohuang-nginx.service" "xiaohuang-nginx.service.in" 1
[ "$DO_APACHE" = "1" ] && install_unit "xiaohuang-apache.service" "xiaohuang-apache.service.in" 0
[ "$DO_PHP" = "1" ] && install_unit "xiaohuang-php.service" "xiaohuang-php.service.in" 1
[ "$DO_DB" = "1" ] && install_unit "xiaohuang-mysql.service" "xiaohuang-mysql.service.in" 1
if [ "$DO_FTP" = "1" ]; then
    render "$SELF_DIR/systemd/xiaohuang-ftp.service.in" "/etc/systemd/system/xiaohuang-ftp.service" \
           "@FTP_BIN@" "$FTP_BIN" "@FTP_HOME@" "$FTP_HOME"
    systemctl enable xiaohuang-ftp.service >/dev/null 2>&1 || true
fi
log_ok "服务单元已注册（$SUPERVISOR）"

# ===========================================================================
# 7.1 管理面板（php -S 以 root 监听本机回环，只有本机能开）
# ===========================================================================
log_step "部署管理面板"
mkdir -p "$APP_DIR/panel"
cp -a "$SELF_DIR/panel/." "$APP_DIR/panel/"
chmod 700 "$APP_DIR/panel/data" 2>/dev/null || mkdir -p "$APP_DIR/panel/data" && chmod 700 "$APP_DIR/panel/data"

PANEL_PORT=""
if port_in_use 9002; then
    PANEL_PORT="$(pick_free_port 9003 || echo 9003)"
    log_warn "9002 端口已被占用，面板改用 $PANEL_PORT"
else
    PANEL_PORT=9002
fi

# 面板密码：首次安装生成 10 位随机串，写进清单，安装结束打印
PANEL_PASS=""
if [ -z "$(manifest_get "$INSTALL_DIR" PANEL_PASS_HASH 2>/dev/null || true)" ]; then
    PANEL_PASS="$(head -c 32 /dev/urandom | md5sum | cut -c1-10)"
    printf '%s' "$PANEL_PASS" | md5sum | awk '{print $1}' > /tmp/.ps_panel_hash
    PANEL_HASH="$(cat /tmp/.ps_panel_hash)"; rm -f /tmp/.ps_panel_hash
else
    PANEL_HASH="$(manifest_get "$INSTALL_DIR" PANEL_PASS_HASH)"
fi

if [ "$SUPERVISOR" = "systemd" ] && [ -n "${PHP_CLI_BIN:-}" ]; then
    render "$SELF_DIR/systemd/xiaohuang-panel.service.in" "/etc/systemd/system/xiaohuang-panel.service" \
           "@INSTALL_DIR@" "$INSTALL_DIR" \
           "@PHP_CLI_BIN@" "$PHP_CLI_BIN" \
           "@PHP_HOME@" "$PHP_HOME" \
           "@PANEL_PORT@" "$PANEL_PORT"
    systemctl daemon-reload
    systemctl enable xiaohuang-panel.service >/dev/null 2>&1 || true
    log_ok "面板服务已注册（127.0.0.1:$PANEL_PORT）"
else
    log_warn "未使用 systemd，面板需手工启动: cd $APP_DIR/panel && $PHP_CLI_BIN -c $PHP_HOME/etc -S 127.0.0.1:$PANEL_PORT -t ."
fi

# SSL 站点模板
cp -f "$SELF_DIR/templates/nginx/vhost-ssl.conf.tpl" "$CONF_DIR/vhost-ssl.nginx.tpl"
cp -f "$SELF_DIR/templates/apache/vhost-ssl.conf.tpl" "$CONF_DIR/vhost-ssl.apache.tpl"

# ===========================================================================
# 8. 安装控制台 CLI
# ===========================================================================
log_step "安装控制台 xiaohuang"
mkdir -p "$BIN_DIR" "$INSTALL_DIR/lib"
cp -f "$SELF_DIR/lib/common.sh" "$INSTALL_DIR/lib/common.sh"
cp -f "$SELF_DIR/lib/cmds.sh" "$INSTALL_DIR/lib/cmds.sh"

# 手册 / 许可 / 完整性清单（随包分发，卸载时不删）
mkdir -p "$INSTALL_DIR/docs"
if [ -f "$SELF_DIR/docs/用户手册.md" ]; then
    cp -f "$SELF_DIR/docs/用户手册.md" "$INSTALL_DIR/docs/用户手册.md"
fi
if [ -f "$SELF_DIR/docs/常见问题.md" ]; then
    cp -f "$SELF_DIR/docs/常见问题.md" "$INSTALL_DIR/docs/常见问题.md"
fi
if [ -f "$SELF_DIR/tools/xh-diag.sh" ]; then
    cp -f "$SELF_DIR/tools/xh-diag.sh" "$INSTALL_DIR/xh-diag.sh"
    chmod 755 "$INSTALL_DIR/xh-diag.sh"
fi
[ -f "$SELF_DIR/LICENSE" ] && cp -f "$SELF_DIR/LICENSE" "$INSTALL_DIR/LICENSE"

BUILD_ID=""
[ -f "$SELF_DIR/BUILD" ] && BUILD_ID="$(head -1 "$SELF_DIR/BUILD")"
cp -f "$SELF_DIR/lib/cmds.sh" "$INSTALL_DIR/lib/cmds.sh"
cp -f "$SELF_DIR/bin/xiaohuang" "$BIN_DIR/xiaohuang"
chmod 755 "$BIN_DIR/xiaohuang"
# CLI 用到卸载器
cp -f "$SELF_DIR/uninstall.sh" "$INSTALL_DIR/uninstall.sh"
chmod 755 "$INSTALL_DIR/uninstall.sh"
if [ "$LINK_CLI" = "1" ]; then
    ln -sfn "$BIN_DIR/xiaohuang" /usr/local/bin/xiaohuang
    log_ok "/usr/local/bin/xiaohuang -> $BIN_DIR/xiaohuang"
fi

# ===========================================================================
# 9. 写安装清单 xiaohuang.ini
# ===========================================================================
log_step "写入安装清单"
: > "$INSTALL_DIR/$MANIFEST_NAME"
{
    echo "# Xiao Huang 安装清单 —— 由安装器自动生成，请勿手工编辑"
    echo "PRODUCT=Xiao Huang"
    echo "VERSION=$XIAOHUANG_VERSION"
    echo "BUILD=$XIAOHUANG_BUILD"
    echo "PLATFORM=linux-aarch64"
    echo "DISTRO=$DISTRO_NAME"
    echo "INSTALL_DIR=$INSTALL_DIR"
    echo "INSTALL_TIME=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "SUPERVISOR=$SUPERVISOR"
    echo "HTTP_PORT=$HTTP_PORT"
    echo "WEB_SERVER=nginx"
    echo "DB_PORT=${DB_PORT:-}"
    echo "PHP_FPM_PORT=${PHP_FPM_PORT:-}"
    echo "NGINX_HOME=$NGINX_HOME"
    echo "NGINX_VER=$NGINX_VER"
    echo "NGINX_BIN=$NGINX_BIN"
    echo "PHP_HOME=${PHP_HOME:-}"
    echo "PHP_VER=${PHP_VER:-}"
    echo "PHP_FPM_BIN=${PHP_FPM_BIN:-}"
    echo "PHP_CLI_BIN=${PHP_CLI_BIN:-}"
    echo "APACHE_HOME=${APACHE_HOME:-}"
    echo "APACHE_VER=${APACHE_VER:-}"
    echo "APACHE_BIN=${APACHE_BIN:-}"
    echo "MYSQL_HOME=${MYSQL_HOME:-}"
    echo "MYSQL_VER=${MYSQL_VER:-}"
    echo "MYSQLD_BIN=${MYSQLD_BIN:-}"
    echo "DB_ROOT_PASS=${DEFAULT_ROOT_PASS}"
    echo "RUN_USER=$RUN_USER"
    echo "RUN_GROUP=$RUN_GROUP"
    echo "PANEL_PORT=$PANEL_PORT"
    echo "PANEL_PASS_HASH=$PANEL_HASH"
    echo "FTP_HOME=${FTP_HOME:-}"
    echo "FTP_BIN=${FTP_BIN:-}"
    echo "FTP_VER=${FTP_VER:-}"
    echo "FTP_PORT=${FTP_PORT:-}"
    echo "FTP_PASV_MIN=${PASV_MIN:-}"
    echo "FTP_PASV_MAX=${PASV_MAX:-}"
    echo "BUILD_ID=${BUILD_ID:-}"

    # 完整性清单：只登记"装完就该在"的脚本/页面/模板，站点目录和组件不登记
    if command -v sha256sum >/dev/null 2>&1; then
        (
            cd "$INSTALL_DIR" || exit 0
            {
                [ -f uninstall.sh ] && echo uninstall.sh
                [ -f LICENSE ] && echo LICENSE
                find bin lib conf docs -type f 2>/dev/null
                find app/panel -type f -not -path 'app/panel/data/*' 2>/dev/null
            } | sort -u | while IFS= read -r f; do
                [ -f "$f" ] && sha256sum "$f"
            done
        ) > "$INSTALL_DIR/.integrity" 2>/dev/null
        chmod 600 "$INSTALL_DIR/.integrity" 2>/dev/null || true
    fi
    echo "WWW_ROOT=$WWW_DIR"
    echo "LOG_DIR=$LOG_DIR"
} > "$INSTALL_DIR/$MANIFEST_NAME"
chmod 600 "$INSTALL_DIR/$MANIFEST_NAME"
log_ok "清单: $INSTALL_DIR/$MANIFEST_NAME"

# ===========================================================================
# 10. 启动与自检
# ===========================================================================
if [ "$DO_START" = "1" ]; then
    log_step "启动服务"
    if "$BIN_DIR/xiaohuang" start; then
        log_ok "服务已启动"
    else
        log_warn "部分服务启动失败，稍后可执行: xiaohuang status / xiaohuang log nginx"
    fi

    log_step "自检"
    sleep 1
    code="$(http_code "http://127.0.0.1:$HTTP_PORT/")"
    if [ "$code" = "200" ]; then
        log_ok "HTTP 自检通过: http://127.0.0.1:$HTTP_PORT/ -> 200"
    else
        log_warn "HTTP 自检返回 ${code:-无响应}，请查看 xiaohuang log nginx"
    fi
    if [ "$DO_PHP" = "1" ]; then
        code="$(http_code "http://127.0.0.1:$HTTP_PORT/index.php")"
        [ "$code" = "200" ] && log_ok "PHP 自检通过: /index.php -> 200" || log_warn "PHP 自检返回 ${code:-无响应}"
    fi
else
    log_info "已跳过启动（--no-start）"
fi

# ===========================================================================
# 摘要
# ===========================================================================
cat <<EOF

$(printf '%s' "$C_GRN")============================================================
 Xiao Huang ${XIAOHUANG_VERSION} 安装完成
============================================================$(printf '%s' "$C_RST")

  安装目录   : $INSTALL_DIR
  站点根目录 : $WWW_DIR
  访问地址   : http://127.0.0.1:$HTTP_PORT/
  Nginx      : $NGINX_VER  ($NGINX_HOME)
  PHP        : ${PHP_VER:-未安装}  (FastCGI 127.0.0.1:${PHP_FPM_PORT:-N/A})
  Apache     : ${APACHE_VER:-未安装}
  MySQL      : ${MYSQL_VER:-未安装}  (端口 ${DB_PORT:-N/A}, 默认 root/${DEFAULT_ROOT_PASS})
  FTP        : $(if [ "$DO_FTP" = "1" ]; then printf 'vsftpd %s  (端口 %s, 被动 %s-%s)' "$FTP_VER" "$FTP_PORT" "$PASV_MIN" "$PASV_MAX"; else printf '未安装'; fi)
  服务管理   : $SUPERVISOR
  控制台     : xiaohuang {start|stop|restart|status|info|port|site|db|ext|module|ports|kill|hosts|version|panel|log|repair|uninstall}
  管理面板   : http://127.0.0.1:$PANEL_PORT/   （仅本机；远程用 ssh -L $PANEL_PORT:127.0.0.1:$PANEL_PORT 转发）

$(if [ -n "$PANEL_PASS" ]; then printf '%s\n\n  面板初始密码 : %s\n  （已写入 %s，改密码: xiaohuang panel passwd 新密码）' "$C_YEL" "$PANEL_PASS" "$INSTALL_DIR/$MANIFEST_NAME"; fi)

$(printf '%s' "$C_DIM")提示: 状态查看 xiaohuang status ；改端口 xiaohuang port nginx 8080$(printf '%s' "$C_RST")
EOF

exit 0
