#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }

OUT_DIR=$(realpath -m "${1:-dist}")
WORK=$(mktemp -d /tmp/gentoo-cjk-iso.XXXXXX)
ROOT="$WORK/root"
BASE="https://distfiles.gentoo.org/releases/amd64/autobuilds/current-install-amd64-minimal"

cleanup() {
  mountpoint -q "$ROOT/dev"  && umount -R "$ROOT/dev"  || true
  mountpoint -q "$ROOT/proc" && umount "$ROOT/proc"    || true
  mountpoint -q "$ROOT/sys"  && umount "$ROOT/sys"     || true
}
trap cleanup EXIT

mkdir -p "$OUT_DIR"
cd "$WORK"

curl -fsSLO "$BASE/latest-install-amd64-minimal.txt"
ISO=$(awk '/^install-amd64-minimal-.*\.iso / {print $1; exit}' \
  latest-install-amd64-minimal.txt)

curl -fLO "$BASE/$ISO"
curl -fLO "$BASE/$ISO.sha256"
grep -E "^[0-9a-fA-F]{64}  ${ISO}$" "$ISO.sha256" | sha256sum -c -

xorriso -osirrox on -indev "$ISO" \
  -extract /image.squashfs image.squashfs \
  -extract /boot/gentoo gentoo.old \
  -extract /boot/gentoo.igz gentoo.igz.old

unsquashfs -d "$ROOT" image.squashfs

git clone --depth 1 https://github.com/gentoo-zh/overlay.git \
  "$ROOT/var/db/repos/gentoo-zh"

mkdir -p "$ROOT/etc/portage/repos.conf" \
  "$ROOT/etc/portage/package.accept_keywords" \
  "$ROOT/etc/portage/package.use" \
  "$ROOT/etc/kernel"

printf '%s\n' \
  '[gentoo-zh]' \
  'location = /var/db/repos/gentoo-zh' \
  'masters = gentoo' \
  'auto-sync = no' \
  > "$ROOT/etc/portage/repos.conf/gentoo-zh.conf"

echo 'sys-kernel/gentoo-cjk-kernel-bin ~amd64' \
  > "$ROOT/etc/portage/package.accept_keywords/cjk-kernel"

echo 'sys-kernel/gentoo-cjk-kernel-bin cjk -generic-uki' \
  > "$ROOT/etc/portage/package.use/cjk-kernel"

printf '%s\n' 'layout=compat' 'initrd_generator=none' \
  'uki_generator=none' > "$ROOT/etc/kernel/install.conf"

cp -L /etc/resolv.conf "$ROOT/etc/resolv.conf"
mount --rbind /dev "$ROOT/dev"
mount --make-rslave "$ROOT/dev"
mount -t proc proc "$ROOT/proc"
mount -t sysfs sys "$ROOT/sys"

chroot "$ROOT" /bin/bash -euxc '
  emerge-webrsync
  emerge --oneshot sys-kernel/gentoo-cjk-kernel-bin::gentoo-zh
'

cleanup

KV=$(find -L "$ROOT/lib/modules" -mindepth 1 -maxdepth 1 \
  -type d -name '*-gentoo-cjk-dist-bin' -printf '%f\n' | sort -V | tail -1)

[[ -n $KV ]] || { echo "CJK kernel was not installed"; exit 1; }

cp "$ROOT/usr/src/linux-$KV/arch/x86/boot/bzImage" gentoo.new


cp -a "$ROOT/lib/modules/$KV" initramfs/lib/modules/


mksquashfs "$ROOT" image.squashfs.new \
  -noappend -no-progress -comp xz -b 1M


OUTPUT="$OUT_DIR/gentoo-cjk-minimal-${KV}.iso"

xorriso -indev "$ISO" -outdev "$OUTPUT" \
  -boot_image any replay \
  -overwrite on \
  -map gentoo.new /boot/gentoo \
  -map gentoo.igz.new /boot/gentoo.igz \
  -map image.squashfs.new /image.squashfs \
  -commit

cd "$OUT_DIR"
sha256sum "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256"
