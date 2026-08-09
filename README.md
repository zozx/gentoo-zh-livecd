# gentoo-zh-livecd

Automated Gentoo Minimal LiveCD builds using
`sys-kernel/gentoo-cjk-kernel-bin::gentoo-zh`.

The build process:

1. Downloads and verifies the latest official amd64 Minimal LiveCD.
2. Builds the CJKTTY kernel in an official Gentoo stage3 container.
3. Replaces the LiveCD kernel and kernel modules.
4. Extracts the official early and main initramfs archives.
5. Replaces the main initramfs kernel modules.
6. Generates a new initramfs while preserving early firmware archives.
7. Rebuilds the SquashFS and hybrid BIOS/UEFI ISO.

## Local build

Required tools include Docker, curl, cpio, initramfs-tools,
squashfs-tools, xorriso, xz and zstd.

```bash
sudo bash scripts/build.sh "$PWD/dist"

Set KEEP_WORK=1 to preserve temporary build files:

sudo KEEP_WORK=1 bash scripts/build.sh "$PWD/dist"

The generated ISO and SHA256 checksum are written to dist/.

Secure Boot is not guaranteed by this build.
