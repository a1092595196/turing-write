# turing-write

最小实验内核模块:对 TU106 Turing GPU(如 NVIDIA CMP40HX,device id 0x1f0b)**只写 SS0 一个寄存器**,测试 "算力解锁是否只需要 SS0=0x88888888" 这一假设。

## 背景

NVIDIA 40HX 系列解锁项目的源码分析表明:

| 寄存器 | BAR0 偏移 | 40HX 值 | 作用 |
|---|---|---|---|
| SS0 | 0x409664 | 0x88888888 | **SM_SPEED_SELECT** —— 真正的 FP16 计算速率开关(tensor target full) |
| SS1 | 0x40966c | 0x08 | SM_SPEED_SELECT_1 |
| FECS_PLM | 0x409650 | 0xffffffff | FECS 功能锁打开(是写锁,不是产品身份门) |

而 `turing-unlock` 项目除了写这些寄存器,还做 FLR、SEC2 fire、GSP 重启、WPR2 修改 —— 这些"重"操作被怀疑是它破坏 vGPU 环境的真正原因,而不是寄存器值本身。

本模块是**最小化对照实验**:

- ✅ 唯一硬件写:`BAR0+0x409664` (SS0),默认 0x88888888
- ❌ 无 FLR / 无 SEC2 fire / 无 GSP 重启 / 无 WPR2 修改 / 不写 PLM/SS1
- 读 PLM/SS0/SS1 前后值作诊断

## 构建与运行

需要当前内核头文件(Debian/Proxmox:`sudo apt install linux-headers-$(uname -r) build-essential`)。

```bash
make
sudo insmod turing_write.ko            # 写 SS0=0x88888888
dmesg | grep turing_write
```

写其他值:

```bash
sudo rmmod turing_write
sudo insmod turing_write.ko ss0=0      # 例如写回 0
```

## 预期输出

```
turing_write: GPU 0000:01:00.0 dev=0x1f0b
turing_write before: PLM=0xffffff8f SS0=0x00000000 SS1=0x00000000
turing_write after : PLM=0xffffff8f SS0=0x88888888 SS1=0x00000000
turing_write: SS0 write OK (0x00000000 -> 0x88888888)
```

`before` 行应为出厂态(PLM=0xffffff8f, SS0=0);若不同,说明之前有解锁残留。

## 结果判定

| 结果 | 含义 | 下一步 |
|---|---|---|
| SS0 写入成功 + vGPU 存活 + FP16 吞吐提升 | 最小写集成立 | 验证重启持久性(参考项目注释:寄存器 STICKY 但 GSP 只在 init 时消费一次,重启后可能需要重写) |
| SS0 写入成功 + vGPU 存活 + FP16 无变化 | 运行时写被 GSP init 时缓存的判定覆盖 | 改为 initramfs 阶段(GSP init 之前)写入 |
| SS0 DROPPED(读回值不变) | 运行时写保护 / 被 GSP 拉回 | 同上,必须 pre-boot 写入 |
| SS0 写入成功 + vGPU 失效 | SS0/SM-speed 域与 vGPU 冲突 | 重启回滚,互斥结论成立 |

vGPU 存活检查:

```bash
nvidia-smi -q | grep -iE -A4 'vgpu|virtualization'
journalctl -u nvidia-vgpud --since "5 min ago" | tail -20
```

## 安全性与回滚

- 模块只映射 BAR0 的 `0x409000..0x409FFF` 一页,只写 1 个 32 位寄存器。
- 不做任何会中断 GPU 的操作(无 FLR/复位),运行中写后 GPU 继续工作。
- **重启即回滚**:该寄存器在 GSP 初始化时按出厂固件配置恢复(40HX 参考项目:STICKY, not GSP-covered at runtime, consumed ONCE at GSP init)。
- 若写入后 vGPU 环境异常,直接重启主机即可恢复。

## 文件

- `turing_write.c` — 实验模块源码
- `Makefile` — 内核模块构建

## 免责

仅供对自己硬件有完全了解的研究用途。修改 GPU 硬件寄存器状态可能导致显卡行为异常、驱动报错或 vGPU 功能失效;使用本项目的风险由使用者自行承担。
