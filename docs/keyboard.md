# Lenovo Keyboard Pack (pogo) — reverse-engineered notes

Source: stock ZUI 17.5.04.070 `vendor_boot` → `lenovo_keyboard.ko` (drivers/tty/serial/lenovo_keyboard,
hooked into Qualcomm's `msm_geni_serial`), vendor HAL `vendor.lenovo.hardware.keyboard-service` +
`liblenovo_keyboard.so`. No source published.

## Hardware (stock DT `soc/lenovo_kb`)

| what | where |
|---|---|
| UART | QUP1 SE7 `0xa9c000` (Android `ttyHS1`), TX gpio62 / RX gpio63 (func `qup1_se7`), **921600 8N1** |
| power | `vdd_3p3` = PM8550 LDO B8 (`ldob8`, 1.8–3.3 V); `vdd_1p8` = LDO B1 |
| plug detect | gpio81 (irq) |
| UART wake | gpio137 (irq) |
| TX enable | gpio100 (output, high = host can transmit) |

Mainline `sm8650.dtsi` has `i2c7`/`spi7` at `0xa9c000` but no UART node; add `serial@a9c000`
(`qcom,geni-uart`, clocks/interconnects/power-domains copied from `i2c7`).

## Framing

```
7E FF  esc( seed  scrambled[0..n-1]  sum8 )  7E
```
- escape: `7D`→`7D 5D`, `7E`→`7D 5E`; `sum8` = 8-bit sum of the **escaped** (wire) bytes of
  seed + scrambled, itself escaped. Host→keyboard frames start with `7E 7E FF`.
- implementation + self-test against captured frames: `build/rootfs-files/tb710fu-keyboard`
- unscramble: `plain[i] = scrambled[i] ^ keyDict[(seed + i) & 0x3f]` (sender picks seed = random & 0x7f)

```
keyDict = b8 02 d9 57 c6 48 c2 13 d7 a6 30 bf 40 d3 07 ce
          c3 ab fa 51 62 18 bd 84 7d ca e0 cf f2 ac bc 12
          f5 14 d0 72 dc 1a 50 00 00 32 d1 7b 33 b6 10 dd
          6a 21 eb 7e 52 5b 3d 9f 85 cb 1f 66 73 96 a1 60
```

## Packets (`plain[0]` = type, `plain[1]` = length of the rest)

Verified 2026-11-12 on the device (Android, `echo 1 > /sys/devices/platform/soc/soc:lenovo_kb/debug_log`,
decoded with the framing above). Every report is sent twice ~9 ms apart; drop exact repeats.
No host command is needed: after plug-in (gpio81 low → vdd_3p3 on) the keyboard starts reporting by itself.

| packet | meaning |
|---|---|
| `11 08 MM 00 k1..k6` | keyboard, HID boot report. MM: 01 LCtrl, 02 LShift, 04 LAlt, 08 LMeta (search key), 10 RCtrl, 20 RShift, 40 RAlt. Keys are HID usages (0x29 Esc, 0x46 PrintScreen = screenshot key, 0x4c Delete, 0x4f-0x52 arrows …) |
| `12 04 uu uu 00 00` | consumer key, LE16 usage, 0 = released: 0x00e2 mute, 0x00ea vol-, 0x00e9 vol+, 0x0070 bright-, 0x006f bright+, 0x0391 mic mute, 0x0394 fullscreen, 0x0395 split screen, 0x0398 AI |
| `13 LL BB [f xL xH yL yH]×n` | touchpad, n = (LL-1)/5 fingers. BB bit0 = pad clicked (single clickpad button; left/right by position). f = slot<<4 \| 7 touching, \| 6 lifting. x 0..3199, y 0..1999 (stock: 4 MT slots) |
| `15 03 02 01 vv` | keys enabled: vv=0 folded back (keyboard firmware then sends no keys), 1 unfolded → `SW_TABLET_MODE = !vv` |
| `16 03 01 01 cc` | plug-in hello; `16 04 04 02 bb xx` heartbeat ~1 Hz (xx varies 00/04/0c/0d) |
| `7d 0a 03 08 "HJN008QS"` | firmware version (reply after plug-in) |

Host → keyboard (`7E 7E FF` frames), each echoed back by the keyboard:

| command | meaning |
|---|---|
| `6a 03 27 01 vv` | Caps Lock LED |
| `6a 03 28 01 vv` | mute LED |
| `6a 03 29 01 vv` | mic-mute LED |
| `6a 04 33 02 00 00` | touchpad autosleep off (stock sends it after plug-in) |

Stock input devices: "Lenovo Keyboard Pack For Yoga Tab Keyboard/Touchpad", vendor 0x17ef product 0x6271.

## Power (L8B) on Linux — read before switching it

Stock (`lenovo_keyboard.ko`, disassembled): `keyboard_power_init` does `regulator_get("vdd_3p3")` and
`regulator_set_voltage(3300000, 3300000)`; `keyboard_power_on` calls `regulator_enable` only after the
plug GPIO says attached (and on screen on/off). No load or mode calls; the stock DT gives L8B
1.8–3.3 V, init 1.8 V, high-power mode. On the stock DT only the keyboard and an OCP notifier use L8B.

2026-11-15: `regulator-boot-on` on L8B (3.304 V) reset the tablet at 0.37 s of every boot, keyboard
attached or not. Mainline rpmh caches the voltage while the rail state is unknown, so 3.304 V
(above stock's 3.300 V) reached the AOP only with that enable: the earlier build that "survived
3.304 V" never sent it. Open hypotheses: the AOP rejects > 3.300 V, or BOB1 dips when the rail turns
on that early (BOB1 also feeds the eUSB2 repeater L5B and the panel L13B).

Measured on stock Android 2026-11-15 (`android/kb-power-probe.sh`, keyboard attached, gpio81 low):
`pm_humu_l8` enabled, 3300000 uV, opmode fast (HPM), one user `soc:lenovo_kb-vdd_3p3`, 0 mA
requested. L9B (same input pair) is camera-only (eeprom/sensor `cam_vaf`) and off.

Rules now:
- Nothing enables L8B at boot. The DT only has a `regulator-virtual-consumer` (`keyboard-vdd`).
- 3.296 V: on the 8 mV grid and not above 3.300 V.
- First switch is manual: `sudo tb710fu-keyboard --vdd-test` (5 s on, then off; marks in the kernel
  log, kept by ramoops on a reset). Only after it survives does the daemon power the keyboard.
- Test from the kShimC menu (Android is the default entry, so a reset ends in Android, not a loop),
  with the USB-C port empty (a reset in host mode once left the PMIC's USB input stuck).
- Order: keyboard detached → `--vdd-test`; then attach it and restart `tb710fu-keyboard`.
