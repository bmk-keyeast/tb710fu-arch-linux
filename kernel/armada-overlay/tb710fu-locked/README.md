# ArmadaOS kernel overlay: tb710fu-locked

Applied on top of [ArmadaOS Freedom](https://github.com/ArmadaOS-Freedom/armadaos-freedom)'s
unified kernel (`packages/kernel`, `KERNEL_OVERLAYS=tb710fu-locked`, see its `overlays/README.md`)
by `.github/workflows/kernel.yml`.

- `dts/sm8650-lenovo-tb710fu-locked.dts` includes Armada's `sm8650-lenovo-tb710fu.dts` and adds the
  Lenovo Keyboard Pack UART (QUP1 SE7), the TX-enable pin and gpio81 as `SW_DOCK`.
- `config/tb710fu-locked.config`: USB storage/UAS, `BOOT_CONFIG` (v4 vendor_boot), f2fs features for
  `ROOT_DEV=userdata`, uinput, `LOCALVERSION=-tb710fu`.

- `patches/0001-qcom-battmgr-tb710fu-current-sign.patch`: the ADSP reports the battery current
  with the opposite sign; flipped for `lenovo,tb710fu` so upower shows charging.
- `patches/0002-drm-panel-nt36532-tb710fu-60hz-mode.patch`: a 60 Hz mode (120 Hz timing, vtotal doubled). Not tried on the device yet.
- `patches/0003-remoteproc-qcom_q6v5-handover-once.patch`: stops the ADSP handover interrupt storm (deinthoedoka/TB710FU-Archlinux).
- `CONFIG_ZSWAP` (off by default), `CONFIG_INPUT_UINPUT=y`.
- `CONFIG_CPU_IDLE_GOV_TEO` (selected by `cpuidle.governor=teo` in build/config.env).

ABL's own DTB requirements (board-id `<8 0>`, `/soc/cache-controller`) are added by `build.sh v4`.
