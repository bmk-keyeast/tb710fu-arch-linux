# TB710FU 업스트림 제출 자료

2026-11-18 기준입니다. 패치와 제출 문안은 모두 준비되어 있고, **아직 아무 곳에도 보내지 않았습니다.** 제출은 본인 이름으로 해야 하므로 아래의 사람이 할 일이 남아 있습니다.

## 메인라인 지원 현황

확인 기준: 메인라인 `20eef29b7`(v7.4-rc3), linux-next `next-20261117`, patchwork의 linux-arm-msm, linux-input, devicetree, dri-devel.

| 항목 | 상태 |
|---|---|
| TB710FU 보드 DTS | **없음.** 제출된 패치도 찾지 못함 |
| SM8650 SoC | 있음 |
| NT36532 패널 드라이버 | 있음. 다만 OnePlus Pad 2의 CSOT 패널용이고, TB710FU 패널은 등록되어 있지 않음 |
| 키보드 팩 드라이버 | **없음.** 이 폴더의 패치가 처음 |

lore.kernel.org는 자동 접속을 막고 있어 직접 검색하지 못했습니다. 보내기 전에 브라우저에서 [`tb710fu` 검색](https://lore.kernel.org/all/?q=tb710fu)을 한 번 확인하세요.

## 폴더 구성

| 폴더 | 보낼 곳 | 방식 | 검증 상태 |
|---|---|---|---|
| `kernel-keyboard/` | linux-input 메일링 리스트 | RFC 패치 메일 | v7.4-rc3 빌드(W=1), checkpatch, dt_binding_check, 코덱 시험 통과. **이 정리본은 기기에서 실행 전** |
| `iio-sensor-proxy/` | freedesktop GitLab | Merge Request | 태블릿에서 돌아가는 코드와 같음, 빌드 통과 |
| `hexagonrpc/` | GitHub PR #21 | 댓글 + 패치 첨부 | 태블릿에서 돌아가는 코드와 같음, 빌드와 시험 통과 |

**hexagonrpc는 새 PR을 열지 않습니다.** 같은 기능을 다루는 [PR #21](https://github.com/linux-msm/hexagonrpc/pull/21)에서 메인테이너가 설계를 논의하고 있고, 쓰기 파일은 `/var` 아래에 두자는 방향입니다. 우리 패치는 그 방향과 다르므로 자료를 제공하고 어떻게 맞출지 묻는 댓글로 시작합니다.

**센서 쪽 커널 드라이버는 없습니다.** 센서는 ADSP를 거치므로, 우리가 고친 코드는 모두 사용자 공간 프로젝트입니다.

## 사람이 할 일

### 공통

1. **패치를 읽고 이해하세요.** 커널 규정상 제출자는 내용 전체를 설명할 수 있어야 하고, AI는 `Signed-off-by`를 달 수 없습니다.
2. **출처를 판단하세요.** 키보드 프로토콜과 스크램블 표는 순정 `lenovo_keyboard.ko`를 디스어셈블해서 얻었습니다. `Signed-off-by`는 이 코드를 제출할 권리가 있다는 법적 서약(DCO)이므로, 괜찮은지 본인이 판단해야 합니다. 커버 레터에도 이 사실을 적어 두었습니다.

### 키보드 드라이버 (리눅스 커널)

1. 이 정리본을 태블릿에서 실제로 시험합니다. 입력, 터치패드, Caps Lock, 탈착, 접기, 절전을 확인합니다.
2. `0000-cover-letter.patch`의 `TODO(submitter)` 줄을 시험 결과로 바꿉니다.
3. 패치의 이름을 본인 것으로 바꿉니다. 실제 이름과 메일을 넣어 실행합니다.

```bash
sed -i 's/YOUR NAME <you@example.com>/실제 이름 <실제@메일>/g' upstream/kernel-keyboard/*.patch
```

4. 메인라인에 적용하고 서명합니다.

```bash
git clone --depth 1 https://github.com/torvalds/linux.git linux-submit
```

```bash
cd linux-submit && git fetch --depth 1 origin 20eef29b7c8465ac98d7dd6d6f2ac07a8d8056ca && git checkout -b tb710fu-kbpack FETCH_HEAD
```

```bash
git am --signoff ../upstream/kernel-keyboard/0001-*.patch ../upstream/kernel-keyboard/0002-*.patch
```

```bash
git format-patch --rfc --base=HEAD~2 -2 -o out/ && cp ../upstream/kernel-keyboard/0000-cover-letter.patch out/
```

5. 마지막으로 검사합니다. 첫 명령은 아무것도 출력하지 않아야 합니다.

```bash
grep -n 'YOUR NAME\|TODO(submitter)' out/*.patch
```

```bash
./scripts/checkpatch.pl --strict out/0001-*.patch out/0002-*.patch
```

6. `git send-email`을 설정한 뒤 먼저 `--dry-run`으로 확인하고, 이상이 없으면 `--dry-run`을 빼고 보냅니다.

```bash
git send-email --dry-run --to=dmitry.torokhov@gmail.com --to=linux-input@vger.kernel.org --cc=robh@kernel.org --cc=krzk+dt@kernel.org --cc=conor+dt@kernel.org --cc=rydberg@bitmath.org --cc=devicetree@vger.kernel.org --cc=linux-kernel@vger.kernel.org out/*.patch
```

7. 리뷰 메일에 답하고, 요청받은 내용을 고쳐 v2를 보냅니다.

### iio-sensor-proxy

1. [freedesktop GitLab](https://gitlab.freedesktop.org/hadess/iio-sensor-proxy) 계정을 만들고 저장소를 포크합니다.
2. `master`에서 브랜치를 만들어 `git am upstream/iio-sensor-proxy/*.patch`로 적용하고 푸시합니다.
3. `iio-sensor-proxy/MERGE_REQUEST.md`의 내용으로 Merge Request를 엽니다.

### hexagonrpc

1. [PR #21](https://github.com/linux-msm/hexagonrpc/pull/21)에 `hexagonrpc/PR21-COMMENT.md`의 내용을 댓글로 답니다.
2. `hexagonrpc/`의 패치 파일을 댓글에 첨부합니다.
