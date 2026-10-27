#!/usr/bin/env bash
# Xiao Huang for Kylin ARM64 —— 从 arm64 sysroot 生成内置组件包
#
# 输入: 一个解包好的 aarch64 sysroot（Debian bullseye arm64 的 deb 全部 dpkg-deb -x 展开）
# 输出: <out>/components/{nginx,php-fpm,apache,mysql}.tar.gz
#       每个包结构:
#         bin/<name>      sh 包装：用自带的 ld-linux 起 libexec/<name>（不依赖目标机 glibc）
#         libexec/<name>  真实 arm64 二进制
#         lib/*.so*       闭包内的全部共享库 + ld-linux-aarch64.so.1 + libnss_*
#         modules/ conf/ share/  按组件需要
#
# 用法: ./tools/gen-components.sh --sysroot /root/sysroot --out payload
set -uo pipefail

SYSROOT=""
OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --sysroot) SYSROOT="${2:-}"; shift 2 ;;
        --out)     OUT="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

[ -n "$SYSROOT" ] && [ -d "$SYSROOT" ] || { echo "[FAIL] --sysroot 无效" >&2; exit 1; }
[ -n "$OUT" ] || { echo "[FAIL] 需要 --out" >&2; exit 1; }
command -v readelf >/dev/null || { echo "[FAIL] 需要 readelf（binutils）" >&2; exit 1; }

mkdir -p "$OUT/components"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

LIBC_DIRS="lib/aarch64-linux-gnu usr/lib/aarch64-linux-gnu lib usr/lib"
MISSING=""

# 依赖闭包：输出相对 sysroot 的路径列表（含入口）
deps_closure() {
    local entry="$1"; shift
    local todo=() f name cand seen=" "
    todo=("$entry")
    [ $# -gt 0 ] && todo+=("$@")
    echo "$entry"
    seen=" $entry "
    while [ ${#todo[@]} -gt 0 ]; do
        f="${todo[0]}"
        todo=("${todo[@]:1}")
        [ -f "$SYSROOT/$f" ] || continue
        while read -r name; do
            [ -n "$name" ] || continue
            case "$name" in
                linux-vdso.so.1) continue ;;
            esac
            cand=""
            for d in $LIBC_DIRS; do
                if [ -e "$SYSROOT/$d/$name" ]; then cand="$d/$name"; break; fi
            done
            if [ -z "$cand" ]; then
                MISSING="$MISSING $name"
                continue
            fi
            case "$seen" in *" $cand "*) continue ;; esac
            seen="$seen $cand "
            echo "$cand"
            todo+=("$cand")
        done < <(readelf -d "$SYSROOT/$f" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
    done
}

# 复制库到组件 lib/（保持 soname 文件名，内容为真实文件）
copy_libs() {
    local dst="$1"; shift
    local rel base
    for rel in "$@"; do
        [ -f "$SYSROOT/$rel" ] || continue
        base="$(basename "$rel")"
        [ -f "$dst/$base" ] && continue
        cp -Lf "$SYSROOT/$rel" "$dst/$base"
    done
}

# 基础运行库：ld-linux + NSS（用自带 loader 时必须一起给）
copy_base_runtime() {
    local dst="$1"
    mkdir -p "$dst/lib"
    cp -Lf "$SYSROOT/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1" "$dst/lib/" 2>/dev/null || \
        cp -Lf "$SYSROOT/lib/ld-linux-aarch64.so.1" "$dst/lib/" 2>/dev/null || true
    cp -Lf "$SYSROOT"/lib/aarch64-linux-gnu/libnss_*.so* "$dst/lib/" 2>/dev/null || true
    cp -Lf "$SYSROOT"/lib/aarch64-linux-gnu/libresolv.so.2 "$dst/lib/" 2>/dev/null || true
}

# 启动包装：优先用组件自带的 ld-linux + 库目录，彻底不依赖目标机 glibc
write_wrapper() {
    local target="$1" rel="${2:-libexec}"
    local name; name="$(basename "$target")"
    mkdir -p "$(dirname "$target")"
    cat > "$target" <<WRAP
#!/bin/sh
# Xiao Huang 内置组件启动器：用组件自带的 aarch64 loader 与共享库
SELF=\$(readlink -f "\$0" 2>/dev/null || echo "\$0")
SELF_DIR=\$(cd "\$(dirname "\$SELF")" && pwd)
ROOT=\$(cd "\$SELF_DIR/.." && pwd)
LD="\$ROOT/lib/ld-linux-aarch64.so.1"
BIN="\$ROOT/$rel/$name.bin"
if [ -x "\$LD" ] && [ -x "\$BIN" ]; then
    exec "\$LD" --library-path "\$ROOT/lib" "\$BIN" "\$@"
fi
if [ -d "\$ROOT/lib" ]; then
    LD_LIBRARY_PATH="\$ROOT/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
    export LD_LIBRARY_PATH
fi
exec "\$BIN" "\$@"
WRAP
    chmod 755 "$target"
    # 组件内部脚本可能直接调用 libexec/<name>，放一个软链回到 wrapper
    if [ "$rel" = "libexec" ]; then
        ln -sfn "../bin/$name" "$(dirname "$target")/../libexec/$name"
    fi
}

pack() {
    local name="$1" dir="$2"
    tar -czf "$OUT/components/$name.tar.gz" -C "$dir" .
    printf '[ OK ] %-22s %s\n' "$name.tar.gz" "$(du -h "$OUT/components/$name.tar.gz" | cut -f1)"
}

echo "sysroot: $SYSROOT"
echo

# ---------------------------------------------------------------------------
# Nginx
# ---------------------------------------------------------------------------
if [ -x "$SYSROOT/usr/sbin/nginx" ]; then
    D="$WORK/nginx"; mkdir -p "$D/libexec" "$D/lib" "$D/bin" "$D/conf"
    cp -f "$SYSROOT/usr/sbin/nginx" "$D/libexec/nginx.bin"
    copy_base_runtime "$D"
    copy_libs "$D/lib" $(deps_closure usr/sbin/nginx | sort -u)
    [ -f "$SYSROOT/etc/nginx/mime.types" ] && cp -f "$SYSROOT/etc/nginx/mime.types" "$D/conf/"
    [ -f "$SYSROOT/etc/nginx/fastcgi_params" ] && cp -f "$SYSROOT/etc/nginx/fastcgi_params" "$D/conf/"
    write_wrapper "$D/bin/nginx"
    pack nginx "$D"
else
    echo "[WARN] sysroot 中没有 usr/sbin/nginx，跳过"
fi

# ---------------------------------------------------------------------------
# PHP-FPM (+ CLI + 扩展)
# ---------------------------------------------------------------------------
PHP_FPM=""
for c in usr/sbin/php-fpm7.4 usr/sbin/php-fpm8.3 usr/sbin/php-fpm8.2 usr/sbin/php-fpm8.1 usr/sbin/php-fpm8.0 usr/sbin/php-fpm; do
    [ -x "$SYSROOT/$c" ] && { PHP_FPM="$c"; break; }
done
PHP_CLI=""
for c in usr/bin/php7.4 usr/bin/php8.3 usr/bin/php8.2 usr/bin/php8.1 usr/bin/php8.0 usr/bin/php; do
    [ -x "$SYSROOT/$c" ] && { PHP_CLI="$c"; break; }
done
if [ -n "$PHP_FPM" ] && [ -n "$PHP_CLI" ]; then
    D="$WORK/php"; mkdir -p "$D/libexec" "$D/lib" "$D/bin"
    cp -f "$SYSROOT/$PHP_FPM" "$D/libexec/php-fpm.bin"
    cp -f "$SYSROOT/$PHP_CLI" "$D/libexec/php.bin"

    # 扩展目录（20190902 之类）
    EXT_SRC=""
    for e in "$SYSROOT"/usr/lib/php/2*; do
        [ -d "$e" ] && { EXT_SRC="$e"; break; }
    done
    EXT_TARGET=""
    if [ -n "$EXT_SRC" ]; then
        EXT_TARGET="$(basename "$EXT_SRC")"
        mkdir -p "$D/lib/php/$EXT_TARGET"
        cp -Lf "$EXT_SRC"/*.so "$D/lib/php/$EXT_TARGET/" 2>/dev/null || true
    fi

    copy_base_runtime "$D"
    deps=$(deps_closure "$PHP_FPM" "$PHP_CLI" | sort -u)
    if [ -n "$EXT_SRC" ]; then
        for so in "$EXT_SRC"/*.so; do
            [ -f "$so" ] || continue
            rel="${so#$SYSROOT/}"
            deps="$deps
$(deps_closure "$rel" | sort -u)"
        done
    fi
    copy_libs "$D/lib" $(printf '%s\n' "$deps" | sort -u)
    # 把扩展 lib 目录也补进 lib/（扩展自己依赖的库已在 lib/）
    write_wrapper "$D/bin/php-fpm"
    write_wrapper "$D/bin/php"
    # 记录扩展目录名，供安装器写 php.ini
    [ -n "$EXT_TARGET" ] && printf '%s\n' "$EXT_TARGET" > "$D/EXT_DIR_NAME"
    pack php-fpm "$D"
else
    echo "[WARN] sysroot 中没有 php-fpm/php，跳过"
fi

# ---------------------------------------------------------------------------
# Apache (+ modules)
# ---------------------------------------------------------------------------
if [ -x "$SYSROOT/usr/sbin/apache2" ]; then
    D="$WORK/apache"; mkdir -p "$D/libexec" "$D/lib" "$D/bin" "$D/modules" "$D/conf"
    cp -f "$SYSROOT/usr/sbin/apache2" "$D/libexec/httpd.bin"
    if [ -d "$SYSROOT/usr/lib/apache2/modules" ]; then
        cp -Lf "$SYSROOT"/usr/lib/apache2/modules/*.so "$D/modules/" 2>/dev/null || true
    fi
    copy_base_runtime "$D"
    deps=$(deps_closure usr/sbin/apache2 | sort -u)
    for so in "$D/modules"/*.so; do
        [ -f "$so" ] || continue
        rel="usr/lib/apache2/modules/$(basename "$so")"
        deps="$deps
$(deps_closure "$rel" | sort -u)"
    done
    copy_libs "$D/lib" $(printf '%s\n' "$deps" | sort -u)
    [ -f "$SYSROOT/etc/apache2/mime.types" ] && cp -f "$SYSROOT/etc/apache2/mime.types" "$D/conf/"
    write_wrapper "$D/bin/httpd"
    pack apache "$D"
else
    echo "[WARN] sysroot 中没有 apache2，跳过"
fi

# ---------------------------------------------------------------------------
# MariaDB / MySQL
# ---------------------------------------------------------------------------
MYSQLD=""
for c in usr/sbin/mariadbd usr/sbin/mysqld usr/libexec/mysqld; do
    [ -x "$SYSROOT/$c" ] && { MYSQLD="$c"; break; }
done
if [ -n "$MYSQLD" ]; then
    D="$WORK/mysql"; mkdir -p "$D/libexec" "$D/lib" "$D/bin" "$D/share"
    cp -f "$SYSROOT/$MYSQLD" "$D/libexec/mysqld.bin"
    # 客户端：MariaDB 的 mysql 是 mariadb 的软链，两者都带
    for c in usr/bin/mariadb usr/bin/mysql usr/bin/mariadb-admin usr/bin/mysqladmin; do
        if [ -f "$SYSROOT/$c" ]; then
            cp -Lf "$SYSROOT/$c" "$D/libexec/$(basename "$c").bin"
        fi
    done
    [ -f "$D/libexec/mariadb.bin" ] && ln -sfn mariadb.bin "$D/libexec/mysql.bin"
    # 初始化脚本（MariaDB 是 shell 脚本，直接放 bin/；没有 --initialize-insecure）
    for c in usr/bin/mariadb-install-db usr/bin/mysql_install_db; do
        if [ -f "$SYSROOT/$c" ]; then
            cp -Lf "$SYSROOT/$c" "$D/bin/$(basename "$c")"
            chmod 755 "$D/bin/$(basename "$c")"
        fi
    done
    # 错误消息与字符集
    if [ -d "$SYSROOT/usr/share/mysql" ]; then
        cp -a "$SYSROOT/usr/share/mysql/." "$D/share/" 2>/dev/null || true
    fi
    copy_base_runtime "$D"
    # 依赖闭包：服务端 + 全部客户端/工具（都按 sysroot 原始路径收集）
    deps=$(deps_closure "$MYSQLD" | sort -u)
    for c in usr/bin/mariadb usr/bin/mysql usr/bin/mariadb-admin usr/bin/mysqladmin \
             usr/bin/resolveip usr/bin/my_print_defaults; do
        [ -f "$SYSROOT/$c" ] || continue
        deps="$deps
$(deps_closure "$c" | sort -u)"
    done
    copy_libs "$D/lib" $(printf '%s\n' "$deps" | sort -u)
    # my_print_defaults：mariadb-install-db 依赖它定位配置
    if [ -f "$SYSROOT/usr/bin/my_print_defaults" ]; then
        cp -f "$SYSROOT/usr/bin/my_print_defaults" "$D/libexec/my_print_defaults.bin"
        write_wrapper "$D/bin/my_print_defaults"
    fi
    # resolveip：mariadb-install-db 初始化时必需
    if [ -f "$SYSROOT/usr/bin/resolveip" ]; then
        cp -f "$SYSROOT/usr/bin/resolveip" "$D/libexec/resolveip.bin"
        write_wrapper "$D/bin/resolveip"
    fi
    write_wrapper "$D/bin/mysqld"
    [ -f "$D/libexec/mariadb.bin" ] && write_wrapper "$D/bin/mysql"
    [ -f "$D/libexec/mariadb.bin" ] && write_wrapper "$D/bin/mariadb"
    pack mysql "$D"
else
    echo "[WARN] sysroot 中没有 mysqld/mariadbd，跳过"
fi


# ---------------------------------------------------------------------------
# FTP (vsftpd，等价 FileZilla Server 的本机 FTP 服务)
# ---------------------------------------------------------------------------
if [ -x "$SYSROOT/usr/sbin/vsftpd" ]; then
    D="$WORK/ftp"; mkdir -p "$D/libexec" "$D/lib" "$D/bin" "$D/conf" "$D/empty"
    cp -f "$SYSROOT/usr/sbin/vsftpd" "$D/libexec/vsftpd.bin"
    # PAM 配置随组件走，安装时写到 /etc/pam.d/xiaohuang-vsftpd
    if [ -f "$SYSROOT/etc/pam.d/vsftpd" ]; then
        cp -f "$SYSROOT/etc/pam.d/vsftpd" "$D/conf/pam.vsftpd"
    else
        printf 'auth     required pam_unix.so\naccount  required pam_unix.so\nsession  required pam_unix.so\n' > "$D/conf/pam.vsftpd"
    fi
    copy_base_runtime "$D"
    deps=$(deps_closure usr/sbin/vsftpd | sort -u)

    # PAM 模块随组件走：不依赖目标机 libpam-modules 的安装位置
    mkdir -p "$D/lib/security"
    PAMSEC=""
    for d in lib/aarch64-linux-gnu/security usr/lib/aarch64-linux-gnu/security; do
        if [ -d "$SYSROOT/$d" ]; then PAMSEC="$d"; break; fi
    done
    if [ -n "$PAMSEC" ]; then
        for m in pam_unix pam_deny pam_permit; do
            if [ -f "$SYSROOT/$PAMSEC/$m.so" ]; then
                cp -f "$SYSROOT/$PAMSEC/$m.so" "$D/lib/security/"
            fi
        done
        deps="$deps
$(deps_closure "$PAMSEC/pam_unix.so" | sort -u)"
    fi

    copy_libs "$D/lib" $(printf '%s
' "$deps" | sort -u)
    write_wrapper "$D/bin/vsftpd"
    pack ftp "$D"
else
    echo "[WARN] sysroot 中没有 usr/sbin/vsftpd，跳过 FTP 组件"
fi

echo
if [ -n "$MISSING" ]; then
    echo "[WARN] 未在 sysroot 中找到的 soname:"
    printf '%s\n' $MISSING | sort -u | sed 's/^/       /'
fi
echo "产物: $OUT/components"
ls -lh "$OUT/components"
