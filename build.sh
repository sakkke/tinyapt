#!/bin/sh

set -eu

export ARCHITECTURE="$(dpkg --print-architecture)"
export WORK="$(mktemp -d)"

main() {
  check_root "$(id -u)"
  check_dependencies
  setup_work

  local tabase=tabase
  local taesp=taesp
  local taroot=taroot
  local taroot_sqfs=taroot.sqfs
  local talb=talb
  local esp=esp
  local esp_img=esp.img
  local talive=talive
  local talive_sqfs=talive.sqfs
  local tinyapt=tinyapt
  local tinyapt_iso=tinyapt.iso

  [ -d "$tabase" ] || {
    create_tabase "$tabase"
    rm -fr "$taesp"
  }
  [ -d "$taesp" ] || {
    create_taesp "$taesp" "$tabase"
    rm -fr "$taroot"
  }
  [ -d "$taroot" ] || {
    create_taroot "$taroot" "$taesp"
    rm -f "$taroot_sqfs"
  }
  [ -f "$taroot_sqfs" ] || {
    create_taroot_sqfs "$taroot_sqfs" "$taroot"
    rm -fr "$talb"
  }
  [ -d "$talb" ] && [ -d "$esp" ] && [ -f "$esp_img" ] || {
    rm -fr "$talb" "$esp" "$esp_img"
    create_talb "$talb" "$esp" "$esp_img" "$taroot"
    rm -fr "$talive"
  }
  [ -d "$talive" ] || {
    create_talive "$talive" "$talb"
    rm -f "$talive_sqfs"
  }
  [ -f "$talive_sqfs" ] || {
    create_talive_sqfs "$talive_sqfs" "$talive"
    rm -fr "$tinyapt"
  }
  [ -d "$tinyapt" ] || {
    create_tinyapt "$tinyapt" "$taroot_sqfs" "$talive_sqfs"
    rm -f "$tinyapt_iso"
  }
  [ -f "$tinyapt_iso" ] ||
    create_tinyapt_iso "$tinyapt_iso" "$tinyapt" "$esp_img"
  ls -hl "$tinyapt_iso"
}

panic() {
  local message="$1"
  echo "$0: panic: $message"
  exit 1
}

check_root() {
  local id="$1"
  [ "$id" -eq 0 ] || panic 'cannot be run as non-root'
}

command_exists() {
  local name="$1"
  command -v "$name" >/dev/null || panic "command not found: '$name'"
}

check_dependencies() {
  command_exists mmdebstrap
  command_exists xorriso
}

setup_work() {
  mount_work
  trap umount_work EXIT
}

mount_work() {
  mount -t tmpfs -v tmpfs "$WORK"
}

umount_work() {
  umount -Rv "$WORK"
  rmdir "$WORK"
}

create_file() {
  local mode="$1"
  local file="$2"
  mkdir -p "$(dirname "$file")"
  cat >"$file"
  chmod "$mode" "$file"
}

setup_taroot() {
  local taroot="$1"
  mount -t devtmpfs -v devtmpfs "$taroot"/dev
  mount -t devpts -v devpts "$taroot"/dev/pts
  mount -t proc -v proc "$taroot"/proc
  mount -t tmpfs -v tmpfs "$taroot"/run
  mount -t sysfs -v sysfs "$taroot"/sys
  mount -t tmpfs -v tmpfs "$taroot"/tmp
}

taroot_apt_install() {
  local taroot="$1"
  shift
  taroot_chroot "$taroot" apt-get update
  taroot_chroot "$taroot" apt-get --no-install-recommends -y install "$@"
  taroot_chroot "$taroot" apt-get clean
  rm -fr "$taroot"/var/lib/apt/lists/*
}

taroot_chroot() {
  local taroot="$1"
  shift
  env \
    -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    chroot "$taroot" "$@"
}

create_sqfs() {
  mksquashfs "$@"
}

fat32_img_size() {
  local path="$1"

  local byts_per_sec=512
  local sec_per_clus=8
  local num_fats=2
  local rsvd_sec_cnt=32

  local root_ent_cnt="$(find "$path" -mindepth 1 | wc -l)"
  local total_ent_byts="$(find "$path" -mindepth 1 -type f -print0 |
    xargs -0 du -b |
    awk "{
  result += int(\$1 / $byts_per_sec) + (\$1 % $byts_per_sec == 0 ? 1 : 0)
}
END {
  print result
}")"

  local fat_sec_cnt="$(expr "$root_ent_cnt" \* "$byts_per_sec")"
  local byts_per_clus="$(expr "$sec_per_clus" \* "$byts_per_sec")"
  local img_byts="$(expr \( "$rsvd_sec_cnt" + "$fat_sec_cnt" \* \
    "$num_fats" + "$root_ent_cnt" + "$total_ent_byts" \) \* "$byts_per_sec")"
  while expr "$img_byts" % "$byts_per_sec" != 0 >/dev/null; do
    img_byts="$(expr "$img_byts" + "$byts_per_sec")"
  done

  printf '%d\n' "$img_byts"
}

create_tabase() {
  local tabase="$1"
  local work="$WORK"/tabase.work
  mmdebstrap --variant=apt stable "$work"
  create_file 644 "$work"/etc/hostname <<EOF
tinyapt
EOF
  create_file 644 "$work"/etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 1.0.0.1
EOF
  cp -a "$work" "$tabase"
}

create_taesp() {
  local taesp="$1"
  local tabase="$2"
  local work="$WORK"/taesp.work
  cp -a "$tabase" "$work"
  create_file 644 "$work"/boot/cmdline.txt <<EOF
root=PARTLABEL=tinyapt_root rw
EOF
  create_file 644 "$work"/etc/kernel-img.conf <<EOF
link_in_boot = Yes
EOF
  create_file 755 "$work"/usr/local/sbin/update-uki <<'EOF.'
#!/bin/sh

set -eu

main() {
  local osrel=/etc/os-release
  local cmdline=/boot/cmdline.txt
  local linux="$(readlink -f /boot/vmlinuz)"
  local initrd="$(readlink -f /boot/initrd.img)"
  local linux_efi_stub=/usr/lib/systemd/boot/efi/linuxx64.efi.stub
  local boot_efi=/boot/efi/EFI/BOOT/BOOTx64.EFI
  create_boot_efi \
    "$osrel" \
    "$cmdline" \
    "$linux" \
    "$initrd" \
    "$linux_efi_stub" \
    "$boot_efi"
}

create_boot_efi() {
  local osrel="$1"
  local cmdline="$2"
  local linux="$3"
  local initrd="$4"
  local linux_efi_stub="$5"
  local boot_efi="$6"
  mkdir -p "$(dirname "$boot_efi")"
  objcopy \
    --add-section .osrel="$osrel" --change-section-vma .osrel=0x20000 \
    --add-section .cmdline="$cmdline" --change-section-vma .cmdline=0x30000 \
    --add-section .linux="$linux" --change-section-vma .linux=0x40000 \
    --add-section .initrd="$initrd" --change-section-vma .initrd=0x1000000 \
    -v \
    "$linux_efi_stub" "$boot_efi"
}

main
EOF.
  setup_taroot "$work"
  taroot_apt_install "$work" \
    binutils \
    linux-image-"$ARCHITECTURE" \
    systemd \
    systemd-boot-efi \
    systemd-sysv
  taroot_chroot "$work" update-uki
  cp -ax "$work" "$taesp"
}

create_taroot() {
  local taroot="$1"
  local taesp="$2"
  local work="$WORK"/taroot.work
  cp -a "$taesp" "$work"
  cp -a "$work" "$taroot"
}

create_taroot_sqfs() {
  local taroot_sqfs="$1"
  local taroot="$2"
  local work_sqfs="$WORK"/taroot.work.sqfs
  create_sqfs "$taroot" "$work_sqfs"
  cp -a "$work_sqfs" "$taroot_sqfs"
}

create_talb() {
  local talb="$1"
  local esp="$2"
  local esp_img="$3"
  local taroot="$4"

  local lowerdir="$WORK"/talb.lower
  local upperdir="$WORK"/talb.upper
  local workdir="$WORK"/talb.work
  local merged="$WORK"/talb.merged

  mkdir "$lowerdir" "$upperdir" "$workdir"

  cp -aT "$taroot" "$lowerdir"

  mkdir "$merged"
  mount \
    -o lowerdir="$lowerdir",upperdir="$upperdir",workdir="$workdir" \
    -t overlay \
    -v \
    overlay "$merged"

  create_file 644 "$merged"/boot/cmdline.txt <<EOF
boot=live
EOF
  setup_taroot "$merged"
  taroot_apt_install "$merged" live-boot
  taroot_chroot "$merged" update-uki

  create_esp "$esp" "$merged"
  create_esp_img "$esp_img" "$esp"

  cp -a "$upperdir" "$talb"
}

create_esp() {
  local esp="$1"
  local talb="$2"
  local work="$WORK"/esp.work
  cp -a "$talb"/boot/efi "$work"
  cp -a "$work" "$esp"
}

create_esp_img() {
  local esp_img="$1"
  local esp="$2"

  local work_img="$WORK"/esp.work.img
  truncate -s "$(fat32_img_size "$esp")" "$work_img"
  mkfs.fat -F 32 "$work_img"

  local work="$WORK"/esp.img.work
  mkdir "$work"
  mount -v "$work_img" "$work"
  cp -rT "$esp" "$work"
  umount -v "$work"

  cp -a "$work_img" "$esp_img"
}

create_talive() {
  local talive="$1"
  local talb="$2"
  local work="$WORK"/talive.work
  cp -a "$talb" "$work"
  cp -a "$work" "$talive"
}

create_talive_sqfs() {
  local talive_sqfs="$1"
  local talive="$2"
  local work_sqfs="$WORK"/talive.work.sqfs
  create_sqfs "$talive" "$work_sqfs"
  cp -a "$work_sqfs" "$talive_sqfs"
}

create_tinyapt() {
  local tinyapt="$1"
  local taroot_sqfs="$2"
  local talive_sqfs="$3"
  local work="$WORK"/tinyapt.work
  create_file 644 "$work"/live/20-taroot.squashfs <"$taroot_sqfs"
  create_file 644 "$work"/live/30-talive.squashfs <"$talive_sqfs"
  cp -a "$work" "$tinyapt"
}

create_tinyapt_iso() {
  local tinyapt_iso="$1"
  local tinyapt="$2"
  local esp_img="$3"
  local work_iso="$WORK"/tinyapt.work.iso
  xorriso \
    -outdev "$work_iso" \
    -append_partition 2 0xef "$esp_img" \
    -map "$tinyapt" /
  cp -a "$work_iso" "$tinyapt_iso"
}

main "$@"
