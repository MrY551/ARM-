<?php
/**
 * Xiao Huang for Kylin ARM64 —— 环境探针
 * 安装后访问 http://127.0.0.1/ 若站点 index 顺序为 index.php 优先，则进入本页。
 * 只读：不写入任何文件，不修改数据库。
 */
declare(strict_types=1);

$version = '@XIAOHUANG_VERSION@';
$build   = '@BUILD@';

/* ---------- 读取安装清单，拿到实际端口与组件版本 ---------- */
$manifest = [];
$candidates = [
    '/opt/xiaohuang/xiaohuang.ini',
    dirname(__DIR__) . '/../xiaohuang.ini',
    dirname(__DIR__) . '/xiaohuang.ini',
    '/usr/local/xiaohuang/xiaohuang.ini',
];
foreach ($candidates as $f) {
    if (is_readable($f)) {
        foreach (file($f, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
            if ($line === '' || $line[0] === '#' || strpos($line, '=') === false) {
                continue;
            }
            [$k, $v] = explode('=', $line, 2);
            $manifest[trim($k)] = trim($v);
        }
        break;
    }
}

$dbPort = $manifest['DB_PORT'] ?? '3306';
$dbPass = $manifest['DB_ROOT_PASS'] ?? 'root';
$dbVer  = $manifest['MYSQL_VER'] ?? '';

/* ---------- 运行时信息 ---------- */
$phpVer   = PHP_VERSION;
$sapi     = PHP_SAPI;
$exts     = get_loaded_extensions();
sort($exts, SORT_NATURAL | SORT_FLAG_CASE);
$server   = $_SERVER['SERVER_SOFTWARE'] ?? 'unknown';
$docRoot  = $_SERVER['DOCUMENT_ROOT'] ?? __DIR__;
$host     = $_SERVER['HTTP_HOST'] ?? '127.0.0.1';

/* ---------- 数据库连通性（容错，3 秒超时） ---------- */
$dbState = '未检测';
$dbClass = 'warn';
if (extension_loaded('mysqli')) {
    mysqli_report(MYSQLI_REPORT_OFF);
    $conn = @mysqli_init();
    if ($conn) {
        @mysqli_options($conn, MYSQLI_OPT_CONNECT_TIMEOUT, 3);
        $ok = @mysqli_real_connect($conn, '127.0.0.1', 'root', $dbPass, null, (int)$dbPort, null, 0);
        if ($ok) {
            $res = @mysqli_query($conn, 'SELECT VERSION() AS v');
            $row = $res ? mysqli_fetch_assoc($res) : null;
            $dbState = '连接成功 · ' . ($row['v'] ?? 'MySQL');
            $dbClass = 'ok';
            mysqli_close($conn);
        } else {
            $dbState = '未连接（' . mysqli_connect_error() . '）';
            $dbClass = 'err';
        }
    }
} else {
    $dbState = 'mysqli 扩展未加载';
    $dbClass = 'warn';
}

/* ---------- 目录可写性 ---------- */
$writable = is_writable(__DIR__);

function h(string $s): string
{
    return htmlspecialchars($s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}
?>
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Xiao Huang 环境探针 - <?= h($version) ?></title>
<style>
  :root{--bg:#f5f7fa;--card:#fff;--pri:#2f8f6b;--pri-d:#256e53;--txt:#243244;--sub:#6b7b8f;--line:#e3e9f0;--ok:#1f9d63;--warn:#c98a12;--err:#c94b4b}
  *{box-sizing:border-box}
  body{margin:0;min-height:100vh;background:var(--bg);color:var(--txt);
       font:15px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI","Noto Sans CJK SC","WenQuanYi Micro Hei","Microsoft Yahei",sans-serif;padding:24px}
  .wrap{max-width:900px;margin:0 auto}
  .card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:28px 30px;box-shadow:0 8px 28px rgba(35,60,90,.07);margin-bottom:18px}
  .brand{display:flex;align-items:center;gap:12px;flex-wrap:wrap}
  .logo{width:38px;height:38px;border-radius:10px;background:linear-gradient(135deg,#37a97c,#22695a);display:flex;align-items:center;justify-content:center;color:#fff;font-weight:700;font-size:16px}
  h1{font-size:20px;margin:0}
  .ver{font-size:13px;color:var(--sub);margin-left:auto}
  h2{font-size:15px;margin:26px 0 10px;padding-left:9px;border-left:3px solid var(--pri);line-height:1.2}
  table{width:100%;border-collapse:collapse;font-size:14px}
  td{padding:8px 0;border-bottom:1px dashed var(--line);vertical-align:top;word-break:break-all}
  td.k{color:var(--sub);width:150px;white-space:nowrap}
  code{font-family:"JetBrains Mono",Consolas,monospace;font-size:13px;background:#f2f5f9;padding:1px 6px;border-radius:5px}
  .tag{display:inline-block;padding:1px 8px;border-radius:999px;font-size:12.5px;font-weight:600}
  .tag.ok{background:#e8f6ef;color:var(--ok)}
  .tag.warn{background:#fdf3e0;color:var(--warn)}
  .tag.err{background:#fdecec;color:var(--err)}
  .exts{display:flex;flex-wrap:wrap;gap:7px;margin-top:6px}
  .ext{font-size:12.5px;background:#eef3f8;color:#41556b;border-radius:6px;padding:3px 9px}
  .tip{font-size:13px;color:var(--sub);line-height:1.85}
  @media (max-width:560px){
    body{padding:14px}
    .card{padding:20px 16px;border-radius:12px}
    h1{font-size:18px}
    .ver{margin-left:0;width:100%}
    table,tbody,tr,td{display:block;width:100%}
    tr{border-bottom:1px dashed var(--line);padding:7px 0}
    td{border:0;padding:0}
    td.k{width:auto;white-space:normal;font-size:13px;padding-bottom:2px}
    code,span.ext{overflow-wrap:anywhere;word-break:break-all}
    .exts{gap:6px}
    .ext{font-size:12px;padding:2px 8px}
  }
</style>
</head>
<body>
<div class="wrap">

  <div class="card">
    <div class="brand">
      <div class="logo">XH</div>
      <h1>环境探针</h1>
      <div class="ver">Xiao Huang <?= h($version) ?> · <?= h($build) ?></div>
    </div>

    <h2>运行环境</h2>
    <table>
      <tr><td class="k">PHP 版本</td><td><code><?= h($phpVer) ?></code>（<?= h($sapi) ?>）</td></tr>
      <tr><td class="k">Web 服务器</td><td><?= h($server) ?></td></tr>
      <tr><td class="k">站点根目录</td><td><code><?= h((string)$docRoot) ?></code></td></tr>
      <tr><td class="k">访问地址</td><td><code>http://<?= h($host) ?>/</code></td></tr>
      <tr><td class="k">站点目录可写</td><td><span class="tag <?= $writable ? 'ok' : 'warn' ?>"><?= $writable ? '是' : '否' ?></span></td></tr>
      <tr><td class="k">系统架构</td><td><?= h(php_uname('m')) ?> · <?= h(php_uname('s')) ?> <?= h(php_uname('r')) ?></td></tr>
      <tr><td class="k">加载配置</td><td><code><?= h(php_ini_loaded_file() ?: '无 php.ini') ?></code></td></tr>
    </table>

    <h2>数据库</h2>
    <table>
      <tr><td class="k">MySQL 端口</td><td><code><?= h($dbPort) ?></code><?= $dbVer !== '' ? '　<code>' . h($dbVer) . '</code>' : '' ?></td></tr>
      <tr><td class="k">root 连通性</td><td><span class="tag <?= h($dbClass) ?>"><?= h($dbState) ?></span></td></tr>
      <tr><td class="k">默认账号</td><td>root / <code><?= h($dbPass) ?></code>（安装清单中记录）</td></tr>
    </table>

    <h2>关键配置</h2>
    <table>
      <tr><td class="k">memory_limit</td><td><code><?= h((string)ini_get('memory_limit')) ?></code></td></tr>
      <tr><td class="k">upload_max_filesize</td><td><code><?= h((string)ini_get('upload_max_filesize')) ?></code></td></tr>
      <tr><td class="k">post_max_size</td><td><code><?= h((string)ini_get('post_max_size')) ?></code></td></tr>
      <tr><td class="k">max_execution_time</td><td><code><?= h((string)ini_get('max_execution_time')) ?></code> 秒</td></tr>
      <tr><td class="k">date.timezone</td><td><code><?= h((string)ini_get('date.timezone')) ?></code></td></tr>
      <tr><td class="k">OPcache</td><td><span class="tag <?= extension_loaded('Zend OPcache') ? 'ok' : 'warn' ?>"><?= extension_loaded('Zend OPcache') ? '已启用' : '未启用' ?></span></td></tr>
    </table>

    <h2>已加载扩展（<?= count($exts) ?>）</h2>
    <div class="exts">
      <?php foreach ($exts as $e): ?>
        <span class="ext"><?= h($e) ?></span>
      <?php endforeach; ?>
    </div>
  </div>

  <div class="card">
    <div class="tip">
      服务管理：<code>xiaohuang start|stop|restart|status</code><br>
      新增站点：<code>xiaohuang site add example.com /www/example</code><br>
      修改端口：<code>xiaohuang port nginx 8080</code>　数据库：<code>xiaohuang db init</code><br>
      本页为只读探针，用完后可删除站点根目录下的 <code>index.php</code>。
    </div>
  </div>

</div>
</body>
</html>
