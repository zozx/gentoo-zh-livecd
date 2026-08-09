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

BUILD_OUT="$WORK/kernel-output"
OVERLAY="$WORK/gentoo-zh"
PORTAGE_CONTAINER="gentoo-portage-${RANDOM}"

mkdir -p "$BUILD_OUT"

git clone --depth 1 \
  https://github.com/gentoo-zh/overlay.git "$OVERLAY"

docker pull gentoo/stage3:latest
docker pull gentoo/portage:latest

docker create \
  --name "$PORTAGE_CONTAINER" \
  gentoo/portage:latest /bin/true

trap 'docker rm -f "$PORTAGE_CONTAINER" >/dev/null 2>&1 || true' EXIT

docker run --rm \
  --platform linux/amd64 \
  --volumes-from "$PORTAGE_CONTAINER:ro" \
  --mount type=bind,src="$OVERLAY",dst=/var/db/repos/gentoo-zh,readonly \
  --mount type=bind,src="$BUILD_OUT",dst=/output \
  gentoo/stage3:latest \
  /bin/bash -euxc '
    mkdir -p \
      /etc/portage/repos.conf \
      /etc/portage/package.accept_keywords \
      /etc/portage/package.use \
      /etc/portage/package.unmask \
      /etc/kernel

    cat > /etc/portage/repos.conf/gentoo-zh.conf <<EOF
[gentoo-zh]
location = /var/db/repos/gentoo-zh
masters = gentoo
auto-sync = no
EOF

    echo "sys-kernel/gentoo-cjk-kernel-bin ~amd64" \
      > /etc/portage/package.accept_keywords/cjk-kernel

    echo "virtual/dist-kernel::gentoo-zh ~amd64" \
      > /etc/portage/package.accept_keywords/dist-kernel

    echo "sys-kernel/gentoo-cjk-kernel-bin cjk -generic-uki" \
      > /etc/portage/package.use/cjk-kernel
    
    echo "sys-kernel/installkernel dracut" \
      > /etc/portage/package.use/installkernel

    echo "virtual/dist-kernel::gentoo-zh" \
      > /etc/portage/package.unmask/dist-kernel

    cat > /etc/kernel/install.conf <<EOF
layout=compat
initrd_generator=none
uki_generator=none
EOF

    emerge --oneshot --verbose \
      sys-kernel/gentoo-cjk-kernel-bin::gentoo-zh

    KV=$(
      find -L /lib/modules \
        -mindepth 1 -maxdepth 1 -type d \
        -name "*-gentoo-cjk-dist-bin" \
        -printf "%f\n" |
      sort -V |
      tail -1
    )

    test -n "$KV"
    test -f "/usr/src/linux-$KV/arch/x86/boot/bzImage"

    cp "/usr/src/linux-$KV/arch/x86/boot/bzImage" \
      /output/gentoo

    mkdir -p /output/modules
    cp -a "/lib/modules/$KV" /output/modules/
    printf "%s\n" "$KV" > /output/kernel-version
  '

docker rm -f "$PORTAGE_CONTAINER"
trap - EXIT

cleanup

KV=$(<"$BUILD_OUT/kernel-version")

cp "$BUILD_OUT/gentoo" "$WORK/gentoo.new"

LIVE_MODULES="$ROOT/lib/modules"
mkdir -p "$LIVE_MODULES"

find "$LIVE_MODULES" -mindepth 1 -maxdepth 1 \
  -type d -exec rm -rf -- {} +

cp -a "$BUILD_OUT/modules/$KV" "$LIVE_MODULES/"

if [[ -L "$WORK/initramfs/lib" ]]; then
  INIT_MODULES="$WORK/initramfs/usr/lib/modules"
else
  INIT_MODULES="$WORK/initramfs/lib/modules"
fi

rm -rf "$INIT_MODULES"
mkdir -p "$INIT_MODULES"
cp -a "$BUILD_OUT/modules/$KV" "$INIT_MODULES/"

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
