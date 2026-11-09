# TB710FU Linux (Arch Linux ARM + KDE Plasma)

배경/설계: Obsidian `R&E/TB710FU 리눅스/` (00 MOC ~ 08)

## 현재 상태 (2026-11-05)

| 산출물 (WSL `~/tb710fu/out/`) | 상태 |
|---|---|
| 커널 `7.2.0-g4d04410798b5` | ✅ |
| `rootfs/` (ALARM + Plasma 6.8.2, 5.7G) | ✅ GMU 펌웨어, 캐시 삭제, networkd/sshd off, 자동 로그인, qbootctl 반영 |
| `initramfs.img`, `boot.img` (27MB) | ✅ |
| `qbootctl` (aarch64 크로스 빌드) | ✅ |
| `tb710fu-ssd.img.xz` (1.5G, 원본 8.4G) | ✅ e2fsck 통과, Windows 사본 [out/tb710fu-ssd.img.xz](out/tb710fu-ssd.img.xz) |
| `boot-signed.img`, `vbmeta-signed.img` | ⚠️ **임시본**: 6월 boot + 8월 vbmeta 덤프로 서명. 실제로는 **슬롯 b 덤프**로 다시 `sign` |

**계획:** USB-C SSD로 먼저 부팅해 기능 테스트 → 이후 내부 `userdata` 쪽으로 정식 설치.

**남은 일**
1. LTBox로 `boot_b`, `vbmeta_b`(+ `boot_a`, `vbmeta_a`) 덤프 → `build.sh sign boot_b.img vbmeta_b.img`
2. `tb710fu-ssd.img.xz`를 SSD에 쓰기 → 부팅 → 기능 테스트

## 받기

```
git clone --recurse-submodules https://github.com/bmk-mikufan/tb710fu-arch-linux.git
# 커널 트리는 WSL ext4에 따로 (NTFS는 대소문자 구분 문제로 커널 트리가 깨짐)
wsl -d Ubuntu --cd ~ -- git clone --depth 1 https://github.com/SpendyYT/tb710fu-linux.git tb710fu/tb710fu-linux
wsl -d Ubuntu --cd ~ -- ln -sfn "<이 저장소 경로를 /mnt/c/... 로>/build" tb710fu/build
```

서브모듈: `device-lenovo-tb710fu`, `linux-firmware-tb710fu`, `tb710fu-mainline` (SpendyYT), `LTBox` (miner7222).

## 빌드 (WSL Ubuntu)

`~/tb710fu/build`는 이 폴더의 `build/`를 가리키는 심볼릭 링크. 출력은 WSL `~/tb710fu/out/`.

```
wsl -d Ubuntu --cd ~ -- bash tb710fu/build/build.sh all     # deps → kernel → rootfs → bootimg → image
```

| 단계 | 결과 |
|---|---|
| `deps` | clang/lld, qemu-user-static, arch-install-scripts 등 (sudo). Ubuntu `mkbootimg` 패키지는 고장 → `build/mkbootimg.py` 사용 |
| `kernel` | `sm8650_defconfig` + `USB_UAS=y`, `LLVM=1` 크로스 빌드 |
| `rootfs` | ALARM aarch64 + Plasma(SDDM, Wayland) + 한글(fcitx5-hangul) → `out/rootfs/`, 모듈/펌웨어/UCM 설치, mkinitcpio → `out/initramfs.img` |
| `bootimg` | `out/boot.img` (header v2, Image.gz+DTB, `root=PARTUUID=…`) — **서명 안 됨** |
| `image` | `out/tb710fu-ssd.img.xz` — SSD에 덮어쓰는 디스크 이미지 (루트 파티션 하나) |
| `sign STOCK_BOOT STOCK_VBMETA` | AOSP testkey_rsa4096로 hash footer → `out/boot-signed.img` (+ 필요하면 `vbmeta-signed.img`) |

보조 도구 (`build/`, 전부 의존성 없는 Python/셸, `selftest` 있음): `avbinfo.py`(AVB 덤프 보기), `avbsign.py`(서명/vbmeta 재키잉), `mkbootimg.py`(header v2), `qbootctl.sh`(aarch64 크로스 빌드).

### 슬롯 전환

- Linux → Android: 앱 메뉴 "Android로 재부팅" (`/usr/bin/reboot-to-android`, qbootctl)
- Android → Linux: [android/switch-to-linux.zip](android/switch-to-linux.zip)을 KernelSU 모듈로 설치 → Action 버튼 (`bootctl` 사용, ROM에 없으면 아무것도 안 바꾸고 종료)
- Linux는 부팅마다 `qbootctl -m`(서비스)으로 슬롯 성공 표시 → 안 하면 ABL이 몇 번 뒤 Android 슬롯으로 되돌림

설정은 `build/config.env` (PARTUUID, 패키지 목록, 사용자). 첫 사용자 `bmk`의 임시 비밀번호도 여기 있다 → 첫 부팅 후 `passwd`.

### SSD 쓰기 (USB NVMe, 디스크 전체 지움)

1. 이미지: [out/tb710fu-ssd.img.xz](out/tb710fu-ssd.img.xz) (원본은 WSL `~/tb710fu/out/`)
2. **balenaEtcher**(`.img.xz` 바로 가능) 또는 **Rufus**(압축 풀어 `.img`로, DD 모드)로 SSD에 쓰기
3. 첫 부팅 때 `tb710fu-firstboot.service`가:
   - 백업 GPT를 디스크 끝으로 옮기고, 루트(p1)를 `ROOT_SIZE`(64G)로 늘림 + `resize2fs`
   - 남은 공간 전부를 `/home` 파티션(p2, `HOME_PARTUUID` 고정)으로 만들고 ext4 포맷, 빌드 때 만든 홈 디렉터리 복사
   - `/var/lib/tb710fu/firstboot-done`을 남겨 한 번만 실행
4. `/home`은 `/etc/fstab`에서 `PARTUUID=$HOME_PARTUUID`로 마운트 (`nofail`이라 실패해도 부팅은 됨)

SSD는 `ROOT_SIZE` + 여유 공간보다 커야 한다 (128GB 이상 권장).

### 기기에 올리기 (락 유지)

1. LTBox로 **덤프**: Linux를 올릴 슬롯의 `boot_*`, `vbmeta_*` (+ 전체 백업, Obsidian 04 Phase 1)
2. `build.sh sign boot_b.img vbmeta_b.img` 실행. 서명은 외부 avbtool 없이 [build/avbsign.py](build/avbsign.py)(순수 Python, AOSP `testkey_rsa4096.pem`)로 한다.
   - vbmeta가 testkey로 서명돼 있지 않으면 **중단**: 이 펌웨어는 testkey 경로가 막힌 것
   - 롤백 인덱스와 파티션 크기는 순정 boot 덤프 값을 그대로 쓴다
   - vbmeta의 `boot` chain 키가 이미 testkey면 → `boot-signed.img`만 만든다
   - chain 키가 Lenovo 정식 키(`8fcb…`, 8월 펌웨어가 이 경우)면 → `boot` chain 키만 testkey로 바꾸고 재서명한 `vbmeta-signed.img`도 만든다. 나머지 descriptor는 원본 그대로
   - `python3 -I build/avbsign.py selftest build/testkey_rsa4096.pem`로 자체 점검. 실제 덤프 3개(LTBox/Lenovo 서명) 검증 통과 확인함
3. LTBox 고급 → **파티션 플래싱**으로 같은 슬롯에 기록: `boot-signed.img` → `boot_b`, (있으면) `vbmeta-signed.img` → `vbmeta_b`. `vbmeta_a`(Android)는 건드리지 않는다
4. 슬롯 전환 (`fastboot --set-active=b`가 안 되면 EDL), SSD 꽂고 부팅

> 미검증: Lenovo ABL이 header v2 + 우리 ramdisk를 그대로 받는지. 실패하면 ABL이 반대 슬롯으로 롤백하거나 EDL로 복구.

### 참고: Y700 Gen 3 (TB321FU, 같은 SM8650)

- [vitalo233-eng/tb321fu-linux](https://github.com/vitalo233-eng/tb321fu-linux), [SteamOS-ARM-Port](https://github.com/hashtagbasit/SteamOS-ARM-Port)는 둘 다 **언락 또는 OpenABL/GRUB EFI** 전제라 락 걸린 TB710FU에는 그대로 안 맞는다
- 가져온 아이디어: PARTUUID 루트, 기기 전용 펌웨어 우선 경로, Arch 기반 rootfs 조립

## 클론 위치

| 레포 | 위치 | 용도 |
|---|---|---|
| SpendyYT/tb710fu-linux (커널 7.2, `--depth 1`) | **WSL** `~/tb710fu/tb710fu-linux` (`\\wsl$\Ubuntu\home\bmk\tb710fu\tb710fu-linux`) | 커널 소스. NTFS는 대소문자 구분이 없어 커널 트리가 깨지므로 WSL ext4에 둠 |
| SpendyYT/device-lenovo-tb710fu | `./device-lenovo-tb710fu` | deviceinfo(boot.img 오프셋), ALSA UCM |
| SpendyYT/linux-firmware-tb710fu | `./linux-firmware-tb710fu` | 펌웨어 블롭 + hexagon 설정 |
| SpendyYT/tb710fu-mainline | `./tb710fu-mainline` | 동작 현황 |
| miner7222/LTBox | `./LTBox` | EDL 덤프/플래시, testkey 서명 (Windows 릴리스 바이너리 사용 권장) |

## Arch로 옮길 때 필요한 정보 (조사 결과)

- 커널 config: `arch/arm64/configs/sm8650_defconfig`는 완성된 `.config`(clang, `LLVM=1`). Rust/ZBOOT 꺼짐 → `Image.gz`
  - UFS, ext4, USB storage, DRM_MSM, QRTR, PD_MAPPER이 built-in이라 initramfs 없이도 부팅 가능성 있음
- DTB: `qcom/sm8650-lenovo-tb710fu.dtb`
- boot.img (deviceinfo): header v2, pagesize 4096, base 0, kernel 0x8000, ramdisk 0x01000000, dtb 0x01f00000, tags 0x100, DTB append
  - cmdline: `clk_ignore_unused pd_ignore_unused console=tty0`
- 펌웨어 경로 (DTS `firmware-name` 기준):
  - `qcom/sm8650/xiaoxin/gt/*` → `/usr/lib/firmware/qcom/sm8650/xiaoxin/gt/`
  - `novatek/`, `awinic/` → 그대로
  - `tplg/Lenovo-TB710FU-tplg.bin` → `/usr/lib/firmware/qcom/sm8650/` (커널은 `qcom/<driver_name=sm8650>/<model>-tplg.bin`을 찾음)
  - `ath12k/`, `qca/` → `linux-firmware` 패키지와 겹치므로 `/usr/lib/firmware/updates/`에 (우선순위 높음)
  - `usr/share/qcom` → `/usr/share/qcom` (hexagonrpcd용, Arch 공식 저장소엔 hexagonrpcd 없음)
- UCM: `HiFi.conf`, `Lenovo-TB710FU.conf` → `/usr/share/alsa/ucm2/Lenovo/tb710fu/`, `conf.d/sm8650/Lenovo-TB710FU.conf` 심볼릭 링크
- pinned commits: kernel `4d04410798b5`, firmware `45a7e188a45b`
