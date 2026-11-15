# 리눅스를 안드로이드 `/data`에 두기 (암호화 해제 + 공간 공유)

목표: 안드로이드 `userdata`의 암호화를 끄고, 리눅스 루트를 그 안의 폴더 `/data/linux`에 둡니다.
파티션을 나누지 않으므로 두 OS가 남은 공간을 그때그때 나눠 씁니다. 리눅스에서는 `/data`
전체가 `/mnt/android`로 보입니다.

## 순정 롬에서 암호화가 걸리는 곳

| 위치 | 내용 |
|---|---|
| `vendor_a`(super 안, ext4) `/etc/fstab.qcom` | `/data` 줄의 `fileencryption=…wrappedkey_v0`, `keydirectory=/metadata/vold/metadata_encryption`, `metadata_encryption=aes-256-xts:wrappedkey_v0`, 마운트 옵션 `inlinecrypt` |
| 누가 읽나 | 2단계 init이 `mount_all /vendor/etc/fstab.qcom --late`로 이 경로를 직접 읽음 (`init.target.rc`). vold도 같은 파일 |
| vendor_boot 1단계 fstab | 같은 줄이 있지만 `/data`는 latemount라 1단계에서는 안 씀 → 그대로 둠 |
| 검증 | vendor는 dm-verity(hashtree), 그 descriptor는 `vbmeta_a`에 있음. vbmeta_a는 이미 LTBox testkey 서명 → 다시 서명 가능 |

롬 패키지의 `super_7.img`는 vendor_a 그 자체입니다(크기와 super 안 위치가 기기 lpdump와 일치).

## 고치는 방법 ([build/fbe-off.py](../build/fbe-off.py))

1. **fstab만 바이트 단위로 고침.** vendor ext4에 `shared_blocks`(중복 제거)가 켜져 있어 e2fsprogs로는
   쓸 수 없습니다. 위 플래그를 지우고 줄어든 바이트는 뒤에 주석 줄(`#---`)로 채워 파일 크기를 그대로
   둡니다. 파일시스템 메타데이터는 바뀌지 않습니다.
2. **hashtree 재계산.** 순정 salt·블록 크기로 다시 만듭니다. 먼저 순정 이미지의 hashtree를 똑같이
   재현해 보고 vbmeta_a의 값과 맞을 때만 진행합니다. FEC는 맞출 수 없어서 descriptor에서 뺍니다
   (dm-verity는 FEC 없이 동작).
3. **vbmeta_a 재서명.** vendor hashtree descriptor만 바꾸고 나머지(체인, 롤백 인덱스, 속성)는 그대로.

기기에는 리눅스에서 씁니다([tb710fu-android-fbe](../build/rootfs-files/tb710fu-android-fbe)). 안드로이드가
돌고 있지 않으니 마운트된 vendor를 덮어쓸 위험이 없습니다. 순정이나 패치본이 아닌 상태면 쓰지 않고,
`/data`와 `/metadata` 앞부분을 0으로 지워 안드로이드가 다음 부팅에 새로 포맷하게 합니다.

## 순서 (kShimC, SSD 없이) — 지금 쓰는 방법

암호화 해제는 위 "기기 결과"대로 끝났고, boot_a는 kShimC입니다. 리눅스는 kShimC 메뉴의 "Arch Linux"로
부팅하고 루트는 `/data/linux`입니다.

1. **PC:** `build.sh personal` → `out/tb710fu-personal.tar`(Wi-Fi·SSH 설정, 롬의 DSP 라이브러리, 16 MB, 비공개).
2. **태블릿(안드로이드, KernelSU 루트):**
   ```sh
   adb push android/install-linux-data.sh out/tb710fu-personal.tar /data/local/tmp/
   adb shell su -c "sh /data/local/tmp/install-linux-data.sh"
   ```
   태블릿이 rootfs-latest 릴리스에서 `tb710fu-rootfs.tar.xz`(약 1.3 GB)를 직접 내려받아 확인하고
   `/data/linux`에 풉니다. 데이터가 걱정되면 Wi-Fi에서 하거나 PC에서 받아 `adb push`로 같은 자리에 둡니다.
3. **PC:** `build.sh initramfs`(60 MB) → `ROOT_DEV=userdata build.sh kshim` → `out/kshim/boot_a.img`.
4. **boot_a 쓰기:** `adb push`한 뒤 `su -c dd`로 쓰고 다시 읽어 해시를 확인합니다(또는 EDL, LUN4 섹터 112006).
5. 재부팅 → 메뉴에서 Arch Linux. `/data/linux`가 없으면 initramfs가 30초 뒤 재부팅해서 안드로이드로 갑니다.
   첫 부팅에 `tb710fu-firstboot`가 파일 capability를 다시 붙입니다(busybox tar는 xattr을 버림).

아래는 SSD를 거치던 이전 순서입니다.

## 순서 (이전: SSD → 슬롯 b)

**0. 백업.** 안드로이드 `/data`는 지워집니다. KernelSU 모듈은 `out/backup-ksu-20261112/`에 있음.

**1. SSD로 리눅스 부팅 (키보드·센서 테스트).** `tb710fu-ssd.img.xz`를 SSD에, `out/v4/e3`를 슬롯 b에.

**2. PC에서 패치 이미지 만들기**
```bash
python -I build/fbe-off.py build <롬>/image/super_7.img out/dump-20261110/vbmeta_a.img \
    build/testkey_rsa4096.pem out/fbe-off
```
`out/fbe-off/`(vendor_a.img 1.8GB, vbmeta_a.img, SHA256SUMS, stock.sha256)를 SSD 리눅스로 복사합니다(`scp`).

**3. 리눅스(SSD)에서 암호화 끄기**
```bash
sudo tb710fu-android-fbe check ~/fbe-off   # 쓰지 않고 상태만 확인 (vendor_a/vbmeta_a: stock)
sudo tb710fu-android-fbe off ~/fbe-off     # WIPE 입력 → vendor_a, vbmeta_a 기록 + /data, /metadata 지움
```

**4. 안드로이드로 부팅.** 첫 부팅에 `/data`가 암호화 없이 포맷됩니다(초기화와 같음). 설정 후
`getprop ro.crypto.state`가 `unencrypted`인지 확인하고 KernelSU를 복구합니다.

**5. 리눅스(SSD)에서 시스템을 `/data/linux`로 복사**
```bash
sudo tb710fu-install-userdata
```

**6. 슬롯 b를 userdata 루트로.** PC에서 `ROOT_DEV=userdata build.sh v4 e3` → `out/v4/e3-userdata/`를
슬롯 b에 씁니다. 이제 SSD 없이 리눅스가 `/data/linux`에서 뜹니다. 루트가 안 보이면 initramfs가 슬롯 a로
돌아갑니다.

## 기기 결과 (2026-11-15) ✔

EDL로 `out/fbe-off`의 vendor_a(super LUN0 섹터 2851976)와 vbmeta_a를 쓰고 metadata 전체와 userdata 앞
64 MiB를 0으로 지운 뒤(모두 다시 읽어 일치) 부팅: `ro.crypto.state=unsupported`, `/data`는
`/dev/block/sda14`를 그대로 마운트(dm-default-key 없음, `inlinecrypt` 없음), `verifiedbootstate=green`.
boot_a는 kShimC 이미지(`build.sh kshim`)였고 문제없이 같이 동작. 데이터 초기화로 KernelSU 매니저 앱은
다시 설치해야 함(`su` 없음).

### 루팅 (LTBox, KernelSU LKM)

KernelSU LKM은 **init_boot_a**만 패치하므로 kShimC boot_a와 상관없습니다. LTBox는 기기에서 vbmeta_a를 읽어
init_boot 항목만 바꿔 다시 서명하고 나머지 항목(우리 vendor hashtree)은 그대로 둡니다(`rebuild_root_vbmeta_owner`).
주의:
- LTBox는 이미 패치된 init_boot를 거부합니다("already KernelSU-patched"). 먼저 롬의 순정 `init_boot.img`를 쓰고
  vbmeta_a의 init_boot 항목만 맞춥니다: `avbsign.py refresh out/fbe-off/vbmeta_a.img OUT testkey init_boot=<롬>/init_boot.img`
  (`out/fbe-off/vbmeta_a-stock-initboot.img`, 2026-11-15 EDL로 기록·확인).
- **LTBox의 Unroot는 쓰지 말 것:** 예전 루팅 때 백업한 vbmeta를 되돌려 vendor hashtree가 틀어집니다(부팅 불가).
- LTBox에서 GKI 모드는 끕니다(GKI 모드는 boot_a 커널을 바꿔 kShimC를 덮어씀).
- 데이터를 초기화하면 LTBox "Disable OTA"(adb로 OTA 앱 제거)도 다시 해야 합니다.

## 검증 (2026-11-15, 기기에 쓰기 전)

✔ = 롬·바이너리에서 확인, 추정 = 확인 못 함.

| 항목 | 결과 |
|---|---|
| 암호화된 `/data` 줄이 있는 곳 | super_1~8 중 vendor(super_7)에만, 딱 한 번 ✔. odm 등 다른 fstab은 없음 |
| 2단계 마운트 | vendor rc의 `mount_all /vendor/etc/fstab.qcom --early/--late` ✔ |
| vendor_boot 1단계 fstab | `/data`는 `latemount`라 1단계에서 안 씀 ✔. `/metadata`는 `formattable` ✔ → 0으로 지워도 다시 포맷됨 |
| 암호화 없는 `/data` 경로 | 시스템 init.rc에 `on nonencrypted`가 남아 있음 ✔ (A16에서도 막는 코드는 못 찾음, 추정) |
| vbmeta_a | 순정 덤프가 이미 testkey(sha1 2597c218…) ✔. 패치본도 같은 키·체인·롤백 인덱스·flags 0 ✔ |
| vendor 해시트리 | `fbe-off.py verify` OK ✔, `out/fbe-off` SHA256SUMS OK ✔ |
| 크기·위치 | super_7.img = vendor_a.img = 3682136 섹터 = lpdump의 vendor_a ✔ |
| 발견한 버그 | Windows에서 만든 `SHA256SUMS`/`stock.sha256`이 CRLF여서 기기의 `sha256sum -c`가 거부했을 것 → LF로 고침 |

남은 위험(추정): ABL이 testkey로 다시 서명한 vbmeta_a를 받는지는 슬롯 b에서만 확인됐습니다(같은 키). 안드로이드가
부팅을 못 하면 `restore`나 EDL 롬 플래시로 되돌립니다.

## 되돌리기

```bash
sudo tb710fu-android-fbe restore ~/fbe-off <롬>/image/super_7.img
```
순정 vendor_a와 백업해 둔 vbmeta_a를 다시 쓰고 `/data`를 지웁니다(암호화 없는 `/data`는 암호화된
상태로 재사용할 수 없음). 롬 전체를 EDL로 다시 플래시해도 됩니다.

## 리눅스 커널 쪽 준비

안드로이드가 포맷한 f2fs에는 casefold·compression·verity 기능이 켜져 있어서, 커널에 `UNICODE`,
`F2FS_FS_COMPRESSION`(LZ4/ZSTD), `FS_VERITY`가 있어야 마운트됩니다. 파일 capability(ping, kwin 등)를
f2fs에 저장하려면 `F2FS_FS_SECURITY`가 필요합니다. 모두 `build.sh kernel`이 켭니다.

## 아직 안 한 것

- 공유 폴더: 리눅스 `~/Android` ↔ 안드로이드 `/data/media/0` (bindfs로 소유자 맞추기, 안드로이드 쪽
  SELinux 라벨은 KernelSU 부팅 스크립트로 `restorecon`)
- 실기 검증 전부 (위 순서의 1번부터)
