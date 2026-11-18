# TB710FU 에이전트 안내

이 저장소나 태블릿에서 작업하는 에이전트가 **가장 먼저 읽는 문서**입니다. 규칙과 기술 참고 자료를 담았습니다.

| 알고 싶은 것 | 문서 |
|---|---|
| 지금 기기 상태, 남은 일 | [docs/SYSTEM-STATE.md](docs/SYSTEM-STATE.md) |
| 커널 빌드와 설치, 업스트림 제출 | [docs/KERNEL-BUILD.md](docs/KERNEL-BUILD.md) |
| 과거 사고와 복구 방법 | [docs/INCIDENTS.md](docs/INCIDENTS.md) |

표기: ✔는 실측으로 확인한 것, (추정)은 확인하지 않은 판단입니다.

## 1. 절대 규칙

모두 실제 사고에서 나온 규칙입니다. 경위는 [사고 기록](docs/INCIDENTS.md)에 있습니다.

1. **부트 파티션(boot_a, 슬롯 b, vbmeta 등)은 사용자의 명시적 동의를 받은 뒤에만 씁니다.** 검증하지 않은 이미지라면 그 사실을 먼저 알립니다.
2. **deep 절전을 쓰지 않습니다.** 깨어나지 못하고 리셋됩니다. s2idle만 씁니다.
3. **L8B(키보드 전원)를 부팅할 때 켜지 않습니다.** `regulator-boot-on`이나 3.300 V를 넘는 전압은 부팅 0.37초에 리셋을 일으켰습니다. 전압은 3.296 V입니다.
4. **USB-C가 호스트(OTG) 모드일 때 리셋하지 않습니다.** 충전과 EDL이 모두 막힌 적이 있습니다.
5. **리눅스에서 슬롯 b를 쓸 때는 `tb710fu-update-slot-b`만 씁니다.** `dd`로 직접 쓰면 리셋 루프에 빠질 수 있습니다.
6. **ADSP를 강제로 재시작하지 않습니다.** 충전, 오디오, 센서가 모두 ADSP에 있습니다.
7. **LTBox의 Unroot와 GKI 모드를 쓰지 않습니다.** vendor가 깨지거나 kShimC가 덮어씌워집니다.
8. **커널과 모듈은 같은 빌드 트리에서 나온 것만 함께 씁니다.** 버전 문자열이 같아도 트리가 다르면 `Exec format error`로 거부됩니다.
9. **`/usr/lib/systemd/system-sleep/`에 백업 파일을 두지 않습니다.** 그 안의 실행 파일은 이름과 상관없이 모두 병렬로 실행됩니다.
10. **큰 빌드는 작업 수를 줄여서 합니다.** 메모리가 바닥나면 OOM 메시지 없이 통째로 멈춥니다.
11. **`/tmp`는 램입니다.** 큰 파일은 `/var/tmp`나 `~/build`에 둡니다.
12. **KWin `edrPolicy`는 `never`로 둡니다.** GAMMA_LUT/CTM 커밋은 이 패널의 DSI 링크를 깨뜨립니다. gamescope를 KMS에 직접 붙이는 시험도 사용자 동의 없이 하지 않습니다.
13. **측정하느라 바꾼 시스템 설정은 끝나면 되돌립니다.**
14. **비밀번호와 토큰을 파일이나 저장소에 남기지 않습니다.** 이 저장소는 공개되어 있습니다. 글꼴, 테마 같은 개인 설정도 넣지 않습니다. 터치 키보드만 복구용으로 `touch-keyboard/`에 둡니다.

위험한 시험은 kShimC 메뉴에서 리눅스를 골라 부팅한 상태에서 하세요. 리셋되면 메뉴 기본값인 안드로이드로 돌아오고 루프에 빠지지 않습니다.

## 2. 작업 방법

- **사용자에게는 한국어로** 답합니다.
- **접속:** 태블릿 SSH는 root만 키로 로그인합니다. PC 쪽 키는 `~/.ssh/tb710fu_ed25519`입니다. bmk 권한 작업은 `runuser -u bmk --`로 실행합니다. IP는 DHCP로 바뀝니다. 절전 중에는 SSH가 되지 않습니다.
- **무거운 작업:** PC가 느리므로 커널 빌드 같은 연산은 GitHub Actions에서 합니다.
- **기기 전용 설정:** 태블릿의 `~/HANDOFF-local.md`에 있습니다. 저장소에 넣지 않습니다.
- **상태가 바뀌면:** [docs/SYSTEM-STATE.md](docs/SYSTEM-STATE.md)만 고칩니다. 같은 사실을 다른 문서에 다시 적지 않습니다.
- **새 사고가 나면:** [docs/INCIDENTS.md](docs/INCIDENTS.md)에 추가합니다.

### 상태 확인 명령

```bash
# 부팅과 커널
uname -r; cat /proc/cmdline
sudo sha256sum /dev/disk/by-partlabel/boot_a | cut -c1-16
journalctl --list-boots | tail -5        # 정상 종료 기록 없이 끊긴 부팅 = 리셋

# 서비스 (hexagonrpcd라는 이름의 유닛은 없음)
systemctl is-active hexagonrpcd-adsp-sensorspd iio-sensor-proxy tb710fu-lid tb710fu-keyboard earlyoom
systemctl --failed

# 키보드와 절전
journalctl -b -k | grep -E 'kbpack|PM: suspend'
journalctl -b -u tb710fu-lid             # "light None"이면 iio-sensor-proxy가 죽어 있음

# 센서
busctl get-property net.hadess.SensorProxy /net/hadess/SensorProxy net.hadess.SensorProxy AccelerometerOrientation
busctl get-property net.hadess.SensorProxy /net/hadess/SensorProxy net.hadess.SensorProxy LightLevel

# ADSP: handover는 멈춰 있고, ready와 smp2p-adsp는 초당 약 5회 증가하는 것이 정상
grep -E 'q6v5 (handover|ready)|smp2p-adsp' /proc/interrupts

# 전력과 메모리
cat /sys/class/power_supply/battery/{status,capacity,current_now}   # 음수 = 방전
swapon --show; free -h; grep -r . /sys/module/zswap/parameters/enabled
```

시험용으로 20초 뒤 자동으로 깨우는 절전:

```bash
echo +20 | sudo tee /sys/class/rtc/rtc0/wakealarm; systemctl suspend
```

## 3. 저장소 구조

| 경로 | 내용 |
|---|---|
| `build/build.sh`, `build/config.env` | 이미지 빌드와 설정 |
| `build/device-kernel.sh` | 태블릿에서 커널 빌드, 패키징, 설치 |
| `build/rootfs-files/` | 데몬, 센서 빌드, 패치 스크립트, 순정 `sns_reg.conf` |
| `kernel/armada-overlay/tb710fu-locked/` | 커널 오버레이(DTS, 설정, 패치) |
| `kernel/tb710fu-kbpack/` | 키보드 커널 드라이버 |
| `kernel/required-options.txt` | 꼭 유지할 커널 옵션 |
| `.github/workflows/` | `kernel.yml`, `kshim.yml`, `kshim-themes.yml`, `rootfs.yml` |
| `android/` | 안드로이드에서 실행하는 설치, 복구 스크립트 |
| `touch-keyboard/` | 터치 키보드 자판, 입력기 설정, 복구 스크립트 |
| `upstream/` | 업스트림 제출용 패치 |

## 4. 부팅 구조

```
ABL(잠금) → boot_a = kShimC 메뉴(볼륨 키로 선택, 8초 뒤 안드로이드)
              ├─ Android: 순정 커널 + LTBox KernelSU(init_boot_a)
              └─ Arch Linux: 7.2.6-tb710fu + initramfs → /dev/sda14의 /linux
슬롯 b = v4-e3-20261115(SSD 부팅용 폴백, 건드리지 않음)
```

- **kShimC:** 순정 안드로이드 커널과 리눅스 커널이 boot 이미지 하나에 들어갑니다. `vbmeta_a`가 boot를 testkey로 체인하므로 잠긴 부트로더에서도 동작합니다 ✔. 런타임은 `kshim.yml`이 Freedom의 고정 커밋으로 빌드합니다.
- **테마:** 빌드할 때 정해집니다. `kshim.yml`의 `style` 입력으로 고르며, 바꾸면 boot_a를 새로 써야 합니다. 31종의 미리보기는 [docs/images/kshim-themes.png](docs/images/kshim-themes.png)에 있습니다.
- **cmdline:** DTB `/chosen`에 들어 있습니다. 바꾸려면 boot_a를 새로 만들어야 합니다.
- **크기:** boot_a는 96 MiB이고, 압축 후 약 76~93 MB입니다.

### 슬롯 b 구성

ABL은 순정 GKI v4 레이아웃만 받아 줍니다. 그래서 슬롯 a 이미지를 헤더 템플릿으로 쓰고 내용만 바꿉니다(`build/bootv4.py`).

| 파티션 | 내용 |
|---|---|
| `boot_b` | 메인라인 `Image` + cmdline, testkey 서명, 순정 롤백 인덱스 |
| `vendor_boot_b` | 메인라인 DTB + 우리 initramfs |
| `init_boot_b` | 빈 ramdisk |
| `dtbo_b` | 0으로 채움 |
| `vbmeta_b` | 슬롯 a vbmeta에서 해시만 갱신해 testkey로 재서명 |

ABL을 통과하려면 세 가지가 필요합니다.

1. **dtbo를 비웁니다.** 순정 오버레이가 메인라인 DTB에 적용되지 않으면 ABL이 DTB를 복사하지 않습니다.
2. **DTB에 `qcom,board-id = <8 0>`이 있어야 합니다.** RAM이 4 GB를 넘으면 DDR 비트가 0이어야 합니다.
3. **`/soc/cache-controller` 빈 노드가 있어야 합니다.** ABL의 `UpdateDeviceTree`가 이 노드를 찾습니다.

### 자동 폴백

| 상황 | 동작 |
|---|---|
| 슬롯 b에서 루트를 못 찾음 | initramfs가 `tb710fu.wait`초(기본 30) 기다린 뒤 슬롯 a로 바꾸고 재부팅 ✔ |
| 커널 패닉 | `panic=10`으로 재부팅. kShimC에서는 안드로이드로 돌아옴 |
| 슬롯 b 정상 부팅 | 데스크톱이 뜨고 60초 뒤 `qbootctl-mark-successful`이 성공으로 표시 |

## 5. 설치 절차

지금 쓰는 방식은 **kShimC + `/data/linux`** 입니다.

1. **안드로이드 암호화 해제:** [6장](#6-안드로이드-data와-암호화-해제)을 따릅니다. `/data`가 지워집니다.
2. **PC:** `build.sh personal`로 `out/tb710fu-personal.tar`를 만듭니다.
3. **태블릿(안드로이드, KernelSU 루트):** 스크립트가 `rootfs-latest` 릴리스에서 약 1.3 GB를 받아 `/data/linux`에 풉니다.

   ```bash
   adb push android/install-linux-data.sh out/tb710fu-personal.tar /data/local/tmp/
   adb shell su -c "sh /data/local/tmp/install-linux-data.sh"
   ```

4. **PC:** `build.sh initramfs` 다음 `ROOT_DEV=userdata KBPACK=1 build.sh kshim`을 실행합니다. `STOCK_DIR/boot_a.img`는 손대지 않은 boot_a 덤프여야 합니다.
5. **boot_a 쓰기(사용자 동의 필요):** `adb push`한 뒤 `su -c dd`로 쓰고, 다시 읽어 해시를 확인합니다.
6. **재부팅:** 메뉴에서 Arch Linux를 고릅니다. 첫 부팅에 `tb710fu-firstboot`가 파일 capability를 다시 붙입니다.

이미 설치된 기기의 커널 교체는 [docs/KERNEL-BUILD.md](docs/KERNEL-BUILD.md)를 따릅니다.

### 슬롯 b에 쓰기

```bash
adb push v4/e3 android/flash-slot-b.sh /data/local/tmp/
adb shell su -c "sh /data/local/tmp/flash-slot-b.sh /data/local/tmp/e3"          # 점검만
adb shell su -c "sh /data/local/tmp/flash-slot-b.sh /data/local/tmp/e3 --write"  # 기록
```

- 슬롯 a는 건드리지 않습니다. 기록 전에 슬롯 b를 백업하고, 기록 후 해시를 확인합니다.
- **안드로이드 → 리눅스:** `android/switch-to-linux.zip`을 KernelSU 모듈로 설치하고 Action 버튼을 누릅니다.
- **리눅스에서 쓸 때:** `sudo tb710fu-update-slot-b DIR --write`만 씁니다. 슬롯 b를 쓰고 다시 읽어 확인한 뒤 `qbootctl -s b`로 재시도 횟수를 다시 설정합니다.
- **`build.sh v4 bounce`는 쓰지 않습니다.** [사고 기록](docs/INCIDENTS.md)을 보세요.

### EDL (최후 수단)

LTBox의 `QSaharaServer`, `fh_loader`를 **PowerShell에서** 실행합니다. Git Bash는 `\\.\COMn` 경로를 망가뜨립니다. 프로그래머는 롬의 `xbl_s_devprg_ns.melf`입니다.

```powershell
QSaharaServer.exe -p \\.\COM48 -s 13:xbl_s_devprg_ns.melf
fh_loader.exe --port=\\.\COM48 --memoryname=UFS --sendxml=write.xml --search_path=. --noprompt --zlpawarehost=1
```

| LUN | 파티션과 시작 섹터(4 KiB) |
|---|---|
| 0 | super 9608, vendor_a는 super+2842368(절대 2851976), metadata 4990376, userdata 5105064 |
| 4 | boot_a 112006(24576개), vbmeta_a 136634(16개), init_boot_a 340102, vbmeta_b 479082(16개), vendor_boot_b 624118(24576개) |

## 6. 안드로이드 `/data`와 암호화 해제

리눅스 루트를 안드로이드 `userdata`(f2fs) 안의 `/linux`에 둡니다. 안드로이드에서는 `/data/linux`로 보입니다.

- **권한:** 리눅스 첫 사용자 uid 1000이 안드로이드의 `system`과 같습니다. 그래서 리눅스의 `/data` 전체는 root만 `/mnt/.android/data`(0700)로 봅니다.
- **fsck:** 리눅스는 userdata를 fsck하지 않습니다. 안드로이드가 자기 fsck로 관리합니다.
- **커널 요구 사항:** `UNICODE`, `F2FS_FS_COMPRESSION`(LZ4, ZSTD), `FS_VERITY`, `F2FS_FS_SECURITY`가 있어야 마운트됩니다.

### 암호화를 끄는 방법 (`build/fbe-off.py`)

암호화 설정은 `vendor_a`의 `/etc/fstab.qcom`에 있습니다(롬의 `super_7.img`가 vendor_a입니다).

1. **fstab을 바이트 단위로 고칩니다.** vendor ext4에 `shared_blocks`가 켜져 있어 e2fsprogs로는 쓸 수 없습니다. 암호화 플래그를 지우고, 줄어든 만큼 주석으로 채워 파일 크기를 유지합니다.
2. **hashtree를 다시 계산합니다.** 순정 salt로 먼저 순정 이미지를 재현해 보고, 값이 맞을 때만 진행합니다. FEC는 descriptor에서 뺍니다.
3. **vbmeta_a를 다시 서명합니다.** vendor hashtree descriptor만 바꿉니다.

```bash
python -I build/fbe-off.py build <롬>/image/super_7.img <덤프>/vbmeta_a.img build/testkey_rsa4096.pem out/fbe-off
sudo tb710fu-android-fbe check ~/fbe-off   # 상태만 확인
sudo tb710fu-android-fbe off ~/fbe-off     # WIPE 입력: vendor_a, vbmeta_a 기록, /data와 /metadata 지움
sudo tb710fu-android-fbe restore ~/fbe-off <롬>/image/super_7.img   # 되돌리기(/data도 지워짐)
```

### KernelSU 루트 (LTBox)

KernelSU LKM은 **init_boot_a**만 패치하므로 kShimC와 상관없습니다.

- LTBox는 이미 패치된 init_boot를 거부합니다. 롬의 순정 `init_boot.img`를 먼저 쓰고, vbmeta_a의 init_boot 항목을 맞춥니다: `avbsign.py refresh <vbmeta> <출력> <testkey> init_boot=<롬>/init_boot.img`
- 데이터를 초기화하면 KernelSU 매니저 앱과 LTBox "Disable OTA"를 다시 해야 합니다.

## 7. 키보드 팩

순정 `lenovo_keyboard.ko`를 분석한 결과입니다. 소스는 공개되어 있지 않습니다.

### 하드웨어

| 항목 | 위치 |
|---|---|
| UART | QUP1 SE7 `0xa9c000`, TX gpio62, RX gpio63, **921600 8N1** |
| 전원 | `vdd_3p3` = PM8550 LDO B8(L8B), `vdd_1p8` = LDO B1 |
| 연결 감지 | gpio81, low = 연결. 리드 센서가 아니며 `SW_DOCK`으로 보냄 |
| UART 깨우기 | gpio137 |
| TX 활성화 | gpio100, high = 호스트 송신 가능 |

순정은 키보드가 연결됐을 때만 L8B를 켭니다(3.300 V, HPM) ✔. 우리는 3.296 V를 씁니다.

### 프레임

```
키보드 → 호스트:    7E FF esc(seed scrambled[0..n-1] sum8) 7E
호스트 → 키보드: 7E 7E FF esc(seed scrambled[0..n-1] sum8) 7E
```

- **이스케이프:** `7D` → `7D 5D`, `7E` → `7D 5E`.
- **sum8:** 이스케이프된 seed와 데이터 바이트의 8비트 합입니다.
- **복호화:** `plain[i] = scrambled[i] ^ keyDict[(seed + i) & 0x3f]`
- **keyDict:** `kernel/tb710fu-kbpack/kbpack-codec.h`의 `kbp_key`

### 패킷

`plain[0]`이 종류, `plain[1]`이 나머지 길이입니다. 같은 보고가 약 9 ms 간격으로 두 번 옵니다.

| 패킷 | 뜻 |
|---|---|
| `11 08 MM 00 k1..k6` | 키보드. MM: 01 LCtrl, 02 LShift, 04 LAlt, 08 LMeta, 10 RCtrl, 20 RShift, 40 RAlt. 키는 HID usage |
| `12 04 uu uu 00 00` | 소비자 키: 0x00e2 음소거, 0x00ea 볼륨−, 0x00e9 볼륨+, 0x0070 밝기−, 0x006f 밝기+, 0x0391 마이크 음소거, 0x0394 전체 화면, 0x0395 화면 분할, 0x0398 AI |
| `13 LL BB [f xL xH yL yH]×n` | 터치패드. n = (LL−1)/5. BB bit0 = 클릭. f = slot<<4 \| 7(터치), \| 6(뗌). x 0..3199, y 0..1999 |
| `15 03 02 01 vv` | vv=0 접힘(키 꺼짐), 1 펼침. `SW_TABLET_MODE = !vv` |
| `16 03 01 01 cc` | 연결 인사 |
| `16 04 04 02 bb xx` | 약 1초 간격 상태 |
| `7d 0a 03 08 "HJN008QS"` | 펌웨어 버전 |

호스트가 보내는 명령:

| 명령 | 뜻 |
|---|---|
| `6a 03 27 01 vv` | Caps Lock LED |
| `6a 03 28 01 vv` | 음소거 LED |
| `6a 03 29 01 vv` | 마이크 음소거 LED |
| `6a 04 33 02 00 00` | 터치패드 자동 절전 끄기 |

### 자세별 동작

| 자세 | 입력 | 시스템 상태 |
|---|---|---|
| 분리 | 없음, 입력 장치도 사라짐 | `SW_DOCK=0`, L8B 꺼짐 |
| 장착 + 펼침 | 동작 | `SW_DOCK=1`, `SW_TABLET_MODE=0` |
| 장착 + 뒤로 접음 | 펌웨어가 키와 터치패드 차단 | `SW_TABLET_MODE=1` |
| 장착 + 화면 위로 덮음 | 차단, 절전 | 접었을 때와 패킷이 같아 조도로 구분 |

**덮기 판별(`tb710fu-lid`):** 조도는 펼침 503~561 lux, 덮음 115~256 lux, 접음 635 lux입니다 ✔. 접힘이 1.5초 유지되고 조도가 직전의 50% 아래로 떨어지면 절전합니다. 직전이 20 lux 미만이면 판단하지 않습니다.

**드라이버 동작:**

- 연결 감지는 1초 디바운스합니다. 접는 도중 신호가 약 0.4초 끊기기 때문입니다.
- UART는 키보드 전원이 켜진 동안에만 엽니다.
- 절전 중에 "펴짐" 신호를 놓치면, 키 입력이나 터치로 태블릿 모드가 풀립니다.
- 패킷 기록: `echo 1 | sudo tee /sys/module/tb710fu_kbpack/parameters/log_packets`
- 기기의 `tb710fu-keyboard` 데몬은 `build/rootfs-files/`의 버전과 다릅니다. 기기용은 `touch-keyboard/tb710fu-keyboard`입니다.

### 터치 키보드

키보드 팩을 떼면 Plasma 키보드, 붙이면 fcitx5를 씁니다. 데몬이 `SW_DOCK`을 보고 KWin 입력기를 바꿉니다.

```bash
sudo bash touch-keyboard/install.sh   # 태블릿에서 전체 복구
```

- **자판:** `layouts/`는 `~/.local/share/plasma/keyboard/layouts/`로 복사되며 시스템 자판보다 우선합니다. 가로 화면에서는 좌우로 나뉘고 안쪽에 예비 키가 한 줄씩 있습니다.
- **간격:** `layouts/tb710fu/SplitGap.qml`의 `gapRatio`로 조절합니다.
- **입력:** `layouts/tb710fu/TermInputMethod.qml`이 두벌식을 조합합니다. Ctrl 조합은 제어 문자를 보내므로 터미널에서만 동작합니다.
- **자동 표시:** `tb710fu-osk-tap`은 이미 포커스된 입력 칸을 탭해도 키보드를 띄웁니다.
- **수정한 뒤:** `~/.cache/plasma-keyboard/qmlcache`를 지우고 입력기를 다시 시작합니다. 캐시가 남으면 영문 자판이 기본 자판으로 돌아갈 수 있습니다. 바꾼 파일은 이 폴더에도 반영합니다.
- **주의:** fcitx5 상태를 D-Bus로 조회하면 입력기가 아닌 fcitx5가 자동 실행될 수 있습니다. 먼저 `NameHasOwner`로 확인합니다.

## 8. 센서

IMU(BMI3xx)와 조도(STK6B9x)는 ADSP 센서 허브 뒤에 있습니다.

```
ADSP SSC → hexagonrpcd-adsp-sensorspd → libssc → iio-sensor-proxy → KWin
```

- **`sns_reg.conf`:** 순정 vendor의 `/etc/sensors/sns_reg_config`와 같아야 합니다.
- **hexagonrpcd 패치:** 센서 PD가 부팅할 때 registry를 쓰므로 쓰기 기능을 넣었습니다(`hexagonrpcd-registry-write.py`).
- **iio-sensor-proxy 패치:** 드라이버가 열리기 전의 클레임 처리와 NULL GError 수정입니다(`iio-sensor-proxy-claim-race.py`).
- **보정 행렬:** `0,1,0;-1,0,0;0,0,1`(`/etc/udev/rules.d/60-tb710fu-sensors.rules`)
- **절전 훅:** `/usr/lib/systemd/system-sleep/tb710fu-sensors`가 절전 전에 proxy를 멈추고, 깨어난 2초 뒤 hexagonrpcd와 proxy를 무조건 다시 켭니다.
- 근접과 나침반은 SSC가 제공하지 않습니다.

## 9. 화면

- **패널:** NT36532(화면과 터치가 한 칩), 3200×2000, 듀얼 DSI, DSC.
- **주사율:** 지금은 120 Hz 하나입니다. 순정 DT에 Qsync가 없어 VRR은 안 됩니다.
- **순정의 주사율 명령:** 페이지 0x10의 B2/B3입니다. 120/60/30 Hz는 `91 40`, 90 Hz는 `80 80`, 144 Hz는 `80 00`입니다.
- **144 Hz:** 순정 DT의 레인당 클럭은 120 Hz 기준 1198 Mbps뿐이고, 144 Hz 값이 없습니다. VFP만으로는 만들 수 없어 링크 클럭을 올려야 합니다. 안드로이드에서 실제 클럭을 재기 전에는 시도하지 마세요.
- **`dsi_err_worker: status=c`:** 화면을 끌 때 두 DSI 링크에서 한 줄씩 나옵니다 ✔. 켜져 있는 동안 DPU underrun은 0입니다.
- **`msm.separate_gpu_kms=1`을 쓰지 않습니다.** gamescope가 KMS 장치를 찾지 못합니다.
- **gamescope:** `steam-deck-ui`는 KWin 안에서 Wayland 백엔드로 돌아서 패널 색상 커밋을 하지 않습니다.

## 10. 하드웨어 메모

- **CPU:** 컷칩이라 CPU 1, 2가 없습니다. `psci: failed to boot CPU1/2 (-22)`는 정상입니다.
- **RTC:** 쓸 수 없어 1970년으로 시작합니다. NTP가 맞추기 전의 로그 시각은 틀립니다.
- **USB-C 호스트:** pmic_glink가 ADSP에 의존하므로 initramfs에 `qcom_q6v5_pas`와 `adsp.mbn`이 들어갑니다.
- **충전:** ADSP가 전류 부호를 반대로 보내서 battmgr 패치로 뒤집습니다. PC USB 포트로는 충전되지 않고, PD 충전기로 약 36 W가 들어갑니다.
- **pacman:** 커널에 Landlock이 없어 `DisableSandboxFilesystem`이 필요합니다.
- **펌웨어 경로:** `qcom/sm8650/xiaoxin/gt/*`, GMU는 `updates/qcom/`, 토폴로지는 `qcom/sm8650/Lenovo-TB710FU-tplg.bin`, WCN7850 보드 파일은 `updates/`입니다.
