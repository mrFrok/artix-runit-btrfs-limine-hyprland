# Artix Linux (runit) — btrfs + snapper + Limine + SDDM + Hyprland

Простой bash-автоустановщик Artix Linux для запуска из live ISO.
Заточен под **AMD Ryzen 5 5500 + NVIDIA RTX 2060 Super + NVMe, UEFI**. Умеет dual boot с Windows.

## Что ставится

| Компонент | Детали |
|---|---|
| Init | runit (`elogind`, `dbus`, `NetworkManager`, `sddm`, `cronie`) |
| ФС | btrfs, `zstd:1`, subvolumes `@`, `@home`, `@snapshots`, `@var_log`, `@var_cache`, `@var_tmp` |
| Снэпшоты | snapper + snap-pac (снэпшот до/после каждого `pacman`), timeline через cron |
| Загрузчик | Limine + [limine-mkinitcpio-hook](https://gitlab.com/Zesko/limine-entry-tool) + [limine-snapper-sync](https://gitlab.com/Zesko/limine-snapper-sync) — снэпшоты появляются в меню загрузки, read-only снэпшоты грузятся через overlayfs |
| Windows | ищется на всех дисках (ESP с `bootmgfw.efi`) и добавляется в меню Limine |
| GPU | `nvidia-open-dkms` (Turing поддерживается), early KMS, `nvidia_drm.modeset=1 fbdev=1` |
| CPU | `amd-ucode` (вшивается в initramfs хуком `microcode`) |
| Графика | SDDM + Hyprland, kitty, wofi, waybar, dolphin, pipewire, xdg-desktop-portal-hyprland |
| Репозитории | Artix + `lib32` + Arch `[extra]`/`[multilib]` (artix-archlinux-support), `yay` для AUR |

## Использование

1. Загрузите **Artix base ISO (runit)** в режиме **UEFI**. Secure Boot выключите.
2. Подключитесь к интернету: кабель обычно работает сразу, для Wi‑Fi — `nmtui` или `connmanctl`.
   Скрипт сам проверит сеть, при неработающем DNS пропишет `1.1.1.1`/`8.8.8.8`
   и выберет самые быстрые зеркала Artix и Arch (по скорости загрузки `.db`).
3. Войдите под root (`su`, пароль `artix`) и выполните:

```bash
curl -LO https://raw.githubusercontent.com/mrFrok/artix-runit-btrfs-limine-hyprland/main/install.sh
bash install.sh
```

4. Ответьте на вопросы: диск, режим разметки, имя хоста, пользователь, пароли, часовой пояс.
5. После `Установка завершена!` выполните `umount -R /mnt && reboot`.
6. В SDDM выберите сессию **«Hyprland (Artix)»**. Она запускает Hyprland через `dbus-run-session`, это нужно на runit. SDDM запомнит выбор.

## Dual boot с Windows

- **Windows на другом диске** — выбирайте режим `1` для NVMe под Artix. Windows найдётся автоматически.
- **Windows на том же NVMe** — сначала в Windows («Управление дисками» → «Сжать том») освободите место.
  Затем выберите режим `2`: Artix создаст свой ESP (2 ГБ) и btrfs-раздел в свободном месте. Разделы Windows не трогаются.
- Отключите в Windows **быстрый запуск** (Fast Startup).
- Чтобы часы не сбивались, в Windows (cmd от администратора) выполните:
  `reg add "HKLM\System\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /d 1 /t REG_DWORD /f`
- Если Windows переустановили или добавили позже, выполните `sudo limine-add-windows`.

## Работа со снэпшотами

```bash
snapper list                     # список снэпшотов
sudo snapper create -d "до экспериментов"
sudo limine-snapper-sync         # вручную обновить меню Limine (обычно не нужно — работает snapper-плагин)
sudo limine-snapper-restore      # откат на снэпшот (в т.ч. после загрузки в снэпшот из меню)
sudo limine-update               # пересобрать initramfs и пункты меню после правки /etc/default/limine
```

Откат: в меню Limine откройте `Snapshots`, загрузитесь в нужный снэпшот, затем выполните `sudo limine-snapper-restore`.

## Настройки

Переменные можно задать через окружение, например:
`TIMEZONE=Europe/Kyiv LANG_=en_US.UTF-8 KEYMAP=us bash install.sh`

| Переменная | По умолчанию |
|---|---|
| `TIMEZONE` | `Europe/Moscow` |
| `LANG_` | `ru_RU.UTF-8` |
| `KEYMAP` / `CONSOLE_FONT` | `ru` / `cyr-sun16` |
| `ESP_SIZE` | `2G` (ядра для снэпшотов хранятся на ESP) |

Раскладка в Hyprland: `us,ru`, переключение Alt+Shift.

## Если что-то пошло не так

- Сборка `limine-snapper-sync` / `limine-mkinitcpio-hook` (GraalVM, ~300 МБ загрузки) могла упасть. Тогда скрипт пишет `limine.conf` вручную, без меню снэпшотов.
  После загрузки снэпшоты можно доустановить так:
  `yay -S limine-mkinitcpio-hook limine-snapper-sync`, затем добавить `btrfs-overlayfs` после `filesystems` в `HOOKS` (`/etc/mkinitcpio.conf`) и выполнить `sudo limine-update`.
- Хуки mkinitcpio — busybox (`base udev ...`), поэтому используется `btrfs-overlayfs`, а не `sd-btrfs-overlayfs`.

⚠️ Скрипт форматирует разделы. Внимательно проверяйте выбранный диск.
