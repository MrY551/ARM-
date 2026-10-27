#!/usr/bin/env bash
# Xiao Huang for Kylin ARM64 —— 构建脚本
# 产物:
#   dist/xiaohuang-kylin-arm64-0.0.0.1Beta.run   自解压安装器（推荐，麒麟 V10 直接运行）
#   dist/xiaohuang-kylin-arm64_0.0.0.1Beta_arm64.deb   Debian 系安装包（可选）
# 用法: ./build.sh [--no-deb]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/src"
DIST="$HERE/dist"
# 允许用环境变量覆盖（打图形安装器兼容包时用纯数字版本号）
VERSION="${VERSION:-0.0.0.1Beta}"
PKG="xiaohuang-kylin-arm64"
DO_DEB=1
[ "${1:-}" = "--no-deb" ] && DO_DEB=0

mkdir -p "$DIST"
# 不自动清空 dist：允许不同版本号并存（标准包 + 图形安装器兼容包）
# 需要清理时手动删，或 rm -rf dist

# ---------------------------------------------------------------------------
# 1. 校验源码完整性
# ---------------------------------------------------------------------------
need=(
    "$SRC/install.sh" "$SRC/uninstall.sh" "$SRC/bin/xiaohuang" "$SRC/lib/common.sh"
    "$SRC/templates/nginx/nginx.conf" "$SRC/templates/nginx/vhost.conf.tpl"
    "$SRC/templates/nginx/mime.types" "$SRC/templates/nginx/fastcgi_params"
    "$SRC/templates/apache/httpd.conf" "$SRC/templates/apache/vhost.conf.tpl"
    "$SRC/templates/php/php.ini" "$SRC/templates/php/php-fpm.conf"
    "$SRC/templates/mysql/my.cnf"
    "$SRC/www/index.html" "$SRC/www/error/_template.html"
    "$SRC/systemd/xiaohuang-nginx.service.in" "$SRC/systemd/xiaohuang-php.service.in"
    "$SRC/systemd/xiaohuang-apache.service.in" "$SRC/systemd/xiaohuang-mysql.service.in"
    "$SRC/systemd/xiaohuang-panel.service.in"
    "$SRC/lib/cmds.sh"
    "$SRC/panel/index.php" "$SRC/panel/assets/panel.css" "$SRC/panel/assets/panel.js"
    "$SRC/panel/assets/img/qr-wechat.png" "$SRC/panel/assets/img/qr-alipay.png"
    "$SRC/panel/assets/img/qr-contact.png"
    "$SRC/templates/nginx/vhost-ssl.conf.tpl" "$SRC/templates/apache/vhost-ssl.conf.tpl"
    "$SRC/templates/ftp/vsftpd.conf" "$SRC/systemd/xiaohuang-ftp.service.in"
)
for f in "${need[@]}"; do
    [ -f "$f" ] || { echo "[FAIL] 缺少文件: $f" >&2; exit 1; }
done
echo "[ OK ] 源码完整性检查通过（${#need[@]} 个文件）"

# ---------------------------------------------------------------------------
# 2. 语法检查
# ---------------------------------------------------------------------------
for s in "$SRC/install.sh" "$SRC/uninstall.sh" "$SRC/bin/xiaohuang" "$SRC/lib/common.sh" "$SRC/lib/cmds.sh"; do
    bash -n "$s" || { echo "[FAIL] 语法错误: $s" >&2; exit 1; }
done
echo "[ OK ] bash 语法检查通过"

# ---------------------------------------------------------------------------
# 3. 生成 payload
# ---------------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 组件内置：payload/components/*.tar.gz 存在就一起打进去
BUNDLE_DIR=""
for cand in "$HERE/payload" "$HERE/bundle"; do
    if [ -d "$cand/components" ] && [ -n "$(ls -A "$cand/components" 2>/dev/null)" ]; then
        BUNDLE_DIR="$cand"
        break
    fi
done

STAGE="$WORK/stage"
mkdir -p "$STAGE"
cp -a "$SRC"/. "$STAGE"/
if [ -n "$BUNDLE_DIR" ]; then
    mkdir -p "$STAGE/components"
    cp -a "$BUNDLE_DIR"/components/*.tar.gz "$STAGE/components/"
    echo "[ OK ] 内置组件: $(ls -1 "$STAGE/components" | tr '\n' ' ')"
    echo "        总大小: $(du -sh "$STAGE/components" | cut -f1)"
else
    echo "[INFO] 未找到 payload/components，构建为在线安装版（安装时从系统源装组件）"
fi

# 构建指纹：每个包唯一，写进面板/CLI，便于核对是不是官方出的那一份
BUILD_ID="$(date +%Y%m%d%H%M)-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
printf '%s\n' "$BUILD_ID" > "$STAGE/BUILD"
echo "[ OK ] BUILD_ID: $BUILD_ID"

# 手册 / 许可 / 构建指纹 一起打包
mkdir -p "$STAGE/docs"
cp -f "$HERE/LICENSE" "$STAGE/LICENSE" 2>/dev/null || echo "[WARN] 缺少 LICENSE"
[ -f "$SRC/docs/用户手册.md" ] && cp -f "$SRC/docs/用户手册.md" "$STAGE/docs/用户手册.md"
[ -f "$HERE/docs/常见问题.md" ] && cp -f "$HERE/docs/常见问题.md" "$STAGE/docs/常见问题.md"
[ -f "$HERE/dist/xh-diag.sh" ] && { mkdir -p "$STAGE/tools"; cp -f "$HERE/dist/xh-diag.sh" "$STAGE/tools/xh-diag.sh"; }

PAYLOAD="$WORK/payload.tar.gz"
# 统一权限；只打包运行所需的文件
tar -czf "$PAYLOAD" -C "$STAGE" \
    --owner=0 --group=0 \
    install.sh uninstall.sh lib bin templates www systemd panel \
    LICENSE docs tools BUILD \
    $( [ -d "$STAGE/components" ] && echo components )
SIZE="$(stat -c%s "$PAYLOAD")"
echo "[ OK ] payload: $SIZE 字节"

# ---------------------------------------------------------------------------
# 4. 生成 .run 自解压安装器
# ---------------------------------------------------------------------------
RUN="$DIST/${PKG}-${VERSION}.run"
cat > "$WORK/stub.sh" <<'STUB'
#!/bin/bash
# Xiao Huang for Kylin ARM64 —— 自解压安装器
# 运行: sudo ./xiaohuang-kylin-arm64-0.0.0.1Beta.run [--dir /opt/xiaohuang] [其他参数]
# 参数与 install.sh 一致，--help 查看全部选项
set -u

PAYLOAD_SIZE=@PAYLOAD_SIZE@
SELF="$0"

if [ ! -f "$SELF" ]; then
    echo "[FAIL] 找不到自身文件: $SELF" >&2
    exit 1
fi

FSIZE="$(stat -c%s "$SELF" 2>/dev/null || wc -c < "$SELF")"
if [ "$FSIZE" -le "$PAYLOAD_SIZE" ]; then
    echo "[FAIL] 安装包不完整（文件被截断）" >&2
    exit 1
fi
START=$(( FSIZE - PAYLOAD_SIZE + 1 ))

TMPDIR_BASE="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "$TMPDIR_BASE/xiaohuang-install.XXXXXX")" || {
    echo "[FAIL] 无法创建临时目录" >&2; exit 1; }
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

if ! tail -c +"$START" "$SELF" | tar -xzf - -C "$WORK"; then
    echo "[FAIL] 解包失败（安装包损坏）" >&2
    exit 1
fi

if [ ! -f "$WORK/install.sh" ]; then
    echo "[FAIL] 安装包内容异常：缺少 install.sh" >&2
    exit 1
fi

chmod +x "$WORK/install.sh" "$WORK/uninstall.sh" "$WORK/bin/xiaohuang" 2>/dev/null || true

# 包内自带 components 时自动走离线安装，无需联网
OFFLINE_ARG=""
if [ -d "$WORK/components" ]; then
    case " $* " in
        *" --offline "*) ;;
        *) OFFLINE_ARG="--offline $WORK" ;;
    esac
fi

bash "$WORK/install.sh" "$@" $OFFLINE_ARG
RC=$?
exit $RC
STUB

sed -i "s/@PAYLOAD_SIZE@/$SIZE/" "$WORK/stub.sh"
cat "$WORK/stub.sh" "$PAYLOAD" > "$RUN"
chmod 755 "$RUN"
echo "[ OK ] 生成: $RUN ($(stat -c%s "$RUN") 字节)"

# ---------------------------------------------------------------------------
# 5. 生成 .deb
# ---------------------------------------------------------------------------
if [ "$DO_DEB" = "1" ] && command -v dpkg-deb >/dev/null 2>&1; then
    ROOT="$WORK/debroot"
    mkdir -p "$ROOT/DEBIAN" \
             "$ROOT/usr/share/xiaohuang-installer" \
             "$ROOT/usr/bin" \
             "$ROOT/etc/xiaohuang"
    tar -xzf "$PAYLOAD" -C "$ROOT/usr/share/xiaohuang-installer"

    # 是否内置组件，决定 postinst 的 --offline 参数与 Depends
    if [ -d "$ROOT/usr/share/xiaohuang-installer/components" ]; then
        OFFLINE_CONF="OFFLINE_DIR=/usr/share/xiaohuang-installer"
        RECOMMENDS="Recommends: curl
"
    else
        OFFLINE_CONF="#（本包未内置组件，安装时从系统源装）"
        RECOMMENDS="Recommends: curl, nginx, php-fpm, mysql-server
"
    fi

    cat > "$ROOT/etc/xiaohuang/install.conf" <<CONF
# /etc/xiaohuang/install.conf —— .deb 安装时传给 install.sh 的参数
# 改完存盘后重装本包生效（本包未注册 debconf，dpkg-reconfigure 不会重读此文件）：
#   sudo dpkg -P xiaohuang-kylin-arm64
#   sudo dpkg -i xiaohuang-kylin-arm64_*.deb
INSTALL_DIR=/opt/xiaohuang
INSTALL_ARGS="--no-start"
${OFFLINE_CONF}
CONF

    cat > "$ROOT/DEBIAN/control" <<CONTROL
Package: xiaohuang-kylin-arm64
Version: ${VERSION}
Section: web
Priority: optional
Architecture: arm64
Maintainer: Xiao Huang Kylin Port <1924053793@qq.com>
Depends: bash (>= 4.4), tar
${RECOMMENDS}Installed-Size: $(du -sk "$ROOT/usr/share/xiaohuang-installer" | awk '{print $1}')
Description: Xiao Huang web server control panel for Kylin ARM64
 Nginx/Apache + PHP-FPM + MySQL 一体化环境，目录布局与 Windows 版 Xiao Huang 一致，
 提供 xiaohuang 控制台管理服务、端口、站点与数据库。
CONTROL

    cat > "$ROOT/DEBIAN/postinst" <<'POSTINST'
#!/bin/bash
set -e
CONF=/etc/xiaohuang/install.conf
[ -f "$CONF" ] && . "$CONF"
INSTALL_DIR="${INSTALL_DIR:-/opt/xiaohuang}"
INSTALL_ARGS="${INSTALL_ARGS:---no-start}"
OFFLINE_DIR="${OFFLINE_DIR:-}"
OFFLINE_ARG=""
if [ -n "$OFFLINE_DIR" ] && [ -d "$OFFLINE_DIR/components" ]; then
    OFFLINE_ARG="--offline $OFFLINE_DIR"
    echo "[xiaohuang] 使用内置组件: $OFFLINE_DIR/components"
fi
echo "[xiaohuang] 执行安装到 $INSTALL_DIR ..."
bash /usr/share/xiaohuang-installer/install.sh --dir "$INSTALL_DIR" $INSTALL_ARGS $OFFLINE_ARG || {
    echo "[xiaohuang] 安装失败，请手动执行: sudo bash /usr/share/xiaohuang-installer/install.sh --dir $INSTALL_DIR" >&2
    exit 1
}
exit 0
POSTINST

    cat > "$ROOT/DEBIAN/prerm" <<'PRERM'
#!/bin/bash
set -e
if [ -x /usr/local/bin/xiaohuang ]; then
    /usr/local/bin/xiaohuang stop >/dev/null 2>&1 || true
fi
if [ -f /opt/xiaohuang/uninstall.sh ]; then
    bash /opt/xiaohuang/uninstall.sh >/dev/null 2>&1 || true
fi
exit 0
PRERM

    cat > "$ROOT/DEBIAN/postrm" <<'POSTRM'
#!/bin/bash
set -e
if [ "$1" = "purge" ]; then
    rm -rf /opt/xiaohuang /etc/xiaohuang /usr/share/xiaohuang-installer
fi
exit 0
POSTRM

    chmod 755 "$ROOT/DEBIAN/postinst" "$ROOT/DEBIAN/prerm" "$ROOT/DEBIAN/postrm"
    dpkg-deb --build --root-owner-group "$ROOT" "$DIST/${PKG}_${VERSION}_arm64.deb" >/dev/null
    echo "[ OK ] 生成: $DIST/${PKG}_${VERSION}_arm64.deb"
else
    echo "[SKIP] 未找到 dpkg-deb，跳过 .deb 构建"
fi

echo
echo "构建完成："
ls -lh "$DIST"
