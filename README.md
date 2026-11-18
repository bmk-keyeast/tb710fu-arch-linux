# TB710FU Linux

**레노버 TB710FU(Xiaoxin Pad Pro GT, Snapdragon 8 Gen 3 / SM8650)를 부트로더 잠금을 유지한 채 Arch Linux ARM + KDE Plasma로 부팅**하는 빌드 도구 모음입니다.

- **부팅:** `boot_a`의 **kShimC 메뉴**에서 볼륨 키로 안드로이드와 리눅스를 고릅니다. 8초 뒤 기본값은 안드로이드라서, 리눅스가 실패해도 안드로이드로 돌아옵니다.
- **서명:** AOSP testkey(LTBox 방식)를 씁니다. fastboot와 언락은 필요 없습니다.
- **루트 파일시스템:** 암호화를 해제한 안드로이드 `/data` 안의 `/data/linux`에 있어서, 두 OS가 저장 공간을 나눠 씁니다.
- **커널:** ArmadaOS Freedom의 Linux 7.2.6에 이 저장소의 오버레이를 얹어 빌드합니다.

## 문서

| 문서 | 내용 |
|---|---|
| [AGENTS.md](AGENTS.md) | 에이전트 작업 규칙과 기술 참고 자료 |
| [docs/SYSTEM-STATE.md](docs/SYSTEM-STATE.md) | 지금 기기 상태, 기능별 동작 여부, 남은 일 |
| [docs/KERNEL-BUILD.md](docs/KERNEL-BUILD.md) | 커널 빌드, 패키징, 설치, 되돌리기, 업스트림 제출 |
| [docs/INCIDENTS.md](docs/INCIDENTS.md) | 사고 기록과 복구 방법 |

## 빌드 (WSL Ubuntu)

```bash
git clone --recurse-submodules https://github.com/bmk-keyeast/tb710fu-arch-linux.git
```

출력은 WSL의 `~/tb710fu/out/`에 생깁니다. 순정 롬의 `dspso.bin` 경로는 [build/config.env](build/config.env)의 `DSPSO`에 맞춰 둡니다.

| 명령 | 하는 일 |
|---|---|
| `build.sh deps` | 빌드 도구 설치 |
| `build.sh kernel` | CI에서 빌드한 커널 내려받기 |
| `build.sh rootfs` | ALARM + Plasma, 모듈, 펌웨어, 센서 스택, initramfs 조립 |
| `build.sh personal` | Wi-Fi, SSH 설정과 롬의 DSP 라이브러리 묶기(비공개) |
| `build.sh initramfs` | `rootfs-latest` 릴리스의 initramfs 받기 |
| `build.sh kshim [STOCK_DIR]` | kShimC 메뉴가 든 `out/kshim/boot_a.img` 만들기 |
| `build.sh image` | SSD에 쓰는 디스크 이미지 만들기 |
| `build.sh v4 e3` | 슬롯 b 페이로드 만들기 |

[build/config.env](build/config.env)의 주요 설정:

- **`ROOT_DEV`:** 루트 위치입니다. `userdata`(`/data/linux`, 지금 쓰는 방식) 또는 `ssd`.
- **`ROOT_FS`:** SSD 루트의 파일시스템입니다. `ext4`(기본) 또는 `btrfs`.
- **`ROOT_SIZE`:** SSD 첫 부팅 때 늘릴 루트 크기입니다.
- **`PACKAGES`, 사용자 이름, 임시 비밀번호:** 첫 부팅 후 `passwd`로 바꾸세요.
- **로컬 오버레이:** Git에 올리면 안 되는 파일은 WSL의 `~/tb710fu/local-overlay/`에 rootfs 경로 그대로 둡니다.

## 설치

전체 절차와 주의 사항은 [AGENTS.md의 설치 절차](AGENTS.md#5-설치-절차)를 보세요. 부트 파티션을 쓰는 작업이므로 먼저 [절대 규칙](AGENTS.md#1-절대-규칙)을 읽어야 합니다.

## 디버깅 도구

| 도구 | 용도 |
|---|---|
| [android/collect-boot-log.sh](android/collect-boot-log.sh), [build/bootlog.py](build/bootlog.py) | ramoops 부팅 로그 수집과 판별 |
| [android/fix-linux-usb.sh](android/fix-linux-usb.sh) | 안드로이드에서 리눅스 디스크 고치기(ext4) |
| [build/ext4grab.py](build/ext4grab.py) | Windows에서 ext4 파티션 읽기와 차분 적용 |
| [build/avbverify/](build/avbverify/), `avbinfo.py`, `avbcheck.py` | AVB 체인 검증 |
| `avbsign.py` | testkey 서명, vbmeta 해시 갱신 |
| `bootv4.py`, `bootimginfo.py`, `ablunpack.py` | 부트 이미지 재조립과 분석 |
| `dtcheck.py`, `dtbprop.py` | ABL이 요구하는 DT 노드 점검 |
| [build/qemu-test.sh](build/qemu-test.sh) | ABL과 같은 initrd 구성으로 QEMU 부팅 |
| [build/write-usb.ps1](build/write-usb.ps1) | 디스크에 이미지 쓰기와 검증 |

## 출처

| 저장소 | 용도 |
|---|---|
| [ArmadaOS-Freedom/armadaos-freedom](https://github.com/ArmadaOS-Freedom/armadaos-freedom) | 커널, 보드 DTS, kShimC 메뉴 |
| [miner7222/LTBox](https://github.com/miner7222/LTBox) | 루트, testkey, EDL 도구 |
| [deinthoedoka/TB710FU-Archlinux](https://github.com/deinthoedoka/TB710FU-Archlinux) | q6v5 handover 패치 |
| [SpendyYT/tb710fu-linux](https://github.com/SpendyYT/tb710fu-linux) | 초기 커널 |
| [SpendyYT/device-lenovo-tb710fu](https://github.com/SpendyYT/device-lenovo-tb710fu) | ALSA UCM |
| [SpendyYT/linux-firmware-tb710fu](https://github.com/SpendyYT/linux-firmware-tb710fu) | 펌웨어, 센서 설정 |
| [SpendyYT/tb710fu-mainline](https://github.com/SpendyYT/tb710fu-mainline) | 메인라인 동작 현황 |
