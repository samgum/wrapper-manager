# wrapper-manager QEMU guest

Assets for booting the whole wrapper-manager inside a QEMU Linux guest so it
runs on Windows / macOS / any Linux host (see the parent README).

## Layout

```text
guest/
├── build.sh     # builds wrapper-manager-initramfs.cpio.gz (+ optional data.img)
├── init         # guest init script (busybox sh)
└── modules/     # historical modules; builds use the matched upstream artifact
    ├── e1000.ko
    └── qemu_fw_cfg.ko
```

`overlay/` is a build output (gitignored): build.sh rebuilds it from scratch
each run by staging the static wrapper-manager binary, static busybox, the
host glibc runtime (for the dynamically-linked `wrapper-lite-rootless`), CA
certificates and the kernel modules.

## Build

```shell
# requires: go, cpio, gzip, curl, unzip, e2fsprogs, glibc + ca-certificates
./guest/build.sh out                  # initramfs only
CREATE_DATA_IMG=1 ./guest/build.sh out   # also create a fresh 512MB data.img
```

## Kernel

`vmlinuz-lite-qemu` is **not** built here. It is the kernel produced by the
upstream [WorldObservationLog/wrapper](https://github.com/WorldObservationLog/wrapper)
`build-lite` workflow and is distributed in its `qemu-assets` artifact:

```shell
curl -sL -o qemu-assets.zip \
  "https://nightly.link/WorldObservationLog/wrapper/workflows/build-lite/lite/qemu-assets.zip"
unzip -o qemu-assets.zip vmlinuz-lite-qemu -d out/
```

`build.sh` downloads this artifact and extracts `e1000.ko` and
`qemu_fw_cfg.ko` from its `lite-initramfs.cpio.gz`. It writes that same
artifact's kernel beside the manager initramfs. Mixing a new kernel with
the old tracked modules can leave the guest without network access.

For an offline build, extract both `vmlinuz-lite-qemu` and
`lite-initramfs.cpio.gz` from one artifact, then run:

```shell
WRAPPER_QEMU_ASSETS_DIR=/path/to/extracted-assets ./guest/build.sh out
```

## What the guest does on boot (init)

1. Mounts proc/sys/dev, loads `e1000.ko`, configures static NAT networking
   (10.0.2.15, DNS 10.0.2.3) and writes `/etc/resolv.conf`.
2. Mounts the ext4 data disk (`/dev/vda` → `/data`); formats it with
   `mke2fs` on first boot when it is a raw empty image.
3. Executes `/wrapper-manager -host 0.0.0.0 -port 8080` from `/data`, so all
   manager state (wrapper-lite payload, accounts, tokens) persists in
   `data.img`. Optional manager args can be supplied via qemu fw_cfg
   (`manager_args`) or the kernel cmdline (`manager_args_b64=`).
