# Xiao Huang — 银河麒麟 ARM64 Web 环境安装包

把 Windows 版 phpStudy V8 的目录布局、组件配置、站点模板、路径规则复刻到
银河麒麟 V10 / aarch64，换成自有品牌。组件全部内置，安装不联网、不读系统仓库。

```
kylin-arm64/
├── build.sh                 构建 .deb 与 .run
├── make-bundle.sh           在联网 arm64 上从系统仓库打离线组件包
├── tools/gen-components.sh  从任意 arm64 sysroot 生成自包含组件包
├── src/                     安装器、命令行、面板、模板、systemd 单元、站点
├── verify/verify.sh         19 项验收用例
└── docs/                    部署手册、验证记录、常见问题、用户手册
```

组件：Nginx 1.18.0 / Apache 2.4.62 / PHP-FPM 7.4.33 / MariaDB 10.5.23 / vsftpd 3.0.3

每个组件自带 `ld-linux-aarch64.so.1` 与完整依赖库（含 libc），启动时用自带 loader，
目标机 glibc 只要 ≥ 2.17。

## 构建

```bash
# 1. 准备 arm64 组件源（一次即可，需要 debootstrap + qemu-user-static）
sudo debootstrap --arch=arm64 --foreign --variant=minbase --no-check-gpg \
     bullseye /root/arm64 http://deb.debian.org/debian
sudo cp /usr/bin/qemu-aarch64-static /root/arm64/usr/bin/
sudo mount -t proc proc /root/arm64/proc
sudo chroot /root/arm64 /debootstrap/debootstrap --second-stage
# chroot 内 apt-get install --download-only <组件>，宿主机把 deb 全部 dpkg-deb -x 到 /root/sysroot

# 2. 生成内置组件 + 打包
./tools/gen-components.sh --sysroot /root/sysroot --out payload
./build.sh
```

产物：

```
dist/xiaohuang-kylin-arm64_0.0.0.1Beta_arm64.deb
dist/xiaohuang-kylin-arm64-0.0.0.1Beta.run
```

## 安装

```bash
sudo dpkg -i xiaohuang-kylin-arm64_0.0.0.1Beta_arm64.deb
sudo xiaohuang start
```

装完打印面板地址与初始密码：

```
管理面板   http://127.0.0.1:9002/
远程访问   ssh -L 9002:127.0.0.1:9002 root@服务器
```

## 文档

- [用户手册](kylin-arm64/src/docs/用户手册.md) — 安装、配置、日常操作、排错
- [常见问题](kylin-arm64/docs/常见问题.md) — 11 章，现象→原因→命令→验证
- [麒麟部署手册](kylin-arm64/docs/麒麟部署手册.md) — 交付方视角：验收清单、系统集成
- [验证记录](kylin-arm64/docs/验证记录.md) — 19 项用例与历次缺陷修复

## 许可

见 [LICENSE](kylin-arm64/LICENSE)。可自由使用、修改、商用，分发时保留署名与声明。

---

by 小黄 · 15359927763 · QQ 1924053793
