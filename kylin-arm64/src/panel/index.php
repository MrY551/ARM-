<?php
/**
 * Xiao Huang for Kylin ARM64 —— Web 管理面板
 *
 * 运行方式：由 systemd 以 root 启动 php -S 127.0.0.1:<PANEL_PORT> 指向本目录，
 * nginx 把 /panel/ 反代到这里。面板本身只做 UI 与参数校验，
 * 所有实际动作通过 <InstallDir>/bin/xiaohuang 执行，保证只有一套操作逻辑。
 *
 * 安全模型：
 *  - 仅监听 127.0.0.1，nginx 层再加 allow 127.0.0.1
 *  - 会话登录 + CSRF token；密码哈希存 <InstallDir>/xiaohuang.ini 的 PANEL_PASS_HASH
 *  - 所有外部输入走白名单校验，命令行参数一律 escapeshellarg
 */
declare(strict_types=1);

define('BASE', dirname(__DIR__, 2));                 // <InstallDir>
define('CLI', BASE . '/bin/xiaohuang');
define('MANIFEST', BASE . '/xiaohuang.ini');
define('DATA', __DIR__ . '/data');
define('VERSION', '0.0.0.1Beta');
// 面板位于 <INSTALL_DIR>/app/panel，往上两级就是安装根
define('ROOT_DIR', dirname(dirname(__DIR__)));

if (!is_dir(DATA)) {
    @mkdir(DATA, 0700, true);
}
session_save_path(DATA);
session_name('XIAOHUANG_PANEL');
session_start();

header('X-Frame-Options: SAMEORIGIN');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: same-origin');

/* ------------------------------------------------------------------ 基础 */
function mf(): array
{
    static $c = null;
    if ($c !== null) return $c;
    $c = [];
    if (is_readable(MANIFEST)) {
        foreach (file(MANIFEST, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $l) {
            if ($l === '' || $l[0] === '#' || strpos($l, '=') === false) continue;
            [$k, $v] = explode('=', $l, 2);
            $c[trim($k)] = trim($v);
        }
    }
    return $c;
}

function mf_set(string $k, string $v): void
{
    $all = mf();
    $all[$k] = $v;
    $out = "# Xiao Huang 安装清单 —— 由安装器/面板维护\n";
    foreach ($all as $key => $val) {
        $out .= $key . '=' . $val . "\n";
    }
    @file_put_contents(MANIFEST, $out, LOCK_EX);
    @chmod(MANIFEST, 0600);
}

function jout($data, int $code = 200): void
{
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    // 日志/文件名里可能有非法 UTF-8 字节，不加 SUBSTITUTE 会让 json_encode 返回 false，
    // 前端拿到空响应就报 "Unexpected end of JSON input"
    $flags = JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES
           | JSON_INVALID_UTF8_SUBSTITUTE | JSON_PARTIAL_OUTPUT_ON_ERROR;
    $body = json_encode($data, $flags);
    if ($body === false) {
        $body = json_encode(['ok' => false, 'error' => '响应编码失败: ' . json_last_error_msg()],
                            JSON_UNESCAPED_UNICODE);
    }
    echo $body;
    exit;
}

/** 把任意字节串压成合法 UTF-8（日志用） */
function clean_utf8(string $s): string
{
    if ($s === '') return '';
    if (preg_match('//u', $s) === 1) return $s;          // 本来就是合法 UTF-8
    $out = @iconv('UTF-8', 'UTF-8//IGNORE', $s);          // 丢掉坏字节
    if ($out === false || $out === '') {
        $out = preg_replace('/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/', '', $s) ?? '';
        $out = mb_convert_encoding($out, 'UTF-8', 'UTF-8');
    }
    return $out;
}

function fail(string $msg, int $code = 400): void
{
    jout(['ok' => false, 'error' => $msg], $code);
}

/** 执行 xiaohuang，返回 [code, stdout+stderr] */
function cli(string $args): array
{
    $out = [];
    $rc = 0;
    exec(CLI . ' ' . $args . ' 2>&1', $out, $rc);
    return [$rc, implode("\n", $out)];
}

function csrf(): string
{
    if (empty($_SESSION['csrf'])) {
        $_SESSION['csrf'] = bin2hex(random_bytes(16));
    }
    return $_SESSION['csrf'];
}

function require_csrf(): void
{
    $t = $_SERVER['HTTP_X_CSRF'] ?? ($_POST['csrf'] ?? '');
    if (!is_string($t) || !hash_equals($_SESSION['csrf'] ?? '', $t)) {
        fail('CSRF 校验失败，请刷新页面', 419);
    }
}

function logged_in(): bool
{
    return !empty($_SESSION['uid']);
}

/* --------------------------------------------------------------- 认证 */
$action = $_GET['api'] ?? '';

if ($action === 'login') {
    $pass = (string)($_POST['pass'] ?? '');
    $buildId = (string)(mf()['BUILD_ID'] ?? '');
$hash = (string)(mf()['PANEL_PASS_HASH'] ?? '');
    if ($hash === '') fail('面板密码未初始化，请执行 xiaohuang panel passwd <密码>');
    if (!hash_equals($hash, md5($pass))) {
        usleep(300000);
        fail('密码错误', 401);
    }
    session_regenerate_id(true);
    $_SESSION['uid'] = 'root';
    $_SESSION['csrf'] = bin2hex(random_bytes(16));
    jout(['ok' => true, 'csrf' => $_SESSION['csrf']]);
}

if ($action === 'logout') {
    $_SESSION = [];
    session_destroy();
    jout(['ok' => true]);
}

if ($action !== '' && !logged_in()) {
    fail('未登录', 401);
}

/* ----------------------------------------------------------- 只读接口 */
function svc_state(): array
{
    [$rc, $out] = cli('status --json');
    $j = json_decode($out, true);
    return is_array($j) ? $j : ['error' => trim($out)];
}

if ($action === 'state') {
    $j = svc_state();
    $j['components'] = json_decode((string)cli('version list')[1], true) ?: [];
    $j['sites'] = json_decode((string)cli('site list --json')[1], true) ?: [];
    $j['panel'] = ['url' => (string)cli('panel url')[1], 'csrf' => csrf()];
    jout($j);
}

if ($action === 'sites') {
    jout(json_decode((string)cli('site list --json')[1], true) ?: []);
}

if ($action === 'dbs') {
    [$rc, $out] = cli('db list');
    jout(json_decode($out, true) ?: []);
}

if ($action === 'exts') {
    jout(json_decode((string)cli('ext list')[1], true) ?: []);
}

if ($action === 'modules') {
    jout(json_decode((string)cli('module list')[1], true) ?: []);
}

if ($action === 'ports') {
    jout(json_decode((string)cli('ports')[1], true) ?: []);
}

if ($action === 'autostart') {
    jout(json_decode((string)cli('autostart status --json')[1], true) ?: []);
}

if ($action === 'ftpusers') {
    jout(json_decode((string)cli('ftp list')[1], true) ?: []);
}

if ($action === 'versions') {
    jout(json_decode((string)cli('version list')[1], true) ?: []);
}

if ($action === 'log') {
    $svc = (string)($_GET['svc'] ?? 'nginx');
    $allowed = ['nginx', 'access', 'php', 'apache', 'mysql', 'ftp', 'panel'];
    if (!in_array($svc, $allowed, true)) fail('未知日志类型: ' . $svc);
    [$rc, $out] = cli('log ' . escapeshellarg($svc));
    $text = clean_utf8((string)$out);
    if ($text === '' || $rc !== 0) {
        $text = $text !== '' ? $text : '（该日志还没有内容，或者服务还没启动过）';
    }
    jout(['ok' => true, 'svc' => $svc, 'text' => $text, 'rc' => $rc]);
}

/* 日志文件清单：让面板知道每个服务有哪些日志、多大、在哪 */
if ($action === 'logfiles') {
    $R = ROOT_DIR;
    $patterns = [
        'nginx'  => [$R.'/logs/nginx-error.log', $R.'/logs/nginx-access-*.log',
                     $R.'/app/Extensions/Nginx*/logs/error.log'],
        'php'    => [$R.'/logs/php-fpm*.log', $R.'/app/Extensions/php/*/log/*.log'],
        'apache' => [$R.'/app/Extensions/Apache*/logs/*_log'],
        'mysql'  => [$R.'/app/Extensions/MySQL*/log/*.log', $R.'/app/Extensions/MySQL*/log/*.err'],
        'ftp'    => [$R.'/app/Extensions/FTP*/logs/*'],
        'panel'  => [],
    ];
    $rows = [];
    foreach ($patterns as $svc => $globs) {
        $found = [];
        foreach ($globs as $g) {
            foreach (glob($g) ?: [] as $f) {
                if (is_file($f)) {
                    $found[] = ['file' => clean_utf8(basename($f)),
                                'path' => clean_utf8($f),
                                'size' => filesize($f)];
                }
            }
        }
        $rows[] = ['svc' => $svc, 'files' => $found];
    }
    jout($rows);
}

/* 目录浏览：站点目录选择用 */
if ($action === 'browse') {
    $p = trim((string)($_GET['path'] ?? ''));
    $www = ROOT_DIR . '/app/WWW';
    if ($p === '') $p = $www;
    if (strpos($p, "\0") !== false) fail('路径非法');

    // 规范化：去掉尾部斜杠、折叠 ../..
    $p = rtrim($p, '/') ?: '/';
    $real = realpath($p);
    if ($real === false) fail('目录不存在: ' . $p);
    if (!is_dir($real)) fail('不是目录: ' . $real);
    foreach (['/proc', '/sys', '/dev', '/run'] as $bad) {
        if ($real === $bad || strpos($real, $bad . '/') === 0) fail('这个目录不给看: ' . $real);
    }
    if (!is_readable($real)) fail('没有读取权限: ' . $real);

    $dirs = [];
    $entries = @scandir($real) ?: [];
    foreach ($entries as $n) {
        if ($n === '.' || $n === '..') continue;
        $full = $real . '/' . $n;
        if (@is_dir($full)) {
            $dirs[] = ['name' => clean_utf8($n), 'path' => clean_utf8($full)];
        }
    }
    usort($dirs, function ($a, $b) { return strcasecmp($a['name'], $b['name']); });

    $fileCount = 0;
    foreach ($entries as $n) {
        if ($n !== '.' && $n !== '..' && @is_file($real . '/' . $n)) $fileCount++;
    }
    $parent = dirname($real);
    if ($parent === $real) $parent = '';

    jout([
        'ok'       => true,
        'path'     => clean_utf8($real),
        'parent'   => clean_utf8($parent),
        'www'      => clean_utf8($www),
        'writable' => is_writable($real),
        'dirs'     => $dirs,
        'files'    => $fileCount,
    ]);
}

/* ----------------------------------------------------------- 写操作 */
if ($action === 'action') {
    if ($_SERVER['REQUEST_METHOD'] !== 'POST') fail('需要 POST', 405);
    require_csrf();

    $op = (string)($_POST['op'] ?? '');
    $arg = $_POST['arg'] ?? [];
    if (!is_array($arg)) $arg = [];

    $safe = function ($v): string {
        $v = (string)$v;
        if (preg_match('/[\x00-\x1f]/', $v)) fail('参数含控制字符');
        return $v;
    };

    switch ($op) {
        /* 服务 */
        case 'svc.start':
        case 'svc.stop':
        case 'svc.restart':
            $t = $safe($arg['target'] ?? 'all');
            if (!in_array($t, ['all', 'nginx', 'apache', 'php', 'mysql'], true)) fail('目标不合法');
            [$rc, $out] = cli(substr($op, 4) . ' ' . escapeshellarg($t));
            jout(['ok' => $rc === 0, 'out' => $out]);

        case 'svc.switch':
            $t = $safe($arg['target'] ?? '');
            if (!in_array($t, ['nginx', 'apache'], true)) fail('目标不合法');
            [$rc, $out] = cli('switch ' . escapeshellarg($t));
            jout(['ok' => $rc === 0, 'out' => $out]);

        /* 网站 */
        case 'site.add':
            $d = $safe($arg['domain'] ?? '');
            $r = $safe($arg['root'] ?? '');
            $p = $safe($arg['port'] ?? '');
            if (!preg_match('/^[A-Za-z0-9.*_-]+(\.[A-Za-z0-9_-]+)*$/', $d)) fail('域名不合法');
            if ($r === '' || !preg_match('#^/[A-Za-z0-9._/+@-]*$#', $r)) fail('站点目录必须是纯英文绝对路径');
            if ($p !== '' && !preg_match('/^\d{1,5}$/', $p)) fail('端口不合法');
            [$rc, $out] = cli('site add ' . escapeshellarg($d) . ' ' . escapeshellarg($r)
                . ($p !== '' ? ' ' . escapeshellarg($p) : ''));
            jout(['ok' => $rc === 0, 'out' => $out]);

        case 'site.del':
            $d = $safe($arg['domain'] ?? '');
            if (!preg_match('/^[A-Za-z0-9.*_-]+(\.[A-Za-z0-9_-]+)*$/', $d)) fail('域名不合法');
            [$rc, $out] = cli('site del ' . escapeshellarg($d));
            jout(['ok' => $rc === 0, 'out' => $out]);

        case 'site.edit':
            $d = $safe($arg['domain'] ?? '');
            $r = $safe($arg['root'] ?? '');
            $p = $safe($arg['port'] ?? '');
            if (!preg_match('/^[A-Za-z0-9.*_-]+(\.[A-Za-z0-9_-]+)*$/', $d)) fail('域名不合法');
            $cmd = 'site edit ' . escapeshellarg($d);
            if ($r !== '') {
                if (!preg_match('#^/[A-Za-z0-9._/+@-]*$#', $r)) fail('站点目录必须是纯英文绝对路径');
                $cmd .= ' --root ' . escapeshellarg($r);
            }
            if ($p !== '' && preg_match('/^\d{1,5}$/', $p)) $cmd .= ' --port ' . escapeshellarg($p);
            [$rc, $out] = cli($cmd);
            jout(['ok' => $rc === 0, 'out' => $out]);

        case 'site.ssl':
            $d = $safe($arg['domain'] ?? '');
            $c = $safe($arg['cert'] ?? '');
            $k = $safe($arg['key'] ?? '');
            if (!preg_match('/^[A-Za-z0-9.*_-]+(\.[A-Za-z0-9_-]+)*$/', $d)) fail('域名不合法');
            if (!preg_match('#^/[A-Za-z0-9._/+@-]*$#', $c) || !is_file($c)) fail('证书文件不存在或路径不合法');
            if (!preg_match('#^/[A-Za-z0-9._/+@-]*$#', $k) || !is_file($k)) fail('私钥文件不存在或路径不合法');
            [$rc, $out] = cli('site ssl ' . escapeshellarg($d) . ' ' . escapeshellarg($c) . ' ' . escapeshellarg($k));
            jout(['ok' => $rc === 0, 'out' => $out]);

        case 'site.ssl-del':
            $d = $safe($arg['domain'] ?? '');
            if (!preg_match('/^[A-Za-z0-9.*_-]+(\.[A-Za-z0-9_-]+)*$/', $d)) fail('域名不合法');
            [$rc, $out] = cli('site ssl-del ' . escapeshellarg($d));
            jout(['ok' => $rc === 0, 'out' => $out]);

        /* 数据库 */
        case 'db.create':
            $n = $safe($arg['name'] ?? '');
            $u = $safe($arg['user'] ?? '');
            $p = $safe($arg['pass'] ?? '');
            if (!preg_match('/^[A-Za-z0-9_]{1,64}$/', $n)) fail('库名只允许字母数字下划线');
            $cmd = 'db create ' . escapeshellarg($n);
            if ($u !== '') {
                if (!preg_match('/^[A-Za-z0-9_]{1,32}$/', $u)) fail('用户名不合法');
                if ($p === '') fail('指定用户时必须给密码');
                $cmd .= ' ' . escapeshellarg($u) . ' ' . escapeshellarg($p);
            }
            [$rc, $out] = cli($cmd);
            jout(['ok' => $rc === 0, 'out' => $out]);

        case 'db.drop':
            $n = $safe($arg['name'] ?? '');
            if (!preg_match('/^[A-Za-z0-9_]{1,64}$/', $n)) fail('库名不合法');
            [$rc, $out] = cli('db drop ' . escapeshellarg($n));
            jout(['ok' => $rc === 0, 'out' => $out]);

        case 'db.passwd':
            $p = $safe($arg['pass'] ?? '');
            if (strlen($p) < 4) fail('密码至少 4 位');
            [$rc, $out] = cli('db passwd ' . escapeshellarg($p));
            jout(['ok' => $rc === 0, 'out' => $out]);

        /* 扩展 / 模块 */
        case 'ext.enable':
        case 'ext.disable':
            $n = $safe($arg['name'] ?? '');
            if (!preg_match('/^[A-Za-z0-9_]{1,40}$/', $n)) fail('扩展名不合法');
            [$rc, $out] = cli('ext ' . substr($op, 4) . ' ' . escapeshellarg($n));
            jout(['ok' => $rc === 0, 'out' => $out]);

        case 'module.enable':
        case 'module.disable':
            $n = $safe($arg['name'] ?? '');
            if (!preg_match('/^[A-Za-z0-9_]{1,40}$/', $n)) fail('模块名不合法');
            [$rc, $out] = cli('module ' . substr($op, 7) . ' ' . escapeshellarg($n));
            jout(['ok' => $rc === 0, 'out' => $out]);

        /* 端口 */
        case 'port.list':
            jout(json_decode((string)cli('ports')[1], true) ?: []);

        case 'kill.port':
        case 'kill.pid':
            $v = $safe($arg['value'] ?? '');
            if (!preg_match('/^\d{1,6}$/', $v)) fail('参数不合法');
            [$rc, $out] = cli('kill --' . substr($op, 5) . ' ' . escapeshellarg($v));
            jout(['ok' => $rc === 0, 'out' => $out]);

        /* hosts */
        case 'hosts.add':
        case 'hosts.del':
            $d = $safe($arg['domain'] ?? '');
            if (!preg_match('/^[A-Za-z0-9.*_-]+(\.[A-Za-z0-9_-]+)*$/', $d)) fail('域名不合法');
            [$rc, $out] = cli('hosts ' . substr($op, 6) . ' ' . escapeshellarg($d));
            jout(['ok' => $rc === 0, 'out' => $out]);

        /* FTP */
        case 'ftp.add':
            $n = $safe($arg['name'] ?? '');
            $d = $safe($arg['dir'] ?? '');
            $p = $safe($arg['pass'] ?? '');
            if (!preg_match('/^[a-z_][a-z0-9_-]{0,31}$/', $n)) fail('账号只能小写字母/数字/下划线');
            if ($d === '' || !preg_match('#^/[A-Za-z0-9._/+@-]*$#', $d)) fail('目录必须是纯英文绝对路径');
            $cmd = 'ftp add ' . escapeshellarg($n) . ' ' . escapeshellarg($d)
                 . ($p !== '' ? ' ' . escapeshellarg($p) : '');
            [$rc, $out] = cli($cmd);
            jout(['ok' => $rc === 0, 'out' => $out]);

        case 'ftp.del':
            $n = $safe($arg['name'] ?? '');
            if (!preg_match('/^[a-z_][a-z0-9_-]{0,31}$/', $n)) fail('账号不合法');
            [$rc, $out] = cli('ftp del ' . escapeshellarg($n));
            jout(['ok' => $rc === 0, 'out' => $out]);

        case 'ftp.passwd':
            $n = $safe($arg['name'] ?? '');
            $p = $safe($arg['pass'] ?? '');
            if (!preg_match('/^[a-z_][a-z0-9_-]{0,31}$/', $n)) fail('账号不合法');
            if (strlen($p) < 4) fail('密码至少 4 位');
            [$rc, $out] = cli('ftp passwd ' . escapeshellarg($n) . ' ' . escapeshellarg($p));
            jout(['ok' => $rc === 0, 'out' => $out]);

        case 'ftp.port':
            $p = $safe($arg['port'] ?? '');
            if (!preg_match('/^\d{1,5}$/', $p)) fail('端口不合法');
            [$rc, $out] = cli('ftp port ' . escapeshellarg($p));
            jout(['ok' => $rc === 0, 'out' => $out]);

        /* 开机自启 */
        case 'autostart.on':
        case 'autostart.off':
            $n = $safe($arg['name'] ?? '');
            if (!preg_match('/^[a-z]{3,10}$/', $n)) fail('服务名不合法');
            [$rc, $out] = cli('autostart ' . substr($op, 10) . ' ' . escapeshellarg($n));
            jout(['ok' => $rc === 0, 'out' => $out]);

        /* 设置 */
        case 'setting.port':
            $svc = $safe($arg['service'] ?? 'nginx');
            $p = $safe($arg['port'] ?? '');
            if (!in_array($svc, ['nginx', 'apache', 'php', 'mysql'], true)) fail('服务不合法');
            if (!preg_match('/^\d{1,5}$/', $p) || (int)$p < 1 || (int)$p > 65535) fail('端口范围 1-65535');
            [$rc, $out] = cli('port ' . escapeshellarg($svc) . ' ' . escapeshellarg($p));
            jout(['ok' => $rc === 0, 'out' => $out]);

        case 'panel.passwd':
            $p = $safe($arg['pass'] ?? '');
            if (strlen($p) < 6) fail('面板密码至少 6 位');
            [$rc, $out] = cli('panel passwd ' . escapeshellarg($p));
            jout(['ok' => $rc === 0, 'out' => $out]);

        case 'version.use':
            $k = $safe($arg['kind'] ?? '');
            $v = $safe($arg['version'] ?? '');
            if (!in_array($k, ['nginx', 'apache', 'mysql', 'php'], true)) fail('组件不合法');
            if (!preg_match('/^[A-Za-z0-9._-]{1,20}$/', $v)) fail('版本号不合法');
            [$rc, $out] = cli('version use ' . escapeshellarg($k) . ' ' . escapeshellarg($v));
            jout(['ok' => $rc === 0, 'out' => $out]);

        case 'repair':
            [$rc, $out] = cli('repair');
            jout(['ok' => $rc === 0, 'out' => $out]);

        default:
            fail('未知操作: ' . $op);
    }
}

/* ------------------------------------------------------------- 视图 */
$buildId = (string)(mf()['BUILD_ID'] ?? '');
$hash = (string)(mf()['PANEL_PASS_HASH'] ?? '');
$needSetup = ($hash === '');
?>
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Xiao Huang 管理面板</title>
<link rel="stylesheet" href="assets/panel.css?v=<?= VERSION ?>">
</head>
<body class="<?= logged_in() ? 'app' : 'login' ?>">

<?php if (!logged_in()): ?>
<div class="login-wrap">
  <form class="login-card" id="loginForm">
    <div class="logo-row"><span class="logo">XH</span><h1>Xiao Huang 管理面板</h1></div>
    <p class="sub">银河麒麟 ARM64 · <?= VERSION ?></p>
    <?php if ($needSetup): ?>
      <div class="alert warn">面板密码尚未初始化。请在终端执行：<br><code>xiaohuang panel passwd 你的密码</code></div>
    <?php endif; ?>
    <label>面板密码
      <input type="password" name="pass" id="loginPass" autocomplete="current-password" required <?= $needSetup ? 'disabled' : '' ?>>
    </label>
    <button class="btn primary block" type="submit" <?= $needSetup ? 'disabled' : '' ?>>登 录</button>
    <div class="err" id="loginErr"></div>
    <div class="foot-mini">Xiao Huang 0.0.0.1Beta · by 小黄 · 15359927763</div>
  </form>
</div>
<?php else: ?>
<aside class="side">
  <div class="brand"><span class="logo">XH</span><div><b>Xiao Huang</b><small><?= VERSION ?></small></div></div>
  <nav id="nav">
    <a href="#/home"     data-page="home">概览</a>
    <a href="#/sites"    data-page="sites">网站</a>
    <a href="#/database" data-page="database">数据库</a>
    <a href="#/software" data-page="software">软件管理</a>
    <a href="#/php"      data-page="php">PHP 扩展</a>
    <a href="#/apache"   data-page="apache">Apache 模块</a>
    <a href="#/ftp"      data-page="ftp">FTP</a>
    <a href="#/ports"    data-page="ports">端口</a>
    <a href="#/logs"     data-page="logs">日志</a>
    <a href="#/settings" data-page="settings">设置</a>
    <a href="#/about"    data-page="about">关于</a>
  </nav>
  <div class="side-foot">
    <button class="btn ghost sm" id="btnLogout">退出</button>
  </div>
</aside>

<main class="main">
  <header class="topbar">
    <div class="crumb" id="crumb">概览</div>
    <div class="top-actions">
      <span class="pill" id="pillHttp">HTTP —</span>
      <button class="btn sm" data-act="svc.restart" data-target="all">重启全部</button>
    </div>
  </header>
  <section class="content" id="content"><div class="loading">加载中…</div></section>
  <footer class="foot">
    <span>Xiao Huang <?= VERSION ?> · by 小黄</span>
    <span class="sep">·</span>
    <span>build <?= $buildId !== '' ? htmlspecialchars($buildId, ENT_QUOTES) : '未签名' ?></span>
    <span class="sep">·</span>
    <span>15359927763 ／ QQ 1924053793</span>
  </footer>
</main>
<div class="toast" id="toast"></div>
<script>window.__CSRF = "<?= csrf() ?>"; window.__BUILD = "<?= htmlspecialchars($buildId, ENT_QUOTES) ?>";</script>
<script src="assets/panel.js?v=<?= VERSION ?>"></script>
<?php endif; ?>
<script>
(function(){
  var f = document.getElementById('loginForm');
  if (f) f.addEventListener('submit', function(e){
    e.preventDefault();
    var fd = new FormData(); fd.append('pass', document.getElementById('loginPass').value);
    fetch('?api=login', {method:'POST', body:fd}).then(function(r){return r.json();}).then(function(j){
      if (j.ok) location.reload(); else {
        var el = document.getElementById('loginErr'); el.textContent = j.error || '登录失败';
      }
    }).catch(function(){ document.getElementById('loginErr').textContent = '请求失败'; });
  });
})();
</script>
</body>
</html>
