#!/bin/sh
# install-module.sh — 老方式:把 turing_write.ko 放进 initramfs,启动早期(nvidia/GSP 之前)insmod
#
# 做两件事:
#   1) 模块装到 /lib/modules/$(uname -r)/extra/ 并 depmod(用户态也能 insmod)
#   2) 模块 + load.sh 拷进 initramfs 的 /turing_write/,
#      钩子插入 scripts/local-premount(root 挂载前、nvidia 加载前)
#
# 用法:
#   make                      # 先编译
#   sudo ./install-module.sh          # 早期加载 targets=all
#   sudo ./install-module.sh --remove # 移除(含 /lib/modules 里的模块)
# 备份: 原 initrd 保留为 /boot/initrd.img-<ver>.bak

set -e
VER=$(uname -r)
IMG=/boot/initrd.img-$VER
MOD=$(pwd)/turing_write.ko

[ -f "$IMG" ] || { echo "错误: 找不到 $IMG"; exit 1; }

# 检测压缩格式(gzip/xz/bzip2/zstd/未压缩 newc cpio)
MAGIC4=$(head -c4 "$IMG" | od -An -tx1 | tr -d ' \n')
case "$MAGIC4" in
  1f8b*) DECOMP="gzip -dc";  REPACK="gzip -9"  ;;
  fd37*) DECOMP="xz -dc";    REPACK="xz -9"    ;;
  425a*) DECOMP="bzip2 -dc"; REPACK="bzip2 -9" ;;
  28b5*) DECOMP="zstd -dc";  REPACK="zstd -19" ;;
  3037*) DECOMP="cat";       REPACK="cat"      ;;  # 未压缩 newc cpio (magic 070701)
  *) echo "错误: 无法识别 $IMG 格式 (magic=$MAGIC4)"; exit 1 ;;
esac
echo "initrd 格式: $DECOMP"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

if [ "$1" = "--remove" ]; then
    $DECOMP "$IMG" | (cd "$TMP" && cpio -idm --quiet 2>/dev/null)
    rm -rf "$TMP/turing_write"
    for f in scripts/local-premount scripts/local; do
        [ -f "$TMP/$f" ] && grep -v 'turing_write' "$TMP/$f" > "$TMP/$f.new" && mv "$TMP/$f.new" "$TMP/$f"
    done
    (cd "$TMP" && find . | cpio -o -H newc --quiet 2>/dev/null | $REPACK) > "$IMG.new"
    mv "$IMG" "$IMG.bak"; mv "$IMG.new" "$IMG"
    rm -f "/lib/modules/$VER/extra/turing_write.ko" 2>/dev/null || true
    depmod -a "$VER" 2>/dev/null || true
    echo "已移除。原 initrd 在 $IMG.bak"
    exit 0
fi

[ -f "$MOD" ] || { echo "错误: 先 make 编译出 turing_write.ko"; exit 1; }

# --- 1) /lib/modules (用户态 insmod 用) ---
install -Dm644 -t "/lib/modules/$VER/extra" "$MOD"
depmod -a "$VER"
echo "模块已装: /lib/modules/$VER/extra/turing_write.ko"

# --- 2) initramfs ---
$DECOMP "$IMG" | (cd "$TMP" && cpio -idm --quiet 2>/dev/null)
mkdir -p "$TMP/turing_write"
cp "$MOD" "$TMP/turing_write/turing_write.ko"

cat > "$TMP/turing_write/load.sh" <<'EOF'
#!/bin/sh
# turing_write 早期加载:此刻 nvidia 未加载、GSP 未初始化
[ -d /sys/bus/pci/devices ] || exit 0
INS=""
for i in /sbin/insmod /bin/insmod /sbin/modprobe /bin/modprobe; do
    [ -x "$i" ] && INS="$i" && break
done
if [ -z "$INS" ]; then
    echo "turing_write-initramfs: 找不到 insmod/modprobe,跳过"
    echo '<7>turing_write-initramfs: 找不到 insmod/modprobe,跳过' >> /proc/kmsg 2>/dev/null
    exit 1
fi
if "$INS" /turing_write/turing_write.ko targets=all 2>/dev/null; then
    echo "turing_write-initramfs: 模块已早期加载 (targets=all)"
    echo '<7>turing_write-initramfs: 模块已早期加载 (targets=all)' >> /proc/kmsg 2>/dev/null
else
    echo "turing_write-initramfs: 加载失败"
    echo '<7>turing_write-initramfs: 加载失败' >> /proc/kmsg 2>/dev/null
    exit 1
fi
EOF
chmod 755 "$TMP/turing_write/load.sh"

TARGET=""
for f in scripts/local-premount scripts/local; do
    [ -f "$TMP/$f" ] && TARGET="$TMP/$f" && break
done
[ -n "$TARGET" ] || { echo "错误: initramfs 里找不到钩子脚本(kinitramfs 结构不同?)"; exit 1; }

if grep -q 'turing_write' "$TARGET" 2>/dev/null; then
    grep -v 'turing_write' "$TARGET" > "$TARGET.new" && mv "$TARGET.new" "$TARGET"
    echo "替换了旧的 turing_write 钩子"
fi
printf '\ntest -x /turing_write/load.sh && /turing_write/load.sh\n' >> "$TARGET"
echo "钩子已插入 $(basename "$TARGET")"

(cd "$TMP" && find . | cpio -o -H newc --quiet 2>/dev/null | $REPACK) > "$IMG.new"
mv "$IMG" "$IMG.bak"
mv "$IMG.new" "$IMG"
echo "完成: $IMG 已更新(原文件备份为 $IMG.bak)。重启生效。"
echo "启动后: dmesg | grep turing_write ; sudo insmod /lib/modules/$VER/extra/turing_write.ko read_only=1"
echo "回滚:   sudo ./install-module.sh --remove"
