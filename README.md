# TB710FU Linux

**레노버 TB710FU(Xiaoxin Pad Pro GT, Snapdragon 8 Gen 3 / SM8650)를 부트로더 잠금을 유지한 채 Arch Linux ARM + KDE Plasma로 부팅**하는 빌드 도구 모음입니다.

- 안드로이드는 슬롯 a에 그대로 두고, 리눅스는 **슬롯 b**에 AOSP testkey로 서명해서 넣습니다(LTBox 방식). fastboot와 언락이 필요 없습니다.
- 루트 파일시스템은 USB-C로 연결한 SSD(NVMe)에 둡니다. 내장 저장소(`userdata` 축소)로 옮기는 것은 다음 단계입니다.
- 커널은 SpendyYT의 메인라인 7.2 트리를 기반으로 합니다.

배경과 설계 메모: Obsidian `R&E/TB710FU 리눅스/`

## 현재 상태 (2026-11-13)

| 항목 | 상태 | 비고 |
|---|---|---|
| 잠긴 부트로더에서 메인라인 부팅 | ✅ | 슬롯 b, `build.sh v4 e3` |
| USB-C 호스트 + 외장 루트 | ✅ | initramfs에서 ADSP를 먼저 띄움 |
| KDE Plasma (Wayland) | ✅ | freedreno FD750 GPU 가속 확인 |
| Wi-Fi, SSH | ✅ | |
| 키보드 팩 (포고 핀) | 🟡 빌드됨, 기기 미검증 | 프로토콜은 안드로이드 캡처로 검증 → [docs/keyboard.md](docs/keyboard.md) |
| 화면 회전 센서 | 🟡 빌드됨, 기기 미검증 | ADSP 센서 허브(SSC) 경유, 장착 방향 보정 필요할 수 있음 |
| 리눅스를 안드로이드 `/data`에 두기 | 🟡 스크립트 준비, 미실행 | 순정 암호화 해제 + 공간 공유 → [docs/userdata.md](docs/userdata.md) |
| 절전(deep suspend) | ❌ | 깨어나지 않음 → 절전 타깃을 막아 둠 |
| 화면 끔 후 다시 켜기 | ⚠️ | DPMS on 때 리셋된 적 있음 → 자동 화면 끔 꺼 둠 |

USB 메모리는 쓰기 지연(1회 약 175ms)이 커서 Plasma가 수 분씩 멈췄습니다. **NVMe SSD를 권장**합니다.

## 부팅 구조

ABL은 순정 GKI v4 레이아웃만 받아 줍니다. 그래서 순정 슬롯 a 이미지를 헤더 템플릿으로 쓰고 내용만 바꿉니다([build/bootv4.py](build/bootv4.py)).

| 슬롯 b 파티션 | 내용 |
|---|---|
| `boot_b` | 메인라인 `Image` + cmdline, testkey 서명, 순정 롤백 인덱스 |
| `vendor_boot_b` | 메인라인 DTB + 우리 initramfs (순정 헤더·bootconfig 유지) |
| `init_boot_b` | 빈 ramdisk (안드로이드 first-stage init이 덮어쓰지 않게) |
| `dtbo_b` | 0으로 채움 |
| `vbmeta_b` | 슬롯 a vbmeta에서 해시만 갱신해 testkey로 재서명 |
| 나머지 | 슬롯 a 사본 |

ABL을 통과하려면 세 가지가 필요했습니다.
1. **dtbo를 비울 것.** 순정 오버레이가 메인라인 DTB에 적용되지 않으면 ABL은 DTB를 아예 복사하지 않습니다(`ApplyOverlay`는 성공할 때만 복사). dtbo가 무효면 ABL이 DTB를 직접 복사합니다.
2. **DTB의 `qcom,board-id = <8 0>`.** RAM이 4GB를 넘으면 DDR 비트가 0이어야 합니다.
3. **`/soc/cache-controller` 빈 노드.** ABL의 `UpdateDeviceTree`가 이 노드를 찾습니다.

## 빌드 (WSL Ubuntu)

### 준비

```bash
git clone --recurse-submodules https://github.com/bmk-keyeast/tb710fu-arch-linux.git
```

**커널**은 기본으로 [ArmadaOS Freedom](https://github.com/ArmadaOS-Freedom/armadaos-freedom)의 통합 커널(Linux 7.2.6 + TB710FU 지원)에 이 저장소의 오버레이 [kernel/armada-overlay/tb710fu-locked](kernel/armada-overlay/tb710fu-locked)(키보드 팩 UART, 부팅 옵션)를 얹어 GitHub Actions([kernel.yml](.github/workflows/kernel.yml), ARM 러너)에서 빌드합니다. `build.sh kernel`은 그 결과물을 내려받기만 합니다(`gh` 필요). 예전 SpendyYT 트리로 로컬 빌드하려면 `KERNEL_SRC=spendy`와 함께 WSL ext4에 트리를 둡니다:

```bash
wsl -d Ubuntu --cd ~ -- git clone --depth 1 https://github.com/SpendyYT/tb710fu-linux.git tb710fu/tb710fu-linux
```

순정 롬 패키지의 `dspso.bin` 경로(센서용 ADSP 라이브러리)를 [build/config.env](build/config.env)의 `DSPSO`에 맞춰 둡니다.

### 단계

출력은 WSL `~/tb710fu/out/`에 생깁니다. sudo가 필요한 단계는 비밀번호를 직접 입력합니다.

| 명령 | 하는 일 |
|---|---|
| `build.sh deps` | 빌드 도구 설치 (clang/lld, qemu-user-static, arch-install-scripts 등) |
| `build.sh kernel` | CI 커널 내려받기(`KERNEL_SRC=armada`, 기본) 또는 SpendyYT 트리 로컬 빌드(`spendy`). 둘 다 `out/kernel-<종류>/lib/modules/<버전>/`에 같은 모양으로 둡니다 |
| `build.sh rootfs` | ALARM + Plasma(qemu chroot), 모듈·펌웨어·UCM, 센서 스택, 키보드 데몬, initramfs |
| `build.sh image` | `tb710fu-ssd.img.xz` — SSD에 통째로 쓰는 디스크 이미지 |
| `build.sh v4 e3` | `v4/e3/` — 슬롯 b 페이로드 (testkey 서명, SHA256SUMS 포함) |

### 설정 ([build/config.env](build/config.env))

- **`ROOT_FS`**: 루트와 `/home`의 파일시스템을 고릅니다.
  - `ext4` (기본): 리눅스가 안 뜰 때 안드로이드에서 마운트해 고칠 수 있습니다.
  - `btrfs`: 스냅샷과 zstd 압축을 씁니다. 안드로이드 GKI 커널에는 btrfs가 없어서 안드로이드에서는 못 읽습니다.
  - 예: `ROOT_FS=btrfs build.sh rootfs && ROOT_FS=btrfs build.sh image`
- **`ROOT_DEV`**: 루트 위치. `ssd`(기본) 또는 `userdata`(안드로이드 `/data` 안의 `/linux` 폴더, [docs/userdata.md](docs/userdata.md)). 슬롯 b 페이로드만 달라집니다(`out/v4/e3`, `out/v4/e3-userdata`).
- **`ROOT_SIZE`**: 첫 부팅 때 루트를 늘릴 크기(기본 64G, 최대 디스크 절반). 나머지는 `/home`이 됩니다.
- **`PACKAGES`**, 사용자 이름, 임시 비밀번호(`tb710fu` → 첫 부팅 후 `passwd`).
- **로컬 오버레이**: Git에 올리면 안 되는 파일(Wi-Fi keyfile, SSH 공개키, sshd 활성화 등)은 WSL `~/tb710fu/local-overlay/`에 rootfs 경로 그대로 두면 rootfs 마지막에 덮어씌워집니다.

## 설치

### 1. SSD에 이미지 쓰기

`tb710fu-ssd.img.xz`를 balenaEtcher(압축 그대로)나 Rufus(압축 풀어서 DD 모드)로 씁니다. [build/write-usb.ps1](build/write-usb.ps1)도 쓸 수 있습니다(관리자 권한, `-Quick`이면 검증 생략).

첫 부팅 때 `tb710fu-firstboot`가 루트를 늘리고 남은 공간을 `/home`으로 만듭니다. 16GB SSD라면 루트 약 9GB, `/home` 약 6GB가 됩니다.

### 2. 슬롯 b에 기록 (루트 안드로이드)

```bash
adb push v4/e3 android/flash-slot-b.sh /data/local/tmp/
adb shell su -c "sh /data/local/tmp/flash-slot-b.sh /data/local/tmp/e3"          # 점검만
adb shell su -c "sh /data/local/tmp/flash-slot-b.sh /data/local/tmp/e3 --write"  # 기록
```

슬롯 a는 건드리지 않습니다. 기록 전에 슬롯 b를 백업하고, 기록 후 해시를 다시 확인합니다.

### 3. 슬롯 전환

- **안드로이드 → 리눅스:** [android/switch-to-linux.zip](android/switch-to-linux.zip)을 KernelSU 모듈로 설치하고 Action 버튼을 누릅니다(부트 컨트롤 HAL로 슬롯 b 활성화 후 재부팅).
- **리눅스 → 안드로이드:** 앱 메뉴의 "Android로 재부팅".

### 리눅스에서 슬롯 b 고쳐 쓰기

리눅스 안에서 새 페이로드를 쓸 때는 **반드시** `sudo tb710fu-update-slot-b DIR --write`를 씁니다. 슬롯 b만 쓰고 다시 읽어 확인한 뒤 `qbootctl -s b`로 슬롯을 다시 무장합니다(성공 표시 지움, 재시도 1회). 리눅스는 정상 부팅마다 슬롯 b를 "성공"으로 표시하는데, ABL은 성공 표시가 있는 슬롯의 재시도 횟수를 줄이지 않습니다. 그래서 `dd`로 직접 쓰고 재부팅하면 망가진 페이로드가 끝없이 재부팅을 반복합니다(2026-11-15에 실제로 겪어 EDL로 복구).

### 자동 폴백

| 상황 | 동작 |
|---|---|
| SSD가 없거나 루트가 안 보임 | initramfs가 `tb710fu.wait`초(기본 30) 기다린 뒤 슬롯 a로 바꾸고 재부팅 |
| 커널 패닉 | `panic=10`으로 재부팅 → ABL 재시도가 소진되면 슬롯 a |
| initramfs 전에 리셋 (2026-11-15 루프) | 다시 무장된 슬롯이면 ABL 재시도 1회 소진 → 슬롯 a |
| 정상 부팅 | 데스크톱이 뜨고 60초 뒤 `qbootctl-mark-successful`이 슬롯 b를 성공으로 표시 |

### 2026-11-15 사고와 재발 방지

✔ = 펌웨어·소스에서 확인, 추정 = 확인 못 함.

경과: 리눅스에서 USB-C 호스트 모드(NVMe)로 쓰던 중 L8B `regulator-boot-on` 페이로드를 `dd`로 슬롯 b에 쓰고 재부팅
→ 0.37초에 리셋 루프 → 슬롯 b가 "성공" 상태라 ABL이 슬롯 a로 넘어가지 않음 → USB가 모든 모드에서 죽어(충전 0 A,
PC 인식 없음) fastboot·EDL 모두 불가.

원인 사슬:
1. **폴백 없음:** ABL은 성공 표시가 있는 슬롯의 재시도를 세지 않음 ✔(LinuxLoader: `Active Slot %s is bootable,
   retry count`, `Slot %s is unbootable, trying alternate slot`). 리눅스가 정상 부팅마다 성공 표시를 했음.
2. **USB가 안 살아남:** 충전·Type-C는 ADSP의 charger_pd가 관리함 ✔. 호스트 모드는 PMIC(PM8550B) OVP를 수동으로
   바꾸고 OTG를 켬 ✔. 이를 되돌리는 건 charger_pd 초기화뿐 ✔. XBL은 USB suspend를 풀지 않고 ✔, UEFI는
   배터리가 3.3V 미만일 때만 충전 펌웨어를 올림 ✔. ADSP 전에 죽는 커널이 루프를 돌면 PMIC 상태를 아무도 되돌리지
   않음(추정). 1차 루프(ADSP가 올라온 루프)는 안드로이드로 돌아가 USB가 정상이었음.
3. **탈출구 없음:** 딥 플래시 케이블 EDL도 XBL이 충전기로 SDP를 먼저 감지해야 함 ✔ → VBUS가 안 보이면 불가.

방지책:
- **슬롯 b 쓰기는 `tb710fu-update-slot-b`만** (위 절). `qbootctl -s b`는 A/B 플래그를 0xF(우선순위 3, 활성,
  재시도 1, 성공 아님)로 씀 ✔(qbootctl 소스). 실패 부팅 한 번이면 ABL이 슬롯 a로 감 → 안드로이드 ADSP가 USB를
  다시 초기화(1차 루프에서 실제로 그랬음).
- **성공 표시를 늦춤:** `graphical.target` 뒤 60초. 부팅 직후 리셋되는 페이로드도 폴백됨.
- **위험한 DT 변경(레귤레이터·전원)은** 위 두 가지가 갖춰진 상태에서만, USB-C 기기를 뺀 채로 시험.
- **리눅스에서 충전이 되는지 한 번 확인** (아직 안 해 봄): 충전기를 꽂고 `/sys/class/power_supply/*/status`.
- 안 한 것: 종료 시 Type-C를 sink로 돌리는 유닛(효과 미확인), 리눅스 `reboot edl`(DT에 EDL reboot-mode 없음 ✔,
  양산 기기의 다운로드 모드는 막혀 있을 가능성, 추정).

## 하드웨어 메모

- **키보드 팩:** UART(QUP1 SE7, 921600 8N1) + 전원(LDO B8 3.3V) + 연결 감지(gpio81). 스크램블된 PPP 비슷한 프레임을 [build/rootfs-files/tb710fu-keyboard](build/rootfs-files/tb710fu-keyboard)가 uinput 키보드·클릭패드·태블릿 모드 스위치로 바꿉니다. 뒤로 접으면 키보드 펌웨어가 키를 막고 태블릿 모드 패킷을 보냅니다. 자세한 것은 [docs/keyboard.md](docs/keyboard.md).
- **gpio81은 홀 센서가 아니라 키보드 연결 감지입니다.** DT에서 `SW_LID`로 잡혀 있어 리드가 "닫힘"으로 보였고, 이제 `SW_DOCK`입니다.
- **센서:** IMU(Bosch BMI3xx)와 조도(Sensortek STK6B9x)는 ADSP 센서 허브 뒤에 있습니다. [build/rootfs-files/build-sensors.sh](build/rootfs-files/build-sensors.sh)가 hexagonrpcd, libssc, SSC 지원 iio-sensor-proxy를 고정 커밋으로 빌드합니다. 회전 방향이 틀리면 `/etc/udev/rules.d/60-tb710fu-sensors.rules`의 `ACCEL_MOUNT_MATRIX`를 고칩니다.
- **USB-C 호스트:** pmic_glink가 ADSP에 의존하므로 initramfs에 `qcom_q6v5_pas`와 `adsp.mbn`이 들어갑니다.
- **펌웨어 경로:** `qcom/sm8650/xiaoxin/gt/*`는 그대로, GMU는 `updates/qcom/`, 토폴로지는 `qcom/sm8650/Lenovo-TB710FU-tplg.bin`, WCN7850 보드 파일은 `updates/`(배포판 것보다 우선).

## 디버깅

- **SSH:** 로컬 오버레이에 Wi-Fi와 키를 넣으면 부팅하자마자 `ssh root@<IP>`로 들어갈 수 있습니다(키 인증만).
- **부팅 로그:** 메인라인 ramoops(`0xac300000`)가 안드로이드와 같은 영역입니다. 리눅스가 조금이라도 돌았다면 안드로이드로 돌아온 뒤 [android/collect-boot-log.sh](android/collect-boot-log.sh)로 모아 [build/bootlog.py](build/bootlog.py)로 판별합니다.
- **리눅스 디스크 손보기:** 안드로이드에서 [android/fix-linux-usb.sh](android/fix-linux-usb.sh)(ext4만), Windows에서 [build/ext4grab.py](build/ext4grab.py)(WSL이 디스크를 못 붙일 때).
- **오프라인 검증:** [build/avbverify/](build/avbverify/)(AOSP libavb로 슬롯 체인 검증), [build/qemu-test.sh](build/qemu-test.sh)(ABL과 같은 initrd 구성으로 QEMU 부팅).

## 도구 목록 (`build/`)

| 파일 | 용도 |
|---|---|
| `bootv4.py` | 순정 v4 boot/vendor_boot/init_boot를 템플릿으로 재조립 |
| `avbsign.py` | testkey 서명, vbmeta 해시 갱신·재키잉 (순수 Python, `selftest` 있음) |
| `avbinfo.py`, `avbcheck.py` | AVB 메타데이터 보기, 슬롯 해시 대조 |
| `dtcheck.py`, `dtbprop.py` | ABL이 요구하는 DT 노드 점검, 속성 교체 |
| `ablunpack.py`, `bootimginfo.py` | ABL·부트 이미지 분석 |
| `ext4grab.py` | Windows에서 ext4 파티션 읽기·차분 적용 |
| `qemu-test.sh`, `qemu-shell.py` | QEMU 부팅 테스트 |
| `write-usb.ps1` | 디스크에 이미지 쓰기 + 검증 |

## 출처

| 레포 | 위치 | 용도 |
|---|---|---|
| [SpendyYT/tb710fu-linux](https://github.com/SpendyYT/tb710fu-linux) | WSL `~/tb710fu/tb710fu-linux` | 커널 7.2 (고정 `4d04410798b5`) |
| [SpendyYT/device-lenovo-tb710fu](https://github.com/SpendyYT/device-lenovo-tb710fu) | `device-lenovo-tb710fu/` | ALSA UCM |
| [SpendyYT/linux-firmware-tb710fu](https://github.com/SpendyYT/linux-firmware-tb710fu) | `linux-firmware-tb710fu/` | 펌웨어, 센서 설정·레지스트리 |
| [SpendyYT/tb710fu-mainline](https://github.com/SpendyYT/tb710fu-mainline) | `tb710fu-mainline/` | 메인라인 동작 현황 |
| [miner7222/LTBox](https://github.com/miner7222/LTBox) | `LTBox/` | 루트, testkey, EDL 도구 |

같은 SM8650인 Y700 Gen 3(TB321FU) 포트([tb321fu-linux](https://github.com/vitalo233-eng/tb321fu-linux), [SteamOS-ARM-Port](https://github.com/hashtagbasit/SteamOS-ARM-Port))는 언락이나 OpenABL을 전제로 해서 그대로 쓰지는 못했고, PARTUUID 루트와 Arch rootfs 조립 아이디어를 가져왔습니다.
