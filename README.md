# turing-write

最小实验:对 TU106 Turing GPU(如 NVIDIA CMP40HX,device id 0x1f0b)**只写 SS0 一个寄存器**(默认 0x88888888),验证 "算力解锁是否只需要 SS0" 这一假设,并确认它与 vGPU 环境是否兼容。

## 背景

NVIDIA 40HX 系列解锁项目的源码分析表明:

| 寄存器 | BAR0 偏移 | 40HX 值 | 作用 |
|---|---|---|---|
| SS0 | 0x409664 | 0x88888888 | **SM_SPEED_SELECT** —— 真正的 FP16 计算速率开关(tensor target full) |
| SS1 | 0x40966c | 0x08 | SM_SPEED_SELECT_1 |
| FECS_PLM | 0x409650 | 0xffffffff | FECS 功能锁打开(是写锁,不是产品身份门) |

参考项目的关键时序结论:**这些功能寄存器 STICKY,运行时不被 GSP 覆盖,但 GSP 只在 init 时消费一次** —— 所以写入必须发生在 GSP init 之前(参考项目在 UEFI 阶段做)。`turing-unlock` 则在 GSP 起来之后还做 FLR/SEC2 fire/GSP 重启/WPR2 修改,被怀疑是它破坏 vGPU 环境的真正原因。

## 方案:老方式 —— deb 安装,内核模块进 initramfs + `targets=all` opt-in

与 turing-unlock 相同的机制,但模块是本项目自己的 `turing_write.ko`(最小路径,无 FLR/fire/GSP 重启/WPR2),打包成 deb,卸载一条命令:

1. 包安装时(postinst):模块装入 `/lib/modules/$(uname -r)/extra/` + depmod,并连同 `load.sh` **拷进 initramfs** 的 `/turing_write/`;
2. 钩子插入 `scripts/local-premount` —— 在 root 文件系统挂载**之前**、任何 nvidia 模块加载**之前**执行 `insmod ... targets=all`;
3. 模块此刻读 PLM/SS0/SS1(此时还是 GSP 前的出厂值)→ 写 SS0 → 读回 → 打日志;
4. 之后 nvidia/GSP 正常初始化,**GSP init 会消费写入值**;
5. 重启后一次性验证:vGPU 是否活着、FP16 吞吐、寄存器读回。

模块带 `targets` 参数(与 turing-unlock 一致):`all` 或逗号分隔 PCI 地址,默认 `all`。

## 文件

| 文件 | 说明 |
|---|---|
| `turing_write.c` / `Makefile` | 实验内核模块:早期写 SS0(带 `targets` opt-in),或 `read_only=1` 只读校验 |
| `build-deb.sh` | 在目标主机上构建 deb:postinst 装模块+initramfs 钩子(自动识别 initrd 格式,备份 `.bak`),postrm 全部还原 |
| `install-module.sh` | 不用 deb 的手动等价方式 |
| `tw_preboot.c` / `tw_preboot` | 备选:pre-boot 写入器静态二进制(/dev/mem 方式),`install-preboot.sh` 安装 |

## 主机操作步骤(Proxmox)

```bash
# 1. 拿到代码
git clone https://github.com/a1092595196/turing-write.git   # 或走 ghfast.top 镜像
cd turing-write

# 2. 编译模块 + 打 deb(都在目标主机上做,针对当前内核)
sudo apt install -y linux-headers-$(uname -r)
make
./build-deb.sh

# 3. 安装(原 initrd 自动备份 .bak)
sudo apt install ./turing-write_0.2_amd64.deb
dpkg -L turing-write        # 看装了哪些文件
sudo reboot
```

## 卸载(deb 方式,一条命令)

```bash
sudo apt remove turing-write && sudo reboot
```
postrm 自动:还原 initramfs(删 `/turing_write/` 和钩子行)、清 `/lib/modules` 里的模块、depmod。

## 重启后检查

```bash
# 1. 早期加载日志(insmod 由 initramfs 的 load.sh 发起,早于 nvidia)
dmesg | grep turing_write
#   期望顺序:
#     turing_write-initramfs: 模块已早期加载 (targets=all)
#     turing_write: GPU xxxx:xx:00.0 dev=0x1f0b targets=all
#     turing_write before: PLM=0xffffff8f SS0=0x00000000 SS1=0x00000000   ← GSP 前的出厂值
#     turing_write post : PLM=0xffffff8f SS0=0x88888888 SS1=0x00000000 write OK

# 2. GSP init 之后寄存器是否保持(运行时 sticky 校验,只读不写)
sudo insmod /lib/modules/$(uname -r)/extra/turing_write.ko read_only=1
dmesg | grep turing_write | tail -3
#   before 行若显示 SS0=0x88888888 → 写入穿过 GSP init 存活

# 3. FP16 bench
./bench_one

# 4. vGPU 存活(真正的判断,boot 时建立的)
nvidia-smi -q | grep -iE -A4 'vgpu|virtualization'
journalctl -u nvidia-vgpud | tail -30
# 有 vGPU 实例的话:直接看 VM 能否正常启动/运行
```

## 结果判定

| 结果 | 含义 | 下一步 |
|---|---|---|
| 早期 write OK + 重启后 SS0 保持 + vGPU 活 + FP16 提升 | **成功**:最小写集成立,且与 vGPU 兼容 | 固化(initramfs 钩子已持久;可进一步评估 SS1) |
| write OK + 重启后 SS0 仍 0x0 | GSP init 时清掉了该寄存器 | 试 40HX 完整时序(SBR 变体);或 GSP 固件层拒绝,到此为止 |
| write OK + vGPU 死 | SS0/SM-speed 域与 vGPU 冲突,互斥结论成立 | `sudo apt remove turing-write` + 重启回滚 |
| initramfs 里 insmod 失败(日志有 "加载失败") | klibc insmod 兼容性问题 | 看具体报错;备选 `tw_preboot` 静态二进制路线 |
| 启动失败/黑屏 | pre-boot 写导致 GSP 起不来 | **再重启一次即恢复出厂**,然后 `sudo apt remove turing-write` |

## 安全性与回滚

- 唯一硬件写:`BAR0+0x409664`,一次 32 位写。无 SBR/FLR/复位,不打断 GPU。
- 安装/卸载都通过 deb:`apt remove turing-write` 一键还原 initramfs + 模块(原 initrd 始终有 `.bak` 兜底)。
- **重启即回滚**:该寄存器每次 GSP init 按出厂固件配置恢复。任何异常状态下再重启一次即可。
- 注意:内核升级会重建 initrd,钩子会丢;若升级内核后仍要实验,`sudo apt install --reinstall turing-write` 重打钩子。
- 风险:pre-boot 写入若被 GSP 拒绝,最坏情况是本次 boot GPU 行为异常;不会造成持久损坏。

## 免责

仅供对自己硬件有完全了解的研究用途。修改 GPU 硬件寄存器状态可能导致显卡行为异常、驱动报错或 vGPU 功能失效;使用本项目的风险由使用者自行承担。
