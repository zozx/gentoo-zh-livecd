#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

[[ $EUID -eq 0 ]] || {
  echo "This script must be run as root." >&2
  exit 1
}

REQUIRED_COMMANDS=(
  awk
  cpio
  curl
  docker
  find
  git
  gzip
  mksquashfs
  sha256sum
  sort
  unmkinitramfs
  unsquashfs
  xorriso
  xz
  zstd
)

for COMMAND_NAME in "${REQUIRED_COMMANDS[@]}"; do
  command -v "$COMMAND_NAME" >/dev/null 2>&1 || {
    echo "Missing command: $COMMAND_NAME" >&2
    exit 1
  }
done

OUT_DIR=$(realpath -m "${1:-$PWD/dist}")
WORK=$(mktemp -d /tmp/gentoo-cjk-iso.XXXXXX)

ROOT="$WORK/live-root"
BUILD_OUT="$WORK/kernel-output"
OVERLAY="$WORK/gentoo-zh"

GENTOO_ISO_BASE="${GENTOO_ISO_BASE:-https://distfiles.gentoo.org/releases/amd64/autobuilds/current-install-amd64-minimal}"
STAGE3_IMAGE="${STAGE3_IMAGE:-gentoo/stage3:latest}"
PORTAGE_IMAGE="${PORTAGE_IMAGE:-gentoo/portage:latest}"

PORTAGE_CONTAINER=""

cleanup() {
  local exit_code=$?
  trap - EXIT

  if [[ -n "$PORTAGE_CONTAINER" ]]; then
    docker rm -f "$PORTAGE_CONTAINER" >/dev/null 2>&1 || true
  fi

  if [[ "${KEEP_WORK:-0}" == "1" ]]; then
    echo "Work directory: $WORK"
  elif [[ -n "$WORK" && "$WORK" == /tmp/gentoo-cjk-iso.* ]]; then
    rm -rf -- "$WORK"
  fi

  exit "$exit_code"
}

trap cleanup EXIT

download() {
  local url=$1
  local destination=$2

  url=${url//$'\r'/}
  url=${url//$'\n'/}

  [[ "$url" == https://* &&
     "$url" != *' '* &&
     "$url" != *$'\t'* ]] || {
    printf 'Invalid download URL: <%q>\n' "$url" >&2
    exit 1
  }

  echo "Downloading: $url"

  curl \
    --fail \
    --location \
    --retry 5 \
    --retry-delay 5 \
    --show-error \
    --progress-bar \
    --output "$destination" \
    --url "$url"
}

GENTOO_ISO_BASE=${GENTOO_ISO_BASE//$'\r'/}
GENTOO_ISO_BASE=${GENTOO_ISO_BASE//$'\n'/}
GENTOO_ISO_BASE=${GENTOO_ISO_BASE%/}

[[ "$GENTOO_ISO_BASE" == https://* &&
   "$GENTOO_ISO_BASE" != *' '* &&
   "$GENTOO_ISO_BASE" != *$'\t'* ]] || {
  printf 'Invalid GENTOO_ISO_BASE: <%q>\n' "$GENTOO_ISO_BASE" >&2
  exit 1
}

mkdir -p "$OUT_DIR" "$BUILD_OUT"

LATEST_FILE="$WORK/latest-install-amd64-minimal.txt"

download \
  "$GENTOO_ISO_BASE/latest-install-amd64-minimal.txt" \
  "$LATEST_FILE"

ISO_NAME=$(
  awk '
    /^install-amd64-minimal-[0-9]+T[0-9]+Z\.iso[[:space:]]/ {
      print $1
      exit
    }
  ' "$LATEST_FILE"
)

ISO_NAME=${ISO_NAME//$'\r'/}
ISO_NAME=${ISO_NAME//$'\n'/}

[[ "$ISO_NAME" =~ ^install-amd64-minimal-[0-9]{8}T[0-9]{6}Z\.iso$ ]] || {
  echo "Unable to determine the current Minimal ISO filename." >&2
  exit 1
}

ISO_PATH="$WORK/$ISO_NAME"
ISO_SHA256_FILE="$WORK/$ISO_NAME.sha256"

download \
  "$GENTOO_ISO_BASE/$ISO_NAME" \
  "$ISO_PATH"

download \
  "$GENTOO_ISO_BASE/$ISO_NAME.sha256" \
  "$ISO_SHA256_FILE"

ISO_SHA256=$(
  awk -v filename="$ISO_NAME" '
    length($1) == 64 && $2 == filename {
      print $1
      exit
    }
  ' "$ISO_SHA256_FILE"
)

[[ "$ISO_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || {
  echo "Unable to read the ISO SHA256 checksum." >&2
  exit 1
}

printf '%s  %s\n' \
  "$ISO_SHA256" \
  "$ISO_NAME" \
  > "$WORK/SHA256SUMS"

(
  cd "$WORK"
  sha256sum -c SHA256SUMS
)

ISO_TREE="$WORK/iso-tree"

mkdir -p "$ISO_TREE"

xorriso \
  -osirrox on \
  -indev "$ISO_PATH" \
  -extract / "$ISO_TREE"

OLD_SQUASHFS="$ISO_TREE/image.squashfs"
OLD_KERNEL="$ISO_TREE/boot/gentoo"
OLD_INITRAMFS="$ISO_TREE/boot/gentoo.igz"
EFI_IMAGE="$ISO_TREE/efi.img"
BIOS_BOOT_IMAGE="$ISO_TREE/boot/grub/i386-pc/eltorito.img"

for EXTRACTED_FILE in \
  "$OLD_SQUASHFS" \
  "$OLD_KERNEL" \
  "$OLD_INITRAMFS" \
  "$EFI_IMAGE" \
  "$BIOS_BOOT_IMAGE"
do
  [[ -s "$EXTRACTED_FILE" ]] || {
    echo "Failed to extract: $EXTRACTED_FILE" >&2
    exit 1
  }
done

unsquashfs \
  -d "$ROOT" \
  "$OLD_SQUASHFS"

git clone \
  --depth 1 \
  https://github.com/gentoo-zh/overlay.git \
  "$OVERLAY"

docker pull "$STAGE3_IMAGE"
docker pull "$PORTAGE_IMAGE"

PORTAGE_CONTAINER="gentoo-portage-${RANDOM}-${RANDOM}"

docker create \
  --name "$PORTAGE_CONTAINER" \
  "$PORTAGE_IMAGE" \
  /bin/true >/dev/null

docker run \
  --rm \
  --platform linux/amd64 \
  --volumes-from "$PORTAGE_CONTAINER:ro" \
  --mount "type=bind,src=$OVERLAY,dst=/var/db/repos/gentoo-zh,readonly" \
  --mount "type=bind,src=$BUILD_OUT,dst=/output" \
  "$STAGE3_IMAGE" \
  /bin/bash -euxc '
    mkdir -p \
      /boot \
      /etc/kernel \
      /etc/portage/package.accept_keywords \
      /etc/portage/package.unmask \
      /etc/portage/package.use \
      /etc/portage/repos.conf \
      /output/modules

    cat > /etc/portage/repos.conf/gentoo-zh.conf <<EOF
[gentoo-zh]
location = /var/db/repos/gentoo-zh
masters = gentoo
auto-sync = no
EOF

    cat > /etc/portage/package.accept_keywords/cjk-kernel <<EOF
sys-kernel/gentoo-cjk-kernel-bin ~amd64
EOF

    cat > /etc/portage/package.accept_keywords/dist-kernel <<EOF
virtual/dist-kernel::gentoo-zh ~amd64
EOF

    cat > /etc/portage/package.use/cjk-kernel <<EOF
sys-kernel/gentoo-cjk-kernel-bin cjk -generic-uki
EOF

    cat > /etc/portage/package.use/installkernel <<EOF
sys-kernel/installkernel dracut
EOF

    cat > /etc/portage/package.unmask/dist-kernel <<EOF
virtual/dist-kernel::gentoo-zh
EOF

    cat > /etc/kernel/install.conf <<EOF
layout=compat
initrd_generator=none
uki_generator=none
EOF

    emerge \
      --oneshot \
      --verbose \
      sys-kernel/gentoo-cjk-kernel-bin::gentoo-zh

    KV=$(
      find -L /lib/modules \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -name "*-gentoo-cjk-dist-bin" \
        -printf "%f\n" |
      sort -V |
      tail -1
    )

    test -n "$KV"

    KERNEL_SOURCE="/usr/src/linux-$KV"
    KERNEL_IMAGE="$KERNEL_SOURCE/arch/x86/boot/bzImage"

    test -s "$KERNEL_IMAGE"
    test -s "$KERNEL_SOURCE/.config"
    test -d "/lib/modules/$KV"

    cp "$KERNEL_IMAGE" /output/gentoo
    cp "$KERNEL_SOURCE/.config" /output/kernel.config
    cp -a "/lib/modules/$KV" /output/modules/
    printf "%s\n" "$KV" > /output/kernel-version
    chmod -R a+rX /output
  '

docker rm -f "$PORTAGE_CONTAINER" >/dev/null
PORTAGE_CONTAINER=""

KV=$(tr -d '\r\n' < "$BUILD_OUT/kernel-version")

[[ "$KV" == *-gentoo-cjk-dist-bin ]] || {
  echo "Invalid kernel version: $KV" >&2
  exit 1
}

KERNEL_CONFIG="$BUILD_OUT/kernel.config"
NEW_KERNEL="$WORK/gentoo.new"

[[ -s "$BUILD_OUT/gentoo" ]] || {
  echo "The CJK kernel image was not produced." >&2
  exit 1
}

[[ -s "$KERNEL_CONFIG" ]] || {
  echo "The CJK kernel configuration was not produced." >&2
  exit 1
}

[[ -d "$BUILD_OUT/modules/$KV" ]] || {
  echo "The CJK kernel modules were not produced." >&2
  exit 1
}

cp "$BUILD_OUT/gentoo" "$NEW_KERNEL"

if [[ -L "$ROOT/lib" ]]; then
  LIVE_LIB_LINK=$(readlink "$ROOT/lib")

  case "$LIVE_LIB_LINK" in
    usr/lib|./usr/lib|/usr/lib)
      LIVE_MODULES="$ROOT/usr/lib/modules"
      ;;
    *)
      echo "Unsupported LiveCD /lib symlink: $LIVE_LIB_LINK" >&2
      exit 1
      ;;
  esac
else
  LIVE_MODULES="$ROOT/lib/modules"
fi

[[ "$LIVE_MODULES" == "$ROOT/"* ]] || {
  echo "Unsafe LiveCD modules path: $LIVE_MODULES" >&2
  exit 1
}

mkdir -p "$LIVE_MODULES"

find "$LIVE_MODULES" \
  -mindepth 1 \
  -maxdepth 1 \
  -exec rm -rf -- {} +

cp -a \
  "$BUILD_OUT/modules/$KV" \
  "$LIVE_MODULES/"

UNPACKED_INITRAMFS="$WORK/unpacked-initramfs"
NEW_INITRAMFS="$WORK/gentoo.igz.new"

rm -rf -- "$UNPACKED_INITRAMFS"
mkdir -p "$UNPACKED_INITRAMFS"

unmkinitramfs \
  "$OLD_INITRAMFS" \
  "$UNPACKED_INITRAMFS"

MAIN_INITRAMFS="$UNPACKED_INITRAMFS/main"

[[ -d "$MAIN_INITRAMFS" ]] || {
  echo "The main initramfs archive was not extracted." >&2
  exit 1
}

[[ -e "$MAIN_INITRAMFS/init" ]] || {
  echo "The extracted main initramfs has no init program." >&2
  exit 1
}

while IFS= read -r MODULES_DIRECTORY; do
  [[ "$MODULES_DIRECTORY" == "$UNPACKED_INITRAMFS/"* ]] || {
    echo "Unsafe extracted modules path: $MODULES_DIRECTORY" >&2
    exit 1
  }

  find "$MODULES_DIRECTORY" \
    -mindepth 1 \
    -maxdepth 1 \
    -exec rm -rf -- {} +
done < <(
  find "$UNPACKED_INITRAMFS" \
    -type d \
    -path '*/lib/modules' \
    -print
)

if [[ -L "$MAIN_INITRAMFS/lib" ]]; then
  INIT_LIB_LINK=$(readlink "$MAIN_INITRAMFS/lib")

  case "$INIT_LIB_LINK" in
    usr/lib|./usr/lib|/usr/lib)
      INIT_MODULES="$MAIN_INITRAMFS/usr/lib/modules"
      ;;
    *)
      echo "Unsupported initramfs /lib symlink: $INIT_LIB_LINK" >&2
      exit 1
      ;;
  esac
else
  INIT_MODULES="$MAIN_INITRAMFS/lib/modules"
fi

[[ "$INIT_MODULES" == "$MAIN_INITRAMFS/"* ]] || {
  echo "Unsafe initramfs modules path: $INIT_MODULES" >&2
  exit 1
}

mkdir -p "$INIT_MODULES"

cp -a \
  "$BUILD_OUT/modules/$KV" \
  "$INIT_MODULES/"

if grep -qx 'CONFIG_RD_ZSTD=y' "$KERNEL_CONFIG"; then
  MAIN_COMPRESS=(
    zstd
    --quiet
    --threads=0
    -19
    --stdout
  )
elif grep -qx 'CONFIG_RD_XZ=y' "$KERNEL_CONFIG"; then
  MAIN_COMPRESS=(
    xz
    --threads=0
    -9e
    --check=crc32
    --stdout
  )
elif grep -qx 'CONFIG_RD_GZIP=y' "$KERNEL_CONFIG"; then
  MAIN_COMPRESS=(
    gzip
    -9n
    --stdout
  )
else
  echo "The CJK kernel supports no known initramfs compression." >&2
  exit 1
fi

COMPRESSED_MAIN="$WORK/initramfs-main.compressed"

(
  cd "$MAIN_INITRAMFS"

  find . -print0 |
    LC_ALL=C sort -z |
    cpio \
      --null \
      --create \
      --format=newc \
      --quiet
) | "${MAIN_COMPRESS[@]}" > "$COMPRESSED_MAIN"

[[ -s "$COMPRESSED_MAIN" ]] || {
  echo "Failed to compress the main initramfs archive." >&2
  exit 1
}

: > "$NEW_INITRAMFS"

mapfile -t EARLY_DIRECTORIES < <(
  find "$UNPACKED_INITRAMFS" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -name 'early*' \
    -print |
  sort -V
)

for EARLY_DIRECTORY in "${EARLY_DIRECTORIES[@]}"; do
  (
    cd "$EARLY_DIRECTORY"

    find . -print0 |
      LC_ALL=C sort -z |
      cpio \
        --null \
        --create \
        --format=newc \
        --quiet
  ) >> "$NEW_INITRAMFS"
done

cat "$COMPRESSED_MAIN" >> "$NEW_INITRAMFS"

[[ -s "$NEW_INITRAMFS" ]] || {
  echo "Failed to generate the new initramfs." >&2
  exit 1
}

VERIFY_INITRAMFS="$WORK/verify-initramfs"

rm -rf -- "$VERIFY_INITRAMFS"
mkdir -p "$VERIFY_INITRAMFS"

unmkinitramfs \
  "$NEW_INITRAMFS" \
  "$VERIFY_INITRAMFS"

find "$VERIFY_INITRAMFS" \
  -type d \
  -path "*/lib/modules/$KV" \
  -print \
  -quit |
grep -q . || {
  echo "The generated initramfs has no modules for $KV." >&2
  exit 1
}

find "$VERIFY_INITRAMFS" \
  -type f \
  -path '*/main/init' \
  -print \
  -quit |
grep -q . || {
  echo "The generated initramfs has no init program." >&2
  exit 1
}

rm -rf -- "$VERIFY_INITRAMFS"

if grep -qx 'CONFIG_SQUASHFS_XZ=y' "$KERNEL_CONFIG"; then
  SQUASHFS_COMPRESSION=xz
elif grep -qx 'CONFIG_SQUASHFS_ZSTD=y' "$KERNEL_CONFIG"; then
  SQUASHFS_COMPRESSION=zstd
elif grep -qx 'CONFIG_SQUASHFS_LZ4=y' "$KERNEL_CONFIG"; then
  SQUASHFS_COMPRESSION=lz4
elif grep -qx 'CONFIG_SQUASHFS=y' "$KERNEL_CONFIG"; then
  SQUASHFS_COMPRESSION=gzip
else
  echo "The CJK kernel does not support SquashFS." >&2
  exit 1
fi

NEW_SQUASHFS="$WORK/image.squashfs.new"

mksquashfs \
  "$ROOT" \
  "$NEW_SQUASHFS" \
  -noappend \
  -no-progress \
  -comp "$SQUASHFS_COMPRESSION" \
  -b 1M

for REQUIRED_FILE in \
  "$NEW_KERNEL" \
  "$NEW_INITRAMFS" \
  "$NEW_SQUASHFS"
do
  [[ -s "$REQUIRED_FILE" ]] || {
    echo "Missing build artifact: $REQUIRED_FILE" >&2
    exit 1
  }
done

OUTPUT_NAME="gentoo-cjk-minimal-${KV}.iso"
OUTPUT="$OUT_DIR/$OUTPUT_NAME"

rm -f -- "$OUTPUT" "$OUTPUT.sha256"

install -m 0644 \
  "$NEW_KERNEL" \
  "$ISO_TREE/boot/gentoo"

install -m 0644 \
  "$NEW_INITRAMFS" \
  "$ISO_TREE/boot/gentoo.igz"

install -m 0644 \
  "$NEW_SQUASHFS" \
  "$ISO_TREE/image.squashfs"

rm -f -- "$ISO_TREE/boot.catalog"

ISO_DATE=${ISO_NAME#install-amd64-minimal-}
ISO_DATE=${ISO_DATE%%T*}
VOLUME_ID="GENTOO_AMD64_${ISO_DATE}"
MBR_TEMPLATE="--interval:local_fs:0s-15s:zero_mbrpt,zero_gpt:$ISO_PATH"

xorriso \
  -as mkisofs \
  -r \
  -V "$VOLUME_ID" \
  -o "$OUTPUT" \
  --grub2-mbr "$MBR_TEMPLATE" \
  --protective-msdos-label \
  -partition_cyl_align off \
  -partition_offset 16 \
  --mbr-force-bootable \
  -append_partition 2 0xef "$EFI_IMAGE" \
  -appended_part_as_gpt \
  -iso_mbr_part_type 0x83 \
  -c boot.catalog \
  -b boot/grub/i386-pc/eltorito.img \
  -no-emul-boot \
  -boot-load-size 4 \
  -boot-info-table \
  --grub2-boot-info \
  -eltorito-alt-boot \
  -e '--interval:appended_partition_2:all::' \
  -no-emul-boot \
  "$ISO_TREE"

[[ -s "$OUTPUT" ]] || {
  echo "Failed to create the output ISO." >&2
  exit 1
}

xorriso \
  -indev "$OUTPUT" \
  -report_el_torito plain \
  -report_system_area plain

(
  cd "$OUT_DIR"
  sha256sum "$OUTPUT_NAME" > "$OUTPUT_NAME.sha256"
)

echo "ISO: $OUTPUT"
echo "Kernel: $KV"

printf 'Initramfs size: '
du -h "$NEW_INITRAMFS" | awk '{print $1}'

printf 'SquashFS size: '
du -h "$NEW_SQUASHFS" | awk '{print $1}'
