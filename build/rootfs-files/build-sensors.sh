#!/bin/bash
# Run inside the rootfs chroot (build.sh rootfs) or on the tablet as root.
# Sensors sit behind the ADSP sensor hub (SSC), not on an AP bus:
#   hexagonrpcd  serves the ADSP sensor PD its config/registry/DSP libs (/usr/share/qcom/sm8650/Lenovo/tb710fu)
#   libssc       talks to SSC over QRTR
#   iio-sensor-proxy (SSC build) -> D-Bus -> KWin auto-rotate
# None of these exist in ALARM with SSC enabled, so build pinned upstream commits.
set -euo pipefail
src=/var/tmp/tb710fu-sensors
# deps for the builds below; pacman's download sandbox doesn't work under qemu-user
# -Syu: a stale package db 404s on the mirror, and -Sy alone would be a partial upgrade
for i in 1 2 3; do
	pacman -Syu --needed --noconfirm --disable-sandbox --disable-download-timeout \
		base-devel git meson glib2-devel protobuf-c libqmi libgudev polkit && break
	[ $i = 3 ] && exit 1
	sleep 10
done
build() { # name url commit [meson args]
	local n=$1 url=$2 rev=$3; shift 3
	rm -rf "$src/$n" && git init -q "$src/$n"
	git -C "$src/$n" fetch -q --depth 1 "$url" "$rev" && git -C "$src/$n" checkout -q FETCH_HEAD
	# the TB710FU sensor PD writes its registry (upstream hexagonrpcd is read-only)
	[ "$n" != hexagonrpc ] || python3 /usr/local/sbin/tb710fu-hexagonrpcd-registry-write "$src/$n"
	# KWin claims the accelerometer before the SSC driver has opened: start it once it has
	[ "$n" != iio-sensor-proxy ] || python3 /usr/local/sbin/tb710fu-iio-sensor-proxy-claim-race "$src/$n"
	meson setup "$src/$n/build" "$src/$n" --prefix=/usr --libexecdir=lib --buildtype=release "$@"
	meson install -C "$src/$n/build"
}
build hexagonrpc https://github.com/linux-msm/hexagonrpc.git da7a3742ab8d5273a281b70ee11f16fb2cb6a690
build libssc https://codeberg.org/DylanVanAssche/libssc.git 033e2a32095c024d6dbdfb1d4ae1db4a94be32f1
# ALARM's iio-sensor-proxy is built without SSC; replace it and keep pacman from bringing it back
pacman -Rdd --noconfirm iio-sensor-proxy 2>/dev/null || true
grep -q '^IgnorePkg.*iio-sensor-proxy' /etc/pacman.conf || sed -i 's/^\[options\]/&\nIgnorePkg = iio-sensor-proxy/' /etc/pacman.conf
build iio-sensor-proxy https://gitlab.freedesktop.org/hadess/iio-sensor-proxy.git ca0d5b08bd647afc5f8ead3ce00a44018fbc633f \
	-Dssc-support=enabled
rm -rf "$src"

# hexagonrpcd units run as fastrpc; the ADSP node is root-only by default
echo 'u fastrpc - "FastRPC server" -' > /usr/lib/sysusers.d/fastrpc.conf
systemd-sysusers fastrpc.conf
cat > /etc/udev/rules.d/60-tb710fu-sensors.rules <<'EOF'
SUBSYSTEM=="misc", KERNEL=="fastrpc-*", GROUP="fastrpc", MODE="0660"
# upstream only tags ADSP for light/compass; the accelerometer is on the ADSP here too.
# mount matrix from the device: upright landscape (keyboard side down) read left-up with the
# identity; this makes it "normal" (2026-11-16)
SUBSYSTEM=="misc", KERNEL=="fastrpc-adsp", ENV{IIO_SENSOR_PROXY_TYPE}+="ssc-accel", ENV{ACCEL_MOUNT_MATRIX}="0,1,0;-1,0,0;0,0,1"
EOF
systemctl enable hexagonrpcd-adsp-sensorspd.service
# the sensor PD's persist/sensors/registry (registry/, sns_reg_version, parsed_file_list.csv)
chown -R fastrpc:fastrpc /usr/share/qcom/sm8650/Lenovo/tb710fu/sensors/persist-registry
# auto-rotate keeps the accelerometer streaming; across s2idle the ADSP would keep waking
# (Armada's TB323FU measured ~36/s): stop the proxy before sleep, start it after
install -Dm755 /dev/stdin /usr/lib/systemd/system-sleep/tb710fu-sensors <<'EOF'
#!/bin/sh
case "$1" in
pre)	systemctl stop iio-sensor-proxy.service ;;
# hexagonrpcd-adsp-sensorspd has Conflicts=suspend.target: nothing starts it again otherwise
post)	systemctl start --no-block hexagonrpcd-adsp-sensorspd.service iio-sensor-proxy.service ;;
esac
exit 0
EOF
