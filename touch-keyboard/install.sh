#!/usr/bin/bash
# Restore the split Korean touch keyboard on the tablet (Arch Linux side).
#   sudo bash touch-keyboard/install.sh
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "sudo로 실행하세요." >&2; exit 1; }
src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
user=${SUDO_USER:-$(id -un 1000)}
home=$(getent passwd "$user" | cut -d: -f6)
uid=$(id -u "$user")
bus=/run/user/$uid/bus

as_user() {
    runuser -u "$user" -- env HOME="$home" XDG_RUNTIME_DIR="/run/user/$uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" "$@"
}
put() { # mode source destination
    runuser -u "$user" -- install -Dm"$1" "$2" "$3"
}

pacman -S --needed --noconfirm plasma-keyboard qt6-virtualkeyboard fcitx5 fcitx5-hangul fcitx5-qt fcitx5-gtk python-evdev

# Stop the running input method first: fcitx5 rewrites its profile when it exits.
[[ -S $bus ]] && as_user kwriteconfig6 --notify --file kwinrc --group Wayland --key InputMethod ""
pkill -u "$user" -x fcitx5 || true
sleep 1

if ! cmp -s "$src/tb710fu-keyboard" /usr/bin/tb710fu-keyboard; then
    [[ -e /usr/bin/tb710fu-keyboard ]] && cp -a /usr/bin/tb710fu-keyboard "/var/tmp/tb710fu-keyboard.bak-$(date +%Y%m%d-%H%M%S)"
    install -Dm755 "$src/tb710fu-keyboard" /usr/bin/tb710fu-keyboard
fi
install -Dm644 "$src/tb710fu-fcitx5.desktop" /usr/local/share/applications/tb710fu-fcitx5.desktop

layouts=$home/.local/share/plasma/keyboard/layouts
rm -rf "$layouts" "$home/.cache/plasma-keyboard/qmlcache"
runuser -u "$user" -- mkdir -p "$(dirname "$layouts")"
runuser -u "$user" -- cp -r "$src/layouts" "$layouts"

put 755 "$src/tb710fu-osk-tap" "$home/.local/bin/tb710fu-osk-tap"
put 644 "$src/tb710fu-osk-tap.service" "$home/.config/systemd/user/tb710fu-osk-tap.service"
put 644 "$src/org.fcitx.Fcitx5.autostart.desktop" "$home/.config/autostart/org.fcitx.Fcitx5.desktop"
put 644 "$src/fcitx5-environment.conf" "$home/.config/environment.d/fcitx5.conf"
put 644 "$src/fcitx5/profile" "$home/.config/fcitx5/profile"
put 644 "$src/fcitx5/config" "$home/.config/fcitx5/config"
runuser -u "$user" -- mkdir -p "$home/.config/systemd/user/graphical-session.target.wants"
runuser -u "$user" -- ln -sf ../tb710fu-osk-tap.service \
    "$home/.config/systemd/user/graphical-session.target.wants/tb710fu-osk-tap.service"
as_user kwriteconfig6 --file plasmakeyboardrc --group General --key enabledLocales ko_KR,en_US

# The keyboard daemon picks the input method that matches the dock state when it starts.
systemctl restart tb710fu-keyboard
if [[ -S $bus ]]; then
    as_user systemctl --user daemon-reload
    as_user systemctl --user restart tb710fu-osk-tap.service
fi
echo "터치 키보드를 복구했습니다."
