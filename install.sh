#!/usr/bin/env bash
# Artix Linux (runit) auto-installer
#   btrfs + snapper + limine (snapshot boot entries) + SDDM + Hyprland + NVIDIA (open, Turing+)
#   Target: AMD Ryzen 5 5500 + RTX 2060 Super, NVMe, UEFI. Optional Windows dual boot.
#
# Run from the Artix live ISO as root:
#   bash install.sh
set -euo pipefail

# ----------------------------------------------------------------------------
# Defaults (can be overridden via environment: HOSTNAME_=... bash install.sh)
# ----------------------------------------------------------------------------
TIMEZONE="${TIMEZONE:-Europe/Moscow}"
LANG_="${LANG_:-ru_RU.UTF-8}"
KEYMAP="${KEYMAP:-ru}"
CONSOLE_FONT="${CONSOLE_FONT:-cyr-sun16}"
ESP_SIZE="${ESP_SIZE:-2G}"
BTRFS_OPTS="noatime,compress=zstd:1"
MNT=/mnt

ESP_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"

c_red=$'\e[1;31m'; c_grn=$'\e[1;32m'; c_ylw=$'\e[1;33m'; c_rst=$'\e[0m'
info() { printf '%s==>%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s==> WARNING:%s %s\n' "$c_ylw" "$c_rst" "$*"; }
die()  { printf '%s==> ERROR:%s %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }

ask() { # ask VAR "prompt" [default]
	local __v __d="${3:-}"
	read -rp "$2${__d:+ [$__d]}: " __v
	printf -v "$1" '%s' "${__v:-$__d}"
}

ask_pass() { # ask_pass VAR "prompt"
	local p1 p2
	while true; do
		read -rsp "$2: " p1; echo
		read -rsp "Повторите: " p2; echo
		[[ -n "$p1" && "$p1" == "$p2" ]] && break
		warn "Пароли пустые или не совпадают, ещё раз."
	done
	printf -v "$1" '%s' "$p1"
}

part_path() { # part_path /dev/nvme0n1 2 -> /dev/nvme0n1p2
	if [[ "$1" =~ [0-9]$ ]]; then echo "${1}p$2"; else echo "${1}$2"; fi
}

# ----------------------------------------------------------------------------
# Pre-flight checks
# ----------------------------------------------------------------------------
((EUID == 0)) || die "Запустите от root."
[[ -d /sys/firmware/efi/efivars ]] || die "Система загружена не в режиме UEFI."
command -v basestrap >/dev/null || die "basestrap не найден — это точно Artix live ISO?"
ping -c1 -W3 artixlinux.org &>/dev/null || die "Нет интернета. Подключитесь (ethernet / nmtui / connmanctl) и повторите."

info "Обновляю ключи и ставлю утилиты в live-окружение..."
pacman -Sy --noconfirm --needed artix-keyring >/dev/null
pacman -S --noconfirm --needed btrfs-progs dosfstools gptfdisk >/dev/null

# ----------------------------------------------------------------------------
# Find existing Windows boot loaders (any ESP on any disk)
# ----------------------------------------------------------------------------
declare -a WIN_PARTS=() WIN_PARTUUIDS=()
scan_windows() {
	local dev tmp
	tmp=$(mktemp -d)
	while read -r dev; do
		mount -o ro "$dev" "$tmp" 2>/dev/null || continue
		if [[ -f "$tmp/EFI/Microsoft/Boot/bootmgfw.efi" ]]; then
			WIN_PARTS+=("$dev")
			WIN_PARTUUIDS+=("$(blkid -s PARTUUID -o value "$dev")")
		fi
		umount "$tmp"
	done < <(lsblk -rpno NAME,PARTTYPE | awk -v g="$ESP_GUID" 'tolower($2)==g {print $1}')
	rmdir "$tmp"
}
scan_windows
if ((${#WIN_PARTS[@]})); then
	info "Найден загрузчик Windows: ${WIN_PARTS[*]} — он будет добавлен в меню Limine."
else
	warn "Загрузчик Windows не найден (будет установлен только Artix)."
fi

# ----------------------------------------------------------------------------
# User input
# ----------------------------------------------------------------------------
echo
info "Доступные диски:"
lsblk -dpno NAME,SIZE,MODEL | grep -Ev 'loop|sr[0-9]|zram' || true
echo
default_disk=$(lsblk -dpno NAME | grep -m1 nvme || true)
ask DISK "Диск для установки" "$default_disk"
[[ -b "$DISK" ]] || die "$DISK не является блочным устройством."

win_on_disk=no
for p in "${WIN_PARTS[@]}"; do
	[[ "/dev/$(lsblk -no PKNAME "$p")" == "$DISK" ]] && win_on_disk=yes
done

echo
echo "Режим разметки $DISK:"
echo "  1) Стереть ВЕСЬ диск (ESP $ESP_SIZE + btrfs)"
echo "  2) Установить в НЕРАЗМЕЧЕННОЕ свободное место (существующие разделы не трогаются)"
if [[ $win_on_disk == yes ]]; then
	warn "На $DISK находится Windows! Выбирайте 2 (заранее освободите место в «Управлении дисками» Windows)."
	ask MODE "Режим" "2"
else
	ask MODE "Режим" "1"
fi
[[ "$MODE" == 1 || "$MODE" == 2 ]] || die "Неизвестный режим: $MODE"

ask HOSTNAME_ "Имя компьютера" "artix"
ask USERNAME "Имя пользователя" "user"
[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Недопустимое имя пользователя."
ask_pass USER_PASS "Пароль для $USERNAME"
ask_pass ROOT_PASS "Пароль для root"
ask TIMEZONE "Часовой пояс" "$TIMEZONE"
[[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] || die "Нет такого часового пояса: $TIMEZONE"

echo
warn "Итог:"
echo "  Диск:          $DISK (режим $MODE)"
echo "  Хост/юзер:     $HOSTNAME_ / $USERNAME"
echo "  Часовой пояс:  $TIMEZONE, язык $LANG_"
echo "  Windows:       ${WIN_PARTS[*]:-нет}"
if [[ $MODE == 1 ]]; then
	[[ $win_on_disk == yes ]] && warn "ЭТО УДАЛИТ WINDOWS НА $DISK!"
	read -rp "Все данные на $DISK будут уничтожены. Введите YES для продолжения: " c
	[[ "$c" == YES ]] || die "Отменено."
else
	read -rp "Продолжить? [y/N]: " c
	[[ "$c" == [yY]* ]] || die "Отменено."
fi

# ----------------------------------------------------------------------------
# Partitioning
# ----------------------------------------------------------------------------
umount -R "$MNT" 2>/dev/null || true

if [[ $MODE == 1 ]]; then
	info "Размечаю $DISK..."
	wipefs -af "$DISK"
	sgdisk -Z "$DISK"
	sgdisk -o "$DISK"
fi

# Start 0 = beginning of the largest free block, so in mode 2 existing partitions stay intact.
before=$(lsblk -rpno NAME "$DISK" | sort)
sgdisk -n "0:0:+$ESP_SIZE" -t 0:ef00 -c 0:ARTIX_ESP "$DISK"
sgdisk -n "0:0:0"          -t 0:8300 -c 0:ARTIX_ROOT "$DISK"
partprobe "$DISK" 2>/dev/null || true
udevadm settle
sleep 1

# Only look at partitions that did not exist before (mode 2 may have old ARTIX_* labels)
new_parts=$(comm -13 <(echo "$before") <(lsblk -rpno NAME "$DISK" | sort))
ESP_PART="" ROOT_PART=""
for p in $new_parts; do
	case "$(lsblk -no PARTLABEL "$p")" in
	ARTIX_ESP) ESP_PART=$p ;;
	ARTIX_ROOT) ROOT_PART=$p ;;
	esac
done
[[ -b "$ESP_PART" && -b "$ROOT_PART" ]] || die "Не удалось найти созданные разделы."

# Windows that lived on a wiped disk is gone
if [[ $MODE == 1 ]]; then
	declare -a keep=()
	for i in "${!WIN_PARTS[@]}"; do
		[[ "/dev/$(lsblk -no PKNAME "${WIN_PARTS[$i]}" 2>/dev/null)" == "$DISK" ]] || keep+=("${WIN_PARTUUIDS[$i]}")
	done
	WIN_PARTUUIDS=("${keep[@]}")
fi

info "ESP: $ESP_PART, root: $ROOT_PART"
mkfs.fat -F32 -n ARTIX_ESP "$ESP_PART"
mkfs.btrfs -f -L ARTIX "$ROOT_PART"

# ----------------------------------------------------------------------------
# Btrfs subvolumes
#   @ -> /    @home -> /home    @snapshots -> /.snapshots
#   @var_log, @var_cache, @var_tmp — excluded from root snapshots
# ----------------------------------------------------------------------------
info "Создаю subvolumes..."
mount "$ROOT_PART" "$MNT"
for sv in @ @home @snapshots @var_log @var_cache @var_tmp; do
	btrfs subvolume create "$MNT/$sv"
done
umount "$MNT"

mount -o "$BTRFS_OPTS,subvol=@" "$ROOT_PART" "$MNT"
mkdir -p "$MNT"/{boot,home,.snapshots,var/log,var/cache,var/tmp}
mount -o "$BTRFS_OPTS,subvol=@home"      "$ROOT_PART" "$MNT/home"
mount -o "$BTRFS_OPTS,subvol=@snapshots" "$ROOT_PART" "$MNT/.snapshots"
mount -o "$BTRFS_OPTS,subvol=@var_log"   "$ROOT_PART" "$MNT/var/log"
mount -o "$BTRFS_OPTS,subvol=@var_cache" "$ROOT_PART" "$MNT/var/cache"
mount -o "$BTRFS_OPTS,subvol=@var_tmp"   "$ROOT_PART" "$MNT/var/tmp"
mount -o fmask=0077,dmask=0077 "$ESP_PART" "$MNT/boot"

# ----------------------------------------------------------------------------
# Base system
# ----------------------------------------------------------------------------
info "Устанавливаю базовую систему (basestrap)..."
basestrap "$MNT" base base-devel runit elogind-runit \
	linux linux-headers linux-firmware amd-ucode mkinitcpio \
	btrfs-progs dosfstools efibootmgr \
	networkmanager networkmanager-runit dbus-runit \
	sudo git nano vim bash-completion

info "Генерирую fstab..."
fstabgen -U "$MNT" >>"$MNT/etc/fstab"
# subvolid pins would break snapshot restore/rollback, keep only subvol=
sed -i 's/subvolid=[0-9]*,\?//g; s/,\s/ /g' "$MNT/etc/fstab"

# ----------------------------------------------------------------------------
# Hand over to chroot
# ----------------------------------------------------------------------------
{
	printf 'HOSTNAME_=%q\n'   "$HOSTNAME_"
	printf 'USERNAME=%q\n'    "$USERNAME"
	printf 'USER_PASS=%q\n'   "$USER_PASS"
	printf 'ROOT_PASS=%q\n'   "$ROOT_PASS"
	printf 'TIMEZONE=%q\n'    "$TIMEZONE"
	printf 'LANG_=%q\n'       "$LANG_"
	printf 'KEYMAP=%q\n'      "$KEYMAP"
	printf 'CONSOLE_FONT=%q\n' "$CONSOLE_FONT"
	printf 'ROOT_UUID=%q\n'   "$(blkid -s UUID -o value "$ROOT_PART")"
	printf 'WIN_PARTUUIDS=(%s)\n' "${WIN_PARTUUIDS[*]:-}"
} >"$MNT/root/install.env"
chmod 600 "$MNT/root/install.env"

cat >"$MNT/root/chroot.sh" <<'CHROOT_EOF'
#!/usr/bin/env bash
set -euo pipefail
source /root/install.env

c_grn=$'\e[1;32m'; c_ylw=$'\e[1;33m'; c_rst=$'\e[0m'
info() { printf '%s==>%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s==> WARNING:%s %s\n' "$c_ylw" "$c_rst" "$*"; }

# --- pacman: Artix lib32 + Arch [extra]/[multilib] ---------------------------
info "Настраиваю pacman (lib32, Arch extra/multilib)..."
sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 5/; s/^#Color/Color/' /etc/pacman.conf
sed -i '/^#\[lib32\]/{N;s/#//g}' /etc/pacman.conf
pacman -Sy --noconfirm --needed artix-archlinux-support

if ! grep -q '^Server' /etc/pacman.d/mirrorlist-arch 2>/dev/null; then
	cat >/etc/pacman.d/mirrorlist-arch <<'EOF'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.yandex.ru/archlinux/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
EOF
fi
if ! grep -q '^\[extra\]' /etc/pacman.conf; then
	cat >>/etc/pacman.conf <<'EOF'

# Arch Linux repositories (artix-archlinux-support)
[extra]
Include = /etc/pacman.d/mirrorlist-arch

[multilib]
Include = /etc/pacman.d/mirrorlist-arch
EOF
fi
pacman-key --populate archlinux
pacman -Syu --noconfirm

# --- packages ----------------------------------------------------------------
info "Устанавливаю пакеты (NVIDIA, Hyprland, SDDM, snapper, limine)..."
pacman -S --noconfirm --needed \
	limine snapper inotify-tools rsync libnotify \
	nvidia-open-dkms nvidia-utils lib32-nvidia-utils nvidia-settings egl-wayland libva-nvidia-driver \
	hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk hyprpolkitagent \
	qt5-wayland qt6-wayland kitty wofi waybar dolphin xdg-utils xdg-user-dirs \
	sddm sddm-runit xorg-server \
	pipewire pipewire-pulse pipewire-alsa wireplumber \
	noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-dejavu \
	cronie cronie-runit

# --- locale / time / host ----------------------------------------------------
info "Локаль, время, hostname..."
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc
sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/; s/^#\(ru_RU.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=$LANG_" >/etc/locale.conf
printf 'KEYMAP=%s\nFONT=%s\n' "$KEYMAP" "$CONSOLE_FONT" >/etc/vconsole.conf
if [[ -f /etc/rc.conf ]]; then
	sed -i "s|^#\?KEYMAP=.*|KEYMAP=\"$KEYMAP\"|; s|^#\?FONT=.*|FONT=\"$CONSOLE_FONT\"|" /etc/rc.conf
fi
echo "$HOSTNAME_" >/etc/hostname
cat >/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME_.localdomain $HOSTNAME_
EOF
# limine-entry-tool / limine-snapper-sync identify the OS entry by machine-id
[[ -s /etc/machine-id ]] || dbus-uuidgen --ensure=/etc/machine-id

# --- users -------------------------------------------------------------------
info "Пользователи..."
echo "root:$ROOT_PASS" | chpasswd
id "$USERNAME" &>/dev/null || useradd -m -G wheel,video,audio,input,storage -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
echo '%wheel ALL=(ALL:ALL) ALL' >/etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel

# --- mkinitcpio (NVIDIA early KMS, busybox hooks) ----------------------------
info "mkinitcpio..."
sed -i 's/^MODULES=.*/MODULES=(btrfs nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf keyboard keymap consolefont block filesystems fsck)/' /etc/mkinitcpio.conf
echo 'options nvidia_drm modeset=1 fbdev=1' >/etc/modprobe.d/nvidia.conf

CMDLINE="root=UUID=$ROOT_UUID rootflags=subvol=@ rw quiet loglevel=3 nvidia_drm.modeset=1 nvidia_drm.fbdev=1"

# --- snapper -----------------------------------------------------------------
info "snapper..."
umount /.snapshots
rmdir /.snapshots
snapper --no-dbus -c root create-config /
btrfs subvolume delete /.snapshots
mkdir /.snapshots
mount /.snapshots
chmod 750 /.snapshots
chown :wheel /.snapshots
sed -i \
	-e 's/^ALLOW_GROUPS=.*/ALLOW_GROUPS="wheel"/' \
	-e 's/^SYNC_ACL=.*/SYNC_ACL="yes"/' \
	-e 's/^NUMBER_LIMIT=.*/NUMBER_LIMIT="10"/' \
	-e 's/^NUMBER_LIMIT_IMPORTANT=.*/NUMBER_LIMIT_IMPORTANT="5"/' \
	-e 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="yes"/' \
	-e 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/' \
	-e 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/' \
	-e 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="0"/' \
	-e 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="0"/' \
	-e 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/' \
	/etc/snapper/configs/root

# No systemd timers on runit -> cron jobs for timeline/cleanup
cat >/etc/cron.hourly/snapper-timeline <<'EOF'
#!/bin/sh
if [ -x /usr/lib/snapper/systemd-helper ]; then
	exec /usr/lib/snapper/systemd-helper --timeline
fi
exec snapper --no-dbus -c root create -c timeline -d timeline
EOF
cat >/etc/cron.daily/snapper-cleanup <<'EOF'
#!/bin/sh
if [ -x /usr/lib/snapper/systemd-helper ]; then
	exec /usr/lib/snapper/systemd-helper --cleanup
fi
snapper --no-dbus -c root cleanup number
snapper --no-dbus -c root cleanup timeline
EOF
chmod 755 /etc/cron.hourly/snapper-timeline /etc/cron.daily/snapper-cleanup

# --- limine config (shared by limine-entry-tool and limine-snapper-sync) ------
info "Конфиг limine..."
cat >/etc/default/limine <<EOF
ESP_PATH="/boot"
TARGET_OS_NAME="Artix Linux"
KERNEL_CMDLINE[default]="$CMDLINE"
BOOT_ORDER="*, *fallback, Snapshots"
FIND_BOOTLOADERS=yes
ENABLE_UKI=no
ENABLE_LIMINE_FALLBACK=yes

# limine-snapper-sync
SNAPPER_CONFIG_NAME="root"
ROOT_SUBVOLUME_PATH="/@"
ROOT_SNAPSHOTS_PATH="/@snapshots"
MAX_SNAPSHOT_ENTRIES=10
LIMIT_USAGE_PERCENT=85
EOF
[[ -f /boot/limine.conf ]] || printf 'timeout: 5\n' >/boot/limine.conf

# --- AUR: limine-mkinitcpio-hook, limine-snapper-sync, yay-bin ---------------
info "Собираю AUR-пакеты (GraalVM native-image — это займёт несколько минут)..."
echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/99-installer
chmod 440 /etc/sudoers.d/99-installer
BUILD_DIR="/home/$USERNAME/.cache/aur-build"
aur_ok=yes
for pkg in limine-mkinitcpio-hook limine-snapper-sync yay-bin; do
	if ! su - "$USERNAME" -c "
		set -e
		mkdir -p '$BUILD_DIR' && cd '$BUILD_DIR'
		rm -rf '$pkg'
		git clone --depth 1 'https://aur.archlinux.org/$pkg.git'
		cd '$pkg'
		makepkg -si --noconfirm --needed
	"; then
		warn "Не удалось собрать $pkg"
		[[ $pkg == yay-bin ]] || aur_ok=no
	fi
done
rm -rf "$BUILD_DIR"
rm -f /etc/sudoers.d/99-installer

# --- bootloader ----------------------------------------------------------------
add_windows_entries() {
	local id name n=0
	for id in "${WIN_PARTUUIDS[@]}"; do
		[[ -n "$id" ]] || continue
		grep -qi "uuid($id)" /boot/limine.conf && continue
		((++n))
		name="Windows"
		((n > 1)) && name="Windows $n"
		cat >>/boot/limine.conf <<EOF

/$name
    comment: Windows Boot Manager
    protocol: efi
    path: uuid($id):/EFI/Microsoft/Boot/bootmgfw.efi
EOF
	done
}

if [[ $aur_ok == yes ]]; then
	info "Limine: установка + генерация пунктов меню (limine-entry-tool)..."
	sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf keyboard keymap consolefont block filesystems btrfs-overlayfs fsck)/' /etc/mkinitcpio.conf
	limine-install --fallback || warn "limine-install завершился с ошибкой"
	limine-update || warn "limine-update завершился с ошибкой"
fi

# Fallback: manual Limine setup if the AUR tooling failed
if ! grep -q 'protocol: linux' /boot/limine.conf; then
	warn "Пишу limine.conf вручную (без меню снэпшотов)."
	mkinitcpio -P
	mkdir -p /boot/EFI/BOOT /boot/EFI/limine
	cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI
	cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/limine_x64.efi
	esp_dev=$(findmnt -no SOURCE /boot)
	esp_disk="/dev/$(lsblk -no PKNAME "$esp_dev")"
	esp_num=$(cat "/sys/class/block/$(basename "$esp_dev")/partition")
	efibootmgr --create --disk "$esp_disk" --part "$esp_num" \
		--label "Limine" --loader '\EFI\limine\limine_x64.efi' || warn "efibootmgr не смог создать запись"
	cat >/boot/limine.conf <<EOF
timeout: 5

/Artix Linux
    comment: machine-id=$(cat /etc/machine-id)
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: $CMDLINE
    module_path: boot():/initramfs-linux.img

/Artix Linux (fallback)
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: $CMDLINE
    module_path: boot():/initramfs-linux-fallback.img
EOF
fi
add_windows_entries

# Helper to re-add Windows later (e.g. after reinstalling it)
cat >/usr/local/bin/limine-add-windows <<'EOF'
#!/usr/bin/env bash
# Finds Windows Boot Manager on any ESP and adds it to /boot/limine.conf
set -euo pipefail
((EUID == 0)) || exec sudo "$0" "$@"
tmp=$(mktemp -d)
while read -r dev; do
	mount -o ro "$dev" "$tmp" 2>/dev/null || continue
	if [[ -f "$tmp/EFI/Microsoft/Boot/bootmgfw.efi" ]]; then
		id=$(blkid -s PARTUUID -o value "$dev")
		if grep -qi "uuid($id)" /boot/limine.conf; then
			echo "Windows на $dev уже в limine.conf"
		else
			printf '\n/Windows\n    comment: Windows Boot Manager\n    protocol: efi\n    path: uuid(%s):/EFI/Microsoft/Boot/bootmgfw.efi\n' "$id" >>/boot/limine.conf
			echo "Добавлено: Windows ($dev)"
		fi
	fi
	umount "$tmp"
done < <(lsblk -rpno NAME,PARTTYPE | awk 'tolower($2)=="c12a7328-f81f-11d2-ba4b-00a0c93ec93b" {print $1}')
rmdir "$tmp"
EOF
chmod 755 /usr/local/bin/limine-add-windows

# --- Hyprland session with D-Bus (no systemd user session on runit) -------------
info "Hyprland / SDDM..."
hypr_exec=$(sed -n 's/^Exec=//p' /usr/share/wayland-sessions/hyprland.desktop 2>/dev/null | head -1)
cat >/usr/share/wayland-sessions/hyprland-artix.desktop <<EOF
[Desktop Entry]
Name=Hyprland (Artix)
Comment=Hyprland with D-Bus session
Exec=dbus-run-session ${hypr_exec:-Hyprland}
Type=Application
DesktopNames=Hyprland
EOF

mkdir -p /etc/sddm.conf.d
cat >/etc/sddm.conf.d/10-artix.conf <<'EOF'
[General]
DisplayServer=x11
Numlock=on
EOF

# User Hyprland config: stock config + NVIDIA env + pipewire + us/ru layout
HYPR_DIR="/home/$USERNAME/.config/hypr"
mkdir -p "$HYPR_DIR"
if [[ -f /usr/share/hypr/hyprland.conf && ! -f "$HYPR_DIR/hyprland.conf" ]]; then
	cp /usr/share/hypr/hyprland.conf "$HYPR_DIR/hyprland.conf"
	if command -v artix-pipewire-launcher &>/dev/null; then
		pw_line="exec-once = artix-pipewire-launcher"
	else
		pw_line=$'exec-once = /usr/bin/pipewire\nexec-once = /usr/bin/pipewire-pulse\nexec-once = /usr/bin/wireplumber'
	fi
	cat >>"$HYPR_DIR/hyprland.conf" <<EOF

# ---------------- added by artix installer ----------------
# NVIDIA
env = LIBVA_DRIVER_NAME,nvidia
env = __GLX_VENDOR_LIBRARY_NAME,nvidia
env = NVD_BACKEND,direct
env = ELECTRON_OZONE_PLATFORM_HINT,auto

# Audio (no systemd user services on runit)
$pw_line

# Polkit agent, portals, bar
exec-once = /usr/lib/hyprpolkitagent/hyprpolkitagent
exec-once = waybar

# Keyboard layouts: Alt+Shift to switch
input:kb_layout = us,ru
input:kb_options = grp:alt_shift_toggle
EOF
fi
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config"

# --- runit services --------------------------------------------------------------
info "Включаю сервисы runit..."
for s in dbus elogind NetworkManager sddm cronie; do
	if [[ -d /etc/runit/sv/$s ]]; then
		ln -sf "/etc/runit/sv/$s" /etc/runit/runsvdir/default/
	else
		warn "runit-сервис $s не найден"
	fi
done

# --- snap-pac + first snapshot ---------------------------------------------------
info "snap-pac и первый снэпшот..."
pacman -S --noconfirm --needed snap-pac || warn "snap-pac не установлен"
snapper --no-dbus -c root create -d "Fresh install" -c important
if command -v limine-snapper-sync &>/dev/null; then
	limine-snapper-sync || warn "limine-snapper-sync завершился с ошибкой"
fi

rm -f /root/install.env
info "Готово внутри chroot."
CHROOT_EOF
chmod 700 "$MNT/root/chroot.sh"

info "Вхожу в chroot..."
artix-chroot "$MNT" /bin/bash /root/chroot.sh
rm -f "$MNT/root/chroot.sh" "$MNT/root/install.env"

echo
info "Установка завершена!"
echo "  Проверьте меню: cat $MNT/boot/limine.conf"
echo "  Затем: umount -R $MNT && reboot"
echo "  В SDDM выберите сессию «Hyprland (Artix)»."
