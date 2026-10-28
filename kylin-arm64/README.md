# Xiao Huang 0.0.0.2Beta for Kylin ARM64

把 phpStudy V8（Windows 版 `phpstudy_x64_8.1.1.3.exe`）的安装契约——目录布局、组件配置、
站点模板、路径规则——复刻成银河麒麟 V10 / aarch64 的安装包，并换成自有品牌 **Xiao Huang**。
**所有组件已内置在包里**，安装过程不联网、不依赖系统仓库：

| 组件 | 版本 | 来源 |
|---|---|---|
| Nginx | 1.18.0 | Debian 11 (bullseye) arm64 |
| Apache | 2.4.62 | 同上 |
| PHP-FPM + CLI | 7.4.33 | 同上（含 mysqli/pdo_mysql/gd/mbstring/curl/xml/zip/opcache/intl/bcmath/sqlite3） |
| MariaDB（MySQL 协议） | 10.5.23 | 同上 |
| vsftpd（FTP） | 3.0.3 | 同上（含 pam_unix，独立 PAM 服务名） |

每个组件自带 `ld-linux-aarch64.so.1` + 全部依赖库（含 libc），启动时用自带 loader，
目标机 glibc 只要 ≥ 2.17 即可运行（麒麟 V10 SP1 是 2.28，SP2/SP3 是 2.31/2.34，都覆盖）。

## 交付物

```
kylin-arm64/
├── dist/
│   ├── xiaohuang-kylin-arm64_0.0.0.2Beta_arm64.deb   91 MB  组件内置，dpkg 安装
│   └── xiaohuang-kylin-arm64-0.0.0.2Beta.run         93 MB  组件内置，自解压
├── build.sh                       构建 .run 与 .deb（自动带上 payload/components）
├── make-bundle.sh                 在联网 arm64 上从系统仓库做离线组件包（备选）
├── tools/gen-components.sh        从 arm64 sysroot 生成内置组件包
├── verify/verify.sh               按原版说明的规则做验证（19 项用例）
├── payload/components/            内置组件（nginx/php-fpm/apache/mysql/ftp）
├── src/                           安装器、控制台、模板、站点、systemd 单元、面板
└── docs/{麒麟部署手册,验证记录,常见问题}.md
```

## 安装（目标机，离线可用）

.deb：

```bash
sudo dpkg -i xiaohuang-kylin-arm64_0.0.0.2Beta_arm64.deb
sudo xiaohuang start
```

`.run`：

```bash
chmod +x xiaohuang-kylin-arm64-0.0.0.2Beta.run
sudo ./xiaohuang-kylin-arm64-0.0.0.2Beta.run --dir /opt/xiaohuang --with-apache
```

安装器自动：校验路径规则 → 解包内置组件 → 渲染配置 → 初始化 MariaDB → 注册 systemd 单元 →
装 `xiaohuang` 控制台 → 部署面板 → 写清单 → 启动自检。

## 管理面板

装完自带 Web 面板，替代原版的 Qt 界面。以 root 运行 `php -S`，**只监听 127.0.0.1**，
端口默认 9002（被占用自动 +1）：

```
管理面板   : http://127.0.0.1:9002/
面板初始密码 : 安装结束时打印一次，写在 /opt/xiaohuang/xiaohuang.ini 的 PANEL_PASS_HASH
```

远程访问走 SSH 转发（面板不对外监听）：

```bash
ssh -L 9002:127.0.0.1:9002 root@服务器
# 本机浏览器开 http://127.0.0.1:9002/
```

九个页面：概览（服务卡片 + 一键启停）、网站（增删改 + SSL）、数据库（建库/删库/改 root）、
软件管理（组件版本切换）、PHP 扩展（47 个开关）、Apache 模块、FTP（账号 + 端口）、
端口（进程 + 结束）、日志、设置（端口/面板密码/hosts）。

改密码：`xiaohuang panel passwd 新密码` 或面板内「设置 → 面板密码」。

侧栏最后一页是「关于」：左侧打赏（微信支付 / 支付宝收款码），右侧联系方式
（手机 15359927763、QQ 1924053793）与微信二维码。三张码存在
`app/panel/assets/img/`，换图直接替换同名文件即可。

## FTP

内置 vsftpd 3.0.3，装在 `app/Extensions/FTP0.9.60`（沿用原版目录命名）：

```
app/Extensions/FTP0.9.60/
├── bin/vsftpd            包装（自带 loader + lib）
├── libexec/vsftpd.bin
├── lib/                  依赖库（libpam/libcrypt/libselinux/libnsl/libtirpc…）
├── lib/security/         pam_unix.so / pam_deny.so / pam_permit.so
├── etc/vsftpd.conf       渲染后的配置（端口、被动段、白名单）
├── etc/userlist          账号白名单
├── logs/                 vsftpd.log + xferlog
└── empty/                secure_chroot_dir
```

账号是系统用户，home 锁在站点目录（chroot），PAM 走独立服务名 `xiaohuang-vsftpd`：

```bash
xiaohuang ftp list
xiaohuang ftp add ftp_site1 /opt/xiaohuang/app/WWW/site1      # 密码留空自动生成
xiaohuang ftp add ftp_site1 /opt/xiaohuang/app/WWW/site1 Pass12345
xiaohuang ftp passwd ftp_site1 NewPass
xiaohuang ftp del ftp_site1                                   # 只删账号，目录保留
xiaohuang ftp port 2121
```

## 开机自启

安装时默认把 nginx / php / mysql / ftp / 面板都设为开机自启（`systemctl enable`），
Apache 不设（它和 Nginx 共用 HTTP 端口，只能二选一）。

```bash
xiaohuang autostart                 # 看每个服务的 enable 状态
xiaohuang autostart off             # 全部关掉
xiaohuang autostart on              # 全部打开
xiaohuang autostart off nginx       # 只关某一个
```

`xiaohuang switch apache` 会自动把自启切过去（disable 旧的、enable 新的），
否则重启后旧的 Web 服务器会抢回端口。面板「设置 → 开机自启」是同一套开关。

## 控制台

```bash
xiaohuang status [--json]
xiaohuang start|stop|restart [all|nginx|apache|php|mysql|ftp|panel]
xiaohuang switch apache|nginx           # 两个 Web 服务器互斥（同端口）
xiaohuang port nginx 8080

xiaohuang site add example.com /www/example 80
xiaohuang site edit example.com --root /www/example2 --port 8080
xiaohuang site list [--json] | del example.com
xiaohuang site ssl example.com /path/cert.pem /path/key.pem
xiaohuang site ssl-del example.com

xiaohuang db init | passwd 新密码
xiaohuang db list | create 库名 [用户 密码] | drop 库名
xiaohuang db import dump.sql 库名 | export 库名 out.sql

xiaohuang ext list | enable mysqli | disable gd
xiaohuang module list | enable rewrite | disable autoindex     # Apache
xiaohuang ports | kill --port 8080 | kill --pid 1234
xiaohuang hosts add example.com | del example.com

xiaohuang version [list] | use nginx 1.20.1
xiaohuang panel url | passwd 新密码

xiaohuang log mysql -f
xiaohuang repair
xiaohuang uninstall [--purge]
```

## 目录（安装后）

```
/opt/xiaohuang/
├── xiaohuang.ini                清单（端口/版本/root 密码/面板哈希，600）
├── app/Extensions/
│   ├── Nginx1.18.0/             bin/nginx(wrapper) libexec/nginx.bin lib/ conf/ logs/ temp/
│   ├── Apache2.4.62/            bin/httpd libexec/httpd.bin lib/ modules/ conf/
│   ├── php/php7.4.33/           bin/{php,php-fpm} libexec/*.bin lib/php/20190902/ etc/
│   ├── MySQL10.5.23/            bin/{mysqld,mysql,mariadb-install-db} libexec/*.bin lib/ share/ etc/ data/
│   ├── FTP0.9.60/               bin/vsftpd libexec/vsftpd.bin lib/ lib/security/ etc/ logs/
│   ├── ErrorPages/
│   └── tmp/tmp/
├── app/WWW/                     站点根（index.html + index.php 探针 + error/*.html）
├── app/panel/                   管理面板（PHP，php -S 托管）
├── bin/xiaohuang                控制台
├── conf/                        vhost 模板
├── run/ logs/ uninstall.sh
```

## 构建（产出内置组件的包）

在 x86_64 上也能构建 arm64 包：

```bash
# 1) 准备 arm64 组件源（一次即可）
sudo apt-get install -y debootstrap qemu-user-static wget
sudo debootstrap --arch=arm64 --foreign --variant=minbase --no-check-gpg \
     bullseye /root/arm64 http://deb.debian.org/debian
sudo cp /usr/bin/qemu-aarch64-static /root/arm64/usr/bin/
sudo mount -t proc proc /root/arm64/proc
sudo chroot /root/arm64 /debootstrap/debootstrap --second-stage
# chroot 内 apt-get update && apt-get install --download-only <组件>
# 宿主机把 deb 全部 dpkg-deb -x 到 /root/sysroot

# 2) 生成内置组件 + 打包
./tools/gen-components.sh --sysroot /root/sysroot --out payload
./build.sh
```

`build.sh` 检测到 `payload/components/*.tar.gz` 就自动内置；没有则构建为在线安装版。

## 防二改与署名

纯脚本没法做到"绝对改不了"（root 权限在手，什么都能动），能做的是**提高门槛 + 留下痕迹**：

**1. 构建指纹**

每个包 build 时生成唯一 `BUILD_ID`（`202610251520-8efe2315` 这种），写进 `xiaohuang.ini`，
CLI 和面板都显示。别人改了之后重新打包，指纹一定不一样，一比对就知道。

**2. 完整性清单 + verify**

安装完成时对脚本、面板、模板、手册算 SHA-256 存到 `<安装目录>/.integrity`：

```bash
$ xiaohuang verify
[INFO] 校验 15 个文件…
[ OK ] 全部与安装时一致
构建指纹: 202610251520-8efe2315
```

改动后：

```bash
$ xiaohuang verify
[WARN] 以下文件被改过：
       bin/xiaohuang: FAILED
       app/panel/index.php: FAILED
[WARN] 不是你自己改的，就重新装一遍官方包
```

清单只覆盖"装完就该在"的文件，站点目录、`conf/vhosts/`、组件目录不登记——那些本来就该你改。

**3. 署名分散在六处**

去掉署名要同时改这些地方，改完 `verify` 还会全报出来：

```
bin/xiaohuang                    version 输出里的作者行
app/panel/index.php              面板页脚 + 手机/QQ
app/panel/assets/panel.js        关于页文案
systemd/xiaohuang-*.service      Description=Xiao Huang Nginx (by 小黄 · Kylin ARM64)
docs/用户手册.md                  封面 + 尾页
LICENSE                          署名保留条款
```

**4. LICENSE**

允许用、改、商用，但分发必须保留 LICENSE、作者署名、联系方式、BUILD_ID；
改后对外发布要在版本输出、面板页脚、安装包文件名上标注「非官方修改版」。
去掉署名再发或拿去收费不在授权范围内。

## 用户手册

完整手册随包分发，装在 `<安装目录>/docs/用户手册.md`：

```bash
less /opt/xiaohuang/docs/用户手册.md
```

内容：系统要求、端口规划、三种安装方式、面板首次配置、日常操作、12 条常见故障排查、
防火墙端口、升级卸载、命令速查表、退出码表。

## 验证

```bash
sudo ./verify/verify.sh
```

覆盖路径含空格/中文/相对路径被拒（退出码 2）、重复安装被拒（退出码 3）、目录与清单、
13 个错误页、启动、HTTP 200、PHP 探针、改端口、站点增删、停止、卸载、非 aarch64 拦截。

## 与原版差异

- 面板：原版是 Qt5 桌面程序；本版是 **本机 Web 面板**（`127.0.0.1:9002`）+ `xiaohuang` 子命令。
- FTP：原版 FileZilla Server 0.9.60 → vsftpd 3.0.3，目录仍是 `FTP0.9.60`，账号语义一致。
- 组件版本管理：面板「软件管理」列出 `app/Extensions/` 下所有版本并可切换（`xiaohuang version use`），
  不再从官网在线下载。
- 数据库用 MariaDB 10.5（MySQL 协议兼容）。
- Nginx 不生成 `vhosts/Listen.conf`（Apache 语法），端口写在 `server{}` 内。
- Windows 专用 MySQL 参数统一加 `loose-` 前缀。
