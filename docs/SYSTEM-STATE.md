# TB710FU 현재 상태

**마지막 확인: 2026-11-18 16:13.** 지금 기기의 상태만 적는 문서입니다. 규칙과 기술 자료는 [AGENTS.md](../AGENTS.md)에 있습니다.

> **미해결:** 2026-11-18 16:15쯤부터 태블릿 SSH가 응답하지 않습니다. 자동 절전인지 리셋인지 아직 확인하지 못했습니다. 이 문서의 값은 그 전에 확인한 것입니다.

## 1. 버전

| 항목 | 현재 값 |
|---|---|
| 기기 | Lenovo TB710FU, SM8650, 램 약 7 GB, UFS 256 GB |
| OS | Arch Linux ARM, KDE Plasma 6.8(Wayland), systemd 262, Mesa 26.2, gcc 16.1 |
| 커널 | `7.2.6-tb710fu`, CI 런 44250381926(`44d67b5`), Freedom `5c4454f` 기반 |
| boot_a | `90affd1f…`, kShimC `IOS_HIG` 테마, 키보드 드라이버 켜짐 |
| vbmeta_a | `26dcd75d…` |
| 슬롯 b | `v4-e3-20261115` |
| 안드로이드 | ZUI 17.5.04.070, 암호화 해제, LTBox KernelSU |
| 루트 | `/dev/sda14`(f2fs)의 `/linux`, 215 GB 중 약 31% 사용 |

**cmdline:** `root=PARTLABEL=userdata tb710fu.rootdir=/linux rw rootwait clk_ignore_unused pd_ignore_unused regulator_ignore_unused console=tty0 panic=10 tb710fu.wait=30 cpuidle.governor=teo tb710fu.kshim=1`

**커널 오버레이:**

| 항목 | 내용 | 기기 확인 |
|---|---|---|
| 보드 DTS | 키보드 UART, gpio81 = `SW_DOCK` | ✔ |
| `0001-qcom-battmgr` | 배터리 전류 부호 반전 | ✔ |
| `0003-remoteproc-qcom_q6v5` | handover 인터럽트 폭주 차단 | ✔ 오류 로그 0줄 |
| 설정 | TEO, zswap, uinput 내장 | ✔ |

## 2. 기능 상태

| 기능 | 상태 | 비고 |
|---|---|---|
| kShimC 메뉴, 안드로이드 부팅 | ✅ | |
| KDE Plasma, Wi-Fi, SSH | ✅ | freedreno FD750 |
| 스피커 | ✅ | 앰프 4개 시작 확인 |
| 터치, 펜 | ✅ | 화면만 꺼진 동안 터치 펌웨어를 반복해서 다시 올리지만 전력 차이는 없음 |
| 키보드, 터치패드 | ✅ | 새 커널에서 사용자 확인 |
| 키보드 뒤로 접기, 덮어서 절전 | ✅ | 새 커널에서는 아직 재시험 전 |
| 화면 회전, 조도 센서 | ✅ | 근접, 나침반 없음 |
| 충전 표시 | ✅ | |
| 절전(s2idle) | 🟡 | 이전 커널에서는 정상. **새 커널에서는 미시험** |
| 덮개를 열어서 깨우기 | ❌ | 전원 버튼으로만 깨어남 |
| 가상 키보드 | 🟡 | Plasma 키보드는 Esc, 화살표, 한글이 없음 |
| Caps Lock LED | ⚠️ | 동작하지만 순정보다 어두움, 원인 미상 |
| Steam, FEX | 🟡 | Steam 실행 확인. 실제 게임은 미시험 |
| 스팀덱 UI(`steam-deck-ui`) | 🟡 | KWin 안의 창 모드만 확인. 전체 화면과 터치 조작은 미시험 |
| 게임 모드 부팅 세션 | ❌ | 패널 색상 커밋 문제로 만들지 않음 |
| 60 Hz, 144 Hz, VRR | ❌ | 120 Hz 고정 |

## 3. 시스템 구성

| 영역 | 구성 |
|---|---|
| 메모리 | zswap(zstd, 풀은 램의 최대 20%) + 8 GB 스왑 파일 `/swap/swapfile`, swappiness 100, earlyoom |
| 절전 | s2idle. 배터리일 때 1분 어둡게, 2분 화면 끄기, 30분 절전 |
| CPU | TEO, 배터리일 때 고성능 코어 약 2.2 GHz 제한(`tb710fu-cpucap`). `steam-arm64` 실행 중에는 해제 |
| PCIe | ASPM powersupersave |
| 디스크 쓰기 주기 | 15초 |
| 데스크톱 | Plasma + Quickshell `macshell`, SDDM 자동 로그인 |
| 입력기 | fcitx5 + hangul |
| 게임 | FEX, Valve linuxarm64 Steam, gamescope 3.17 |

**주요 서비스:** `hexagonrpcd-adsp-sensorspd`, `iio-sensor-proxy`, `tb710fu-lid`, `tb710fu-keyboard`, `tb710fu-cpucap`, `tb710fu-android-storage`, `qbootctl-mark-successful`, `earlyoom`, `power-profiles-daemon`, `sshd`, `sddm`

**설정 파일:** `/etc/tmpfiles.d/tb710fu-zswap.conf`, `/etc/tmpfiles.d/tb710fu-aspm.conf`, `/etc/sysctl.d/90-tb710fu-power.conf`, `/etc/sysctl.d/91-tb710fu-swap.conf`, `/etc/systemd/sleep.conf.d/tb710fu.conf`, `/usr/lib/systemd/system-sleep/tb710fu-sensors`

## 4. 전력 측정 (2026-11-18)

| 상태 | 소비 전력 |
|---|---|
| 화면 켜짐, 유휴 | 약 4 W(밝기 100%, 2026-11-16 측정) |
| 화면 꺼짐, 유휴 | 약 0.7 W |
| 화면 꺼짐 + 센서 스트림 중지 | 약 0.1 W 감소 |
| 화면 꺼짐 + Brave 일시 정지 | 약 0.06 W 감소 |

클럭, 전원 도메인, 레귤레이터 누수는 없었습니다. Wi-Fi 절전, PCIe L1.2, GPU 최저 클럭도 정상입니다.

## 5. 백업

| 위치 | 내용 |
|---|---|
| 태블릿 `/var/lib/tb710fu/backup/20261118-153301` | 이전 boot_a(`987009be…`)와 이전 커널 모듈 |
| 태블릿 `/var/lib/tb710fu/stock/boot_a.img` | 패키징에 필요한 순정 boot_a(`37bb1bc5…`). **지우지 마세요** |
| PC `out/backup-a-20261115`, `out/backup-a-20261116` | boot_a, vbmeta_a |
| PC `out/v4-e3-20261115` | 슬롯 b |
| PC `out/fbe-off` | 암호화 해제 vendor_a, vbmeta_a |

## 6. 남은 일

1. **SSH가 끊긴 원인 확인:** 절전인지 리셋인지 봅니다.
2. **새 커널 재시험:** 절전을 반복한 뒤 충전, 소리, 센서, 키보드, 덮기가 유지되는지 확인합니다.
3. **gamescope:** FEX 세션(`6bdbed6d`)의 패널 문제 조사 결과를 받아 전체 화면 동작을 판단합니다.
4. **전력:** 배터리 자동 절전을 5분으로 줄일지, 화면이 꺼지면 센서 스트림을 멈출지 결정합니다.
5. **덮개를 열 때 깨우기:** 키보드 UART나 gpio81을 깨우기 소스로 등록합니다.
6. **가상 키보드:** fcitx5-osk를 `CARGO_BUILD_JOBS=2`로 다시 빌드합니다.
7. **libssc:** `report_received` 크래시가 다시 나는지 지켜봅니다.
8. **Caps Lock LED:** 안드로이드에서 UART를 캡처해 비교합니다.
9. **업스트림:** [제출 현황](KERNEL-BUILD.md#11-업스트림-제출)을 보세요.
10. **보류:** SSD 이미지 쓰기
