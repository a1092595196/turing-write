#!/bin/sh
# build-deb.sh — 在目标主机上构建 turing-write deb
# 包内容: 模块 (/lib/modules/$(uname -r)/extra + /usr/share 副本) + 生命周期脚本
#   postinst: 装模块 + depmod + initramfs 早期钩子 (原 initrd 备份 .bak)
#   postrm  : 移除 initramfs 钩子 + 清 /lib/modules 模块 + depmod
# 用法:
#   make
#   ./build-deb.sh
#   sudo apt install ./turing-write_0.2_amd64.deb
#   sudo reboot
# 卸载:
#   sudo apt remove turing-write && sudo reboot

set -e
[ -f turing_write.ko ] || { echo "错误: 先 make 编译出 turing_write.ko"; exit 1; }
[ -x "$(command -v dpkg-deb)" ] || { echo "错误: 需要 dpkg-deb (Debian/Proxmox 自带)"; exit 1; }

VER=0.3
KVER=$(uname -r)
T=turing-write-build
rm -rf "$T"
mkdir -p "$T/DEBIAN" "$T/lib/modules/$KVER/extra" "$T/usr/share/turing-write"
cp turing_write.ko "$T/lib/modules/$KVER/extra/"
cp turing_write.ko "$T/usr/share/turing-write/"

cat > "$T/DEBIAN/control" <<EOF
Package: turing-write
Version: $VER
Architecture: amd64
Maintainer: a1092595196 <a1092595196@localhost>
Section: misc
Priority: optional
Description: 最小 SS0 pre-boot 写入实验模块 (TU106/CMP40HX)
 把 turing_write.ko 装入 /lib/modules,并放入 initramfs(nvidia/GSP 之前加载)。
 默认什么都不做;opt-in 方式与 turing-unlock 相同:GRUB 加
 turing_write.targets=all + update-grub + 重启。
 卸载: apt remove turing-write (自动还原 initramfs 和模块)。
EOF

cat > "$T/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
# turing-write postinst: 装模块 + initramfs 早期钩子
KVER=$(uname -r)
# 解析实际 initrd 路径:优先 grub.cfg 里当前内核条目的 initrd 行,回退默认路径
IMG=/boot/initrd.img-$KVER
for gc in /boot/grub/grub.cfg /boot/efi/EFI/*/grub.cfg; do
    [ -f "$gc" ] || continue
    p=$(awk -v k="vmlinuz-$KVER" 'index($0,k){f=1;next} f && $1=="initrd"{print $2; exit}' "$gc")
    if [ -n "$p" ] && [ -f "$p" ]; then IMG="$p"; break; fi
done
echo "postinst: initrd = $IMG" >&2

mkdir -p "/lib/modules/$KVER/extra"
cp -f /usr/share/turing-write/turing_write.ko "/lib/modules/$KVER/extra/"
depmod -a "$KVER" 2>/dev/null || true

if [ -f "$IMG" ]; then
    M4=$(head -c4 "$IMG" | od -An -tx1 | tr -d ' \n')
    case "$M4" in
      1f8b*) DE="gzip -dc"; RP="gzip -9" ;;
      fd37*) DE="xz -dc"; RP="xz -9" ;;
      425a*) DE="bzip2 -dc"; RP="bzip2 -9" ;;
      28b5*) DE="zstd -dc"; RP="zstd -19" ;;
      3037*) DE="cat"; RP="cat" ;;
      *) echo "postinst: 无法识别 initrd 格式 (magic=$M4),跳过钩子" >&2; exit 0 ;;
    esac
    TMP=$(mktemp -d)
    if $DE "$IMG" | (cd "$TMP" && cpio -idm --quiet 2>/dev/null); then
        mkdir -p "$TMP/turing_write"
        install -m644 /usr/share/turing-write/turing_write.ko "$TMP/turing_write/"
        cat > "$TMP/turing_write/load.sh" <<'LOAD'
#!/bin/sh
# turing_write 早期加载:此刻 nvidia 未加载、GSP 未初始化
# opt-in(老 turing-unlock 方式):内核命令行必须有 turing_write.targets= 才加载
[ -d /sys/bus/pci/devices ] || exit 0
T=""
for a in $(cat /proc/cmdline); do
    case "$a" in
        turing_write.targets=*) T="${a#turing_write.targets=}" ;;
    esac
done
if [ -z "$T" ]; then
    echo "turing_write-initramfs: 无 turing_write.targets= 参数,跳过"
    echo '<7>turing_write-initramfs: 无 turing_write.targets= 参数,跳过' >> /proc/kmsg 2>/dev/null
    exit 0
fi
INS=""
for i in /sbin/insmod /bin/insmod /sbin/modprobe /bin/modprobe; do
    [ -x "$i" ] && INS="$i" && break
done
if [ -z "$INS" ]; then
    echo "turing_write-initramfs: 找不到 insmod/modprobe,跳过"
    echo '<7>turing_write-initramfs: 找不到 insmod/modprobe,跳过' >> /proc/kmsg 2>/dev/null
    exit 1
fi
if "$INS" /turing_write/turing_write.ko "targets=$T" 2>/dev/null; then
    echo "turing_write-initramfs: 模块已早期加载 (targets=$T)"
    echo "<7>turing_write-initramfs: 模块已早期加载 (targets=$T)" >> /proc/kmsg 2>/dev/null
else
    echo "turing_write-initramfs: 加载失败"
    echo '<7>turing_write-initramfs: 加载失败' >> /proc/kmsg 2>/dev/null
    exit 1
fi
LOAD
        chmod 755 "$TMP/turing_write/load.sh"
        TARGET=""
        for f in scripts/local-premount scripts/local; do
            [ -f "$TMP/$f" ] && TARGET="$TMP/$f" && break
        done
        if [ -z "$TARGET" ]; then
            echo "postinst: initramfs 里找不到钩子脚本,跳过" >&2
        else
            grep -q 'turing_write' "$TARGET" 2>/dev/null && \
                grep -v 'turing_write' "$TARGET" > "$TARGET.new" && mv "$TARGET.new" "$TARGET"
            printf '\ntest -x /turing_write/load.sh && /turing_write/load.sh\n' >> "$TARGET"
            (cd "$TMP" && find . | cpio -o -H newc --quiet 2>/dev/null | $RP) > "$IMG.new"
            if [ -s "$IMG.new" ]; then
                mv "$IMG" "$IMG.bak"
                mv "$IMG.new" "$IMG"
                echo "postinst: initramfs 钩子已安装 ($IMG,备份 .bak)"
            else
                echo "postinit: 重打包失败,initrd 未改动" >&2
            fi
        fi
    else
        echo "postinst: 解包 initrd 失败,initrd 未改动" >&2
    fi
    rm -rf "$TMP"
fi
exit 0
POSTINST

cat > "$T/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
# turing-write postrm: 移除 initramfs 钩子 + 清模块
KVER=$(uname -r)
IMG=/boot/initrd.img-$KVER
for gc in /boot/grub/grub.cfg /boot/efi/EFI/*/grub.cfg; do
    [ -f "$gc" ] || continue
    p=$(awk -v k="vmlinuz-$KVER" 'index($0,k){f=1;next} f && $1=="initrd"{print $2; exit}' "$gc")
    if [ -n "$p" ] && [ -f "$p" ]; then IMG="$p"; break; fi
done
if [ -f "$IMG" ]; then
    M4=$(head -c4 "$IMG" | od -An -tx1 | tr -d ' \n')
    case "$M4" in
      1f8b*) DE="gzip -dc"; RP="gzip -9" ;;
      fd37*) DE="xz -dc"; RP="xz -9" ;;
      425a*) DE="bzip2 -dc"; RP="bzip2 -9" ;;
      28b5*) DE="zstd -dc"; RP="zstd -19" ;;
      3037*) DE="cat"; RP="cat" ;;
      *) DE="" ;;
    esac
    if [ -n "$DE" ]; then
        TMP=$(mktemp -d)
        if $DE "$IMG" | (cd "$TMP" && cpio -idm --quiet 2>/dev/null); then
            rm -rf "$TMP/turing_write"
            for f in scripts/local-premount scripts/local; do
                [ -f "$TMP/$f" ] && grep -v 'turing_write' "$TMP/$f" > "$TMP/$f.new" && mv "$TMP/$f.new" "$TMP/$f"
            done
            (cd "$TMP" && find . | cpio -o -H newc --quiet 2>/dev/null | $RP) > "$IMG.new"
            [ -s "$IMG.new" ] && { mv "$IMG" "$IMG.bak"; mv "$IMG.new" "$IMG"; echo "postrm: initramfs 钩子已移除"; }
        fi
        rm -rf "$TMP"
    fi
fi
rm -f "/lib/modules/$KVER/extra/turing_write.ko" 2>/dev/null || true
depmod -a "$KVER" 2>/dev/null || true
exit 0
POSTRM

chmod 755 "$T/DEBIAN/postinst" "$T/DEBIAN/postrm"
dpkg-deb --build "$T" "turing-write_${VER}_amd64.deb"
rm -rf "$T"
echo "生成: $(pwd)/turing-write_${VER}_amd64.deb (针对内核 $KVER)"
echo "安装: sudo apt install ./turing-write_${VER}_amd64.deb && sudo reboot"
echo "卸载: sudo apt remove turing-write && sudo reboot"
