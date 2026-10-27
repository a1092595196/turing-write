#!/bin/sh
# install-preboot.sh — 把 tw_preboot 装进当前内核的 initramfs (Proxmox/kinitramfs)
# 钩子插入 scripts/local-premount(在 root 挂载之前、任何 nvidia 模块加载之前)
#
# 用法:
#   ./install-preboot.sh            # 写 SS0=0x88888888,无 SBR
#   SBR=1 ./install-preboot.sh      # 写前双重 SBR(40HX 完整流程)
#
# 卸载: ./install-preboot.sh --remove
# 备份: 原 initrd 保留为 /boot/initrd.img-<ver>.bak

set -e
VER=$(uname -r)
IMG=/boot/initrd.img-$VER
HOOK_LINE='test -x /tw_preboot && /tw_preboot 0x88888888'

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
echo "检测到格式: $DECOMP"

if [ "$1" = "--remove" ]; then
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    $DECOMP "$IMG" | (cd "$TMP" && cpio -idm --quiet 2>/dev/null)
    for f in scripts/local-premount scripts/local; do
        [ -f "$TMP/$f" ] && grep -v tw_preboot "$TMP/$f" > "$TMP/$f.new" && mv "$TMP/$f.new" "$TMP/$f"
    done
    rm -f "$TMP/tw_preboot"
    (cd "$TMP" && find . | cpio -o -H newc --quiet 2>/dev/null | $REPACK) > "$IMG.new"
    mv "$IMG" "$IMG.bak"; mv "$IMG.new" "$IMG"
    echo "已移除钩子。原文件在 $IMG.bak"
    exit 0
fi

[ -x ./tw_preboot ] || { echo "错误: 本目录需要 tw_preboot 静态二进制"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
$DECOMP "$IMG" | (cd "$TMP" && cpio -idm --quiet 2>/dev/null)

cp ./tw_preboot "$TMP/tw_preboot"
chmod 755 "$TMP/tw_preboot"

# 选钩子位置: 优先 local-premount,退而 local
TARGET=""
for f in scripts/local-premount scripts/local; do
    if [ -f "$TMP/$f" ]; then TARGET="$TMP/$f"; break; fi
done
[ -n "$TARGET" ] || { echo "错误: initramfs 里找不到 $TARGET 脚本(kinitramfs 结构不同?)"; exit 1; }

# SBR 模式: 通过钩子里追加参数实现
if [ "${SBR:-0}" = "1" ]; then
    HOOK_LINE='test -x /tw_preboot && /tw_preboot 0x88888888 1'
fi

if grep -q tw_preboot "$TARGET" 2>/dev/null; then
    # 已存在则先移除旧行(允许切换 SBR 模式)
    grep -v tw_preboot "$TARGET" > "$TARGET.new" && mv "$TARGET.new" "$TARGET"
    echo "替换了旧的 tw_preboot 钩子"
fi
printf '\n%s\n' "$HOOK_LINE" >> "$TARGET"
echo "钩子已插入 $(basename "$TARGET"):"
grep tw_preboot "$TARGET"

(cd "$TMP" && find . | cpio -o -H newc --quiet 2>/dev/null | gzip -9) > "$IMG.new"
mv "$IMG" "$IMG.bak"
mv "$IMG.new" "$IMG"
echo "完成: $IMG 已更新(原文件备份为 $IMG.bak)。重启生效。"
echo "启动后检查: dmesg | grep tw_preboot ; sudo insmod turing_write.ko (读回寄存器)"
