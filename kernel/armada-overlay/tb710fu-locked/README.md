# ArmadaOS kernel overlay: tb710fu-locked

Applied on top of [ArmadaOS Freedom](https://github.com/ArmadaOS-Freedom/armadaos-freedom)'s
unified kernel (`packages/kernel`, `KERNEL_OVERLAYS=tb710fu-locked`, see its `overlays/README.md`)
by `.github/workflows/kernel.yml`.

- `dts/sm8650-lenovo-tb710fu-locked.dts` includes Armada's `sm8650-lenovo-tb710fu.dts` and adds the
  Lenovo Keyboard Pack UART (QUP1 SE7), the TX-enable pin and gpio81 as `SW_DOCK`.
- `config/tb710fu-locked.config`: USB storage/UAS, `BOOT_CONFIG` (v4 vendor_boot), f2fs features for
  `ROOT_DEV=userdata`, uinput, `LOCALVERSION=-tb710fu`.

ABL's own DTB requirements (board-id `<8 0>`, `/soc/cache-controller`) are added by `build.sh v4`.
