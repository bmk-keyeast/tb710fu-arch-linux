# TB710FU Linux

**레노버 TB710FU(Xiaoxin Pad Pro GT, Snapdragon 8 Gen 3 / SM8650)를 부트로더 잠금을 유지한 채 Arch Linux ARM + KDE Plasma로 부팅**하는 빌드 도구 모음입니다.

- **부팅:** `boot_a` 하나에 **kShimC 부트 메뉴**(ArmadaOS Freedom)를 넣어, 볼륨 키로 안드로이드와 리눅스를 고릅니다. 기본값은 안드로이드(8초)라서, 리눅스가 실패하거나 리셋되면 안드로이드로 돌아옵니다. 서명은 AOSP testkey(LTBox 방식)이고, fastboot와 언락은 필요 없습니다.
- **루트 파일시스템:** 안드로이드 `/data`(암호화 해제한 userdata) 안의 `/data/linux`에 있습니다(`ROOT_DEV=userdata`). → [docs/userdata.md](docs/userdata.md)
- **커널:** ArmadaOS Freedom의 7.2.6 unified 커널에 이 저장소의 오버레이(`kernel/armada-overlay/tb710fu-locked`)를 얹어 CI(`kernel.yml`)에서 빌드합니다.
- **슬롯 b:** 검증된 `v4-e3-20261115` 이미지를 그대로 둡니다. SSD가 없으면 30초 뒤 슬롯 a로 돌아갑니다.
- **에이전트는 먼저 읽으세요:** [docs/SYSTEM-STATE.md](docs/SYSTEM-STATE.md)에 현재 시스템 상태와 절대 규칙을 정리했습니다.
- **커널 재컴파일과 재패키징:** [docs/KERNEL-BUILD.md](docs/KERNEL-BUILD.md). 태블릿 안에서 빌드하는 도구는 [build/device-kernel.sh](build/device-kernel.sh)입니다.
- **인계 문서:** [docs/handoff-2026-11-16.md](docs/handoff-2026-11-16.md)에 지금까지 알아낸 사실과 남은 일을 모두 정리했습니다.

## 현재 상태 (2026-11-17, 기기 실측)

| 항목 | 상태 | 비고 |
|---|---|---|
| kShimC 부트 메뉴(boot_a) | ✅ | iOS 테마, 기본값 안드로이드. 지금 기기의 boot_a는 `90affd1f…`(키보드 커널 드라이버판, `KBPACK=1`) |
| 안드로이드 암호화 해제 + LTBox KernelSU 루트 | ✅ | `ro.crypto.state=unsupported`. LTBox Unroot와 GKI 모드는 쓰지 말 것 |
| `/data/linux` 루트 | ✅ | 안드로이드 `/data`는 root만 접근(`/mnt/.android/data`) |
| KDE Plasma (Wayland), Wi-Fi, SSH | ✅ | freedreno FD750 |
| 키보드 팩 | ✅ 커널 드라이버 | `tb710fu-kbpack`(serdev). 연결 감지 1초 디바운스, UART는 VDD가 켜진 동안만 열기, 놓친 "펴짐" 신호는 키·터치로 복구 → [docs/keyboard.md](docs/keyboard.md) |
| 키보드 뒤로 접기 | ✅ | 펌웨어가 키·터치패드를 끄고 `SW_TABLET_MODE=1` |
| 키보드 덮을 때 절전 | ✅ (재시험 필요) | 패킷으로는 접기와 구분 불가 → 조도 센서로 판별(`tb710fu-lid`). 절전 후 재구독·태블릿 모드 복구 수정은 재시험 전 |
| 화면 회전·조도 센서 | ✅ | hexagonrpcd registry 쓰기 패치, iio-sensor-proxy 경합·NULL GError 수정, 보정 행렬 확정. 근접·나침반 없음 |
| 충전 표시 | ✅ | ADSP가 배터리 전류 부호를 반대로 보냄 → battmgr 패치 |
| 절전 | ✅ s2idle | 전원 버튼·덮기로 재우고 전원 버튼으로 깨움. **deep은 리셋됨(사용 금지)** |
| 화면 자동 끄기 | ✅ | 배터리: 1분 어둡게, 2분 끄기, 30분 절전 |
| 전력 최적화 | 🟡 | TEO, 스피커 유휴 절전, PCIe ASPM L1.2, 배터리 시 고성능 코어 2.2 GHz 제한, 쓰기 주기 15초, zswap. 화면 켜짐 유휴 약 4 W, 화면 꺼짐 유휴 약 0.7 W |
| 키보드 Caps Lock LED | ⚠️ | 동작하지만 순정보다 어두움(원인 미상) |
| 가상 키보드 | 🟡 | Plasma 키보드는 Esc·화살표와 한글이 없음. fcitx5-osk 빌드는 중단됨(메모리 부족) |

## 앞으로 할 일

1. **재시험:** 덮기 → 깨우기 → 첫 키 입력에 태블릿 모드가 풀리는지(`36369b9`), 두 번째 덮기도 절전되는지(`4d849bd`).
2. **덮개를 열 때 깨우기:** 키보드 UART나 gpio81을 s2idle 깨우기 소스로 등록합니다(드라이버 작업).
3. **가상 키보드:** fcitx5-osk를 `CARGO_BUILD_JOBS=2`로 다시 빌드하고(zram이 켜져 있어야 함), KWin 입력기를 "Fcitx 5 Osk Kwin Launcher"로 바꿉니다.
4. **유휴 전력:** 앱을 모두 닫고 밝기 50%에서 다시 잽니다. plasmashell과 타이머 깨움을 줄이고, ADSP `q6v5 handover` 폭주가 재발하는지 봅니다.
5. **libssc 안정성:** `report_received` 크래시가 NULL GError 수정 뒤에도 남는지 지켜봅니다.
6. **Caps Lock LED가 어두운 원인:** 안드로이드에서 UART를 캡처해 비교합니다.
7. **보류:** SSD 이미지 쓰기, FEX/Steam.

자세한 사실, 백업 위치, 되돌리는 방법은 [docs/handoff-2026-11-16.md](docs/handoff-2026-11-16.md)에 있습니다.

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

### kShimC 메뉴 (boot_a, 슬롯 전환 없이 듀얼부팅)

[ArmadaOS Freedom](https://github.com/ArmadaOS-Freedom/armadaos-freedom)의 kShimC 부팅 메뉴를 boot_a에 넣습니다.
순정 안드로이드 커널과 리눅스 커널이 한 boot 이미지에 들어가고, 부팅할 때 볼륨 키로 고릅니다(8초 뒤 기본값
안드로이드). Freedom이 TB710FU에서 검증한 구조이며, vbmeta_a가 boot를 testkey로 체인하므로(✔ 이 기기) 잠긴
부트로더에서도 됩니다.

- 런타임과 패커: [.github/workflows/kshim.yml](.github/workflows/kshim.yml)이 Freedom의 고정 커밋에서
  `tb710fu_android_defconfig`로 빌드합니다.
- 패킹: `build.sh kernel` 다음 `build.sh kshim [STOCK_DIR]` → `out/kshim/boot_a.img`. `STOCK_DIR/boot_a.img`는
  **손대지 않은** boot_a 덤프여야 합니다. 리눅스 cmdline은 DTB `/chosen`에 들어가고(`tb710fu.kshim=1` 포함),
  initramfs는 스테이징한 커널의 모듈로 덮어씁니다.
- 리눅스의 "Android로 재부팅"은 kShimC로 부팅했을 때 슬롯을 바꾸지 않고 그냥 재부팅합니다(메뉴 기본값).
- 크기: 압축 후 약 93 MB로 96 MiB 파티션에 겨우 들어갑니다. initramfs를 7.2.6용으로 다시 만들면 줄어듭니다.
- 루트 파일시스템에 커널 7.2.6 모듈이 있어야 Wi-Fi, 터치, 소리, 배터리가 됩니다(`build.sh rootfs`).
- 되돌리기: boot_a 백업을 다시 쓰면 됩니다(9008 또는 루트 안드로이드).

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

복구 (실제로 된 순서):
1. **배터리 방전:** fastboot 화면(볼륨 업 + 전원)에 두어 배터리를 다 씀 → 꺼짐. 이 상태에서 전원 키 무반응,
   충전기 5.2 V / 0 A.
2. **충전기 + 전류계를 꽂은 채 전원 + 볼륨 다운을 약 10분** → 전류가 흐르기 시작하고 곧 충전 로고와 9 V PD 충전.
   - 해석(추정): 배터리가 있을 때는 루프 중 3분 넘게 눌러도 소용없었음. 7초마다 다시 부팅하면서 PON 타이머가
     처음부터 다시 시작돼 S3 리셋(16초, ✔ xbl_config `s3-reset`)이 끝까지 가지 못한 것으로 봄. 방전으로 루프가
     멈춘 뒤에야 S3가 끝까지 돌아 PMIC를 초기화함. **방전 전략은 S3 타이머를 돌게 하는 데 유효했음.** 배터리
     보호회로 차단(POR)이 같은 때 일어났을 가능성은 배제 못 함.
   - 충전 로고 = UEFI가 저전압 + USB를 보고 ADSP 충전 펌웨어를 올린 것 ✔ → Type-C/USBIN이 다시 초기화됨.
3. **EDL:** 루프가 다시 시작되면 딥 플래시 케이블로 9008 진입 → 정상 부팅됐던 `vendor_boot_b` + `vbmeta_b`를 씀
   → 다시 읽어 확인 → 리셋. LTBox 도구(`QSaharaServer`, `fh_loader`)를 **PowerShell에서** 실행(Git Bash는
   `\\.\COMn`을 망가뜨림). 프로그래머는 롬의 `xbl_s_devprg_ns.melf`.
   - `QSaharaServer.exe -p \\.\COM48 -s 13:xbl_s_devprg_ns.melf`
   - `fh_loader.exe --port=\\.\COM48 --memoryname=UFS --sendxml=write.xml --search_path=. --noprompt --zlpawarehost=1`
   - LUN 4, 4 KiB 섹터: `vbmeta_b` 479082(16), `vendor_boot_b` 624118(24576), `vbmeta_a` 136634(16).
4. **SSD 없이 리눅스 부팅** → 30초 뒤 initramfs가 `qbootctl -s a` → 안드로이드로 정상 복귀.

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
