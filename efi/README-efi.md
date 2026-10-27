# NVPermissiveEFI — CMP40HX UEFI 解锁方案(与 vGPU 共存目标)

来源: PZH1gdmu/CMP40HX-Unlock 仓库根目录的 NVPermissiveEFI(独立于 windows-v2.5 的 Go 工具链,
C/EDK2 风格 UEFI 应用, TU106 core 为本地 `src/core_40hx.c`)。

## 原理与时机

- 它是 EFI **应用**(不是驱动):通过 UEFI `LocateHandleBuffer` 枚举 PCI,
  找 `10de:1f0b`(CMP40HX),读 BAR0/BOOT0,加载内嵌的 TU106 core ELF,执行解锁。
- **所有写操作发生在 UEFI 阶段,早于内核/任何 nvidia 驱动**:
  此时 GSP 未初始化、host 驱动未加载、vGPU 会话不存在——
  这正是参考项目在 Windows 上的做法(每次开机先跑解锁画面,再进系统)。
- 之前 turing-unlock 破坏 vGPU 的冲突面(运行时的 FLR / SEC2 fire / GSP 重启 / WPR2)
  在本方案里**全部不存在**。

## 解锁序列(来自 src/core_40hx.c)

| 寄存器 | 偏移 | 写入值 | 含义 |
|---|---|---|---|
| XP3G_PLM | 0x8E1B0 | 0xFFFFFFFF | 算力解锁(已验证) |
| XVE_OVR | 0x8872C | 0x00000006 | PCIe Gen2(已验证) |
| FECS_PLM | 0x409650 | 0xFFFFFFFF | FECS 特征锁 |
| SS0 | 0x409664 | 0x88888888 | SM 速度选择(FP16 关键) |
| SS1 | 0x40966C | 0x00000008 | SM 速度选择 1 |
| XVE_08610 | 0x88610 | 0x00001001 | 2070 对齐 sticky 寄存器 |
| FECS consumer-chain | 0x409500/0x40960C/0x409610/0x409614 | 0xFFFFFFFF | 疑似 GSP 初始化时一次性消费 |

两种模式:
- **compute**:写上面全套 + **1 次 SBR**(PCI 二级总线复位,SBR 会清 PCI 端点状态,
  寄存器在 SBR 后仍需保持——core 的设计就是写一次后靠 GSP 初始化时消费)。
- **full**:compute(SBR)→ graphics(SBR,重写 SS0/SS1 + PDISP 探测写)→ gr-reset(SBR)→ gr-acr(最终提交,无 SBR)。
  共 **3 次 SBR**,与 Windows 完整解锁对齐。
- 默认(无 LoadOptions)= **inspect 只读**,零写入,可用 UEFI 手动引导验证 GPU 可读性。

> 注: SBR 发生在 UEFI 阶段,等价于固件上电时对 GPU 的复位,host 侧无驱动在场,对 vGPU 无运行期冲突。
> 若 compute 档验证通过且要 50 TFLOPS 全速,再试 full 档。

## 构建(本目录内, 任意 x86-64 Linux, 只需 gcc/binutils/python3)

```bash
cd efi
make clean && make                          # → build/NVPermissiveEFI.efi (inspect 默认)
make clean && make AUTO=REQUEST_COMPUTE     # → build/NVPermissiveEFI-COMPUTE.efi
make clean && make AUTO=REQUEST_FULL        # → build/NVPermissiveEFI-FULL.efi
```

`AUTO=` 是本仓库加的编译期开关(上游没有):从 GRUB `exec` 调用时没有 LoadOptions,
上游会退回 inspect 只读;加了 `AUTO=REQUEST_xxx` 后直接自动执行对应模式,无需 KVM 按键。
三个 .efi 已随仓库提交(2026-10 构建),一般无需重编。

## 安装(在 PVE 主机上, root)

```bash
cd /root/turing-write
git pull
sudo sh efi/install-efi.sh
```

脚本做三件事:
1. 三个 .efi → `/boot/efi/EFI/UNLOCK/`
2. 生成 `/etc/grub.d/40-cmp40hx`(自动从 grub.cfg 抽取 PVE 原条目),新增三个菜单项:
   - `PVE + CMP40HX UNLOCK (inspect, ...)` ← 第一次先选这个:只读,零风险
   - `PVE + CMP40HX UNLOCK (compute, ...)` ← 确认链路 OK 后选这个
   - `PVE + CMP40HX UNLOCK (full, ...)`
   每个条目 = `search` 找 ESP → `exec /EFI/UNLOCK/NVPermissiveEFI-*.efi` → 恢复 root → 原样启 PVE
3. `update-grub`

**前置**: 主机 UEFI 启动(已确认); Secure Boot 必须关闭
(`mokutil --sb-state` 检查, 开启时脚本会直接拒绝)。

## 重启后验证(KVM 控制台)

选 compute 条目后,引导 PVE 前会出现解锁画面(几秒):
- `BOOT0=0x...`、`40HX: full set written (...)`、`UNLOCK SEQUENCE COMPLETED`、
  等 60 秒按键后自动继续进 PVE
- 进系统后:
```bash
dmesg | grep -iE 'nvidia|npu' | head -30
journalctl -u nvidia-vgpud | tail -20          # vGPU 服务存活?
nvidia-smi -q | grep -iE 'product|vgpu'        # 卡识别 + vGPU 模式
# FP16 实测: 用之前 turing-write 的 bench_one
```
判定: FP16 算力上来(≈50 TFLOPS 级)且 `nvidia-vgpud` 正常、vGPU 可分配 = 共存成功。

## 切换 / 回滚

- **不改 GRUB 菜单即可切换**: 选原 PVE 条目 = 不解锁(工厂状态, 寄存器由 GSP 每次启动重新初始化)
- **设默认解锁项**(验证成功后):
  ```bash
  echo "GRUB_DEFAULT='PVE + CMP40HX UNLOCK (compute, 最小解锁: 全套寄存器 + 1 次 SBR)'" >> /etc/default/grub
  sudo update-grub
  ```
- **完全卸载**:
  ```bash
  sudo sh efi/uninstall-efi.sh
  ```

## 与 turing-write(initramfs 模块)的关系

两者写的寄存器相同,可共存但**建议做对照实验时只开一个**:
若 `GRUB_CMDLINE_LINUX_DEFAULT` 里已有 `turing_write.targets=all`,
它对所有菜单项(含解锁条目)生效 → 双重写入。实验期间建议先移除该参数
(`sudo sed -i '/turing_write.targets/d' /etc/default/grub && sudo update-grub`),
让 EFI 路线单独验证。
