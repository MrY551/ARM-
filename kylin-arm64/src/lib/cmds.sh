#!/usr/bin/env bash
# Xiao Huang for Kylin ARM64 —— 扩展命令模块
# 由 bin/xiaohuang source；实现网站 SSL/编辑、数据库增删、扩展开关、Apache 模块、
# 端口进程、hosts、组件版本、面板口令等子命令。
# 依赖主程序里的：INSTALL_DIR / m / render / manifest_set / svc_do / svc_active / die / log_*

# 主程序没导出的路径/端口变量，这里补齐（面板与 CLI 共用）
: "${EXT_DIR:=}"
[ -n "$EXT_DIR" ] || EXT_DIR="$INSTALL_DIR/app/Extensions"
# PHP 扩展目录：PHP_HOME 在 source 之后才赋值，因此惰性求值
php_ext_dir() {
    local d="${PHP_EXT_DIR:-}"
    if [ -z "$d" ] && [ -n "${PHP_HOME:-}" ] && [ -d "$PHP_HOME/lib/php" ]; then
        d="$(find "$PHP_HOME/lib/php" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1)"
    fi
    printf '%s' "$d"
}
: "${WEB_SERVER:=nginx}"
: "${HTTP_PORT:=80}"

# ---------------------------------------------------------------------------
# JSON 输出辅助
# ---------------------------------------------------------------------------
jesc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r//g'; }

json_arr_open()  { printf '['; }
json_arr_close() { printf ']'; }

# ---------------------------------------------------------------------------
# 网站：SSL / 编辑
# ---------------------------------------------------------------------------
# 从现有 vhost 提取 root
vhost_root_of() {
    local f="$1"
    awk '/^[[:space:]]*root[[:space:]]|^[[:space:]]*DocumentRoot[[:space:]]/{gsub(/[;"]/,"",$2); print $2; exit}' "$f" 2>/dev/null
}

site_ssl() {
    local domain="${1:-}" cert="${2:-}" key="${3:-}"
    [ -n "$domain" ] && [ -n "$cert" ] && [ -n "$key" ] || \
        die "$E_GENERIC" "用法: xiaohuang site ssl <域名> <证书.pem> <私钥.pem>"
    [ -f "$cert" ] || die "$E_GENERIC" "证书文件不存在: $cert"
    [ -f "$key" ]  || die "$E_GENERIC" "私钥文件不存在: $key"

    local httpf root
    httpf="$(ls "$NGINX_HOME/conf/vhosts/${domain}-"*.conf 2>/dev/null | grep -v -- '-443' | head -1)"
    [ -n "$httpf" ] || die "$E_GENERIC" "站点不存在: $domain（先 xiaohuang site add）"
    root="$(vhost_root_of "$httpf")"
    [ -n "$root" ] || root="$WWW_ROOT"

    mkdir -p "$NGINX_HOME/conf/ssl"
    cp -f "$cert" "$NGINX_HOME/conf/ssl/${domain}.pem"
    cp -f "$key"  "$NGINX_HOME/conf/ssl/${domain}.key"
    chmod 600 "$NGINX_HOME/conf/ssl/${domain}.key" 2>/dev/null || true

    render "$INSTALL_DIR/conf/vhost-ssl.nginx.tpl" "$NGINX_HOME/conf/vhosts/${domain}-443.conf" \
        "@DOMAIN@" "$domain" \
        "@ROOT@" "$root" \
        "@PHP_FPM_PORT@" "${PHP_FPM_PORT:-9000}" \
        "@LOG_DIR@" "$LOG_DIR" \
        "@SSL_CERT@" "$NGINX_HOME/conf/ssl/${domain}.pem" \
        "@SSL_KEY@" "$NGINX_HOME/conf/ssl/${domain}.key"

    if [ -n "${APACHE_HOME:-}" ] && [ -n "${APACHE_BIN:-}" ]; then
        render "$INSTALL_DIR/conf/vhost-ssl.apache.tpl" "$APACHE_HOME/conf/vhosts/${domain}-443.conf" \
            "@DOMAIN@" "$domain" "@ROOT@" "$root" \
            "@PHP_FPM_PORT@" "${PHP_FPM_PORT:-9000}" "@LOG_DIR@" "$LOG_DIR" \
            "@SSL_CERT@" "$NGINX_HOME/conf/ssl/${domain}.pem" \
            "@SSL_KEY@" "$NGINX_HOME/conf/ssl/${domain}.key"
        # 确保 ssl 模块与 443 监听
        if ! grep -q "^Listen 443" "$APACHE_HOME/conf/vhosts/Listen.conf" 2>/dev/null; then
            printf 'Listen 443\n' >> "$APACHE_HOME/conf/vhosts/Listen.conf"
        fi
    fi

    "$NGINX_BIN" -t -c "$NGINX_HOME/conf/nginx.conf" -p "$NGINX_HOME" >/dev/null 2>&1 \
        || die "$E_GENERIC" "nginx 配置校验失败，检查证书路径"
    svc_do restart nginx >/dev/null 2>&1 || true
    [ -n "${APACHE_HOME:-}" ] && { svc_do restart apache >/dev/null 2>&1 || true; }
    log_ok "SSL 已启用: https://$domain/  (证书 $cert)"
}

site_ssl_del() {
    local domain="${1:-}"
    [ -n "$domain" ] || die "$E_GENERIC" "用法: xiaohuang site ssl-del <域名>"
    rm -f "$NGINX_HOME/conf/vhosts/${domain}-443.conf" \
          "$NGINX_HOME/conf/ssl/${domain}.pem" "$NGINX_HOME/conf/ssl/${domain}.key" 2>/dev/null
    [ -n "${APACHE_HOME:-}" ] && rm -f "$APACHE_HOME/conf/vhosts/${domain}-443.conf" 2>/dev/null
    svc_do restart nginx >/dev/null 2>&1 || true
    log_ok "已移除 $domain 的 SSL 配置"
}

site_edit() {
    local domain="" root="" port="" alias=""
    domain="${1:-}"; shift || true
    [ -n "$domain" ] || die "$E_GENERIC" "用法: xiaohuang site edit <域名> [--root 目录] [--port 端口] [--alias 别名]"
    while [ $# -gt 0 ]; do
        case "$1" in
            --root)  root="${2:-}"; shift 2 ;;
            --port)  port="${2:-}"; shift 2 ;;
            --alias) alias="${2:-}"; shift 2 ;;
            *) die "$E_GENERIC" "未知参数: $1" ;;
        esac
    done

    local httpf
    httpf="$(ls "$NGINX_HOME/conf/vhosts/${domain}-"*.conf 2>/dev/null | grep -v -- '-443' | head -1)"
    [ -n "$httpf" ] || die "$E_GENERIC" "站点不存在: $domain"
    [ -n "$root" ] || root="$(vhost_root_of "$httpf")"
    [ -n "$root" ] || root="$WWW_ROOT"
    [ -n "$port" ] || port="$(awk '/listen/{gsub(/;/,"",$2); print $2; exit}' "$httpf")"
    [ -n "$port" ] || port="$HTTP_PORT"

    case "$root" in /*) ;; *) root="$WWW_ROOT/$root" ;; esac
    if str_has_space "$root"; then die "$E_BAD_PATH" "站点目录不能含空格: $root"; fi
    if ! str_is_safe_path "$root"; then die "$E_BAD_PATH" "站点目录含中文或非法字符: $root"; fi
    mkdir -p "$root"

    local old
    old="$(basename "$httpf")"
    render "$INSTALL_DIR/conf/vhost.nginx.tpl" "$NGINX_HOME/conf/vhosts/${domain}-${port}.conf" \
        "@DOMAIN@" "$domain" "@PORT@" "$port" "@ROOT@" "$root" \
        "@PHP_FPM_PORT@" "${PHP_FPM_PORT:-9000}" "@LOG_DIR@" "$LOG_DIR" \
        "@SSL_CERT@" "" "@SSL_KEY@" ""
    [ "$old" != "${domain}-${port}.conf" ] && rm -f "$httpf"

    if [ -n "${APACHE_HOME:-}" ]; then
        [ -f "$INSTALL_DIR/conf/vhost.apache.tpl" ] || cp -f "$APACHE_HOME/conf/vhost.tpl" "$INSTALL_DIR/conf/vhost.apache.tpl"
        rm -f "$APACHE_HOME/conf/vhosts/${domain}-"*.conf 2>/dev/null
        render "$INSTALL_DIR/conf/vhost.apache.tpl" "$APACHE_HOME/conf/vhosts/${domain}-${port}.conf" \
            "@DOMAIN@" "$domain" "@PORT@" "$port" "@ROOT@" "$root" "@LOG_DIR@" "$LOG_DIR"
    fi
    svc_do restart nginx >/dev/null 2>&1 || true
    [ -n "${APACHE_HOME:-}" ] && { svc_do restart apache >/dev/null 2>&1 || true; }
    log_ok "站点已更新: $domain -> $root (端口 $port)"
}

site_list_json() {
    local f d p r ssl first=1
    printf '['
    for f in "$NGINX_HOME/conf/vhosts"/*.conf; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in Listen.conf) continue ;; esac
        d="$(awk '/server_name/{gsub(/;/,"",$2); print $2; exit}' "$f")"
        [ -n "$d" ] || continue
        p="$(awk '/listen/{gsub(/;/,"",$2); print $2; exit}' "$f")"
        r="$(vhost_root_of "$f")"
        ssl=0
        [ -f "$NGINX_HOME/conf/vhosts/${d}-443.conf" ] && ssl=1
        [ "$first" = "1" ] || printf ','
        first=0
        printf '{"domain":"%s","port":"%s","root":"%s","ssl":%s}' \
            "$(jesc "$d")" "$(jesc "$p")" "$(jesc "$r")" "$ssl"
    done
    printf ']'
}

# ---------------------------------------------------------------------------
# 数据库：列出 / 建库 / 删库 / 导入 / 导出
# ---------------------------------------------------------------------------
db_client() {
    local c
    c="$(first_bin "$MYSQL_HOME/bin/mysql" "$MYSQL_HOME/bin/mariadb" /usr/bin/mysql /usr/bin/mariadb 2>/dev/null || true)"
    [ -n "$c" ] || die "$E_DEP" "缺少 mysql 客户端"
    printf '%s' "$c"
}

db_run() {
    local cli sql
    cli="$(db_client)"; sql="$1"
    local pass; pass="$(m DB_ROOT_PASS)"
    "$cli" -uroot ${pass:+-p"$pass"} --socket="$RUN_DIR/mysql.sock" -N -B -e "$sql" 2>/dev/null
}

db_list_json() {
    local names; names="$(db_run 'SHOW DATABASES' || true)"
    printf '['
    local first=1 n size
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        case "$n" in information_schema|performance_schema|mysql|sys) : ;; esac
        size="$(db_run "SELECT IFNULL(ROUND(SUM(data_length+index_length)/1024/1024,1),0) FROM information_schema.tables WHERE table_schema='$n'" || echo 0)"
        [ "$first" = "1" ] || printf ','
        first=0
        printf '{"name":"%s","size_mb":"%s"}' "$(jesc "$n")" "$(jesc "${size:-0}")"
    done <<< "$names"
    printf ']'
}

db_create() {
    local name="${1:-}" user="${2:-}" pass="${3:-}"
    [ -n "$name" ] || die "$E_GENERIC" "用法: xiaohuang db create <库名> [用户名] [密码]"
    printf '%s' "$name" | grep -qE '^[A-Za-z0-9_]{1,64}$' || die "$E_GENERIC" "库名只允许字母数字下划线: $name"
    db_run "CREATE DATABASE IF NOT EXISTS \`$name\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci" \
        || die "$E_GENERIC" "建库失败（数据库未启动？xiaohuang start mysql）"
    log_ok "数据库已创建: $name"
    if [ -n "$user" ]; then
        printf '%s' "$user" | grep -qE '^[A-Za-z0-9_]{1,32}$' || die "$E_GENERIC" "用户名不合法: $user"
        [ -n "$pass" ] || die "$E_GENERIC" "指定用户名时必须给密码"
        local is_maria=0
        "$MYSQLD_BIN" --version 2>/dev/null | grep -qi mariadb && is_maria=1
        db_run "CREATE USER IF NOT EXISTS '$user'@'localhost' IDENTIFIED BY '$pass'" || true
        db_run "CREATE USER IF NOT EXISTS '$user'@'127.0.0.1' IDENTIFIED BY '$pass'" || true
        db_run "GRANT ALL PRIVILEGES ON \`$name\`.* TO '$user'@'localhost'" || true
        db_run "GRANT ALL PRIVILEGES ON \`$name\`.* TO '$user'@'127.0.0.1'" || true
        db_run "FLUSH PRIVILEGES" || true
        log_ok "已授权: $user / ******** -> $name"
    fi
}

db_drop() {
    local name="${1:-}"
    [ -n "$name" ] || die "$E_GENERIC" "用法: xiaohuang db drop <库名>"
    printf '%s' "$name" | grep -qE '^[A-Za-z0-9_]{1,64}$' || die "$E_GENERIC" "库名不合法: $name"
    db_run "DROP DATABASE IF EXISTS \`$name\`" || die "$E_GENERIC" "删除失败"
    log_ok "数据库已删除: $name"
}

db_import() {
    local file="${1:-}" name="${2:-}"
    [ -f "$file" ] || die "$E_GENERIC" "SQL 文件不存在: $file"
    [ -n "$name" ] || die "$E_GENERIC" "用法: xiaohuang db import <file.sql> <库名>"
    local cli pass; cli="$(db_client)"; pass="$(m DB_ROOT_PASS)"
    "$cli" -uroot ${pass:+-p"$pass"} --socket="$RUN_DIR/mysql.sock" "$name" < "$file" \
        || die "$E_GENERIC" "导入失败: $file"
    log_ok "已导入 $(basename "$file") -> $name"
}

db_export() {
    local name="${1:-}" file="${2:-}"
    [ -n "$name" ] && [ -n "$file" ] || die "$E_GENERIC" "用法: xiaohuang db export <库名> <file.sql>"
    local dump; dump="$(first_bin /usr/bin/mysqldump /usr/bin/mariadb-dump "$MYSQL_HOME/bin/mysqldump" 2>/dev/null || true)"
    [ -n "$dump" ] || die "$E_DEP" "缺少 mysqldump"
    local pass; pass="$(m DB_ROOT_PASS)"
    "$dump" -uroot ${pass:+-p"$pass"} --socket="$RUN_DIR/mysql.sock" --databases "$name" > "$file" \
        || die "$E_GENERIC" "导出失败"
    log_ok "已导出 $name -> $file ($(du -h "$file" | cut -f1))"
}

# ---------------------------------------------------------------------------
# PHP 扩展
# ---------------------------------------------------------------------------
ext_conf() { printf '%s/etc/php.ini' "$PHP_HOME"; }

ext_available() {
    local n="$1" ed; ed="$(php_ext_dir)"
    [ -n "$ed" ] && [ -f "$ed/$n.so" ] && return 0
    # 内置（无需 .so）的常见扩展
    ext_builtin "$n" && return 0
    return 1
}

# PHP 7.4 里编译进核心、没有独立 .so 的扩展
ext_builtin() {
    case "$1" in
        Core|date|filter|hash|pcre|Reflection|SPL|standard|session|zlib|json|openssl|ctype|tokenizer|iconv|phar|posix|sockets|exif|simplexml|dom|xml|xmlreader|xmlwriter|libxml) return 0 ;;
    esac
    return 1
}

ext_is_on() {
    local n="$1" c
    c="$(ext_conf)"
    if grep -qE "^extension=${n}(\.so)?$|^zend_extension=.*/${n}\.so$" "$c" 2>/dev/null; then
        return 0
    fi
    # 内置扩展：没有 .so 也算可用
    if ext_builtin "$n" && { [ -z "$(php_ext_dir)" ] || [ ! -f "$(php_ext_dir)/$n.so" ]; }; then
        return 0
    fi
    return 1
}

ext_list_json() {
    local first=1 n on avail ed; ed="$(php_ext_dir)"
    printf '['
    {
        [ -n "$ed" ] && ls "$ed"/*.so 2>/dev/null | sed 's#.*/##; s#\.so$##'
        printf '%s\n' json openssl pdo ctype tokenizer filter session pcre hash date spl standard reflection zlib iconv
    } | sort -u | while IFS= read -r n; do
        [ -n "$n" ] || continue
        on=0; ext_is_on "$n" && on=1
        avail=0; ext_available "$n" && avail=1
        [ "$first" = "1" ] || printf ','
        first=0
        printf '{"name":"%s","enabled":%s,"available":%s}' "$(jesc "$n")" "$on" "$avail"
    done
    printf ']'
}

ext_set() {
    local n="${1:-}" act="${2:-}"
    [ -n "$n" ] || die "$E_GENERIC" "用法: xiaohuang ext <list|enable|disable> <扩展名>"
    printf '%s' "$n" | grep -qE '^[A-Za-z0-9_]{1,40}$' || die "$E_GENERIC" "扩展名不合法: $n"
    local c; c="$(ext_conf)"
    [ -f "$c" ] || die "$E_GENERIC" "php.ini 不存在: $c"

    case "$act" in
        enable)
            ext_available "$n" || die "$E_GENERIC" "扩展不可用（$(php_ext_dir)/$n.so 不存在）: $n"
            if grep -qE "^;extension=${n}(\.so)?$" "$c"; then
                sed -i "s#^;extension=${n}\(\.so\)\?$#extension=${n}#" "$c"
            elif ! ext_is_on "$n"; then
                if [ "$n" = "opcache" ]; then
                    printf 'zend_extension=%s/opcache.so\n' "$(php_ext_dir)" >> "$c"
                else
                    printf 'extension=%s\n' "$n" >> "$c"
                fi
            fi
            log_ok "已启用扩展: $n"
            ;;
        disable)
            if [ "$n" = "opcache" ]; then
                sed -i "s#^zend_extension=.*/opcache\.so#;zend_extension=opcache.so#" "$c"
            fi
            sed -i "s#^extension=${n}\(\.so\)\?$#;extension=${n}#" "$c"
            log_ok "已禁用扩展: $n"
            ;;
        *) log_ok "扩展 $n 状态: $(ext_is_on "$n" && echo enabled || echo disabled)" ;;
    esac
    "$PHP_FPM_BIN" -t -c "$PHP_HOME/etc" -y "$PHP_HOME/etc/php-fpm.conf" >/dev/null 2>&1 || true
    svc_do restart php >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Apache 模块
# ---------------------------------------------------------------------------
mod_conf() { printf '%s/conf/httpd.conf' "$APACHE_HOME"; }

module_list_json() {
    [ -n "${APACHE_HOME:-}" ] || { printf '[]'; return 0; }
    local c dir en f base name on first=1
    c="$(mod_conf)"; dir="$APACHE_HOME/modules"
    en=""
    [ -f "$c" ] && en="$(grep -E '^LoadModule' "$c" 2>/dev/null \
        | sed -E 's/^LoadModule[[:space:]]+([A-Za-z0-9_]+)_module.*/\1/' | tr '\n' ' ')"

    printf '['
    for f in "$dir"/mod_*.so; do
        [ -f "$f" ] || continue
        base="$(basename "$f" .so)"
        name="${base#mod_}"
        case " $en " in *" $name "*) on=true ;; *) on=false ;; esac
        [ "$first" = "1" ] || printf ','
        first=0
        printf '{"name":"%s","enabled":%s,"so":"%s"}' "$(jesc "$name")" "$on" "$(jesc "$base")"
    done
    printf ']'
}

module_set() {
    [ -n "${APACHE_HOME:-}" ] || die "$E_GENERIC" "Apache 未安装（安装时加 --with-apache）"
    local n="${1:-}" act="${2:-}"
    [ -n "$n" ] || die "$E_GENERIC" "用法: xiaohuang module <list|enable|disable> <模块名>"
    printf '%s' "$n" | grep -qE '^[A-Za-z0-9_]{1,40}$' || die "$E_GENERIC" "模块名不合法: $n"
    local c so bak; c="$(mod_conf)"
    [ -f "$c" ] || die "$E_GENERIC" "找不到 httpd.conf: $c"
    so="$APACHE_HOME/modules/mod_${n}.so"

    bak="$(mktemp)"
    cp -f "$c" "$bak"

    case "$act" in
        enable)
            if [ ! -f "$so" ]; then rm -f "$bak"; die "$E_GENERIC" "没有这个模块文件: $so"; fi
            if grep -qE "^LoadModule[[:space:]]+${n}_module" "$c"; then
                log_info "$n 已经是启用状态"
                rm -f "$bak"; return 0
            elif grep -qE "^#LoadModule[[:space:]]+${n}_module" "$c"; then
                sed -i -E "s|^#LoadModule([[:space:]]+${n}_module)|LoadModule\1|" "$c"
            else
                printf 'LoadModule %s_module "%s"\n' "$n" "$so" >> "$c"
            fi
            ;;
        disable)
            if ! grep -qE "^LoadModule[[:space:]]+${n}_module" "$c"; then
                log_info "$n 本来就没启用"
                rm -f "$bak"; return 0
            fi
            sed -i -E "s|^LoadModule([[:space:]]+${n}_module)|#LoadModule\1|" "$c"
            ;;
        *) rm -f "$bak"; die "$E_GENERIC" "用法: xiaohuang module <list|enable|disable> <模块名>" ;;
    esac

    # 改完必须过 httpd -t，不然 Apache 起不来
    if ! "$APACHE_BIN" -t -f "$c" >/dev/null 2>&1; then
        cp -f "$bak" "$c"; rm -f "$bak"
        die "$E_GENERIC" "$n 改动后 httpd -t 检查失败，已回滚（部分模块有加载顺序依赖）"
    fi
    rm -f "$bak"

    if [ "$WEB_SERVER" = "apache" ]; then svc_do restart apache >/dev/null 2>&1 || true; fi
    log_ok "$n 已$([ "$act" = "enable" ] && echo 启用 || echo 停用)"
}

# ---------------------------------------------------------------------------
# 端口 / 进程
# ---------------------------------------------------------------------------
port_list_json() {
    local first=1 line port addr pid proc
    printf '['
    while IFS= read -r line; do
        addr="$(printf '%s' "$line" | awk '{print $4}')"
        pid="$(printf '%s' "$line" | sed -n 's/.*pid=\([0-9]*\).*/\1/p')"
        port="${addr##*:}"
        case "$port" in ''|*[!0-9]*) continue ;; esac
        proc=""
        [ -n "$pid" ] && proc="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
        [ "$first" = "1" ] || printf ','
        first=0
        printf '{"port":"%s","addr":"%s","pid":"%s","process":"%s"}' \
            "$(jesc "$port")" "$(jesc "$addr")" "$(jesc "$pid")" "$(jesc "$proc")"
    done < <(ss -lntp 2>/dev/null | tail -n +2)
    printf ']'
}

kill_target() {
    local port="" pid=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --port) port="${2:-}"; shift 2 ;;
            --pid)  pid="${2:-}"; shift 2 ;;
            *) die "$E_GENERIC" "用法: xiaohuang kill --port <端口> | --pid <pid>" ;;
        esac
    done
    if [ -z "$pid" ] && [ -n "$port" ]; then
        printf '%s' "$port" | grep -qE '^[0-9]+$' || die "$E_GENERIC" "端口不合法: $port"
        pid="$(ss -lntp 2>/dev/null | awk -v p=":$port" '$4 ~ p {print $NF}' | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1)"
        [ -n "$pid" ] || die "$E_GENERIC" "端口 $port 没有监听进程"
    fi
    [ -n "$pid" ] || die "$E_GENERIC" "用法: xiaohuang kill --port <端口> | --pid <pid>"
    printf '%s' "$pid" | grep -qE '^[0-9]+$' || die "$E_GENERIC" "pid 不合法: $pid"
    local name; name="$(ps -p "$pid" -o comm= 2>/dev/null || echo unknown)"
    kill "$pid" 2>/dev/null || die "$E_GENERIC" "无法结束进程 $pid（权限不足？）"
    log_ok "已结束进程 $pid ($name)"
}

# ---------------------------------------------------------------------------
# hosts
# ---------------------------------------------------------------------------
hosts_set() {
    local act="${1:-}" domain="${2:-}"
    [ -n "$domain" ] || die "$E_GENERIC" "用法: xiaohuang hosts <add|del> <域名>"
    printf '%s' "$domain" | grep -qE '^[A-Za-z0-9.*_-]+(\.[A-Za-z0-9_-]+)*$' || die "$E_GENERIC" "域名不合法: $domain"
    local H=/etc/hosts
    case "$act" in
        add)
            if grep -qE "^127\.0\.0\.1[[:space:]]+${domain}([[:space:]]|$)" "$H"; then
                log_ok "hosts 已存在: $domain"; return 0
            fi
            cp -f "$H" "$H.xiaohuang.bak"
            printf '127.0.0.1 %s\n' "$domain" >> "$H"
            log_ok "已写入 hosts: 127.0.0.1 $domain"
            ;;
        del)
            cp -f "$H" "$H.xiaohuang.bak"
            sed -i -E "/^127\.0\.0\.1[[:space:]]+${domain}([[:space:]]|$)/d" "$H"
            log_ok "已从 hosts 删除: $domain"
            ;;
        *) die "$E_GENERIC" "用法: xiaohuang hosts <add|del> <域名>" ;;
    esac
}

# ---------------------------------------------------------------------------
# 组件版本
# ---------------------------------------------------------------------------
ver_list_json() {
    local kind dirs d v cur first=1 on
    printf '['
    for kind in nginx apache mysql php; do
        case "$kind" in
            nginx)  dirs="$(ls -d "$EXT_DIR"/Nginx* 2>/dev/null)";      cur="${NGINX_HOME:-}" ;;
            apache) dirs="$(ls -d "$EXT_DIR"/Apache* 2>/dev/null)";     cur="${APACHE_HOME:-}" ;;
            mysql)  dirs="$(ls -d "$EXT_DIR"/MySQL* 2>/dev/null)";      cur="${MYSQL_HOME:-}" ;;
            php)    dirs="$(ls -d "$EXT_DIR"/php/php* 2>/dev/null)";    cur="${PHP_HOME:-}" ;;
        esac
        [ -n "$dirs" ] || continue
        while IFS= read -r d; do
            [ -n "$d" ] || continue
            v="$(basename "$d")"
            v="${v#Nginx}"; v="${v#Apache}"; v="${v#MySQL}"; v="${v#php}"
            [ "$first" = "1" ] || printf ','
            first=0
            if [ "$d" = "$cur" ]; then on=true; else on=false; fi
            printf '{"kind":"%s","version":"%s","path":"%s","current":%s}' \
                "$kind" "$(jesc "$v")" "$(jesc "$d")" "$on"
        done <<< "$dirs"
    done
    printf ']'
}

ver_use() {
    local kind="${1:-}" ver="${2:-}"
    [ -n "$kind" ] && [ -n "$ver" ] || die "$E_GENERIC" "用法: xiaohuang version use <nginx|apache|mysql|php> <版本>"
    local dir=""
    case "$kind" in
        nginx)  dir="$EXT_DIR/Nginx$ver";  [ -d "$dir" ] || die "$E_GENERIC" "版本不存在: $dir" ;;
        apache) dir="$EXT_DIR/Apache$ver"; [ -d "$dir" ] || die "$E_GENERIC" "版本不存在: $dir" ;;
        mysql)  dir="$EXT_DIR/MySQL$ver";  [ -d "$dir" ] || die "$E_GENERIC" "版本不存在: $dir" ;;
        php)    dir="$EXT_DIR/php/php$ver";[ -d "$dir" ] || die "$E_GENERIC" "版本不存在: $dir" ;;
        *) die "$E_GENERIC" "未知组件: $kind" ;;
    esac

    case "$kind" in
        nginx)
            manifest_set "$INSTALL_DIR" NGINX_HOME "$dir"
            manifest_set "$INSTALL_DIR" NGINX_BIN "$dir/bin/nginx"
            manifest_set "$INSTALL_DIR" NGINX_VER "$ver"
            sed -i "s#^\(.*nginx\) .*#\1 $dir/bin/nginx -c $dir/conf/nginx.conf -p $dir#" /dev/null 2>/dev/null || true
            ;;
        apache)
            manifest_set "$INSTALL_DIR" APACHE_HOME "$dir"
            manifest_set "$INSTALL_DIR" APACHE_BIN "$dir/bin/httpd"
            manifest_set "$INSTALL_DIR" APACHE_VER "$ver"
            ;;
        mysql)
            manifest_set "$INSTALL_DIR" MYSQL_HOME "$dir"
            manifest_set "$INSTALL_DIR" MYSQLD_BIN "$dir/bin/mysqld"
            manifest_set "$INSTALL_DIR" MYSQL_VER "$ver"
            ;;
        php)
            manifest_set "$INSTALL_DIR" PHP_HOME "$dir"
            manifest_set "$INSTALL_DIR" PHP_FPM_BIN "$dir/bin/php-fpm"
            manifest_set "$INSTALL_DIR" PHP_CLI_BIN "$dir/bin/php"
            manifest_set "$INSTALL_DIR" PHP_VER "$ver"
            ;;
    esac
    log_ok "$kind 已切换到 $ver"
    log_warn "systemd 单元仍指向旧路径，执行 xiaohuang repair 重建单元后 restart"
}


# ---------------------------------------------------------------------------
# FTP（vsftpd）账号与端口
# ---------------------------------------------------------------------------
ftp_conf()     { printf '%s/etc/vsftpd.conf' "$FTP_HOME"; }
ftp_userlist() { printf '%s/etc/userlist' "$FTP_HOME"; }

ftp_user_list_json() {
    local first=1 u dir
    printf '['
    [ -f "$(ftp_userlist)" ] || { printf ']'; return 0; }
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        dir="$(getent passwd "$u" | cut -d: -f6)"
        [ -n "$dir" ] || continue
        [ "$first" = "1" ] || printf ','
        first=0
        printf '{"name":"%s","home":"%s"}' "$(jesc "$u")" "$(jesc "$dir")"
    done < "$(ftp_userlist)"
    printf ']'
}

ftp_user_add() {
    local name="${1:-}" dir="${2:-}" pass="${3:-}"
    [ -n "$name" ] && [ -n "$dir" ] || die "$E_GENERIC" "用法: xiaohuang ftp user add <账号> <目录> [密码]"
    printf '%s' "$name" | grep -qE '^[a-z_][a-z0-9_-]{0,31}$' || die "$E_GENERIC" "账号只能小写字母/数字/下划线，且以字母开头"
    case "$dir" in /*) ;; *) dir="$WWW_ROOT/$dir" ;; esac
    if str_has_space "$dir" || ! str_is_safe_path "$dir"; then die "$E_BAD_PATH" "目录必须是纯英文绝对路径: $dir"; fi
    [ "$(id -u "$name" 2>/dev/null || echo x)" = "x" ] || die "$E_GENERIC" "系统里已有同名用户: $name"
    if [ -z "$pass" ]; then
        pass="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 10)"
    fi

    mkdir -p "$dir"
    if ! useradd -d "$dir" -M -s /usr/sbin/nologin "$name" 2>/dev/null; then
        useradd -d "$dir" -M -s /usr/sbin/nologin "$name" || die "$E_GENERIC" "创建系统用户失败: $name"
    fi
    printf '%s:%s\n' "$name" "$pass" | chpasswd || die "$E_GENERIC" "设置密码失败"
    chown -R "$name:$(id -gn "$name" 2>/dev/null || echo nogroup)" "$dir" 2>/dev/null || true
    chmod 775 "$dir" 2>/dev/null || true

    mkdir -p "$(dirname "$(ftp_userlist)")"
    touch "$(ftp_userlist)"; chmod 600 "$(ftp_userlist)"
    grep -qxF "$name" "$(ftp_userlist)" || printf '%s\n' "$name" >> "$(ftp_userlist)"

    svc_do restart ftp >/dev/null 2>&1 || true
    log_ok "FTP 账号已创建: $name / $pass  ->  $dir"
    log_info "端口 $FTP_PORT，被动 $(manifest_get "$INSTALL_DIR" FTP_PASV_MIN 2>/dev/null || echo 30000)-$(manifest_get "$INSTALL_DIR" FTP_PASV_MAX 2>/dev/null || echo 30100)"
}

ftp_user_del() {
    local name="${1:-}"
    [ -n "$name" ] || die "$E_GENERIC" "用法: xiaohuang ftp user del <账号>"
    [ -f "$(ftp_userlist)" ] && sed -i "/^${name}$/d" "$(ftp_userlist)" 2>/dev/null
    if id "$name" >/dev/null 2>&1; then
        userdel "$name" 2>/dev/null || die "$E_GENERIC" "删除系统用户失败: $name"
    fi
    svc_do restart ftp >/dev/null 2>&1 || true
    log_ok "FTP 账号已删除: $name（站点目录保留）"
}

ftp_passwd() {
    local name="${1:-}" pass="${2:-}"
    [ -n "$name" ] && [ -n "$pass" ] || die "$E_GENERIC" "用法: xiaohuang ftp passwd <账号> <新密码>"
    id "$name" >/dev/null 2>&1 || die "$E_GENERIC" "账号不存在: $name"
    printf '%s:%s\n' "$name" "$pass" | chpasswd || die "$E_GENERIC" "改密失败"
    log_ok "FTP 账号密码已更新: $name"
}

ftp_port() {
    local port="${1:-}"
    [ -n "$port" ] || die "$E_GENERIC" "用法: xiaohuang ftp port <端口>"
    printf '%s' "$port" | grep -qE '^[0-9]{1,5}$' || die "$E_GENERIC" "端口不合法"
    if port_in_use "$port"; then die "$E_GENERIC" "端口 $port 已被占用"; fi
    local c; c="$(ftp_conf)"
    sed -i "s/^listen_port=.*/listen_port=$port/" "$c"
    svc_do restart ftp >/dev/null 2>&1 || true
    manifest_set "$INSTALL_DIR" FTP_PORT "$port"
    log_ok "FTP 端口已改为 $port"
}

# ---------------------------------------------------------------------------
# 面板
# ---------------------------------------------------------------------------
panel_passwd() {
    local pass="${1:-}"
    [ -n "$pass" ] || die "$E_GENERIC" "用法: xiaohuang panel passwd <新密码>"
    [ ${#pass} -ge 6 ] || die "$E_GENERIC" "密码至少 6 位"
    local h
    h="$(printf '%s' "$pass" | md5sum | awk '{print $1}')"
    manifest_set "$INSTALL_DIR" PANEL_PASS_HASH "$h"
    log_ok "面板密码已更新"
}

panel_url() {
    local port; port="$(manifest_get "$INSTALL_DIR" PANEL_PORT 2>/dev/null || true)"
    [ -n "$port" ] || port="$(m HTTP_PORT)"
    printf 'http://127.0.0.1:%s/\n' "$port"
}


# ---------------------------------------------------------------------------
# 结构化状态（面板用）
# ---------------------------------------------------------------------------
status_json() {
    local first=1 t st ver port code
    printf '{"version":"%s","build":"%s","dir":"%s","web":"%s","http":"%s","services":[' \
        "$(jesc "$(m VERSION)")" "$(jesc "$(m BUILD)")" "$(jesc "$INSTALL_DIR")" \
        "$(jesc "${WEB_SERVER:-nginx}")" "$(jesc "${HTTP_PORT:-}")"
    for t in ${INSTALLED:-nginx}; do
        case "$t" in
            nginx)  ver="Nginx ${NGINX_VER:-?}"; port="$HTTP_PORT" ;;
            apache) ver="Apache ${APACHE_VER:-?}"; port="$HTTP_PORT" ;;
            php)    ver="PHP ${PHP_VER:-?}"; port="${PHP_FPM_PORT:-?}" ;;
            mysql)  ver="MySQL ${MYSQL_VER:-?}"; port="$DB_PORT" ;;
            ftp)    ver="FTP vsftpd ${FTP_VER:-?}"; port="$FTP_PORT" ;;
        esac
        st="$(svc_active "$t" 2>/dev/null)"; [ -n "$st" ] || st=stopped
        [ "$first" = "1" ] || printf ','
        first=0
        if [ "$t" = "${WEB_SERVER:-nginx}" ]; then
            printf '{"name":"%s","status":"%s","version":"%s","port":"%s","active":true}' \
                "$t" "$st" "$(jesc "$ver")" "$port"
        else
            printf '{"name":"%s","status":"%s","version":"%s","port":"%s","active":false}' \
                "$t" "$st" "$(jesc "$ver")" "$port"
        fi
    done
    code="$(http_code "http://127.0.0.1:${HTTP_PORT:-80}/")"
    printf '],"http_code":"%s"}' "${code:-000}"
}
