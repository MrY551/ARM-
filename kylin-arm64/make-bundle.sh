#!/usr/bin/env bash
# phpStudy V8 for Kylin ARM64 —— 离线组件包制作
#
# 在一台已联网的银河麒麟 V10 (aarch64) 上运行，把系统仓库里的
# nginx / php-fpm / apache2 / mysql 二进制及其私有共享库抽出来，
# 打包成安装器可用的 components/*.tar.gz，之后即可在完全离线的机器上安装。
#
# 用法: ./make-bundle.sh [--out payload] [--php 8.3]
# 产物: payload/components/{nginx,php-fpm,apache,mysql}.tar.gz
# 安装: sudo ./phpstudy-kylin-arm64-8.1.1.3.run --dir /opt/phpstudy --offline payload
set -euo pipefail

OUT="$PWD/payload"
PHPV=""
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="${2:-}"; shift 2 ;;
        --php) PHPV="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

[ "$(id -u)" = "0" ] || { echo "[FAIL] 需要 root 运行" >&2; exit 1; }
case "$(uname -m)" in
    aarch64|arm64) ;;
    *) echo "[FAIL] 本脚本应在 aarch64 上运行（当前 $(uname -m)），否则打出来的二进制无法在麒麟上执行" >&2; exit 1 ;;
esac

command -v apt-get >/dev/null || { echo "[FAIL] 需要 apt 系系统" >&2; exit 1; }
command -v dpkg-deb >/dev/null || { echo "[FAIL] 需要 dpkg-deb（apt-get install dpkg）" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT/components" "$WORK/dl" "$WORK/root"

# 基础库白名单：系统自带的不要打进包里
BASE_LIBS='^(linux-vdso|ld-linux-aarch64|libc\.so|libm\.so|libpthread|libdl\.so|librt\.so|libresolv|libnss_|libgcc_s\.so|libstdc\+\+\.so|libz\.so)'

# 提取一组 deb 到 root/
fetch_and_unpack() {
    local tag="$1"; shift
    local pkgs=("$@") p
    ( cd "$WORK/dl" && apt-get download "${pkgs[@]}" >/dev/null 2>&1 ) || {
        echo "[WARN] $tag: apt-get download 失败（${pkgs[*]}），跳过" >&2
        return 1
    }
    local extracted=0
    for p in "$WORK/dl"/*.deb; do
        [ -f "$p" ] || continue
        dpkg-deb -x "$p" "$WORK/root" || return 1
        rm -f "$p"
        extracted=$((extracted+1))
    done
    [ "$extracted" -gt 0 ]
}

# 收集二进制的非系统依赖库
collect_libs() {
    local bindir="$1" libdir="$2"; shift 2
    mkdir -p "$libdir"
    local bin lib
    for bin in "$@"; do
        [ -f "$bin" ] || continue
        ldd "$bin" 2>/dev/null | awk '/=> \//{print $3}' | while read -r lib; do
            [ -f "$lib" ] || continue
            case "$(basename "$lib")" in
                libc.so*|libm.so*|libpthread*|libdl.so*|librt.so*|libresolv*|libnss_*|libgcc_s.so*|libstdc++.so*|libz.so*|ld-linux-aarch64*) continue ;;
            esac
            cp -Lf "$lib" "$libdir/" 2>/dev/null || true
        done
    done
}

# 生成会设置 LD_LIBRARY_PATH 的启动包装脚本
make_wrapper() {
    local target="$1" realname="$2"
    mkdir -p "$(dirname "$target")"
    cat > "$target" <<WRAP
#!/bin/sh
# phpStudy 离线组件启动包装：优先使用组件自带库
SELF_DIR=\$(cd "\$(dirname "\$0")" && pwd)
ROOT_DIR=\$(cd "\$SELF_DIR/.." && pwd)
if [ -d "\$ROOT_DIR/lib" ]; then
    LD_LIBRARY_PATH="\$ROOT_DIR/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
    export LD_LIBRARY_PATH
fi
exec "\$ROOT_DIR/libexec/$realname" "\$@"
WRAP
    chmod 755 "$target"
}

pack() {
    local name="$1" dir="$2"
    tar -czf "$OUT/components/$name.tar.gz" -C "$dir" .
    echo "[ OK ] $OUT/components/$name.tar.gz ($(du -h "$OUT/components/$name.tar.gz" | cut -f1))"
}

echo "==> 下载并解包系统组件"
fetch_and_unpack nginx nginx nginx-common || true
fetch_and_unpack apache apache2 apache2-bin apache2-data || true
fetch_and_unpack mysql mysql-server-core-8.0 mysql-client-core-8.0 mysql-common || true
if [ -n "$PHPV" ]; then
    fetch_and_unpack php "php${PHPV}-fpm" "php${PHPV}-cli" "php${PHPV}-common" \
                         "php${PHPV}-mysql" "php${PHPV}-curl" "php${PHPV}-gd" \
                         "php${PHPV}-mbstring" "php${PHPV}-xml" "php${PHPV}-zip" || true
else
    for v in 8.3 8.2 8.1 8.0 7.4; do
        if fetch_and_unpack php "php${v}-fpm" "php${v}-cli" "php${v}-common"; then
            PHPV="$v"; break
        fi
    done
fi

# ---------------------------------------------------------------------------
# nginx
# ---------------------------------------------------------------------------
if [ -x "$WORK/root/usr/sbin/nginx" ]; then
    D="$WORK/b-nginx"; mkdir -p "$D/libexec" "$D/lib" "$D/conf" "$D/bin"
    cp -f "$WORK/root/usr/sbin/nginx" "$D/libexec/nginx"
    collect_libs "$D/libexec" "$D/lib" "$D/libexec/nginx"
    make_wrapper "$D/bin/nginx" nginx
    [ -d "$WORK/root/etc/nginx" ] && cp -f "$WORK/root/etc/nginx/mime.types" "$D/conf/" 2>/dev/null || true
    [ -f "$WORK/root/etc/nginx/fastcgi_params" ] && cp -f "$WORK/root/etc/nginx/fastcgi_params" "$D/conf/" 2>/dev/null || true
    pack nginx "$D"
else
    echo "[WARN] 未取到 nginx 二进制，跳过"
fi

# ---------------------------------------------------------------------------
# php-fpm
# ---------------------------------------------------------------------------
PHP_FPM_SRC=""
for c in "$WORK/root"/usr/sbin/php-fpm*; do [ -x "$c" ] && { PHP_FPM_SRC="$c"; break; }; done
PHP_CLI_SRC=""
for c in "$WORK/root"/usr/bin/php*; do [ -x "$c" ] && { PHP_CLI_SRC="$c"; break; }; done
if [ -n "$PHP_FPM_SRC" ] && [ -n "$PHP_CLI_SRC" ]; then
    D="$WORK/b-php"; mkdir -p "$D/libexec" "$D/lib" "$D/bin" "$D/lib/php"
    cp -f "$PHP_FPM_SRC" "$D/libexec/php-fpm"
    cp -f "$PHP_CLI_SRC" "$D/libexec/php"
    collect_libs "$D/libexec" "$D/lib" "$D/libexec/php-fpm" "$D/libexec/php"
    # PHP 扩展 .so（系统默认扩展目录）
    for extdir in "$WORK/root"/usr/lib/php/*; do
        [ -d "$extdir" ] || continue
        cp -a "$extdir/." "$D/lib/php/" 2>/dev/null || true
    done
    make_wrapper "$D/bin/php-fpm" php-fpm
    make_wrapper "$D/bin/php" php
    pack php-fpm "$D"
else
    echo "[WARN] 未取到 php-fpm/php 二进制，跳过"
fi

# ---------------------------------------------------------------------------
# apache
# ---------------------------------------------------------------------------
if [ -x "$WORK/root/usr/sbin/apache2" ]; then
    D="$WORK/b-apache"; mkdir -p "$D/libexec" "$D/lib" "$D/bin" "$D/modules" "$D/conf"
    cp -f "$WORK/root/usr/sbin/apache2" "$D/libexec/httpd"
    collect_libs "$D/libexec" "$D/lib" "$D/libexec/httpd"
    cp -a "$WORK/root/usr/lib/apache2/modules/." "$D/modules/" 2>/dev/null || true
    [ -f "$WORK/root/etc/apache2/mime.types" ] && cp -f "$WORK/root/etc/apache2/mime.types" "$D/conf/" 2>/dev/null || true
    make_wrapper "$D/bin/httpd" httpd
    pack apache "$D"
else
    echo "[WARN] 未取到 apache2 二进制，跳过"
fi

# ---------------------------------------------------------------------------
# mysql
# ---------------------------------------------------------------------------
MYSQLD_SRC=""
for c in "$WORK/root"/usr/sbin/mysqld "$WORK/root"/usr/libexec/mysqld; do [ -x "$c" ] && { MYSQLD_SRC="$c"; break; }; done
if [ -n "$MYSQLD_SRC" ]; then
    D="$WORK/b-mysql"; mkdir -p "$D/libexec" "$D/lib" "$D/bin" "$D/share"
    cp -f "$MYSQLD_SRC" "$D/libexec/mysqld"
    collect_libs "$D/libexec" "$D/lib" "$D/libexec/mysqld"
    # 错误消息文件（缺少会导致 mysqld 启动失败）
    for sh in "$WORK/root"/usr/share/mysql*; do
        [ -d "$sh" ] && cp -a "$sh/." "$D/share/" 2>/dev/null || true
    done
    # 客户端（phpstudy db 需要）
    for cli in "$WORK/root"/usr/bin/mysql "$WORK/root"/usr/bin/mysqladmin; do
        [ -x "$cli" ] && cp -f "$cli" "$D/libexec/" 2>/dev/null || true
    done
    make_wrapper "$D/bin/mysqld" mysqld
    [ -f "$D/libexec/mysql" ] && make_wrapper "$D/bin/mysql" mysql || true
    pack mysql "$D"
else
    echo "[WARN] 未取到 mysqld 二进制，跳过"
fi

echo
echo "完成。离线组件目录: $OUT/components"
ls -lh "$OUT/components" 2>/dev/null || true
echo
echo "离线安装: sudo ./phpstudy-kylin-arm64-8.1.1.3.run --dir /opt/phpstudy --offline $OUT"
