# Xiao Huang — 银河麒麟 ARM64 Web 环境

把 phpStudy V8 在 Windows 上的那套目录布局、组件配置、站点模板、路径规则，复刻到
银河麒麟 V10 / aarch64 上，换成自有品牌。组件全部内置，装的时候不联网、不读系统仓库、
不要求目标机装过 LAMP。

```
Nginx 1.18.0  ·  Apache 2.4.62  ·  PHP-FPM 7.4.33  ·  MariaDB 10.5.23  ·  vsftpd 3.0.3
```

| | |
|---|---|
| 目标平台 | 银河麒麟 V10 aarch64（兼容 UOS / openEuler / Debian / Ubuntu arm64） |
| 语言构成 | Bash 2,511 行 · JavaScript 855 · PHP 528 · CSS 225 · 配置模板 493 |
| 代码总量 | 5,347 行（不含文档） |
| 交付形态 | `.deb` 92 MB · `.run` 93 MB，两个都能离线装 |
| 命令行 | 18 个子命令 |
| 管理面板 | 11 个页面，15 个 JSON 接口 |
| 验收用例 | 19 项 |

---

## 1. 要解决的问题

麒麟 V10 自带软件源里的 Nginx、PHP、MariaDB 版本参差，装一套能跑 PHP 站点的环境要
拉几十个系统包，离线场景基本走不通；换一台机器就得重来一遍，配置还散在
`/etc/nginx`、`/etc/php`、`/etc/mysql` 三个地方各管一段。

这个项目把整件事收进一个目录：

- 五个组件各自带 `ld-linux-aarch64.so.1` 和完整依赖库（含 `libc.so.6`），启动时用
  自带 loader，目标机 glibc 只要 ≥ 2.17 就能跑
- 所有配置渲染到安装目录内，不碰 `/etc` 下的系统文件
- 一条命令起停，一个面板管站点、数据库、扩展、端口、日志

装完的效果：

```
/opt/xiaohuang/
├── app/WWW/            站点根
├── app/Extensions/     五个组件，每个都是自包含的
├── app/panel/          管理面板
├── bin/xiaohuang       命令行
├── conf/               vhost 模板
└── xiaohuang.ini       清单：端口、版本、密码哈希、构建指纹
```

---

## 2. 为什么组件要自包含

麒麟各个 SP 版本 glibc 从 2.28 到 2.34 都有，Debian 11 编出来的二进制直接拷过去
多半报 `GLIBC_2.29 not found`。装一套 `libc6` 又会影响系统。

办法是每个组件目录里放一份自己的运行时：

```
Nginx1.18.0/
├── bin/nginx                  sh 包装：
│                                ROOT=$(readlink -f $0)/..
│                                exec "$ROOT/lib/ld-linux-aarch64.so.1" \
│                                     --library-path "$ROOT/lib" \
│                                     "$ROOT/libexec/nginx.bin" "$@"
├── libexec/nginx.bin          真实 ELF
├── libexec/nginx -> ../bin/nginx    组件内部脚本调 libexec 时也走包装
├── lib/                       完整依赖闭包，含 libc.so.6
├── conf/  logs/  temp/
```

`--library-path` 把 `lib/` 排在搜索路径最前面，动态链接器不会再去读 `/lib`。
三个后果：

- 目标机 glibc 是什么版本都无所谓
- 卸载时删目录就干净，不残留系统库
- 同一个机器上能并存不同版本的组件（面板里可以切）

代价是磁盘：解包后约 700 MB。

---

## 3. 仓库结构

```
├── .gitattributes            强制 LF（脚本要在 Linux 上跑）
├── .gitignore                排除构建产物与调试件
├── README.md                 本文件
├── LICENSE
└── kylin-arm64/
    ├── build.sh              235 行  打包：骨架 + 组件 + 单元 + 控制信息 → .run / .deb
    ├── make-bundle.sh        182 行  在联网 arm64 上从系统仓库打离线组件包
    ├── tools/
    │   └── gen-components.sh 301 行  从任意 arm64 sysroot 生成自包含组件包
    ├── verify/
    │   └── verify.sh         217 行  19 项验收用例
    ├── docs/
    │   ├── 麒麟部署手册.md     交付方视角：交付物对比、部署前检查、系统集成、验收清单、升级回滚
    │   ├── 验证记录.md        19 项用例的设计意图与历次缺陷台账
    │   └── 常见问题.md        11 章排错手册，每条都是 现象 → 原因 → 命令 → 验证
    ├── src/
    │   ├── install.sh        923 行  安装器
    │   ├── uninstall.sh       86 行
    │   ├── bin/xiaohuang     命令行入口与分发
    │   ├── lib/
    │   │   ├── common.sh     367 行  日志、路径、清单、端口、错误码
    │   │   └── cmds.sh       603 行  站点/数据库/扩展/模块/FTP/hosts 实现
    │   ├── panel/
    │   │   ├── index.php     528 行  会话、CSRF、15 个 JSON 接口、11 个页面骨架
    │   │   └── assets/       panel.js 855 · panel.css 225 · img/ 三张二维码
    │   ├── templates/        nginx apache php mysql ftp 的配置模板
    │   ├── systemd/          6 个服务单元
    │   ├── www/              默认站点页 + 13 个错误页
    │   └── docs/用户手册.md   597 行，使用方视角
    └── payload/              构建输入：五个组件的 tar.gz（不入库）
```

---

## 4. 命令行

`xiaohuang` 装在 `bin/`，软链到 `/usr/local/bin/`。

```
服务    start  stop  restart  status  info  switch  autostart  verify  repair
站点    site {add,list,del,edit,ssl,ssl-del}
数据库  db {list,create,drop,passwd,import,export,init}
组件    ext {list,enable,disable}     module {list,enable,disable}
FTP     ftp {list,add,del,passwd,port}
其他    port  ports  kill  hosts  log  panel  version  uninstall  help
```

几个设计上的选择：

**`status --json`** 所有只读命令都有 JSON 形态，面板直接消费，不重复实现一遍逻辑。
面板里的每个按钮背后都是 CLI 的一次调用。

**`verify`** 装完时对 15 个文件算 SHA-256 存进 `.integrity`，之后随时能核对。
被改过会明确指出是哪个文件：

```
$ sudo xiaohuang verify
[WARN] 以下文件被改过：
       bin/xiaohuang: FAILED
构建指纹: 202610271304-309ccf74        # 退出码 1
```

**启动前自检** `start` 会先跑 `nginx -t` / `httpd -t` / `php-fpm -t`，配置错在
systemd 之前就被拦下并打印 `[emerg]` 原文；启动后 1 秒再查 `is-active`，进程秒退也算失败，
并自动带出 journal、端口占用、nofile、SELinux 四条线索。

**FTP 用独立 PAM 服务名** `xiaohuang-vsftpd`，不覆盖系统的 `vsftpd`，两者能共存。

---

## 5. 管理面板

`php -S 127.0.0.1:9002` 起的，只监听回环，远程用 `ssh -L 9002:127.0.0.1:9002` 转发。
不挂到 nginx 后面——面板要能重启 nginx，挂在它后面会自己把自己弄断。

| 页面 | 做什么 |
|---|---|
| 概览 | 五个服务状态、一键启停、环境信息、HTTP 自检结果 |
| 网站 | 站点增删改、目录可点击浏览、SSL 证书 |
| 数据库 | 建库删库、改密码、导入导出 |
| 软件管理 | 组件版本切换 |
| PHP 扩展 | 47 个扩展开关，带搜索。改完自动 reload php-fpm |
| Apache 模块 | 118 个模块开关，带搜索。改完先跑 `httpd -t`，失败自动回滚 |
| FTP | 账号增删改、端口 |
| 端口 | 谁占着哪个端口、一键结束进程 |
| 日志 | 7 种日志在线看，可选 5 秒自动刷新 |
| 设置 | 端口、面板密码、开机自启、hosts |
| 关于 | 构建指纹、作者联系方式 |

会话 + CSRF 双校验，密码哈希存 `xiaohuang.ini`（文件权限 600）。
忘了密码不用登录：`sudo xiaohuang panel passwd 新密码`。

---

## 6. 交付物

```
xiaohuang-kylin-arm64_0.0.0.1Beta_arm64.deb     92 MB
xiaohuang-kylin-arm64-0.0.0.1Beta.run           93 MB
```

两个装的是同一套东西，只能装一个（单元名固定，第二个会被拒，退出码 3）。

| | `.deb` | `.run` |
|---|---|---|
| 参数 | 改 `/etc/xiaohuang/install.conf` 后重装 | 命令行全参数 |
| 适合 | 批量铺、内网源、要 `dpkg -l` 可查 | 单机交付、要换目录换端口 |

`.deb` 的依赖只有 `bash (>= 4.4)` 和 `tar`——麒麟最小系统都有。
`curl` 放在 `Recommends`，没有也能装（状态码探测会退回用组件自带的 PHP）。

安装参数：

```
--dir PATH          安装目录，默认 /opt/xiaohuang，只能纯英文绝对路径
--http-port PORT    默认 80，被占自动往上找
--db-port PORT      默认 3306
--ftp-port PORT     默认 21
--with-apache       额外装 Apache
--no-db --no-ftp --no-php   跳过组件
--no-start          只装不起
--no-link           不建 /usr/local/bin/xiaohuang
--supervisor MODE   systemd 或 pidfile
--force             组件起不来也继续
```

安装器做的事：校验路径 → 查冲突 → 建目录 → 部署站点与面板 → 解包组件 →
渲染配置 → 初始化 MariaDB → 注册 6 个单元 → 写清单与 `.integrity` → 启动自检。

---

## 7. 验证

`verify/verify.sh` 19 项，覆盖路径规则、安装幂等、配置渲染、服务可用性、端口切换、
站点增删、面板接口、完整性校验。

```
$ ./verify/verify.sh
结果: 19 通过, 0 失败, 0 跳过
结论: 安装包符合原版说明的两条路径规则，且安装后服务可用
```

路径规则是这批用例的核心：含空格、含中文、相对路径必须被拒绝（退出码 2），
同一路径重复安装必须被拒绝（退出码 3）。

当前构建的实测输出：

```
$ sudo xiaohuang status
Xiao Huang 0.0.0.1Beta (kylin-arm64-1)
安装目录: /opt/xiaohuang
管理方式: systemd   当前 Web: nginx
构建指纹: 202610271304-309ccf74

服务   状态     版本                         端口
nginx    running    Nginx 1.18.0                   80 *
php      running    PHP 7.4.33 (FPM)               9000
mysql    running    MySQL 10.5.23                  3306
ftp      running    FTP vsftpd 3.0.3               21
HTTP 80: 200
PHP     : 200

$ sudo xiaohuang verify
[ OK ] 全部与安装时一致
```

---

## 8. 构建

组件源需要一次准备（在 arm64 环境里，或者 x86 上装 `qemu-user-static` 走 binfmt）：

```bash
sudo debootstrap --arch=arm64 --foreign --variant=minbase --no-check-gpg \
     bullseye /root/arm64 http://deb.debian.org/debian
sudo cp /usr/bin/qemu-aarch64-static /root/arm64/usr/bin/
sudo mount -t proc proc /root/arm64/proc
sudo chroot /root/arm64 /debootstrap/debootstrap --second-stage
# chroot 里 apt-get install --download-only 拉组件，宿主机 dpkg-deb -x 到 /root/sysroot
```

打组件包和安装包：

```bash
./tools/gen-components.sh --sysroot /root/sysroot --out payload   # 生成五个 tar.gz
./build.sh                                                        # 出 .deb 与 .run
```

`build.sh` 检测到 `payload/components/*.tar.gz` 就内置，没有则打成在线安装版
（依赖系统源）。`VERSION` 可用环境变量覆盖，用来出不同版本号的包。

---

## 9. 安装与验收

```bash
sudo dpkg -i xiaohuang-kylin-arm64_0.0.0.1Beta_arm64.deb
sudo xiaohuang start
```

装完打印面板地址和初始密码：

```
管理面板   http://127.0.0.1:9002/
远程访问   ssh -L 9002:127.0.0.1:9002 root@服务器
```

10 条验收命令：

| # | 命令 | 预期 |
|---|---|---|
| 1 | `sudo xiaohuang status` | 头部有版本和构建指纹，服务 running |
| 2 | `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/` | `200` |
| 3 | `curl -s http://127.0.0.1/index.php` | 探针页，PHP 7.4.33 |
| 4 | `sudo xiaohuang verify` | 全部一致，退出码 0 |
| 5 | `ls /opt/xiaohuang/app/Extensions/` | Nginx / php / MySQL / FTP |
| 6 | `sudo xiaohuang db list` | 列出 information_schema 等 |
| 7 | `ss -lnt \| grep -E ':(80\|3306\|21\|9002) '` | 四个都在监听 |
| 8 | `systemctl is-active xiaohuang-panel` | `active` |
| 9 | `sudo xiaohuang autostart` | 四个 enabled |
| 10 | `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9002/` | `200` |

起不来就跑诊断脚本，它一次打九段：systemd 状态、`nginx -t` 真实报错、前台启动报错、
端口占用、目录权限、nofile 限制、SELinux、系统里有没有别的 web 服务、最近日志。

```bash
sudo bash /opt/xiaohuang/xh-diag.sh
```

---

## 10. 边界

**单实例**。单元名固定，一台机器只能跑一套。要并行只能换机器或容器。

**面板只监听回环**。`php -S` 不带 TLS，直接对外等于把 root 级操作暴露在明文上。
远程走 SSH 转发。

**没有 SELinux 策略**。麒麟如果 `getenforce` 返回 `Enforcing`，需要自己给
`/opt/xiaohuang` 打上下文，或者放行相关域。

**PHP 扩展就是包里那 47 个**。redis、imagick、swoole 这些要另外编译，
产物放进 `lib/php/20190902/` 就能被面板识别。

**MariaDB 顶替 MySQL**。10.5.23 与 MySQL 5.7 语法基本兼容，但 `JSON` 类型、
窗口函数的行为有差异。

**卸载不恢复被接管的系统服务**。装的时候如果停用了系统自带的 nginx / httpd / mysqld，
清单写在 `.disabled-system-services` 里，卸载时提示但不自动恢复——避免把客户环境
改回去时出意外。

---

## 11. 文档

- [用户手册](kylin-arm64/src/docs/用户手册.md) — 597 行，安装、配置、日常操作、排错
- [常见问题](kylin-arm64/docs/常见问题.md) — 11 章，现象 → 原因 → 命令 → 验证
- [麒麟部署手册](kylin-arm64/docs/麒麟部署手册.md) — 交付方视角：验收清单、系统集成
- [验证记录](kylin-arm64/docs/验证记录.md) — 19 项用例与历次缺陷台账

---

## 12. 许可

见 [LICENSE](LICENSE)。可自由使用、修改、商用，分发时保留署名与声明。

---

by 小黄 · 15359927763 · QQ 1924053793
