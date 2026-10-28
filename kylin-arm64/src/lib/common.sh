#!/usr/bin/env bash
# Xiao Huang for Kylin ARM64 —— 公共函数库
# 被 install.sh / xiaohuang / uninstall.sh / verify.sh source
# 兼容 bash 4.4+（银河麒麟 V10 自带 bash 4.4/5.0）

# ---------------------------------------------------------------------------
# 退出码约定（与 Windows 版安装器的两种拒绝场景一一对应）
# ---------------------------------------------------------------------------
E_OK=0
E_GENERIC=1        # 通用错误
E_BAD_PATH=2       # 安装路径含中文/空格  -> 说明第 1 条
E_NOT_CLEAN=3      # 安装路径下已有 V8   -> 说明第 2 条
E_ARCH=4           # 架构不支持（非 aarch64）
E_PERM=5           # 非 root
E_DEP=6            # 依赖缺失
E_START=7          # 服务启动失败

XIAOHUANG_VERSION="0.0.0.2Beta"
XIAOHUANG_BUILD="kylin-arm64-1"
MANIFEST_NAME="xiaohuang.ini"

# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[36m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_DIM=''; C_RST=''
fi

log_info()  { printf '%s[INFO]%s %s\n'  "$C_BLU" "$C_RST" "$*"; }
log_ok()    { printf '%s[ OK ]%s %s\n'  "$C_GRN" "$C_RST" "$*"; }
log_warn()  { printf '%s[WARN]%s %s\n'  "$C_YEL" "$C_RST" "$*" >&2; }
log_error() { printf '%s[FAIL]%s %s\n'  "$C_RED" "$C_RST" "$*" >&2; }
log_step()  { printf '\n%s==> %s%s\n' "$C_BLU" "$*" "$C_RST"; }
log_dim()   { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RST"; }

# die <退出码> <消息...>
die() {
    local code="$1"; shift
    log_error "$*"
    exit "$code"
}

# ---------------------------------------------------------------------------
# 环境校验
# ---------------------------------------------------------------------------
require_root() {
    if [ "$(id -u)" != "0" ]; then
        die "$E_PERM" "需要 root 权限执行（安装到系统目录并注册 systemd 服务）。请使用: sudo $0 ..."
    fi
}

# 架构：银河麒麟 arm64 => uname -m == aarch64
check_arch() {
    local m
    m="$(uname -m)"
    case "$m" in
        aarch64|arm64)
            log_ok "架构检查通过: $m"
            return 0
            ;;
        *)
            if [ "${XIAOHUANG_SKIP_ARCH_CHECK:-0}" = "1" ]; then
                log_warn "当前架构 $m 不是 aarch64，已按 XIAOHUANG_SKIP_ARCH_CHECK=1 跳过检查（仅用于流程测试）"
                return 0
            fi
            die "$E_ARCH" "架构不支持: $m。本安装包仅适配银河麒麟 ARM64（aarch64）。"
            ;;
    esac
}

# 发行版：kylin / ubuntu / debian / openeuler / anolis / centos
detect_distro() {
    DISTRO_ID="unknown"; DISTRO_VER=""; DISTRO_NAME="unknown"; PKG_FAMILY="unknown"
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_VER="${VERSION_ID:-}"
        DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"
    fi
    case "$DISTRO_ID" in
        kylin|neokylin|ubuntu|debian|deepin|uos) PKG_FAMILY="deb" ;;
        openEuler|openeuler|anolis|centos|rhel|fedora|rocky|almalinux) PKG_FAMILY="rpm" ;;
        *) PKG_FAMILY="unknown" ;;
    esac
    export DISTRO_ID DISTRO_VER DISTRO_NAME PKG_FAMILY
}

# ---------------------------------------------------------------------------
# 安装路径规则（压缩包内《安装路径不能包含中文或空格.txt》）
# ---------------------------------------------------------------------------

# 规则 1：路径只能是 ASCII 字母/数字/点/下划线/斜杠/加号/@/短横线
#         含中文、空格、括号、全角字符一律拒绝，并复刻 Windows 版报错文案
path_rule_error() {
    local p="$1"
    # 与 Windows 版一致：反斜杠展示为 \\，文案 "Can't change dir to '<path>'"
    local shown="${p//\\/\\\\}"
    printf '%s[FAIL]%s Can\x27t change dir to \x27%s\x27\n' "$C_RED" "$C_RST" "$shown" >&2
    printf '%s       安装路径不能包含中文或空格。\n' '' >&2
    printf '%s       请改用纯英文、无空格的路径，例如 /opt/xiaohuang%s\n' '' "$C_RST" >&2
}

# 判断字符串是否只含安全字符（不用 grep/管道，避免 pipefail 与 glob 字符类歧义）
str_is_safe_path() {
    local s="$1" i c
    [ -n "$s" ] || return 1
    local LC_ALL=C
    for (( i=0; i<${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [A-Za-z0-9._/+@-]) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

str_has_space() {
    local s="$1" i c
    local LC_ALL=C
    for (( i=0; i<${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            ' '|$'\t'|$'\n'|$'\r'|$'\v'|$'\f') return 0 ;;
        esac
    done
    return 1
}

validate_install_path() {
    local p="$1"
    INSTALL_DIR_NORM=""

    if [ -z "$p" ]; then
        path_rule_error "$p"
        exit "$E_BAD_PATH"
    fi

    # 绝对路径
    case "$p" in
        /*) ;;
        *)
            path_rule_error "$p"
            printf '       安装路径必须是绝对路径。\n' >&2
            exit "$E_BAD_PATH"
            ;;
    esac

    # 空格（单独判断，给出与说明一致的提示）
    if str_has_space "$p"; then
        path_rule_error "$p"
        exit "$E_BAD_PATH"
    fi

    # 中文/全角/括号等非白名单字符
    if ! str_is_safe_path "$p"; then
        path_rule_error "$p"
        printf '       路径只允许字母、数字、点、下划线、斜杠、加号、@ 和短横线。\n' >&2
        exit "$E_BAD_PATH"
    fi

    # 去掉结尾多余的 /
    while :; do
        case "$p" in
            */) [ "$p" = "/" ] && break; p="${p%/}" ;;
            *) break ;;
        esac
    done

    INSTALL_DIR_NORM="$p"
}

# 规则 2：安装路径必须是纯净的，不能有已安装的 V8
check_path_pure() {
    local p="$1"
    if [ -e "$p/$MANIFEST_NAME" ] || [ -d "$p/app/Extensions" ] || [ -d "$p/app/COM" ]; then
        log_error "检测到安装路径下已存在 Xiao Huang: $p"
        printf '%s       %s\n' '' "保证安装路径是纯净的，安装路径下不能有已安装的 V8 版本，若重新安装，请选择其它路径。" >&2
        exit "$E_NOT_CLEAN"
    fi
    if [ -d "$p" ] && [ -n "$(ls -A "$p" 2>/dev/null)" ]; then
        log_warn "目标目录非空（但未检测到 V8 安装记录）: $p"
        log_warn "安装器会保留已有文件，仅在冲突时覆盖 Xiao Huang 自身文件。"
    fi
}

# ---------------------------------------------------------------------------
# 包管理
# ---------------------------------------------------------------------------
pkg_install() {
    [ $# -gt 0 ] || return 0
    case "$PKG_FAMILY" in
        deb)
            log_info "安装系统组件: $*"
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" >/dev/null 2>&1
            ;;
        rpm)
            log_info "安装系统组件: $*"
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y "$@" >/dev/null 2>&1
            else
                yum install -y "$@" >/dev/null 2>&1
            fi
            ;;
        *)
            log_warn "未知包管理器，跳过自动安装: $*"
            return 1
            ;;
    esac
}

pkg_present() {
    case "$PKG_FAMILY" in
        deb)  dpkg -s "$1" >/dev/null 2>&1 ;;
        rpm)  rpm -q "$1" >/dev/null 2>&1 ;;
        *)    return 1 ;;
    esac
}

# 在候选列表中找第一个存在的可执行文件

# HTTP 状态码：curl 优先，其次 wget，最后用组件自带的 PHP
# 目标机没装 curl 也能用，不把 curl 当硬依赖
http_code() {
    local url="${1:-}" out=""
    [ -n "$url" ] || { printf '000'; return 0; }
    if command -v curl >/dev/null 2>&1; then
        out="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$url" 2>/dev/null)"
    elif command -v wget >/dev/null 2>&1; then
        out="$(wget -q -O /dev/null -S --timeout=3 "$url" 2>&1 | awk '/^  HTTP\//{c=$2} END{print c}')"
    elif [ -n "${PHP_CLI_BIN:-}" ] && [ -x "$PHP_CLI_BIN" ]; then
        out="$("$PHP_CLI_BIN" -r '
$u = $argv[1];
$ctx = stream_context_create(["http" => ["timeout" => 3, "ignore_errors" => true]]);
@file_get_contents($u, false, $ctx);
$c = "000";
foreach (($http_response_header ?? []) as $l) {
    if (preg_match("#^HTTP/\S+\s+(\d{3})#", $l, $m)) { $c = $m[1]; }
}
echo $c;' "$url" 2>/dev/null)"
    fi
    printf '%s' "${out:-000}"
}

first_bin() {
    local c
    for c in "$@"; do
        if [ -x "$c" ]; then printf '%s' "$c"; return 0; fi
    done
    return 1
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# 取二进制版本号（用于 Extensions 目录命名）
bin_version() {
    local bin="$1" kind="$2" v=""
    case "$kind" in
        nginx)
            v="$("$bin" -v 2>&1 | sed -n 's#.*nginx/\([0-9.]*\).*#\1#p')" ;;
        apache)
            v="$("$bin" -v 2>&1 | sed -n 's#.*Apache/\([0-9.]*\).*#\1#p')" ;;
        php)
            v="$("$bin" -v 2>&1 | sed -n 's#^PHP \([0-9.]*\).*#\1#p' | head -1)" ;;
        mysql)
            v="$("$bin" --version 2>&1 | sed -n 's#.*Ver \([0-9.]*\).*#\1#p' | head -1)"
            [ -n "$v" ] || v="$("$bin" --version 2>&1 | sed -n 's#.*mysql  *Ver \([0-9.]*\).*#\1#p' | head -1)"
            [ -n "$v" ] || v="$("$bin" --version 2>&1 | sed -n 's#.*mariadb.*\([0-9]\+\.[0-9]\+\.[0-9]\+\).*#\1#p' | head -1)"
            ;;
    esac
    printf '%s' "$v"
}

# ---------------------------------------------------------------------------
# 模板渲染：render <src> <dst> [@KEY@ value]...
# 使用 bash 内建替换，避免 sed 对路径中 / & 的转义问题
# ---------------------------------------------------------------------------
render() {
    local src="$1" dst="$2"; shift 2
    [ -f "$src" ] || die "$E_GENERIC" "模板不存在: $src"
    local content k v
    content="$(cat "$src")"
    while [ $# -ge 2 ]; do
        k="$1"; v="$2"; shift 2
        content="${content//"$k"/"$v"}"
    done
    mkdir -p "$(dirname "$dst")"
    printf '%s\n' "$content" > "$dst"
}

# ---------------------------------------------------------------------------
# 清单读写：InstallDir/xiaohuang.ini
# ---------------------------------------------------------------------------
manifest_get() {
    local dir="$1" key="$2"
    [ -f "$dir/$MANIFEST_NAME" ] || return 1
    sed -n "s/^${key}=\(.*\)$/\1/p" "$dir/$MANIFEST_NAME" | head -1
}

manifest_set() {
    local dir="$1" key="$2" val="$3"
    local f="$dir/$MANIFEST_NAME"
    mkdir -p "$dir"
    [ -f "$f" ] || : > "$f"
    if grep -q "^${key}=" "$f" 2>/dev/null; then
        local tmp="$f.tmp.$$"
        sed "s|^${key}=.*|${key}=${val}|" "$f" > "$tmp" && mv "$tmp" "$f"
    else
        printf '%s=%s\n' "$key" "$val" >> "$f"
    fi
}

# ---------------------------------------------------------------------------
# systemd 抽象；无 systemd 时回退到 pid 文件直管
# ---------------------------------------------------------------------------
has_systemd() {
    have_cmd systemctl && [ -d /run/systemd/system ]
}

# 读清单里的 supervisor（systemd|pidfile）
supervisor_mode() {
    local dir="$1" m
    m="$(manifest_get "$dir" SUPERVISOR 2>/dev/null || true)"
    [ -n "$m" ] || m="pidfile"
    printf '%s' "$m"
}

# ---------------------------------------------------------------------------
# 端口
# ---------------------------------------------------------------------------
port_in_use() {
    local port="$1" out="" l
    if have_cmd ss; then
        out="$(ss -lntu 2>/dev/null | awk '{print $5}' || true)"
    elif have_cmd netstat; then
        out="$(netstat -lntu 2>/dev/null | awk '{print $4}' || true)"
    else
        return 1
    fi
    while IFS= read -r l; do
        case "$l" in
            *":$port"|*".$port") return 0 ;;
        esac
    done <<< "$out"
    return 1
}

# 找一个空闲端口，从 start 开始向上探测
pick_free_port() {
    local p="$1" max=$(( $1 + 100 ))
    while [ "$p" -le "$max" ]; do
        port_in_use "$p" || { printf '%s' "$p"; return 0; }
        p=$(( p + 1 ))
    done
    return 1
}

# ---------------------------------------------------------------------------
# 二进制/服务名映射（不同发行版 php-fpm、apache 名字不同）
# ---------------------------------------------------------------------------
find_php_fpm() {
    local c
    for c in /usr/sbin/php-fpm /usr/sbin/php-fpm8.3 /usr/sbin/php-fpm8.2 \
             /usr/sbin/php-fpm8.1 /usr/sbin/php-fpm8.0 /usr/sbin/php-fpm7.4 \
             /usr/sbin/php-fpm7.3 /usr/local/sbin/php-fpm /usr/bin/php-fpm; do
        [ -x "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

find_php_cli() {
    local c
    for c in /usr/bin/php /usr/local/bin/php /usr/bin/php8.3 /usr/bin/php8.2 \
             /usr/bin/php8.1 /usr/bin/php8.0 /usr/bin/php7.4; do
        [ -x "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

find_nginx() {
    first_bin /usr/sbin/nginx /usr/local/nginx/sbin/nginx /usr/local/sbin/nginx
}

find_apache() {
    first_bin /usr/sbin/apache2 /usr/sbin/httpd /usr/local/apache2/bin/httpd /usr/local/httpd/bin/httpd
}

find_mysqld() {
    first_bin /usr/sbin/mysqld /usr/libexec/mysqld /usr/sbin/mariadbd /usr/local/mysql/bin/mysqld
}

# Apache 模块目录
apache_module_dir() {
    local bin="$1" d
    for d in /usr/lib/apache2/modules /usr/lib64/httpd/modules /usr/lib/httpd/modules \
             /usr/local/apache2/modules; do
        [ -d "$d" ] && { printf '%s' "$d"; return 0; }
    done
    # 从二进制推导：dirname/modules 或 ../lib/apache2/modules
    d="$(dirname "$bin")/modules"
    [ -d "$d" ] && { printf '%s' "$d"; return 0; }
    printf '%s' "/usr/lib/apache2/modules"
}
