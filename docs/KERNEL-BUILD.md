# TB710FU 커널 재컴파일과 재패키징

커널을 고쳐서 빌드하고, boot_a 이미지로 만들어 기기에 넣는 절차입니다. 최종 목표는 **태블릿 안에서 컴파일과 패키징을 모두 끝내는 것**입니다. 현재 시스템 상태는 [SYSTEM-STATE.md](SYSTEM-STATE.md)를 보세요.

> **boot_a 쓰기는 사용자의 명시적 동의를 받은 뒤에만 합니다.** 컴파일과 패키징까지는 기기에 아무 영향이 없습니다.

## 1. 전체 흐름

```
ArmadaOS Freedom 커널 트리(kernel.yml의 ARMADA_SHA로 고정)
  + kernel/armada-overlay/tb710fu-locked(패치, 설정, DTS)
  + kernel/tb710fu-kbpack(키보드 모듈)
      ↓ device-kernel.sh build 또는 GitHub Actions
  $TB_WORK/out/kernel-armada
      ↓ device-kernel.sh package(순정 boot_a + kShimC + 커널 + initramfs, testkey 서명)
  $TB_WORK/out/kshim/boot_a.img
      ↓ device-kernel.sh install(사용자 동의 필요)
  boot_a + /usr/lib/modules/<release>
```

| 방법 | 언제 쓰나 | 소요 시간 |
|---|---|---|
| **기기 빌드**(3장) | 기본 경로. PC 없이 작업할 때 | 1~3시간(추정, 전체 빌드 실측 없음) |
| **CI 빌드**(4장) | 빨리 받고 싶을 때, 기기 발열을 피할 때 | 약 1시간 이상 |

어느 쪽이든 패키징은 기기에서 합니다.

## 2. 사전 조건

```bash
git clone https://github.com/bmk-keyeast/tb710fu-arch-linux /var/tmp/tb710fu-repo
cd /var/tmp/tb710fu-repo
build/device-kernel.sh check     # 아무것도 바꾸지 않음
build/device-kernel.sh deps      # 빠진 패키지 설치(sudo)
```

`check`가 확인하는 항목:

| 항목 | 기준 |
|---|---|
| 아키텍처 | aarch64 |
| 빈 공간 | 작업 폴더에 30 GB 이상 |
| 스왑 | 3 GB 이상. 없으면 큰 빌드 중 기기가 통째로 멈춤 |
| 빌드 도구 | gcc, make, pahole, dtc, cmake 등 |
| 순정 boot_a | `/var/lib/tb710fu/stock/boot_a.img`, sha256 앞자리 `37bb1bc53ca26c18` |

**순정 boot_a는 저장소에 없습니다.** 저작권이 있는 파일이라 태블릿에만 보관합니다. 지우지 마세요. 공식 롬의 `image/boot.img`는 해시가 달라(`31494539…`) 대신 쓸 수 없습니다.

환경 변수:

| 변수 | 기본값 | 뜻 |
|---|---|---|
| `TB_WORK` | `/var/tmp/tb710fu-kernel` | 작업 폴더. `/tmp`는 램이라 쓰면 안 됨 |
| `TB_STOCK` | `/var/lib/tb710fu/stock` | 순정 boot_a가 있는 폴더 |
| `JOBS` | `4` | 컴파일 작업 수 |
| `KBPACK` | `1` | DTB에서 키보드 커널 드라이버를 켬 |

## 3. 기기에서 빌드

충전기를 연결하고 시작하세요. 컴파일은 번호가 낮은 코어에서 가장 낮은 우선순위로 돌아서, 그동안 데스크톱을 쓸 수 있습니다.

```bash
cd /var/tmp/tb710fu-repo
git pull
build/device-kernel.sh fetch     # Armada 트리 받기 + 오버레이 복사
build/device-kernel.sh prepare   # 패치와 설정만 시험(컴파일 없음)
build/device-kernel.sh build     # 컴파일. 로그: /var/tmp/tb710fu-kernel/build.log
build/device-kernel.sh package   # boot_a.img 생성과 AVB 검증
```

- **`prepare`를 먼저 돌리세요.** 패치 충돌과 옵션 누락을 몇 분 안에 잡아냅니다.
- SSH로 작업한다면 연결이 끊겨도 계속되도록 `systemd-run --user --unit=kbuild build/device-kernel.sh build`로 돌리고 `journalctl --user -fu kbuild`로 봅니다.
- 기기가 느려지거나 멈추면 `JOBS=2`로 다시 돌립니다.
- 결과물은 `/var/tmp/tb710fu-kernel/out/kshim/boot_a.img`입니다.
- `package`는 처음 실행할 때 인터넷이 필요합니다. kShimC 도구를 `kshim-latest` 릴리스에서 받습니다.
- initramfs는 지금 시스템이 쓰는 `/boot/initramfs-tb710fu.img`를 그대로 씁니다(sudo 필요). 릴리스의 initramfs는 더 새로운 패키지로 다시 만들어지므로 쓰지 않습니다.
- 실측 시간: `prepare` 약 1분, `package` 약 30초입니다.

## 4. CI로 빌드하고 기기에서 패키징

`kernel/**`나 `.github/workflows/kernel.yml`을 main에 push하면 자동으로 빌드됩니다. 직접 돌리려면 `gh workflow run kernel.yml`을 씁니다.

```bash
# RUN은 Actions의 kernel 워크플로 런 번호. 아티팩트는 30일 뒤 사라짐
gh run download RUN -n kernel-tb710fu -D /var/tmp/tb710fu-ci
build/device-kernel.sh import /var/tmp/tb710fu-ci/kernel-*.tar.gz
build/device-kernel.sh package
```

아티팩트에는 커널·모듈 tar, `rootfs-extra.tar.gz`(펌웨어, UCM), `kernel.config`, 체크섬이 들어 있습니다.

## 5. 커널 고치기

| 하고 싶은 일 | 고칠 곳 |
|---|---|
| 패치 추가 | `kernel/armada-overlay/tb710fu-locked/patches/NNNN-이름.patch` |
| 커널 옵션 변경 | `kernel/armada-overlay/tb710fu-locked/config/tb710fu-locked.config` |
| 꼭 유지할 옵션 지정 | `kernel/required-options.txt` |
| 보드 DTS 변경 | `kernel/armada-overlay/tb710fu-locked/dts/` |
| 키보드 드라이버 | `kernel/tb710fu-kbpack/` |
| Armada 기준 커밋 변경 | `.github/workflows/kernel.yml`의 `ARMADA_SHA` |
| 커널 cmdline | DTB `/chosen`. `build/build.sh`의 `kshim` 단계 |

- 패치는 Armada의 `patches/series`가 끝난 뒤 파일 이름순으로 `patch -p1 -F0`로 적용됩니다. **fuzz를 허용하지 않으므로** 문맥이 정확해야 합니다.
- 요청한 옵션이 Kconfig 의존성 때문에 빠지면 빌드가 실패합니다.
- 고친 뒤에는 `fetch`를 다시 돌려야 오버레이가 Armada 트리로 복사됩니다.
- **커널과 모듈은 항상 같은 트리에서 빌드합니다.** 모듈 하나만 다른 트리로 빌드하면 `Exec format error`로 거부됩니다.

## 6. 기기에 설치

**사용자 동의를 받은 뒤에만 실행합니다.** USB-C 호스트 모드에서는 스크립트가 거부합니다.

```bash
sudo CONFIRM=write-boot_a build/device-kernel.sh install
```

스크립트가 하는 일:

1. AVB 서명을 검증합니다.
2. 현재 boot_a와 모듈을 `/var/lib/tb710fu/backup/<날짜>`에 백업합니다.
3. 새 모듈을 설치하고 boot_a를 쓴 뒤 다시 읽어 해시를 비교합니다.

**설치 후 바로 재부팅하세요.** 릴리스 이름이 같아서, 재부팅 전에는 실행 중인 커널이 새 모듈을 읽지 못합니다. kShimC 메뉴에서 Arch Linux를 고릅니다.

### 부팅 후 확인

```bash
uname -a; systemctl --failed
journalctl -b -p err -k --no-pager | grep -v 'Handover signaled' | tail -20
cat /sys/class/remoteproc/remoteproc0/state                  # running
cat /sys/class/power_supply/battery/status                   # 충전기를 꽂으면 Charging
wpctl status | grep -A4 Sinks                                # 스피커
busctl get-property net.hadess.SensorProxy /net/hadess/SensorProxy net.hadess.SensorProxy LightLevel
```

그다음 키보드(연결, 분리, 접기, 덮기), 절전 후 복귀, 터치와 펜을 순서대로 확인합니다.

### 이번 커널에서 새로 확인할 것

| 항목 | 확인 방법 | 정상 |
|---|---|---|
| q6v5 수정 | `grep -E 'q6v5 (handover\|ready)\|smp2p-adsp' /proc/interrupts`를 30초 간격으로 두 번 | **handover만 멈춤.** ready와 smp2p-adsp는 계속 증가 |
| q6v5 로그 | `journalctl -b -k -g 'Handover signaled' \| wc -l` | 0 |
| ADSP 복귀 | 절전을 여러 번 반복한 뒤 충전, 소리, 센서 | 모두 동작 |
| uinput 내장 | `ls -l /dev/uinput`, `steam-arm64` 컨트롤러 | 장치가 있고 입력됨 |

## 7. 되돌리기

**리눅스가 부팅될 때:**

```bash
ls /var/lib/tb710fu/backup/
sudo CONFIRM=write-boot_a build/device-kernel.sh rollback /var/lib/tb710fu/backup/<날짜>
```

**리눅스가 부팅되지 않을 때:** kShimC 메뉴는 그대로 남아 있으므로 안드로이드로 들어갑니다(메뉴에서 8초 기다리면 자동 선택). 그다음 PC에서 `adb shell`, `su`로 root를 얻습니다.

```bash
B=/data/linux/var/lib/tb710fu/backup/<날짜>
dd if=$B/boot_a.img of=/dev/block/by-name/boot_a bs=4M && sync
rm -rf /data/linux/usr/lib/modules/$(cat $B/RELEASE)
cp -a $B/modules /data/linux/usr/lib/modules/$(cat $B/RELEASE)
```

## 8. zswap 켜기

새 커널에는 zswap이 내장되어 있지만 **기본으로 꺼져 있습니다.** zram과 함께 켜면 이중으로 압축되므로, zram을 끄고 켭니다. 이 절차는 아직 기기에서 시험하지 않았습니다.

```bash
sudo mv /etc/systemd/zram-generator.conf /etc/systemd/zram-generator.conf.off
sudo systemctl daemon-reload
sudo swapoff /dev/zram0
echo 'w /sys/module/zswap/parameters/enabled - - - - 1' | sudo tee /etc/tmpfiles.d/tb710fu-zswap.conf
sudo systemd-tmpfiles --create /etc/tmpfiles.d/tb710fu-zswap.conf
grep -r . /sys/module/zswap/parameters/     # enabled=Y, compressor=zstd
```

되돌리기:

```bash
sudo rm /etc/tmpfiles.d/tb710fu-zswap.conf
echo 0 | sudo tee /sys/module/zswap/parameters/enabled
sudo mv /etc/systemd/zram-generator.conf.off /etc/systemd/zram-generator.conf
sudo systemctl daemon-reload && sudo systemctl start systemd-zram-setup@zram0 dev-zram0.swap
```

## 9. 문제 해결

| 증상 | 원인과 조치 |
|---|---|
| `prepare`에서 패치 실패 | Armada 기준 커밋이 바뀌어 문맥이 어긋남. 패치를 새 트리에 맞게 다시 만듦 |
| `missing CONFIG_X` | Kconfig 의존성으로 옵션이 빠짐. `$TB_WORK/kb/linux-*/`에서 `make menuconfig`의 검색으로 의존성 확인 |
| `build-kernel.sh changed` | Armada 빌드 스크립트의 컴파일 줄이 바뀜. `device-kernel.sh`의 `prepare` 수정 |
| 빌드 중 기기가 멈춤 | 메모리 부족. `JOBS=2`로 다시 실행, `swapon --show` 확인 |
| 모듈 로드 시 `Exec format error` | 커널과 다른 트리에서 빌드한 모듈. 전체를 다시 빌드 |
| `is not the stock image` | 순정 boot_a가 다른 파일임. 2장의 해시 확인 |
| `AVB verification failed` | 패키징 실패. `package`를 다시 실행하고 로그 확인 |
| 화면이 켜지지 않음 | 7장의 안드로이드 복구 |

## 10. 검증 기록

| 항목 | 상태 |
|---|---|
| CI 전체 빌드(Freedom 5c4454f + 패치 0001, 0003) | ✔ 런 44250381926(44d67b5). 패치 304개 적용, 필수 옵션 통과 |
| `check`, `deps`, `fetch`, `prepare`(기기, gcc 16.1.1) | ✔ 2026-11-18. 패치와 설정 통과 |
| `import`, `package`(기기, 위 CI 커널) | ✔ 2026-11-18. `boot_a.img` `90affd1f…`, AVB OK, cmdline 동일, 키보드 노드 okay |
| `install` | ✔ 2026-11-18. 기록 후 해시 일치, 백업 생성 |
| `rollback` | **아직 안 함** |
| 기기에서 전체 컴파일(`build`) | **아직 안 함** |
| 새 커널 부팅 | ✔ 2026-11-18. 실패한 서비스 없음, q6v5 수정 동작, 앰프 4개 시작 성공, 센서 동작 |
| 새 커널에서 절전 반복과 키보드 입력 | **아직 안 함** |
