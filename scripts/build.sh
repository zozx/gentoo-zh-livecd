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

echo "==> 3. 掛載 Chroot 目錄..."
mount -t proc proc "${SQUASH_DIR}/proc"
mount --bind /sys "${SQUASH_DIR}/sys"
mount --bind /dev "${SQUASH_DIR}/dev"
mount --bind /dev/pts "${SQUASH_DIR}/dev/pts"
cp /etc/resolv.conf "${SQUASH_DIR}/etc/resolv.conf"

# 定義離場清理掛載點的機制
cleanup() {
    echo "==> 清理 Chroot 掛載點..."
    umount -l "${SQUASH_DIR}/dev/pts" 2>/dev/null || true
    umount -l "${SQUASH_DIR}/dev" 2>/dev/null || true
    umount -l "${SQUASH_DIR}/sys" 2>/dev/null || true
    umount -l "${SQUASH_DIR}/proc" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> 4. 進入 Chroot 替換內核..."
chroot "${SQUASH_DIR}" /bin/bash -s << 'EOF'
set -e
env-update && source /etc/profile

# 1. 啟用 gentoo-zh overlay (內含 gentoo-cjk-kernel-bin)
eselect repository enable gentoo-zh || true
emaint sync -r gentoo-zh

# 2. 強制僅安裝內核 (--nodeps 確保不觸動/升級任何其他 LiveCD 套件)
emerge --nodeps sys-kernel/gentoo-cjk-kernel-bin

# 3. 抓取新安裝的內核版本號
NEW_KVER=$(ls /lib/modules | sort -V | tail -n 1)
echo "新內核版本號: ${NEW_KVER}"

# 4. 重建 initramfs (必須夾帶 liveCD 專用的 dmsquash-live 模組)
dracut --kver "${NEW_KVER}" --force --add "dmsquash-live live" /boot/initramfs-cjk.img

# 5. 清理下載快取與套件庫，避免 SquashFS 體積膨脹
rm -rf /var/cache/distfiles/* /var/db/repos/*
EOF

echo "==> 5. 覆蓋 ISO 開機引導目錄下的內核與 Initramfs..."
NEW_KERNEL=$(ls -t ${SQUASH_DIR}/boot/vmlinuz-* | head -n 1)

# 直接替換 ISO 原有的啟動檔 (Gentoo 預設為 /boot/gentoo 與 /boot/gentoo.igz)
cp -f "${NEW_KERNEL}" "${ISO_DIR}/boot/gentoo"
cp -f "${SQUASH_DIR}/boot/initramfs-cjk.img" "${ISO_DIR}/boot/gentoo.igz"

echo "==> 6. 重新打包 SquashFS..."
rm -f "${ISO_DIR}/image.squashfs"
mksquashfs "${SQUASH_DIR}" "${ISO_DIR}/image.squashfs" -comp xz -b 1M

echo "==> 7. 重新打包雙引導 (Legacy BIOS / UEFI) ISO..."
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

echo "==> [完成] ISO 已生成於：${OUTPUT_DIR}/gentoo-cjk-minimal.iso"
