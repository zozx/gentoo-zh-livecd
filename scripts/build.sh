#!/bin/bash
set -eo pipefail

WORK_DIR="/tmp/livecd-build"
ISO_DIR="${WORK_DIR}/iso"
SQUASH_DIR="${WORK_DIR}/squashfs"
OUTPUT_DIR="$(pwd)/output"

# Clean up old data and create working directories
rm -rf "${WORK_DIR}" "${OUTPUT_DIR}"
mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"

echo "==> 1. Fetching latest Gentoo Minimal ISO and Stage3 URLs..."
MIRROR="https://distfiles.gentoo.org/releases/amd64/autobuilds"

LATEST_ISO_PATH=$(curl -s "${MIRROR}/latest-iso.txt" | grep -v '^#' | grep "install-amd64-minimal" | awk '{print $1}')
wget -q "${MIRROR}/${LATEST_ISO_PATH}" -O "${WORK_DIR}/gentoo-base.iso"

LATEST_STAGE3_PATH=$(curl -s "${MIRROR}/latest-stage3-amd64-openrc.txt" | grep -v '^#' | head -n 1 | awk '{print $1}')
wget -q "${MIRROR}/${LATEST_STAGE3_PATH}" -O "${WORK_DIR}/stage3.tar.xz"

echo "==> 2. Extracting ISO and SquashFS..."
7z x "${WORK_DIR}/gentoo-base.iso" -o"${ISO_DIR}" > /dev/null
unsquashfs -d "${SQUASH_DIR}" "${ISO_DIR}/image.squashfs"

echo "==> 3. Extracting emerge, env-update, and Portage management tools from Stage3..."
# Extract emerge, env-update, emaint, and related core tools/configs from Stage3
tar -xf "${WORK_DIR}/stage3.tar.xz" -C "${SQUASH_DIR}" \
    ./usr/bin/emerge* \
    ./usr/sbin/env-update \
    ./usr/sbin/emaint \
    ./usr/sbin/etc-update \
    ./usr/sbin/dispatch-conf \
    ./usr/lib/python* \
    ./usr/lib/portage \
    ./etc/portage \
    ./etc/env.d \
    ./var/db/pkg

echo "==> 4. Downloading and installing Portage tree (/var/db/repos/gentoo)..."
mkdir -p "${SQUASH_DIR}/var/db/repos/gentoo"
wget -q https://distfiles.gentoo.org/snapshots/portage-latest.tar.xz -O "${WORK_DIR}/portage-latest.tar.xz"
tar -xf "${WORK_DIR}/portage-latest.tar.xz" -C "${SQUASH_DIR}/var/db/repos/gentoo" --strip-components=1

echo "==> 5. Fetching gentoo-cjk-kernel binary and modules..."
RELEASE_JSON=$(curl -s https://api.github.com/repos/microcai/gentoo-cjk-kernel/releases/latest)

VMLINUZ_URL=$(echo "${RELEASE_JSON}" | grep -oP '"browser_download_url": "\K[^"]*vmlinuz[^"]*' | head -n 1)
MODULES_URL=$(echo "${RELEASE_JSON}" | grep -oP '"browser_download_url": "\K[^"]*modules[^"]*' | head -n 1)

wget -q "${VMLINUZ_URL}" -O "${WORK_DIR}/vmlinuz-cjk"
wget -q "${MODULES_URL}" -O "${WORK_DIR}/modules-cjk.tar.xz"

# Replace kernel modules
rm -rf "${SQUASH_DIR}/lib/modules/*"
mkdir -p "${SQUASH_DIR}/lib/modules"
tar -xf "${WORK_DIR}/modules-cjk.tar.xz" -C "${SQUASH_DIR}/lib/modules/"

NEW_KVER=$(ls "${SQUASH_DIR}/lib/modules" | head -n 1)
echo "New CJK Kernel Version: ${NEW_KVER}"

# Copy kernel binary
cp -f "${WORK_DIR}/vmlinuz-cjk" "${SQUASH_DIR}/boot/vmlinuz-${NEW_KVER}"
cp -f "${WORK_DIR}/vmlinuz-cjk" "${ISO_DIR}/boot/gentoo"

echo "==> 6. Regenerating Initramfs corresponding to the new kernel..."
mount -t proc proc "${SQUASH_DIR}/proc"
mount --bind /sys "${SQUASH_DIR}/sys"
mount --bind /dev "${SQUASH_DIR}/dev"

cleanup() {
    echo "==> Cleaning up mount points..."
    umount -l "${SQUASH_DIR}/dev" 2>/dev/null || true
    umount -l "${SQUASH_DIR}/sys" 2>/dev/null || true
    umount -l "${SQUASH_DIR}/proc" 2>/dev/null || true
}
trap cleanup EXIT

dracut --sysroot "${SQUASH_DIR}" \
       --kver "${NEW_KVER}" \
       --force \
       --add "dmsquash-live live" \
       "${ISO_DIR}/boot/gentoo.igz"

echo "==> 7. Repacking SquashFS..."
rm -f "${ISO_DIR}/image.squashfs"
mksquashfs "${SQUASH_DIR}" "${ISO_DIR}/image.squashfs" -comp xz -b 1M

echo "==> 8. Repacking ISO..."
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

echo "==> [Complete] ISO successfully generated at: ${OUTPUT_DIR}/gentoo-cjk-minimal.iso"
