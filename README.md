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

本项目的策略:**pre-boot 写入**(initramfs 阶段,nvidia 模块/GSP 之前)写 SS0,重启后一次性验证三件事:
1. vGPU 是否还活着(vGPU 状态在 boot 时建立,**只有重启后才能判断**)
2. FP16 吞吐是否提升
3. 寄存器读回值

## 文件

| 文件 | 说明 |
|---|---|
| `tw_preboot.c` / `tw_preboot` | pre-boot 写入器(静态二进制,可在 kinitramfs 中运行)。/dev/mem 写 SS0,日志同时进控制台和 dmesg(/proc/kmsg)。可选双重 SBR(40HX 完整流程):`/tw_preboot 0x88888888 1` |
| `install-preboot.sh` | 把 `tw_preboot` 装进当前内核 initramfs,钩子插入 `scripts/local-premount`(root 挂载之前)。自动备份原 initrd 为 `.bak` |
| `turing_write.c` / `Makefile` | post-boot 校验内核模块:读 PLM/SS0/SS1 当前值(并可选重写 SS0),确认 pre-boot 写入在 GSP init 后是否保持 |

## 主机操作步骤(Proxmox)

```bash
# 1. 拿到文件(git clone 或从别处拷): tw_preboot(二进制) + install-preboot.sh + turing_write.c + Makefile
cd turing-write
chmod +x install-preboot.sh

# 2. 构建 post-boot 校验模块(需要内核头文件)
sudo apt install -y linux-headers-$(uname -r)
make

# 3. 装入 initramfs(备份自动保留)
sudo ./install-preboot.sh
# 想要 40HX 完整流程(双重 SBR + 写 SS0):
#   sudo SBR=1 ./install-preboot.sh

# 4. 重启(建议开 KVM/串口控制台观察早期启动,能看到 tw_preboot: 行)
sudo reboot
```

## 重启后检查

```bash
# 1. pre-boot 写入日志(来自 /proc/kmsg)
dmesg | grep tw_preboot
#   期望: pre : PLM=0xffffff8f SS0=0x00000000 ...
#         post: SS0=0x88888888 write OK — GSP 将在 init 时消费

# 2. GSP init 之后寄存器是否保持(运行时 sticky 校验,只读不写)
sudo insmod turing_write.ko read_only=1
dmesg | grep turing_write
#   before 行若显示 SS0=0x88888888 → 写入穿过 GSP init 存活

# 3. FP16 bench
./bench_one   # 用你之前的 bench 二进制

# 4. vGPU 存活(这才是真正的判断,boot 时建立的)
nvidia-smi -q | grep -iE -A4 'vgpu|virtualization'
journalctl -u nvidia-vgpud | tail -30
# 有 vGPU 实例的话:直接看 VM 能否正常启动/运行
```

## 结果判定

| 结果 | 含义 | 下一步 |
|---|---|---|
| dmesg write OK + 重启后 SS0 保持 + vGPU 活 + FP16 提升 | **成功**:最小写集成立,且与 vGPU 兼容 | 固化方案(initramfs 钩子已持久;可进一步评估是否写入 SS1 等) |
| write OK + 重启后 SS0 仍 0x0 | GSP init 时清掉了该寄存器 | 试 `SBR=1`(40HX 完整时序);或 GSP 固件层拒绝,到此为止 |
| write OK + vGPU 死 | SS0/SM-speed 域与 vGPU 冲突,互斥结论成立 | `sudo ./install-preboot.sh --remove` + 重启回滚 |
| /dev/mem open/mmap 失败 | STRICT_DEVMEM 或内核配置阻止 | 看错误行;Proxmox 默认 STRICT_DEVMEM=y 但允许 PCI MMIO,若失败需确认 BAR 未被早期占用 |
| 启动失败/黑屏 | pre-boot 写导致 GSP 起不来 | **再重启一次即恢复出厂**(寄存器每次 boot 按固件配置恢复),然后 `--remove` |

## 对比实验:老 turing-unlock 全路径(GRUB 参数,不动 initramfs)

如果主机上还装着 turing-unlock 的模块和固件(之前回滚时可能只去掉了内核参数),可以直接用老方式跑一次"全路径"对照实验(FLR + SEC2 fire + GSP 重启 + WPR2 修改):

```bash
# 先确认模块还在
modinfo turing_unlock | head
cpio -t < /boot/initrd.img-$(uname -r) | grep -i turing   # 本机 initrd 是未压缩 newc cpio,直接 cpio -t

# 加内核参数(唯一 opt-in,模块没参数时什么都不做)
grep -q 'turing_unlock.targets' /etc/default/grub || \
  sudo sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/s/"$/" turing_unlock.targets=all"/' /etc/default/grub
grep GRUB_CMDLINE_LINUX_DEFAULT /etc/default/grub
sudo update-grub && sudo reboot
```

重启后检查:`journalctl -k -b | grep turing_unlock`、vGPU 状态、`./bench_one`。
回滚:把参数删掉再 update-grub + 重启即可:

```bash
sudo sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/s/ turing_unlock.targets=all//' /etc/default/grub
sudo update-grub && sudo reboot
```

注意:这是之前被怀疑破坏 vGPU 的那条重路径,本次重启实验的目的就是在 reboot 级别验证互斥结论;若 GPU 起不来,删参数重启即恢复。

## 安全性与回滚

- 唯一硬件写:`BAR0+0x409664`,一次 32 位写。默认无 SBR/FLR/复位,不打断 GPU。
- `install-preboot.sh` 自动备份原 initrd(`/boot/initrd.img-<ver>.bak`);`--remove` 一键还原钩子。
- **重启即回滚**:该寄存器每次 GSP init 按出厂固件配置恢复。任何异常状态下再重启一次即可。
- 风险:pre-boot 写入若被 GSP 拒绝,最坏情况是本次 boot GPU 行为异常;不会造成持久损坏。

## 免责

仅供对自己硬件有完全了解的研究用途。修改 GPU 硬件寄存器状态可能导致显卡行为异常、驱动报错或 vGPU 功能失效;使用本项目的风险由使用者自行承担。
