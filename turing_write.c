/* turing_write.c — 最小实验模块:只写 SS0 (SM_SPEED_SELECT),默认 0x88888888
 *
 * 与 turing-unlock 的区别:
 *   - 不做 FLR / SEC2 fire / GSP 重启 / WPR2 修改
 *   - 不写 PLM / SS1 / XP3G (只读它们作参考)
 *   - 唯一硬件写: BAR0+0x409664 (SS0)
 *
 * 用法:
 *   make
 *   sudo insmod turing_write.ko read_only=1   # post-boot 校验:只读,不写
 *   sudo insmod turing_write.ko               # 写 SS0=0x88888888
 *   sudo insmod turing_write.ko ss0=0         # 写别的值(如重新锁回 0)
 *   dmesg | grep turing_write
 *   sudo rmmod turing_write
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/pci.h>
#include <linux/io.h>
#include <linux/delay.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("a1092595196");
MODULE_DESCRIPTION("Minimal experiment: write SS0 (SM_SPEED_SELECT) only, no FLR/fire/GSP-reboot");

/* SS0 要写的值,默认 tensor target full */
static u32 ss0 = 0x88888888;
module_param(ss0, uint, 0444);
MODULE_PARM_DESC(ss0, "value to write to SS0 (BAR0+0x409664), default 0x88888888");

/* 1 = 只读 PLM/SS0/SS1,不写任何寄存器(post-boot 校验用) */
static u32 read_only;
module_param(read_only, uint, 0444);
MODULE_PARM_DESC(read_only, "1 = read-only dump, no hardware write (post-boot verification)");

/* 只读参考寄存器 (BAR0 偏移) */
#define REG_PLM  0x00409650u
#define REG_SS0  0x00409664u
#define REG_SS1  0x0040966cu

static struct pci_dev *gpu;

static void reg_dump(const char *tag, void __iomem *bar)
{
    pr_info("turing_write %s: PLM=0x%08x SS0=0x%08x SS1=0x%08x\n", tag,
            readl(bar + REG_PLM), readl(bar + REG_SS0), readl(bar + REG_SS1));
}

static int __init turing_write_init(void)
{
    resource_size_t start;
    unsigned long base = 0x409664u & PAGE_MASK;   /* 0x409000 */
    void __iomem *bar;
    u32 before, after;
    int ret = 0;

    /* 找第一块 NVIDIA GPU (CMP40HX: TU106, dev 0x1f0b) */
    gpu = pci_get_device(PCI_VENDOR_ID_NVIDIA, 0, gpu);
    if (!gpu) {
        pr_err("turing_write: no NVIDIA GPU found\n");
        return -ENODEV;
    }
    pr_info("turing_write: GPU %04x:%02x:%02x.%x dev=0x%04x\n",
            pci_domain_nr(gpu->bus), gpu->bus, PCI_SLOT(gpu->devfn), PCI_FUNC(gpu->devfn),
            gpu->device);

    if (!pci_resource_start(gpu, 0)) {
        pr_err("turing_write: BAR0 not present\n");
        ret = -ENXIO;
        goto out_put;
    }

    ret = pci_enable_device(gpu);
    if (ret) {
        pr_err("turing_write: pci_enable_device failed: %d\n", ret);
        goto out_put;
    }

    start = pci_resource_start(gpu, 0);
    /* 只映射 0x409000..0x409FFF 这一页,覆盖 PLM/SS0/SS1 */
    bar = ioremap(start + base, PAGE_SIZE);
    if (!bar) {
        pr_err("turing_write: ioremap failed\n");
        ret = -ENOMEM;
        goto out_dis;
    }

    reg_dump("before", bar);
    before = readl(bar + REG_SS0);

    if (read_only) {
        pr_info("turing_write: read-only mode, 不写寄存器 (SS0 当前值见 before 行)\n");
    } else {
        /* —— 唯一的硬件写: SS0 —— */
        writel(ss0, bar + REG_SS0);
        mdelay(100);
        after = readl(bar + REG_SS0);

        reg_dump("after ", bar);
        if (after == ss0)
            pr_info("turing_write: SS0 write OK (0x%08x -> 0x%08x)\n", before, after);
        else
            pr_warn("turing_write: SS0 DROPPED (before=0x%08x wrote=0x%08x readback=0x%08x) — 写保护或 GSP 覆盖\n",
                    before, ss0, after);
    }

    iounmap(bar);
out_dis:
    pci_disable_device(gpu);
out_put:
    pci_dev_put(gpu);
    return ret;
}

static void __exit turing_write_exit(void)
{
    pr_info("turing_write: removed (硬件寄存器值保持,重启恢复出厂)\n");
}

module_init(turing_write_init);
module_exit(turing_write_exit);
