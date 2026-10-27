/* tw_preboot.c — initramfs 阶段的 pre-boot 写入器(40HX 项目方式的 Linux 等价)
 *
 * 在 nvidia.ko 加载 / GSP init 之前,通过 /dev/mem 直接写 GPU BAR0:
 *   唯一硬件写: BAR0+0x409664 (SS0 / SM_SPEED_SELECT),默认 0x88888888
 * 日志同时打到 控制台 和 /proc/kmsg(启动后 dmesg 可见)。
 *
 * 用法(由 initramfs 钩子调用):
 *   /tw_preboot [值] [sbr]
 *     值   默认 0x88888888,支持 0x 前缀/十六进制/十进制
 *     sbr  可选参数,传任意值(如 1)则写前做双重 SBR(40HX 的 clean 流程)
 *
 * 编译: gcc -static -O2 -o tw_preboot tw_preboot.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdarg.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <dirent.h>

#define REG_PLM_OFF  0x00409650u
#define REG_SS0_OFF  0x00409664u
#define REG_SS1_OFF  0x0040966cu
#define PAGE         0x1000ul

static int kfd = -1;

static void logmsg(const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    fprintf(stdout, "tw_preboot: %s\n", buf);
    fflush(stdout);
    if (kfd < 0)
        kfd = open("/proc/kmsg", O_WRONLY);
    if (kfd >= 0) {
        char kb[600];
        int n = snprintf(kb, sizeof kb, "<7>%s\n", buf);
        ssize_t w = write(kfd, kb, n);
        (void)w;
    }
}

/* 在 /sys/bus/pci 下找 NVIDIA (vendor 0x10de) 的 BAR0 物理地址 */
static const char *find_nvidia(unsigned long long *bar0, unsigned long long *size,
                               char *pci_name_out, size_t outlen)
{
    DIR *d = opendir("/sys/bus/pci/devices");
    struct dirent *e;
    if (!d)
        return NULL;
    while ((e = readdir(d))) {
        char vpath[512], path[512], line[256];
        FILE *f;
        if (e->d_name[0] == '.')
            continue;
        snprintf(vpath, sizeof vpath, "/sys/bus/pci/devices/%s/vendor", e->d_name);
        f = fopen(vpath, "r");
        if (!f)
            continue;
        {
            int v = 0;
            if (fscanf(f, "%x", &v) != 1 || v != 0x10de) {
                fclose(f);
                continue;
            }
        }
        fclose(f);
        snprintf(path, sizeof path, "/sys/bus/pci/devices/%s/resource", e->d_name);
        f = fopen(path, "r");
        if (!f)
            continue;
        if (fgets(line, sizeof line, f)) {
            unsigned long long a, b;
            if (sscanf(line, "%llx %llx", &a, &b) == 2 && b >= a) {
                *bar0 = a;
                *size = b - a + 1;
                snprintf(pci_name_out, outlen, "%s", e->d_name);
                fclose(f);
                closedir(d);
                return pci_name_out;
            }
        }
        fclose(f);
    }
    closedir(d);
    return NULL;
}

/* 通过设备 sysfs 路径的父目录找上游 bridge(做 SBR 用) */
static int find_bridge(const char *pci_name, char *bridge_out, size_t outlen)
{
    char link[512], path[512];
    char *p, *parent;
    ssize_t n;

    snprintf(path, sizeof path, "/sys/bus/pci/devices/%s", pci_name);
    n = readlink(path, link, sizeof link - 1);
    if (n <= 0)
        return -1;
    link[n] = 0;
    /* /sys/devices/pci0000:00/0000:00:01.0/0000:01:00.0
     * 倒数第二段若形如 bus:dev.fn 即为 bridge */
    p = strrchr(link, '/');
    if (!p)
        return -1;
    *p = 0;
    parent = strrchr(link, '/');
    if (!parent)
        return -1;
    parent++;
    if (strlen(parent) != 12 || parent[4] != ':' || parent[7] != ':' || parent[9] != '.')
        return -1;
    snprintf(bridge_out, outlen, "%s", parent);
    return 0;
}

static void sbr_on_bridge(const char *bridge)
{
    char path[512];
    int fd;
    volatile unsigned short *bc;

    snprintf(path, sizeof path, "/sys/bus/pci/devices/%s/config", bridge);
    fd = open(path, O_RDWR);
    if (fd < 0) {
        logmsg("SBR: open bridge config failed: %s", strerror(errno));
        return;
    }
    bc = mmap(NULL, 0x400, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (bc == MAP_FAILED) {
        logmsg("SBR: mmap bridge config failed: %s", strerror(errno));
        close(fd);
        return;
    }
    /* PCI bridge control 寄存器: config offset 0x3E,bit1 = secondary bus reset */
    logmsg("SBR: bridge=%s before BC=0x%04x", bridge, bc[0x3E / 2]);
    bc[0x3E / 2] |= 0x0002;
    usleep(200 * 1000);
    bc[0x3E / 2] &= (unsigned short)~0x0002;
    usleep(200 * 1000);
    logmsg("SBR: done, BC=0x%04x", bc[0x3E / 2]);
    munmap((void *)bc, 0x400);
    close(fd);
}

int main(int argc, char **argv)
{
    unsigned long long bar, size;
    unsigned long base = REG_SS0_OFF & ~(unsigned long)(PAGE - 1); /* 0x409000 */
    unsigned int idx_plm = (REG_PLM_OFF - base) / 4;
    unsigned int idx_ss0 = (REG_SS0_OFF - base) / 4;
    unsigned int idx_ss1 = (REG_SS1_OFF - base) / 4;
    char pci[32], bridge[32];
    const char *name;
    unsigned int val = 0x88888888;
    int do_sbr = (argc > 2);
    int fd;
    volatile unsigned int *p;
    unsigned int ss0_before, ss0_after;

    if (argc > 1)
        val = (unsigned int)strtoul(argv[1], 0, 0);

    name = find_nvidia(&bar, &size, pci, sizeof pci);
    if (!name) {
        logmsg("no NVIDIA GPU with BAR0 found in /sys — aborting (boot continues)");
        return 1;
    }
    logmsg("GPU %s BAR0=0x%llx size=0x%llx target SS0=0x%08x sbr=%d",
           name, bar, size, val, do_sbr);

    if (do_sbr && find_bridge(pci, bridge, sizeof bridge) == 0) {
        /* 40HX 流程: 双重 SBR 建立干净初始状态 */
        sbr_on_bridge(bridge);
        sbr_on_bridge(bridge);
    }

    fd = open("/dev/mem", O_RDWR);
    if (fd < 0 && errno == ENOENT) {
        if (mknod("/dev/mem", S_IFCHR | 0600, makedev(1, 1)) == 0)
            fd = open("/dev/mem", O_RDWR);
    }
    if (fd < 0) {
        logmsg("open /dev/mem failed: %s (STRICT_DEVMEM 应允许 PCI MMIO,检查内核配置)",
               strerror(errno));
        return 1;
    }
    p = mmap(NULL, PAGE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)(bar + base));
    if (p == MAP_FAILED) {
        logmsg("mmap BAR0+0x%lx failed: %s", base, strerror(errno));
        return 1;
    }

    {
        unsigned int plm = p[idx_plm];
        unsigned int ss1 = p[idx_ss1];
        ss0_before = p[idx_ss0];
        logmsg("pre : PLM=0x%08x SS0=0x%08x SS1=0x%08x", plm, ss0_before, ss1);
    }

    p[idx_ss0] = val;
    ss0_after = p[idx_ss0];

    logmsg("post: SS0=0x%08x %s", ss0_after,
           ss0_after == val ? "write OK — GSP 将在 init 时消费"
                            : "DROPPED (写保护?)");
    logmsg("tw_preboot: 完成,继续启动");
    return ss0_after == val ? 0 : 2;
}
