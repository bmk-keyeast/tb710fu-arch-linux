# TB710FU Linux (Arch Linux ARM + KDE Plasma)

배경/설계: Obsidian `R&E/TB710FU 리눅스/` (00 MOC ~ 08)

## 잠금 상태 부팅 재설계: GKI v4 (2026-11-10)

**왜:** SpendyYT의 `deviceinfo`(header v2, `flash_method=fastboot`)는 언락 기기 기준. 잠긴 기기에 v2 boot_b를 넣었더니 ABL이 커널 시작 전에 슬롯 b를 부팅 불가로 표시하고 슬롯 a로 돌아감 (pstore에 Android 로그만 남음). 양산 펌웨어라 ABL 로그(`logfs`)는 비어 있음.

**설계:** 순정 슬롯 a의 v4 이미지를 헤더 템플릿으로 쓰고 내용물만 교체 (`build/bootv4.py`, 순정 이미지 왕복 재조립 시 바이트 동일 확인)

| 파티션 | 내용 |
|---|---|
| `boot_b` | v4, mainline `Image`(순정처럼 비압축) + cmdline, testkey 서명, 롤백 인덱스 순정값 |
| `vendor_boot_b` | v4, 순정 헤더/cmdline/bootconfig 유지, DTB = mainline `sm8650-lenovo-tb710fu.dtb`(msm-id 0x2b8 / board-id 0x8 = 이 기기 MTP 보드), ramdisk = 우리 initramfs |
| `init_boot_b` | v4, 빈 cpio (Android first-stage init이 덮어쓰지 않게) |
| `vbmeta_b` | 슬롯 a vbmeta + vendor_boot/init_boot 해시 갱신 후 testkey 재서명 (`avbsign.py refresh`, 무변경 시 순정과 동일 descriptor 확인) |
| 나머지 | 슬롯 a 사본 (`android/flash-slot-b.sh`가 페이로드 없는 파티션은 a에서 복사) |

- 커널에 `CONFIG_BOOT_CONFIG=y` 추가: v4에서 ABL이 ramdisk 뒤에 bootconfig를 붙이므로
- **진단 채널:** mainline DTS의 ramoops(`0xac300000`, 1MB)가 순정 Android와 같은 영역 → mainline이 조금이라도 돌면 Android 복귀 후 `/sys/fs/pstore`에 로그가 남음. `android/collect-boot-log.sh`(읽기 전용)로 모으고 `build/bootlog.py`로 판별

**실험 페이로드** (`build.sh v4 e1|e2|e3`, 전부 오프라인 해시 대조 통과)

| | 내용 | 확인하는 것 |
|---|---|---|
| **E2** | mainline v4 (위 표) | 본 시도. **2026-11-10 슬롯 b에 기록·재검증 완료** |
| E3 | E2 + dtbo 0으로 채움 | 순정 오버레이가 mainline DTB에 적용 실패해서 막히는지 |
| E1 | 순정 Android 커널 + `init=/없음 panic=5` | 슬롯 b 펌웨어 체인 + 서명 경로가 통과하는지 (유저공간 안 뜸 → 데이터 안전) |

**오프라인 검증 (기기 없이, 2026-11-10 밤)**

| 검증 | 도구 | 결과 |
|---|---|---|
| AOSP libavb `avb_slot_verify` (잠김, testkey만 신뢰, 요청 boot/dtbo/vendor_boot/init_boot, 실제 롤백 floor) | `build/avbverify/` | 순정 a, **거부됐던 v2**, E1, E1big, E2, E3 전부 OK → v2 거부는 AVB가 아니라 ABL 이미지 로드 문제. 음성 대조군(변조·다른 키·롤백)은 맞는 오류로 실패 |
| QEMU virt + ABL과 같은 initrd(vendor ramdisk + init_boot ramdisk + bootconfig 트레일러), 디스크 없음 | `build/qemu-test.sh nodisk` | `Load bootconfig: 216 bytes 16 nodes`, initramfs `/init` 실행, 폴백 hook 동작 |
| 같은 조건 + USB 이미지 사본(31G virtio) | `qemu-test.sh disk` | PARTUUID로 루트 마운트 → systemd → SDDM → 그래픽 타깃 → 로그인. **첫 부팅 버그 2개 발견·수정** (아래) |
| 수정 후 전체 부팅 2회 | 〃 | 1회차: 루트 8.4→15.5G 온라인 확장, `/home` 15.5G 생성·마운트. 2회차: 첫 부팅 건너뜀, `/home` 마운트 |

찾아서 고친 것:
- 첫 부팅 `/home` 생성 실패: ① `--relocate` 뒤 별도 `sfdisk -N 1`이 systemd 환경에서 실패, ② `lsblk -no PARTUUID`가 udev db 이전이라 빈 값 → GPT를 한 번에 다시 쓰고(루트 시작/PARTUUID 유지, PARTUUID는 `blkid`), 값이 없으면 GPT를 건드리지 않음 (`build/rootfs-files/tb710fu-firstboot`)
- 폴백 hook: qbootctl이 실패하면 비상 셸에 갇히던 것 → 항상 재부팅 (ABL 재시도 소진 시 슬롯 a). v4 페이로드는 `--overlay`로 최신 hook을 initramfs 뒤에 덧붙임 (sudo 없이)
- 디버그 도구: `qemu-shell.py`(QEMU 루트 셸 자동 조작), `imgpatch.sh`(이미지 안 파일 교체, sudo 없이), `write-usb.ps1`(USB 쓰기 + 읽어서 해시 검증)

**아침에 반영할 것** (기기·USB를 건드리므로 사용자 결정 후, UniXNU 세션과 사전 공지)
1. USB 다시 쓰기: `out/tb710fu-ssd.img.xz` (수정된 첫 부팅 포함, sha256은 `out/tb710fu-ssd.img.sha256`). 지금 USB의 첫 부팅 스크립트는 구버전이라 `/home`이 안 만들어짐 (부팅 자체는 됨)
2. 슬롯 b E2 재기록: 지금 슬롯 b의 E2는 폴백 hook 수정 전 버전. 테스트에 USB를 꽂는다면 차이 없음

**테스트 절차**
1. USB(이미지 기록됨)를 OTG로 연결 → KernelSU "Reboot to Linux"
2. Linux가 뜨면 성공. Android로 돌아오면 adb 연결 → `collect-boot-log.sh` → `bootlog.py`로 판별
   - mainline 로그 없음 → E3 → (그래도 없으면) E1
   - mainline 로그 있음 → 어디서 멈췄는지 보고 커널/initramfs 쪽 수정

## 슬롯 상태 (2026-11-10, 루트 Android에서 읽기 전용 덤프, `out/dump-20261110/`)

- 펌웨어 `ZUI_17.5.04.070 ROW`, 현재 슬롯 `_a`, 잠김(green), KernelSU 루트. EDL 프로그래머 없음 → **루트 Android에서 기록**
- `vbmeta_a`/`vbmeta_b` 둘 다 testkey 서명, `boot` chain도 testkey → **vbmeta 재키잉 불필요**
- `build/avbcheck.py`로 해시 대조: 슬롯 a 전부 MATCH, **슬롯 b는 dtbo·vendor_boot MISMATCH** (059 ROW vbmeta + PRC 이미지가 섞임). `vbmeta_system_b` 롤백 인덱스(1759622400)도 슬롯 a(1780617600)보다 낮음 → 슬롯 b는 지금 상태로는 부팅 거부될 것
- 그래서 [android/flash-slot-b.sh](android/flash-slot-b.sh): 슬롯 a의 `vbmeta vbmeta_system dtbo vendor_boot init_boot recovery`를 슬롯 b로 복사 + `boot_b`에 Linux. 슬롯 a는 안 건드림, 기본은 dry run, `--write`일 때 슬롯 b 백업 후 기록·검증
- **2026-11-10 기록 완료**: 다시 덤프해서 슬롯 b 해시 전부 MATCH, `boot_b` = `boot-signed.img`(testkey OK), 슬롯 a 7개 파티션 덤프와 동일, 활성 슬롯 `_a` 그대로. 슬롯 b 원본 백업: `out/backup-slot-b-20261110/` (기기에도 `/data/local/tmp/tb710fu-flash/backup-slot-b`)
- 첫 부팅 루트 크기: `min(ROOT_SIZE, 디스크 절반)` → 32GB USB면 루트 ~15.5G + `/home` ~15.5G

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
3. 기록: EDL이 되면 LTBox 고급 → 파티션 플래싱, 안 되면 루트 Android에서 `android/flash-slot-b.sh DIR --write` (슬롯 a 체인을 슬롯 b로 복사 + `boot_b`)
4. 슬롯 전환: KernelSU "Reboot to Linux" 액션, SSD 꽂고 부팅

### 자동 폴백 (슬롯 a로 돌아가기)

| 상황 | 동작 |
|---|---|
| SSD가 없거나 루트 파티션이 안 보임 | initramfs hook `tb710fu-fallback`이 `tb710fu.wait`초(기본 30) 기다린 뒤 `qbootctl -s a` + 재부팅 |
| 커널 패닉 | `panic=10`으로 10초 뒤 재부팅 → ABL 재시도 횟수 소진 시 슬롯 a |
| 정상 부팅 | `qbootctl-mark-successful`이 슬롯 b를 성공으로 표시 |
| 데스크톱에서 수동 | 앱 메뉴 "Android로 재부팅" |

대기 시간은 `config.env`의 `CMDLINE`에서 `tb710fu.wait=` 값으로 조정 (boot.img 재생성 필요).

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
