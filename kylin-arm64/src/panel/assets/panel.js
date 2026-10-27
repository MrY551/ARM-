/* Xiao Huang 管理面板 —— 前端（无框架，hash 路由 + fetch） */
(function () {
  'use strict';

  const CSRF = window.__CSRF || '';
  const $c = document.getElementById('content');
  const $crumb = document.getElementById('crumb');
  const $toast = document.getElementById('toast');
  const $pill = document.getElementById('pillHttp');

  const esc = (s) => String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');

  function toast(msg, type) {
    const d = document.createElement('div');
    d.className = 't ' + (type || '');
    d.textContent = msg;
    $toast.appendChild(d);
    setTimeout(() => { d.style.opacity = '0'; d.style.transition = 'opacity .3s'; }, 3200);
    setTimeout(() => d.remove(), 3600);
  }

  async function get(api, params) {
    let url = '?api=' + encodeURIComponent(api);
    if (params) {
      Object.keys(params).forEach(function (k) {
        const v = params[k];
        if (v !== undefined && v !== null) {
          url += '&' + encodeURIComponent(k) + '=' + encodeURIComponent(v);
        }
      });
    }
    const r = await fetch(url, { headers: { 'X-CSRF': CSRF } });
    if (r.status === 401) { location.reload(); throw new Error('未登录'); }
    const text = await r.text();
    // 未登录/接口出错时后端会吐 HTML，直接 JSON.parse 会抛 "Unexpected token '<'"
    if (text.trim().charAt(0) === '<') {
      throw new Error('接口返回了网页而不是数据，可能登录已过期，刷新页面重试');
    }
    try {
      return JSON.parse(text);
    } catch (e) {
      throw new Error('接口返回的不是合法 JSON：' + text.slice(0, 60));
    }
  }

  async function act(op, arg) {
    const fd = new FormData();
    fd.append('op', op);
    Object.keys(arg || {}).forEach(k => fd.append('arg[' + k + ']', arg[k]));
    const r = await fetch('?api=action', { method: 'POST', body: fd, headers: { 'X-CSRF': CSRF } });
    const j = await r.json().catch(() => ({ ok: false, error: '响应解析失败' }));
    if (!j.ok) { toast(j.error || j.out || '操作失败', 'err'); throw new Error(j.error || 'failed'); }
    if (j.out) toast(j.out.split('\n').filter(Boolean).slice(-1)[0], 'ok');
    return j;
  }

  const btnBusy = (el, on) => { if (el) { el.disabled = !!on; } };

  /* ------------------------------------------------------------ 页面 */
  const pages = {};

  pages.home = async function () {
    const s = await get('state');
    const svc = (s.services || []).map(x => `
      <div class="card svc">
        <div class="svc-top">
          <span class="dot ${x.status === 'running' ? 'on' : 'off'}"></span>
          <span class="svc-name">${esc(x.name)}</span>
          <span class="tag ${x.status === 'running' ? 'ok' : 'off'}">${x.status === 'running' ? '运行中' : '已停止'}</span>
          ${x.active ? '<span class="tag">当前 Web</span>' : ''}
        </div>
        <div class="svc-meta"><span>${esc(x.version)}</span><span>端口 ${esc(x.port)}</span></div>
        <div class="svc-btns">
          <button class="btn sm" data-act="svc.start" data-target="${esc(x.name)}">启动</button>
          <button class="btn sm" data-act="svc.stop" data-target="${esc(x.name)}">停止</button>
          <button class="btn sm" data-act="svc.restart" data-target="${esc(x.name)}">重启</button>
        </div>
      </div>`).join('');

    const comp = (s.components || []).filter(c => c.current)
      .map(c => `<tr><td data-th="组件">${esc(c.kind)}</td><td data-th="版本"><code>${esc(c.version)}</code></td></tr>`).join('');

    $c.innerHTML = `
      <div class="sec-title"><h3>服务</h3>
        <div style="display:flex;gap:8px">
          <button class="btn sm primary" data-act="svc.start" data-target="all">一键启动</button>
          <button class="btn sm" data-act="svc.stop" data-target="all">全部停止</button>
        </div>
      </div>
      <div class="grid c3">${svc || '<div class="card muted">未安装任何组件</div>'}</div>

      <div class="sec-title"><h3>环境</h3></div>
      <div class="grid c2">
        <div class="card">
          <h2>安装信息</h2>
          <table style="min-width:0">
            <tr><td data-th="版本">Xiao Huang</td><td data-th="值"><code>${esc(s.version)} ${esc(s.build)}</code></td></tr>
            <tr><td data-th="路径">安装目录</td><td data-th="值"><code>${esc(s.dir)}</code></td></tr>
            <tr><td data-th="端口">HTTP</td><td data-th="值"><code>${esc(s.http)}</code></td></tr>
            <tr><td data-th="自检">首页响应</td><td data-th="值"><span class="tag ${s.http_code === '200' ? 'ok' : 'off'}">${esc(s.http_code || '000')}</span></td></tr>
          </table>
        </div>
        <div class="card">
          <h2>已装组件</h2>
          <table style="min-width:0">${comp || '<tr><td class="muted">无</td></tr>'}</table>
          <div class="hint"><a href="#/software">软件管理</a> 可查看全部版本并切换</div>
        </div>
      </div>`;
    if ($pill) {
      $pill.textContent = 'HTTP ' + (s.http_code || '000');
      $pill.className = 'pill ' + (s.http_code === '200' ? 'ok' : 'err');
    }
  };

  pages.sites = async function () {
    const list = await get('sites');
    const rows = (list || []).map(x => `
      <tr>
        <td data-th="域名"><b>${esc(x.domain)}</b></td>
        <td data-th="端口"><code>${esc(x.port)}</code></td>
        <td data-th="目录"><a href="javascript:void 0" class="dir-link" data-browse="${esc(x.root)}"
              title="点击浏览目录"><code>${esc(x.root)}</code> <span class="dir-go">›</span></a></td>
        <td data-th="SSL">${x.ssl ? '<span class="tag ssl">已启用</span>' : '<span class="tag off">未启用</span>'}</td>
        <td class="act">
          <button class="btn sm" data-site-edit="${esc(x.domain)}" data-root="${esc(x.root)}" data-port="${esc(x.port)}">编辑</button>
          <button class="btn sm" data-site-ssl="${esc(x.domain)}">SSL</button>
          <button class="btn sm danger" data-site-del="${esc(x.domain)}">删除</button>
        </td>
      </tr>`).join('');

    $c.innerHTML = `
      <div class="sec-title"><h3>站点列表</h3></div>
      <div class="table-wrap">
        <table>
          <thead><tr><th>域名</th><th>端口</th><th>目录</th><th>SSL</th><th style="text-align:right">操作</th></tr></thead>
          <tbody>${rows || '<tr><td colspan="5" class="row-empty">还没有站点</td></tr>'}</tbody>
        </table>
      </div>

      <div class="sec-title"><h3>新增站点</h3></div>
      <div class="card">
        <div class="form-grid">
          <label class="fld">域名<input id="sDomain" placeholder="example.com"></label>
          <label class="fld">站点目录
            <span class="input-with-btn">
              <input id="sRoot" placeholder="点右边浏览，或直接填绝对路径">
              <button type="button" class="btn sm" id="btnBrowseRoot">浏览…</button>
            </span>
          </label>
          <label class="fld">端口<input id="sPort" placeholder="留空 = 当前 HTTP 端口"></label>
          <button class="btn primary" id="btnAddSite">添加</button>
        </div>
        <div class="hint">目录不存在会自动建。路径只能纯英文，别带空格和中文——跟安装那会儿一个规矩。加完站点想上 HTTPS，点右边那个「SSL」。</div>
      </div>`;
  };

  pages.database = async function () {
    const list = await get('dbs');
    const rows = (list || []).map(x => `
      <tr>
        <td data-th="库名"><b>${esc(x.name)}</b></td>
        <td data-th="大小">${esc(x.size_mb)} MB</td>
        <td class="act"><button class="btn sm danger" data-db-drop="${esc(x.name)}">删除</button></td>
      </tr>`).join('');

    $c.innerHTML = `
      <div class="sec-title"><h3>数据库</h3>
        <button class="btn sm" data-act="svc.start" data-target="mysql">启动数据库</button>
      </div>
      <div class="table-wrap">
        <table>
          <thead><tr><th>库名</th><th>大小</th><th style="text-align:right">操作</th></tr></thead>
          <tbody>${rows || '<tr><td colspan="3" class="row-empty">没有数据库（先启动 MySQL）</td></tr>'}</tbody>
        </table>
      </div>

      <div class="sec-title"><h3>新建数据库</h3></div>
      <div class="card">
        <div class="form-grid">
          <label class="fld">库名<input id="dbName" placeholder="mydb"></label>
          <label class="fld">用户名（可选）<input id="dbUser" placeholder="myuser"></label>
          <label class="fld">密码<input id="dbPass" type="password" placeholder="给用户设密码"></label>
          <button class="btn primary" id="btnCreateDb">创建</button>
        </div>
        <div class="hint">不填用户名只建库。命令行：<code>xiaohuang db create 库名 [用户 密码]</code>；导入导出用 <code>xiaohuang db import|export</code>。</div>
      </div>

      <div class="sec-title"><h3>root 密码</h3></div>
      <div class="card">
        <div class="form-grid">
          <label class="fld">新密码<input id="rootPass" type="password" placeholder="至少 4 位"></label>
          <button class="btn" id="btnRootPass" style="justify-self:start;min-width:160px">修改 root 密码</button>
        </div>
      </div>`;
  };

  pages.software = async function () {
    const list = await get('versions');
    const groups = { nginx: 'Nginx', apache: 'Apache', php: 'PHP', mysql: 'MySQL / MariaDB' };
    const blocks = Object.keys(groups).map(k => {
      const items = (list || []).filter(x => x.kind === k);
      if (!items.length) return '';
      const rows = items.map(x => `
        <tr>
          <td data-th="版本"><code>${esc(x.version)}</code></td>
          <td data-th="路径" class="small muted">${esc(x.path)}</td>
          <td data-th="状态">${x.current ? '<span class="tag ok">当前</span>' : '<span class="tag off">可用</span>'}</td>
          <td class="act">${x.current ? '' : `<button class="btn sm" data-ver-use="${k}" data-ver="${esc(x.version)}">切换</button>`}</td>
        </tr>`).join('');
      return `<div class="sec-title"><h3>${groups[k]}</h3></div>
        <div class="table-wrap"><table>
          <thead><tr><th>版本</th><th>路径</th><th>状态</th><th style="text-align:right">操作</th></tr></thead>
          <tbody>${rows}</tbody></table></div>`;
    }).join('');

    $c.innerHTML = blocks + `
      <div class="sec-title"><h3>安装新版本</h3></div>
      <div class="card">
        <div class="hint">
          把新版本的组件包（<code>payload/components/&lt;name&gt;.tar.gz</code>）重新构建进安装包，或手工解到
          <code>app/Extensions/&lt;组件&gt;&lt;版本&gt;</code> 后刷新本页即可在列表里切换。
          切换后执行 <code>xiaohuang repair</code> 重建 systemd 单元并重启。
        </div>
        <div style="margin-top:10px"><button class="btn" data-op="repair">重建配置</button></div>
      </div>`;
  };

  pages.php = async function () {
    const list = await get('exts');
    const on = (list || []).filter(x => x.enabled).length;
    $c.innerHTML = `
      <div class="sec-title"><h3>PHP 扩展</h3>
        <span class="muted small">共 ${(list || []).length} 个 · 已启用 ${on} 个 · 点开关即时生效</span>
      </div>
      <div class="card">
        <div class="filter-bar">
          <input id="extFilter" class="filter-input" placeholder="搜扩展名，比如 mysql、gd、zip">
          <label class="switch-inline"><input type="checkbox" id="extOnlyOn"> 只看已启用</label>
        </div>
        <div class="chips" id="extChips"></div>
      </div>
      <div class="hint">改完自动 reload php-fpm，不用手动重启。命令行：<code>xiaohuang ext enable mysqli</code></div>`;
    renderExts(list || []);
    document.getElementById('extFilter').addEventListener('input', function () { renderExts(list || []); });
    document.getElementById('extOnlyOn').addEventListener('change', function () { renderExts(list || []); });
  };

  function renderExts(list) {
    const box = document.getElementById('extChips');
    if (!box) return;
    const kw = (document.getElementById('extFilter') || {}).value || '';
    const onlyOn = (document.getElementById('extOnlyOn') || {}).checked;
    let arr = list;
    if (kw.trim()) arr = arr.filter(x => x.name.toLowerCase().indexOf(kw.trim().toLowerCase()) >= 0);
    if (onlyOn) arr = arr.filter(x => x.enabled);
    if (!arr.length) { box.innerHTML = '<span class="muted">没有匹配的扩展</span>'; return; }
    box.innerHTML = arr.map(x =>
      `<span class="chip ${x.enabled ? 'on' : ''}" data-ext="${esc(x.name)}" data-on="${x.enabled ? 1 : 0}">
        <span class="k"></span>${esc(x.name)}</span>`).join('');
  }

  pages.apache = async function () {
    const list = await get('modules');
    const on = (list || []).filter(x => x.enabled).length;
    $c.innerHTML = `
      <div class="sec-title"><h3>Apache 模块</h3>
        <span class="muted small">共 ${(list || []).length} 个 · 已加载 ${on} 个 · 改动前会先跑 httpd -t</span>
      </div>
      <div class="card">
        <div class="filter-bar">
          <input id="modFilter" class="filter-input" placeholder="搜模块名，比如 rewrite、ssl、proxy">
          <label class="switch-inline"><input type="checkbox" id="modOnlyOn"> 只看已加载</label>
        </div>
        <div class="chips" id="modChips"></div>
      </div>
      <div class="hint">加载新模块后如果 <code>httpd -t</code> 报错会自动回滚，不会把 Apache 弄挂。切换 Web 服务器：<code>xiaohuang switch apache</code></div>`;
    renderMods(list || []);
    document.getElementById('modFilter').addEventListener('input', function () { renderMods(list || []); });
    document.getElementById('modOnlyOn').addEventListener('change', function () { renderMods(list || []); });
  };

  function renderMods(list) {
    const box = document.getElementById('modChips');
    if (!box) return;
    const kw = (document.getElementById('modFilter') || {}).value || '';
    const onlyOn = (document.getElementById('modOnlyOn') || {}).checked;
    let arr = list;
    if (kw.trim()) arr = arr.filter(x => x.name.toLowerCase().indexOf(kw.trim().toLowerCase()) >= 0);
    if (onlyOn) arr = arr.filter(x => x.enabled);
    if (!arr.length) { box.innerHTML = '<span class="muted">没有匹配的模块</span>'; return; }
    box.innerHTML = arr.map(x =>
      `<span class="chip ${x.enabled ? 'on' : ''}" data-mod="${esc(x.name)}" data-on="${x.enabled ? 1 : 0}"
        title="${esc(x.so)}.so">${esc(x.name)}</span>`).join('');
  }

  pages.ftp = async function () {
    const st = await get('state');
    const ftp = (st.services || []).find(x => x.name === 'ftp');
    const list = await get('ftpusers');
    const rows = (list || []).map(x => `
      <tr>
        <td data-th="账号"><b>${esc(x.name)}</b></td>
        <td data-th="目录"><code>${esc(x.home)}</code></td>
        <td class="act">
          <button class="btn sm" data-ftp-pass="${esc(x.name)}">改密</button>
          <button class="btn sm danger" data-ftp-del="${esc(x.name)}">删除</button>
        </td>
      </tr>`).join('');

    const statusBox = ftp ? `
      <div class="card svc">
        <div class="svc-top">
          <span class="dot ${ftp.status === 'running' ? 'on' : 'off'}"></span>
          <span class="svc-name">FTP (vsftpd)</span>
          <span class="tag ${ftp.status === 'running' ? 'ok' : 'off'}">${ftp.status === 'running' ? '运行中' : '已停止'}</span>
        </div>
        <div class="svc-meta"><span>${esc(ftp.version)}</span><span>端口 ${esc(ftp.port)}</span></div>
        <div class="svc-btns">
          <button class="btn sm" data-act="svc.start" data-target="ftp">启动</button>
          <button class="btn sm" data-act="svc.stop" data-target="ftp">停止</button>
          <button class="btn sm" data-act="svc.restart" data-target="ftp">重启</button>
        </div>
      </div>` : '<div class="card muted">未安装 FTP 组件（安装时加 --ftp-port 或去掉 --no-ftp）</div>';

    $c.innerHTML = `
      <div class="sec-title"><h3>FTP 服务</h3></div>
      <div class="grid c2">${statusBox}
        <div class="card">
          <h2>端口</h2>
          <div class="form-grid">
            <label class="fld">FTP 端口<input id="ftpPort" placeholder="${ftp ? esc(ftp.port) : '21'}"></label>
            <button class="btn" id="btnFtpPort" style="justify-self:start;min-width:150px">修改</button>
          </div>
          <div class="hint">被动模式端口段由安装器分配（约 20 个），防火墙需放行 FTP 端口与被动段。</div>
        </div>
      </div>

      <div class="sec-title"><h3>FTP 账号</h3></div>
      <div class="table-wrap">
        <table>
          <thead><tr><th>账号</th><th>站点目录</th><th style="text-align:right">操作</th></tr></thead>
          <tbody>${rows || '<tr><td colspan="3" class="row-empty">还没有 FTP 账号</td></tr>'}</tbody>
        </table>
      </div>

      <div class="sec-title"><h3>新建账号</h3></div>
      <div class="card">
        <div class="form-grid">
          <label class="fld">账号<input id="ftpName" placeholder="ftp_site1"></label>
          <label class="fld">站点目录<input id="ftpDir" placeholder="/opt/xiaohuang/app/WWW/site1"></label>
          <label class="fld">密码<input id="ftpPass" type="password" placeholder="留空自动生成"></label>
          <button class="btn primary" id="btnFtpAdd">创建</button>
        </div>
        <div class="hint">每个账号是个系统用户，home 锁死在站点目录里，只能看见自己那一份。命令行同样能建：<code>xiaohuang ftp add ftp_site1 /path pass</code></div>
      </div>`;
  };

  pages.ports = async function () {
    const list = await get('ports');
    const rows = (list || []).map(x => `
      <tr>
        <td data-th="端口"><code>${esc(x.port)}</code></td>
        <td data-th="地址">${esc(x.addr)}</td>
        <td data-th="进程">${esc(x.process || '-')} <span class="muted small">${esc(x.pid || '')}</span></td>
        <td class="act"><button class="btn sm danger" data-kill="${esc(x.pid)}">结束</button></td>
      </tr>`).join('');
    $c.innerHTML = `
      <div class="sec-title"><h3>监听端口</h3><button class="btn sm" data-op="reload-ports">刷新</button></div>
      <div class="table-wrap"><table>
        <thead><tr><th>端口</th><th>地址</th><th>进程</th><th style="text-align:right">操作</th></tr></thead>
        <tbody>${rows || '<tr><td colspan="4" class="row-empty">没有监听</td></tr>'}</tbody>
      </table></div>
      <div class="hint" style="margin-top:12px">等价命令：<code>xiaohuang ports</code> / <code>xiaohuang kill --port 8080</code></div>`;
  };

  pages.logs = async function () {
    $c.innerHTML = `
      <div class="sec-title"><h3>日志</h3>
        <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap">
          <select id="logSvc" class="sel sm">
            <option value="nginx">Nginx 错误</option>
            <option value="access">访问日志</option>
            <option value="php">PHP-FPM</option>
            <option value="apache">Apache 错误</option>
            <option value="mysql">MySQL 错误</option>
            <option value="ftp">FTP</option>
            <option value="panel">面板</option>
          </select>
          <label class="switch-inline"><input type="checkbox" id="logAuto"> 自动刷新 5s</label>
          <button class="btn sm" id="btnLog">刷新</button>
        </div>
      </div>
      <div class="log-meta" id="logMeta"></div>
      <pre class="log" id="logBox">加载中…</pre>`;
    await loadLog();
    await loadLogMeta();
  };

  async function loadLog() {
    const svc = (document.getElementById('logSvc') || {}).value || 'nginx';
    const box = document.getElementById('logBox');
    if (!box) return;
    try {
      const j = await get('log', { svc: svc });
      const t = (j && j.text) ? j.text : '';
      box.textContent = t || '（这个日志还没有内容，或者服务还没启动过）';
    } catch (e) {
      box.textContent = '读取失败：' + (e && e.message ? e.message : '未知错误')
        + '\n\n可以到服务器上看：' + 'sudo xiaohuang log ' + svc;
    }
    box.scrollTop = box.scrollHeight;
  }

  async function loadLogMeta() {
    const el = document.getElementById('logMeta');
    if (!el) return;
    const svc = (document.getElementById('logSvc') || {}).value || 'nginx';
    try {
      const all = await get('logfiles');
      const me = (all || []).find(x => x.svc === svc);
      if (!me || !me.files.length) { el.innerHTML = '<span class="muted">没有找到日志文件</span>'; return; }
      el.innerHTML = me.files.map(f =>
        `<span class="log-file"><code>${esc(f.file)}</code> ${fmtSize(f.size)}</span>`).join('');
    } catch (e) { el.innerHTML = ''; }
  }

  function fmtSize(n) {
    if (n < 1024) return n + ' B';
    if (n < 1048576) return (n / 1024).toFixed(1) + ' KB';
    return (n / 1048576).toFixed(1) + ' MB';
  }

  let logTimer = null;
  function toggleLogAuto(on) {
    if (logTimer) { clearInterval(logTimer); logTimer = null; }
    if (on) logTimer = setInterval(function () {
      if (location.hash.indexOf('#/logs') !== 0) { toggleLogAuto(false); return; }
      loadLog();
    }, 5000);
  }

  pages.settings = async function () {
    const s = await get('state');
    const auto = await get('autostart');
    const autoChips = (auto || []).map(x => {
      const on = x.enabled === 'enabled';
      const missing = x.enabled === 'missing';
      return `<span class="chip ${on ? 'on' : ''}" data-auto="${esc(x.name)}" data-on="${on ? 1 : 0}"
        ${missing ? 'style="opacity:.45;pointer-events:none"' : ''}>
        <span class="k"></span>${esc(x.name)}${missing ? '（未注册）' : ''}
      </span>`;
    }).join('');

    $c.innerHTML = `
      <div class="sec-title"><h3>开机自启</h3><span class="muted small">点击开关；只影响 systemd 的 enable 状态</span></div>
      <div class="card">
        <div class="chips">${autoChips || '<span class="muted">没有可配置的服务</span>'}</div>
        <div class="hint">点开关就行。Apache 和 Nginx 抢同一个端口，用 <code>xiaohuang switch</code> 换的时候，自启会跟着一起切过去。</div>
      </div>

      <div class="sec-title"><h3>端口</h3></div>
      <div class="card">
        <div class="form-grid">
          <label class="fld">服务
            <select id="portSvc">
              <option value="nginx">Nginx</option>
              <option value="apache">Apache</option>
              <option value="php">PHP-FPM</option>
              <option value="mysql">MySQL</option>
            </select>
          </label>
          <label class="fld">端口<input id="portVal" placeholder="8080"></label>
          <button class="btn primary" id="btnPort">修改并重启</button>
        </div>
        <div class="hint">当前：HTTP ${esc(s.http)}，PHP-FPM ${esc((s.services || []).find(x => x.name === 'php')?.port || '-')}，MySQL ${esc((s.services || []).find(x => x.name === 'mysql')?.port || '-')}。</div>
      </div>

      <div class="sec-title"><h3>面板密码</h3></div>
      <div class="card">
        <div class="form-grid">
          <label class="fld">新密码<input id="panelPass" type="password" placeholder="至少 6 位"></label>
          <button class="btn" id="btnPanelPass" style="justify-self:start;min-width:150px">修改</button>
        </div>
        <div class="hint">忘了密码进不来，就在终端跑 <code>xiaohuang panel passwd 新密码</code>。</div>
      </div>

      <div class="sec-title"><h3>本机 hosts</h3></div>
      <div class="card">
        <div class="form-grid">
          <label class="fld">域名<input id="hostsDomain" placeholder="example.com"></label>
          <button class="btn" id="btnHostsAdd">写入 127.0.0.1</button>
          <button class="btn danger" id="btnHostsDel" style="justify-self:start;min-width:150px">从 hosts 删除</button>
        </div>
        <div class="hint">改之前会自动备份成 <code>/etc/hosts.xiaohuang.bak</code>，写坏了能捞回来。</div>
      </div>

      <div class="sec-title"><h3>环境检查</h3></div>
      <div class="card">
        <div style="display:flex;gap:8px;flex-wrap:wrap">
          <button class="btn" data-op="repair">校验并重建配置</button>
          <a class="btn" href="#/logs">查看日志</a>
          <a class="btn" href="/index.php" target="_blank">环境探针</a>
        </div>
      </div>`;
  };


  pages.about = async function () {
    $c.innerHTML = `
      <div class="about-hero">
        <span class="logo">XH</span>
        <div class="about-hero-txt">
          <b>Xiao Huang</b>
          <span>0.0.0.1Beta · 麒麟 ARM64 · 组件全在包里，断网也能装</span>
        </div>
        <span class="tag">Beta</span>
      </div>

      <div class="about-meta">
        <span>构建指纹 <code>${esc(window.__BUILD || '未签名')}</code></span>
        <span class="dotsep">·</span>
        <span>作者 小黄</span>
        <span class="dotsep">·</span>
        <span>完整手册见 <code>app/docs/用户手册.md</code></span>
      </div>

      <div class="about-grid">
        <div class="about-col">
          <h3>如果你觉得好用可以打赏我一杯奶茶</h3>
          <p>这面板是我下班后一行行敲出来的，没广告也没会员。</p>
          <p>用得顺手就请我喝一杯，多少都是心意。</p>
          <div class="qr-row">
            <div class="qr-card">
              <img src="assets/img/qr-wechat.png" alt="微信支付收款码">
              <span class="badge wx"><i></i>微信支付</span>
            </div>
            <div class="qr-card">
              <img src="assets/img/qr-alipay.png" alt="支付宝收款码">
              <span class="badge ali"><i></i>支付宝</span>
            </div>
          </div>
        </div>

        <div class="about-col">
          <h3>如果你有什么意见建议，欢迎联系我。</h3>
          <p>装不上、用着别扭、想要什么功能，直接找我，别客气。</p>
          <p>看到就回。</p>
          <ul class="contact-list">
            <li><span>手机</span><b>15359927763</b></li>
            <li><span>QQ</span><b>1924053793</b></li>
          </ul>
          <div class="qr-corner">
            <div class="qr-card sm">
              <img src="assets/img/qr-contact.png" alt="微信二维码">
              <span class="badge wx"><i></i>扫码加我微信</span>
            </div>
          </div>
        </div>
      </div>`;
  };


  /* --------------------------------------------------------- 目录浏览弹窗 */
  const pick = { target: null, cb: null };

  async function openBrowser(startPath, onPick) {
    pick.target = startPath || '';
    pick.cb = onPick;
    let box = document.getElementById('dirModal');
    if (!box) {
      box = document.createElement('div');
      box.id = 'dirModal';
      box.className = 'modal-mask';
      box.innerHTML = `
        <div class="modal">
          <div class="modal-hd">
            <b>选择目录</b>
            <button class="btn sm" data-dir-close>关闭</button>
          </div>
          <div class="modal-crumbs" id="dirCrumbs"></div>
          <div class="modal-body" id="dirList">加载中…</div>
          <div class="modal-ft">
            <span class="modal-path" id="dirPath"></span>
            <button class="btn primary" id="dirPick">用这个目录</button>
          </div>
        </div>`;
      document.body.appendChild(box);
      box.addEventListener('click', async function (ev) {
        const t = ev.target;
        if (t.dataset.dirClose !== undefined || t === box) { closeBrowser(); return; }
        if (t.dataset.dirGo) { await loadDir(t.dataset.dirGo); return; }
        if (t.dataset.dirUp) { await loadDir(t.dataset.dirUp); return; }
        if (t.id === 'dirPick') {
          const p = document.getElementById('dirPath').dataset.path || '';
          if (pick.cb) pick.cb(p);
          closeBrowser();
          return;
        }
      });
    }
    box.style.display = 'flex';
    await loadDir(pick.target);
  }

  async function loadDir(p) {
    const list = document.getElementById('dirList');
    const crumbs = document.getElementById('dirCrumbs');
    const pathEl = document.getElementById('dirPath');
    list.innerHTML = '加载中…';
    try {
      const j = await get('browse', { path: p || '' });
      if (!j || !j.ok) throw new Error((j && j.error) || '读取失败');
      pathEl.dataset.path = j.path;
      pathEl.textContent = j.path + (j.writable ? '（可写）' : '（只读）');

      // 面包屑
      const parts = j.path.split('/').filter(Boolean);
      let acc = '';
      const cs = ['<a href="javascript:void 0" data-dir-go="/">/</a>'];
      parts.forEach(function (seg) {
        acc += '/' + seg;
        cs.push('<a href="javascript:void 0" data-dir-go="' + esc(acc) + '">' + esc(seg) + '</a>');
      });
      crumbs.innerHTML = cs.join('<span class="sep">›</span>');

      const up = j.parent ? `<div class="dir-row up" data-dir-up="${esc(j.parent)}">↑ 上一层</div>` : '';
      const dirs = (j.dirs || []).map(d =>
        `<div class="dir-row" data-dir-go="${esc(d.path)}"><span class="ico">📁</span>${esc(d.name)}</div>`).join('');
      list.innerHTML = up + (dirs || '<div class="dir-empty">这里没有子目录</div>')
        + `<div class="dir-note">当前目录下还有 ${j.files || 0} 个文件</div>`;
    } catch (e) {
      list.innerHTML = '<div class="dir-empty">打不开：' + esc(e.message || '未知错误') + '</div>';
      pathEl.textContent = p;
      pathEl.dataset.path = p;
    }
  }

  function closeBrowser() {
    const box = document.getElementById('dirModal');
    if (box) box.style.display = 'none';
  }

  /* --------------------------------------------------------- 路由 */
  const titles = {
    home: '概览', sites: '网站', database: '数据库', software: '软件管理',
    php: 'PHP 扩展', apache: 'Apache 模块', ftp: 'FTP', ports: '端口', logs: '日志',
    settings: '设置', about: '关于'
  };

  function refreshPill() {
    if (!$pill) return;
    get('state').then(function (s) {
      $pill.textContent = 'HTTP ' + (s.http_code || '000');
      $pill.className = 'pill ' + (s.http_code === '200' ? 'ok' : 'err');
    }).catch(function () {});
  }

  async function route() {
    refreshPill();
    const m = (location.hash || '#/home').match(/^#\/([a-z]+)/);
    const page = (m && pages[m[1]]) ? m[1] : 'home';
    document.querySelectorAll('#nav a').forEach(a => a.classList.toggle('on', a.dataset.page === page));
    $crumb.textContent = titles[page] || '概览';
    $c.innerHTML = '<div class="loading">加载中…</div>';
    try { await pages[page](); } catch (e) { $c.innerHTML = '<div class="card muted">加载失败：' + esc(e.message) + '</div>'; }
  }

  /* ------------------------------------------------------- 事件委托 */
  document.addEventListener('click', async function (ev) {
    const t = ev.target.closest('button, .chip');
    if (!t) return;

    const busy = (on) => btnBusy(t, on);

    /* 服务 */
    if (t.dataset.act) {
      busy(true);
      try {
        const j = await act(t.dataset.act, { target: t.dataset.target || 'all' });
        toast(j.out || '完成', 'ok');
      } catch (e) {}
      busy(false);
      if (['svc.start', 'svc.stop', 'svc.restart', 'svc.switch'].includes(t.dataset.act)) {
        setTimeout(() => route(), 600);
      }
      return;
    }

    /* 站点 */
    if (t.id === 'btnAddSite') {
      const d = document.getElementById('sDomain').value.trim();
      const r = document.getElementById('sRoot').value.trim();
      const p = document.getElementById('sPort').value.trim();
      if (!d) return toast('域名不能为空', 'err');
      if (!r) return toast('站点目录不能为空', 'err');
      busy(true);
      try { await act('site.add', { domain: d, root: r, port: p }); route(); } catch (e) {}
      busy(false);
      return;
    }
    if (t.dataset.siteDel) {
      if (!confirm('删除站点 ' + t.dataset.siteDel + ' ？站点文件不会删除')) return;
      busy(true);
      try { await act('site.del', { domain: t.dataset.siteDel }); route(); } catch (e) {}
      busy(false);
      return;
    }
    if (t.dataset.siteEdit) {
      const d = t.dataset.siteEdit;
      const r = prompt('站点目录', t.dataset.root);
      if (r === null) return;
      const p = prompt('端口', t.dataset.port);
      if (p === null) return;
      busy(true);
      try { await act('site.edit', { domain: d, root: r, port: p }); route(); } catch (e) {}
      busy(false);
      return;
    }
    if (t.dataset.siteSsl) {
      const d = t.dataset.siteSsl;
      const c = prompt('证书文件绝对路径（.pem / .crt）', '/etc/ssl/certs/' + d + '.pem');
      if (!c) return;
      const k = prompt('私钥文件绝对路径（.key）', '/etc/ssl/private/' + d + '.key');
      if (!k) return;
      busy(true);
      try { await act('site.ssl', { domain: d, cert: c, key: k }); route(); } catch (e) {}
      busy(false);
      return;
    }

    /* 数据库 */
    if (t.id === 'btnCreateDb') {
      const n = document.getElementById('dbName').value.trim();
      const u = document.getElementById('dbUser').value.trim();
      const p = document.getElementById('dbPass').value;
      if (!n) return toast('库名不能为空', 'err');
      busy(true);
      try { await act('db.create', { name: n, user: u, pass: p }); route(); } catch (e) {}
      busy(false);
      return;
    }
    if (t.dataset.dbDrop) {
      if (!confirm('删除数据库 ' + t.dataset.dbDrop + ' ？数据不可恢复')) return;
      busy(true);
      try { await act('db.drop', { name: t.dataset.dbDrop }); route(); } catch (e) {}
      busy(false);
      return;
    }
    if (t.id === 'btnRootPass') {
      const p = document.getElementById('rootPass').value;
      if (p.length < 4) return toast('密码至少 4 位', 'err');
      busy(true);
      try { await act('db.passwd', { pass: p }); } catch (e) {}
      busy(false);
      return;
    }

    /* 扩展 / 模块开关 */
    if (t.dataset.ext !== undefined) {
      const name = t.dataset.ext;
      const on = t.dataset.on === '1';
      if (!on && t.dataset.avail === '0') return toast('扩展文件不存在', 'err');
      busy(true);
      try { await act(on ? 'ext.disable' : 'ext.enable', { name: name }); route(); } catch (e) {}
      busy(false);
      return;
    }
    if (t.dataset.mod !== undefined) {
      const name = t.dataset.mod;
      const on = t.dataset.on === '1';
      busy(true);
      try { await act(on ? 'module.disable' : 'module.enable', { name: name }); route(); } catch (e) {}
      busy(false);
      return;
    }

    /* FTP */
    if (t.id === 'btnFtpAdd') {
      const n = document.getElementById('ftpName').value.trim();
      const d = document.getElementById('ftpDir').value.trim();
      const p = document.getElementById('ftpPass').value;
      if (!n) return toast('账号不能为空', 'err');
      if (!d) return toast('目录不能为空', 'err');
      busy(true);
      try { await act('ftp.add', { name: n, dir: d, pass: p }); route(); } catch (e) {}
      busy(false);
      return;
    }
    if (t.dataset.ftpDel) {
      if (!confirm('删除 FTP 账号 ' + t.dataset.ftpDel + ' ？（站点目录保留）')) return;
      busy(true);
      try { await act('ftp.del', { name: t.dataset.ftpDel }); route(); } catch (e) {}
      busy(false);
      return;
    }
    if (t.dataset.ftpPass) {
      const p = prompt('新密码（至少 4 位）');
      if (!p) return;
      busy(true);
      try { await act('ftp.passwd', { name: t.dataset.ftpPass, pass: p }); } catch (e) {}
      busy(false);
      return;
    }
    if (t.id === 'btnFtpPort') {
      const p = document.getElementById('ftpPort').value.trim();
      if (!/^\d{1,5}$/.test(p)) return toast('端口不合法', 'err');
      busy(true);
      try { await act('ftp.port', { port: p }); route(); } catch (e) {}
      busy(false);
      return;
    }

    /* 开机自启 */
    if (t.dataset.auto !== undefined) {
      const name = t.dataset.auto;
      const on = t.dataset.on === '1';
      busy(true);
      try { await act(on ? 'autostart.off' : 'autostart.on', { name: name }); route(); } catch (e) {}
      busy(false);
      return;
    }

    /* 扩展开关 */
    if (t.dataset.ext !== undefined) {
      busy(true);
      try { await act(t.dataset.on === '1' ? 'ext.disable' : 'ext.enable', { name: t.dataset.ext }); route(); } catch (e) {}
      busy(false);
      return;
    }

    /* 模块开关 */
    if (t.dataset.mod !== undefined) {
      busy(true);
      try { await act(t.dataset.on === '1' ? 'module.disable' : 'module.enable', { name: t.dataset.mod }); route(); } catch (e) {}
      busy(false);
      return;
    }

    /* 目录浏览 */
    if (t.dataset.browse) { openBrowser(t.dataset.browse, null); return; }
    if (t.id === 'btnBrowseRoot') {
      const cur = (document.getElementById('sRoot') || {}).value || '';
      openBrowser(cur, function (p) {
        const el = document.getElementById('sRoot');
        if (el) el.value = p;
      });
      return;
    }
    if (t.id === 'btnBrowseEditRoot') {
      const cur = (document.getElementById('eRoot') || {}).value || '';
      openBrowser(cur, function (p) {
        const el = document.getElementById('eRoot');
        if (el) el.value = p;
      });
      return;
    }

    /* 端口 / 进程 */
    if (t.dataset.kill) {
      if (!confirm('结束进程 ' + t.dataset.kill + ' ？')) return;
      busy(true);
      try { await act('kill.pid', { value: t.dataset.kill }); route(); } catch (e) {}
      busy(false);
      return;
    }
    if (t.dataset.op === 'reload-ports') { route(); return; }
    if (t.dataset.op === 'repair') {
      busy(true);
      try { await act('repair', {}); toast('配置已重建', 'ok'); } catch (e) {}
      busy(false);
      return;
    }

    /* 版本切换 */
    if (t.dataset.verUse) {
      if (!confirm('切换 ' + t.dataset.verUse + ' 到 ' + t.dataset.ver + ' ？切换后需 repair 并重启'))
        return;
      busy(true);
      try { await act('version.use', { kind: t.dataset.verUse, version: t.dataset.ver }); route(); } catch (e) {}
      busy(false);
      return;
    }

    /* 设置 */
    if (t.id === 'btnPort') {
      const svc = document.getElementById('portSvc').value;
      const p = document.getElementById('portVal').value.trim();
      if (!/^\d{1,5}$/.test(p)) return toast('端口不合法', 'err');
      busy(true);
      try { await act('setting.port', { service: svc, port: p }); route(); } catch (e) {}
      busy(false);
      return;
    }
    if (t.id === 'btnPanelPass') {
      const p = document.getElementById('panelPass').value;
      if (p.length < 6) return toast('至少 6 位', 'err');
      busy(true);
      try { await act('panel.passwd', { pass: p }); toast('面板密码已更新', 'ok'); } catch (e) {}
      busy(false);
      return;
    }
    if (t.id === 'btnHostsAdd' || t.id === 'btnHostsDel') {
      const d = document.getElementById('hostsDomain').value.trim();
      if (!d) return toast('域名不能为空', 'err');
      busy(true);
      try { await act(t.id === 'btnHostsAdd' ? 'hosts.add' : 'hosts.del', { domain: d }); } catch (e) {}
      busy(false);
      return;
    }

    /* 日志 */
    if (t.id === 'btnLog') { await loadLog(); await loadLogMeta(); return; }

    /* 退出 */
    if (t.id === 'btnLogout') {
      await fetch('?api=logout');
      location.reload();
    }
  });

  document.addEventListener('change', function (ev) {
    if (ev.target.id === 'logSvc') loadLog();
  });

  window.addEventListener('hashchange', route);
  route();
})();
