# list recipes
default:
  @just --list

# build the kernel executable
build:
  zig build

image: build
  # prepare image file system
  mkdir -p image/boot/limine
  mkdir -p image/EFI/BOOT
  cp zig-out/bin/sapphire image/boot/kernel.elf
  cp limine.conf image/boot/limine/
  cp -f "$LIMINE_SHARE/BOOTX64.EFI" image/EFI/BOOT
  cp -f "$LIMINE_SHARE/limine-bios.sys" "$LIMINE_SHARE/limine-bios-cd.bin" "$LIMINE_SHARE/limine-uefi-cd.bin" image/boot/limine

  # build image iso
  xorriso -as mkisofs \
    -b boot/limine/limine-bios-cd.bin \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -hfsplus \
    -apm-block-size 2048 \
    --efi-boot boot/limine/limine-uefi-cd.bin \
    -efi-boot-part \
    --efi-boot-image \
    --protective-msdos-label \
    -o os.iso \
    image
  limine bios-install os.iso

# run the kernel in qemu
run: image
  qemu-system-x86_64 \
    -cdrom os.iso \
    -m 512M
