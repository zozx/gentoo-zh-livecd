#!/bin/bash
set -eo pipefail

WORK_DIR="/tmp/livecd-build"
ISO_DIR="${WORK_DIR}/iso"
SQUASH_DIR="${WORK_DIR}/squashfs"
OUTPUT_DIR="$(pwd)/output"

# 清理舊數據並建立工作目錄
rm -rf "${WORK_DIR}" "${OUTPUT_DIR}"
mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"

echo "==> 1. 取得最新官方 Gentoo Minimal ISO 鏈結..."
MIRROR="https://distfiles.gentoo.org/releases/amd64/autobuilds"
LATEST_ISO_PATH=$(curl -s "${MIRROR}/latest-iso.txt" | grep -v '^#' | grep "install-amd64-minimal" | awk '{print $1}')
ISO_URL="${MIRROR}/${LATEST_ISO_PATH}"

echo "==> 下載 ISO: ${ISO_URL}"
wget -q "${ISO_URL}" -O "${WORK_DIR}/gentoo-base.iso"

echo "==> 2. 解包 ISO 與 SquashFS..."
7z x "${WORK_DIR}/gentoo-base.iso" -o"${ISO_DIR}" > /dev/null
unsquashfs -d "${SQUASH_DIR}" "${ISO_DIR}/image.squashfs"

echo "==> 3. 在 Host 端預先為 LiveCD 補全 Portage 套件庫 (Gentoo Main + gentoo-zh)..."
mkdir -p "${SQUASH_DIR}/var/db/repos/gentoo"
mkdir -p "${SQUASH_DIR}/var/db/repos/gentoo-zh"
mkdir -p "${SQUASH_DIR}/etc/portage/repos.conf"

# 下載官方 Portage Snapshot 並解包
wget -q https://distfiles.gentoo.org/snapshots/portage-latest.tar.xz -O "${WORK_DIR}/portage-latest.tar.xz"
tar -xf "${WORK_DIR}/portage-latest.tar.xz" -C "${SQUASH_DIR}/var/db/repos/gentoo" --strip-components=1

# 直接 Clone gentoo-zh repo (免在 Chroot 內配置 eselect/emaint)
git clone --depth 1 https://github.com/microcai/gentoo-zh.git "${SQUASH_DIR}/var/db/repos/gentoo-zh"

# 寫入 repos.conf 設定
cat << 'EOF' > "${SQUASH_DIR}/etc/portage/repos.conf/repos.conf"
[DEFAULT]
main-repo = gentoo

[gentoo]
location = /var/db/repos/gentoo

[gentoo-zh]
location = /var/db/repos/gentoo-zh
priority = 100
EOF

echo "==> 4. 掛載 Chroot 目錄..."
mount -t proc proc "${SQUASH_DIR}/proc"
mount --bind /sys "${SQUASH_DIR}/sys"
mount --bind /dev "${SQUASH_DIR}/dev"
mount --bind /dev/pts "${SQUASH_DIR}/dev/pts"
cp /etc/resolv.conf "${SQUASH_DIR}/etc/resolv.conf"

cleanup() {
    echo "==> 清理 Chroot 掛載點..."
    umount -l "${SQUASH_DIR}/dev/pts" 2>/dev/null || true
    umount -l "${SQUASH_DIR}/dev" 2>/dev/null || true
    umount -l "${SQUASH_DIR}/sys" 2>/dev/null || true
    umount -l "${SQUASH_DIR}/proc" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> 5. 進入 Chroot 替換內核..."
chroot "${SQUASH_DIR}" /bin/bash -s << 'EOF'
set -e

# 明確匯入 Gentoo 的執行路徑 (解決 command not found)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
env-update && source /etc/profile

echo "==> 開始安裝 gentoo-cjk-kernel-bin..."
# 使用 --nodeps 確保完全不更動 LiveCD 原有的其他套件
emerge --nodeps sys-kernel/gentoo-cjk-kernel-bin

# 抓取新內核版本號
NEW_KVER=$(ls /lib/modules | sort -V | tail -n 1)
echo "新內核版本號: ${NEW_KVER}"

echo "==> 重新生成對應內核的 LiveCD Initramfs..."
dracut --kver "${NEW_KVER}" --force --add "dmsquash-live live" /boot/initramfs-cjk.img

echo "==> 清理套件庫與快取 (控制 ISO 體積)..."
rm -rf /var/cache/distfiles/* /var/db/repos/*
EOF

echo "==> 6. 覆蓋 ISO 開機引導目錄下的內核與 Initramfs..."
NEW_KERNEL=$(ls -t ${SQUASH_DIR}/boot/vmlinuz-* | head -n 1)

cp -f "${NEW_KERNEL}" "${ISO_DIR}/boot/gentoo"
cp -f "${SQUASH_DIR}/boot/initramfs-cjk.img" "${ISO_DIR}/boot/gentoo.igz"

echo "==> 7. 重新打包 SquashFS..."
rm -f "${ISO_DIR}/image.squashfs"
mksquashfs "${SQUASH_DIR}" "${ISO_DIR}/image.squashfs" -comp xz -b 1M

echo "==> 8. 重新打包雙引導 ISO..."
xorriso -as mkisofs \
  -r -V "GENTOO_CJK_LIVECD" \
  -J -joliet-long \
  -b isolinux/isolinux.bin \
  -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img \
  -no-emul-boot \
  -o "${OUTPUT_DIR}/gentoo-cjk-minimal.iso" \
  "${ISO_DIR}"

echo "==> [完成] ISO 已成功生成於：${OUTPUT_DIR}/gentoo-cjk-minimal.iso"
