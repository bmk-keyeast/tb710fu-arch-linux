# TB710FU 시스템 상태 (에이전트용)

이 기기에서 작업하는 에이전트가 **가장 먼저 읽는 문서**입니다. 지금 시스템이 어떤 상태인지, 무엇을 건드리면 안 되는지를 한 번에 알 수 있게 정리했습니다.

- **기준 시각:** 2026-11-18. 값이 의심되면 7장의 명령으로 직접 확인하세요.
- **커널을 고치거나 부트 이미지를 만들 때:** [KERNEL-BUILD.md](KERNEL-BUILD.md)
- **사고 기록과 자세한 경위:** [handoff-2026-11-16.md](handoff-2026-11-16.md)
- **기기 전용 개인 설정:** 태블릿의 `~/HANDOFF-local.md`(저장소에 없음), `~/AGENTS.md`

## 1. 절대 규칙

어기면 기기가 부팅되지 않거나 복구가 어려워집니다. 모두 실제 사고에서 나온 규칙입니다.

1. **부트 파티션(boot_a, 슬롯 b, vbmeta 등)은 사용자의 명시적 동의를 받은 뒤에만 씁니다.** 검증되지 않은 이미지라면 그 사실을 먼저 알립니다.
2. **deep 절전을 쓰지 않습니다.** 깨어나지 못하고 리셋됩니다. s2idle만 씁니다.
3. **L8B(키보드 전원)를 부팅할 때 켜지 않습니다.** `regulator-boot-on`이나 3.300 V를 넘는 전압은 부팅 0.37초에 리셋을 일으켰습니다. 전압은 3.296 V입니다.
4. **USB-C가 호스트(OTG) 모드일 때 리셋하지 않습니다.** PMIC 입력이 막혀 충전과 EDL이 모두 안 된 적이 있습니다.
5. **슬롯 b를 리눅스에서 썼다면 `tb710fu-update-slot-b`를 씁니다.** `dd`만 하면 리셋 루프에 빠질 수 있습니다.
6. **ADSP를 강제로 재시작하지 않습니다.** 충전, 오디오, 센서가 모두 ADSP에 있습니다.
7. **LTBox의 Unroot와 GKI 모드를 쓰지 않습니다.** vendor가 깨지거나 kShimC가 덮어씌워집니다.
8. **커널과 모듈은 같은 빌드 트리에서 나온 것만 함께 씁니다.** 버전 문자열이 같아도 트리가 다르면 `Exec format error`로 거부됩니다.
9. **`/usr/lib/systemd/system-sleep/`에 백업 파일을 두지 않습니다.** 그 안의 실행 파일은 이름과 상관없이 모두 실행됩니다.
10. **큰 빌드는 작업 수를 줄여서 합니다.** 메모리가 바닥나면 OOM 메시지 없이 통째로 멈춥니다.
11. **`/tmp`는 램입니다.** 큰 파일은 `/var/tmp`나 `~/build`에 둡니다.
12. **비밀번호와 토큰을 파일로 남기지 않습니다.**

위험한 시험은 kShimC 메뉴에서 리눅스를 골라 부팅한 상태에서 하세요. 리셋되면 메뉴 기본값인 안드로이드로 돌아오고, 루프에 빠지지 않습니다.

## 2. 기기와 접속

| 항목 | 내용 |
|---|---|
| 기기 | Lenovo TB710FU(Xiaoxin Pad Pro GT), Snapdragon 8 Gen 3(SM8650) |
| CPU | 컷칩: CPU 0, 3~7만 있음. `psci: failed to boot CPU1/2 (-22)`는 정상 |
| 램 | 약 7 GB |
| 저장소 | UFS 256 GB. 리눅스는 userdata(`/dev/sda14`, f2fs)를 안드로이드와 공유 |
| 화면 | 3200×2000, 120 Hz(NT36532, DSI-1), freedreno FD750 |
| OS | Arch Linux ARM, KDE Plasma 6.8(Wayland), systemd 262, Mesa 26.2 |
| 사용자 | `bmk`(uid 1000). sudo는 `/etc/sudoers.d/91-opencode-nopasswd`로 암호 없이 동작 |
| SSH | root만 키 로그인. PC 쪽 키는 `~/.ssh/tb710fu_ed25519`. bmk 작업은 `runuser -u bmk --`로 실행. IP는 DHCP로 바뀜(같은 대역을 22번 포트로 스캔) |

## 3. 부팅 구조

```
ABL(잠금) → boot_a = kShimC 메뉴(iOS 테마, 볼륨 키로 선택, 8초 뒤 안드로이드)
              ├─ Android: 순정 커널 + LTBox KernelSU(init_boot_a)
              └─ Arch Linux: 7.2.6-tb710fu + initramfs → /dev/sda14의 /linux로 부팅
슬롯 b = v4-e3-20261115(예전 SSD 부팅용 폴백, 건드리지 않음)
```

| 파티션 | 지금 내용 | 해시 앞자리 |
|---|---|---|
| boot_a | kShimC + 커널 fd9e0a2 + 키보드 커널 드라이버(`KBPACK=1`) | `987009be` |
| vbmeta_a | testkey 체인(KSU init_boot, FBE 해제 vendor) | `26dcd75d` |
| 순정 boot_a | 패키징 재료. 태블릿의 `/var/lib/tb710fu/stock/boot_a.img` | `37bb1bc5` |

- **서명:** AOSP testkey(`build/testkey_rsa4096.pem`), verifiedbootstate green. fastboot 쓰기는 안 됩니다.
- **커널 cmdline:** DTB `/chosen`에 있습니다. 바꾸려면 boot_a를 새로 만들어야 합니다.
  `root=PARTLABEL=userdata tb710fu.rootdir=/linux rw rootwait clk_ignore_unused pd_ignore_unused regulator_ignore_unused console=tty0 panic=10 tb710fu.wait=30 cpuidle.governor=teo tb710fu.kshim=1`
- **안드로이드 `/data`:** 암호화 해제 상태입니다. 리눅스에서는 root만 `/mnt/.android/data`로 봅니다.

## 4. 커널

| 구분 | 내용 |
|---|---|
| **기기에서 실행 중** | `7.2.6-tb710fu`, CI 런 43799637253(fd9e0a2) = Freedom b75a6d48 + 오버레이. 키보드 모듈만 36369b9 빌드로 교체됨 |
| **저장소 최신(아직 기기에 안 씀)** | Freedom 5c4454f + q6v5 수정 + zswap + uinput 내장 + 60 Hz 모드. 빌드는 [KERNEL-BUILD.md](KERNEL-BUILD.md)의 CI 기록 참고 |

오버레이 `kernel/armada-overlay/tb710fu-locked`:

| 파일 | 내용 | 기기 검증 |
|---|---|---|
| `dts/sm8650-lenovo-tb710fu-locked.dts` | 키보드 UART, L8B 가상 소비자, gpio81=`SW_DOCK` | ✔ |
| `patches/0001-qcom-battmgr-…` | 배터리 전류 부호 반전(upower 충전 표시) | ✔ |
| `patches/0002-drm-panel-nt36532-…-60hz` | 60 Hz 모드 | 미시험 |
| `patches/0003-remoteproc-qcom_q6v5-…` | ADSP handover 인터럽트 폭주(초당 5회) 차단 | 미시험 |
| `config/tb710fu-locked.config` | TEO, f2fs, zswap, uinput 등 | zswap, uinput 내장은 미시험 |

꼭 유지할 옵션은 `kernel/required-options.txt`에 있습니다. CI와 기기 빌드가 이 목록을 검사합니다.

## 5. 하드웨어 기능 상태

### 키보드 팩(pogo 핀, UART 921600)

커널 드라이버 `tb710fu-kbpack`(`kernel/tb710fu-kbpack/`)가 처리합니다. 데몬 `tb710fu-keyboard`는 지금 입력기 전환 정도만 합니다. **기기의 데몬 파일은 저장소 버전과 다르니 덮어쓰지 마세요.**

| 자세 | 입력 | 시스템 상태 |
|---|---|---|
| 분리 | 없음, 입력 장치도 사라짐 | `SW_DOCK=0`, L8B 꺼짐 |
| 장착 + 펼침 | 동작 | `SW_DOCK=1`, `SW_TABLET_MODE=0` |
| 장착 + 뒤로 접음 | 펌웨어가 키·터치패드 차단 | `SW_TABLET_MODE=1` |
| 장착 + 화면 위로 덮음 | 차단, **절전** | 접었을 때와 같은 신호. `tb710fu-lid`가 조도로 구분 |

- 연결 감지(gpio81)는 1초 디바운스합니다. 접는 도중 신호가 0.4초쯤 끊기기 때문입니다.
- UART는 키보드 전원이 켜진 동안에만 엽니다.
- 절전 중에 "펴짐" 신호를 놓치면, 키 입력이나 터치로 태블릿 모드가 풀립니다.
- 패킷을 보려면 `echo 1 | sudo tee /sys/module/tb710fu_kbpack/parameters/log_packets`를 쓰고, 끝나면 0으로 돌립니다.
- 알려진 문제: Caps Lock LED가 순정보다 어둡습니다(원인 미상).

### 절전과 전원

| 항목 | 상태 |
|---|---|
| 절전 | s2idle만(`/etc/systemd/sleep.conf.d/tb710fu.conf`). 전원 버튼이나 덮개로 재우고, **전원 버튼으로만 깨움**(덮개를 열어도 안 깨어남) |
| 덮기 판별 `tb710fu-lid` | 접힘 1.5초 유지 + 조도가 직전의 50% 미만이면 절전. 직전 20 lux 미만이면 판단 안 함. logind sleep 차단을 존중 |
| CPU | 배터리일 때 고성능 코어 약 2.2 GHz 제한(`tb710fu-cpucap`). `steam-arm64` 실행 중에는 해제 |
| cpuidle | TEO |
| PCIe | ASPM powersupersave(`/etc/tmpfiles.d/tb710fu-aspm.conf`) |
| 유휴 소비 | 화면 켜짐, 밝기 100%에서 약 4 W |
| 충전 | PD 약 36 W. 상한 80%(ADSP에 남은 안드로이드 설정으로 추정) |
| RTC | 쓸 수 없어 1970년으로 시작. NTP가 맞춤 |

### 센서

ADSP SSC → `hexagonrpcd-adsp-sensorspd`(registry 쓰기 패치) → libssc → iio-sensor-proxy(경합·NULL GError 수정) → KWin.

- 가속도계와 조도 센서가 동작합니다. 근접과 나침반은 없습니다.
- 보정 행렬: `0,1,0;-1,0,0;0,0,1`(`/etc/udev/rules.d/60-tb710fu-sensors.rules`)
- 절전 훅: `/usr/lib/systemd/system-sleep/tb710fu-sensors`
- `hexagonrpcd`라는 이름의 유닛은 없습니다. `hexagonrpcd-adsp-sensorspd`로 조회하세요.

### 화면

- KWin `edrPolicy`는 `never`로 둡니다. `always`면 밝기를 바꿀 때 DSI 오류가 나고 화면이 깨집니다.
- 지금은 120 Hz 하나입니다. VRR은 안 됩니다.
- **144 Hz는 아직 넣지 않습니다.** 순정 DT에 패널 명령(`B2=80 B3=00`)은 있지만, 144 Hz일 때의 DSI 클럭 값이 없습니다. 지금 타이밍에서 VFP만 줄여서는 만들 수 없고 링크 클럭을 올려야 합니다. 안드로이드에서 실제 클럭을 측정하기 전에는 시도하지 마세요.
- 이 부팅에서 120 Hz인데도 `dsi_err_worker: status=c`가 8번 기록됐습니다(2026-11-18, 원인 미상).
- `msm.separate_gpu_kms=1`을 쓰지 마세요. gamescope가 KMS 장치를 찾지 못합니다.

## 6. 소프트웨어 구성

| 영역 | 구성 |
|---|---|
| 데스크톱 | Plasma 세션 위에 Quickshell 기반 `macshell`(`~/.config/quickshell/macshell`, 자체 git) |
| 로그인 | SDDM 자동 로그인(bmk, plasma), 테마 MacShell.Tahoe |
| 입력기 | fcitx5 + hangul(왼쪽 Alt로 한영). 화면 키보드는 Plasma 키보드 |
| 메모리 | zram 3.4 GB(zstd) + 스왑 파일 `/swap/swapfile`, `/swap/swapfile2`(각 4 GB), 모두 pri 100, swappiness 100, earlyoom |
| 게임 | FEX, Valve linuxarm64 Steam(`~/.local/bin/steam-arm64`), gamescope 3.17, `steam-deck-ui` 세션, `tb710fu-steam-touch` |
| 저장소 사본 | `~/tb710fu-arch-linux-main`(worktree), `~/tb710fu-arch-linux`(오래된 클론, 참고만) |

**주요 서비스:** `hexagonrpcd-adsp-sensorspd`, `iio-sensor-proxy`, `tb710fu-lid`, `tb710fu-keyboard`, `tb710fu-cpucap`(oneshot), `tb710fu-android-storage`, `qbootctl-mark-successful`, `earlyoom`, `power-profiles-daemon`, `sshd`, `sddm`

## 7. 상태 확인 명령

```bash
# 부팅과 커널
uname -r; cat /proc/cmdline
sudo sha256sum /dev/disk/by-partlabel/boot_a | cut -c1-16
journalctl --list-boots | tail -5        # 정상 종료 기록 없이 끊긴 부팅 = 리셋

# 서비스
systemctl is-active hexagonrpcd-adsp-sensorspd iio-sensor-proxy tb710fu-lid tb710fu-keyboard earlyoom
systemctl --failed

# 키보드와 절전
journalctl -b -k | grep -E 'kbpack|PM: suspend'
journalctl -b -u tb710fu-lid             # "light None"이면 iio-sensor-proxy가 죽어 있음

# 센서
busctl get-property net.hadess.SensorProxy /net/hadess/SensorProxy net.hadess.SensorProxy AccelerometerOrientation
busctl get-property net.hadess.SensorProxy /net/hadess/SensorProxy net.hadess.SensorProxy LightLevel

# ADSP handover 폭주: 수정 전에는 handover, ready, smp2p-adsp가 모두 초당 약 5회 증가
# 수정 후에는 handover만 멈춤. ready와 smp2p-adsp는 계속 올라가는 것이 정상
grep -E 'q6v5 (handover|ready)|smp2p-adsp' /proc/interrupts

# 전력과 메모리
cat /sys/class/power_supply/battery/{status,capacity,current_now}   # 음수 = 방전
swapon --show; free -h
```

시험용으로 20초 뒤 자동으로 깨우는 절전:

```bash
echo +20 | sudo tee /sys/class/rtc/rtc0/wakealarm; systemctl suspend
```

## 8. 남은 일

1. **새 커널 적용:** 빌드한 커널을 사용자 동의 후 기기에 쓰고, q6v5·zswap·60 Hz를 시험합니다.
2. **zswap으로 전환:** 새 커널에서 zram을 끄고 zswap을 켭니다([KERNEL-BUILD.md](KERNEL-BUILD.md)의 "zswap 켜기").
3. **덮개를 열 때 깨우기:** 키보드 UART나 gpio81을 깨우기 소스로 등록합니다.
4. **유휴 전력:** plasmashell과 macshell의 깨움, 타이머를 줄입니다.
5. **libssc:** `report_received` 크래시와 busy-wait를 지켜봅니다(`CPUQuota=3%`로 완화 중).
6. **게임 모드:** 전체 화면 세션, 실제 게임 실행, SDDM 세션 등록은 아직 안 했습니다.
7. **Caps Lock LED가 어두운 원인**
8. **보류:** SSD 이미지 쓰기
