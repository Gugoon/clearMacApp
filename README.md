# clearMacApp

macOS에 설치된 앱과 그에 연관된 잔여 파일을 함께 깔끔하게 삭제하는 단일 셸 스크립트입니다.

앱을 휴지통으로 끌어다 버리면 본체(`/Applications/Foo.app`)는 사라지지만, `~/Library/Caches`, `~/Library/Containers`, `~/Library/Preferences` 등에 남아 있는 설정·캐시·로그는 그대로 남습니다. `clearMacApp`은 Bundle ID와 앱 이름을 기준으로 이런 잔여 파일을 모아 한 번에 정리합니다.

## 주요 기능

- 설치된 앱(.app)을 한 번에 보고 번호로 선택 (fzf 설치 시 검색 UI 자동 사용)
- Homebrew **cask** / **formula** 도 같은 메뉴에서 함께 정리 (`-b` 옵션)
- Bundle ID + 앱 이름으로 흩어진 잔여 파일 자동 수집
- 삭제 전 대상 목록과 용량 미리보기, 확인 프롬프트
- 사용자 영역은 휴지통 이동, 시스템 영역은 `sudo rm -rf`
- brew 항목은 `brew uninstall [--cask] <name>` 으로 메타데이터까지 정리
- dry-run 모드로 실제 삭제 없이 대상만 확인 가능
- 위험 경로(`/`, `/Library`, `$HOME` 등) 자동 차단

## 요구 사항

- macOS (Darwin)
- bash 3.2+ (macOS 기본 bash 호환)
- (선택) `fzf` — 설치되어 있으면 검색 가능한 선택 UI 자동 사용

## 설치

```bash
git clone https://github.com/Gugoon/clearMacApp.git
cd clearMacApp
chmod +x clearapp.sh
```

원하면 PATH 위에 심볼릭 링크를 두어 어디서나 실행할 수 있습니다.

```bash
ln -s "$(pwd)/clearapp.sh" /usr/local/bin/clearapp
```

## 사용법

```bash
./clearapp.sh             # 대화형 모드 (번호 또는 fzf 검색으로 선택)
./clearapp.sh -n          # dry-run — 어떤 파일이 지워질지 미리 확인
./clearapp.sh -a          # Spotlight 인덱스 전체에서 앱 탐색
./clearapp.sh -b          # Homebrew cask/formula 도 함께 표시
./clearapp.sh -a -b -n    # 옵션은 자유롭게 조합 가능
./clearapp.sh -y          # 확인 프롬프트 생략 (주의)
./clearapp.sh -h          # 도움말
```

처음 사용한다면 `-n`(dry-run)으로 한 번 확인한 뒤 실제 삭제를 진행하는 것을 권장합니다.

## 옵션

| 옵션 | 설명 |
|------|------|
| `-a`, `--all` | Spotlight 인덱스 전체에서 검색합니다. 시스템 앱·빌드 산출물·휴지통 등은 자동 필터됩니다. |
| `-b`, `--brew` | Homebrew cask/formula 도 메뉴에 포함시킵니다. 삭제는 `brew uninstall [--cask] <name>` 을 사용합니다. |
| `-n`, `--dry-run` | 실제 삭제 없이 대상 파일만 출력합니다. |
| `-y`, `--yes` | 삭제 전 확인 프롬프트를 생략합니다. |
| `-h`, `--help` | 도움말을 표시합니다. |

## 항목 종류

`-b` 옵션으로 brew 통합을 켜면 메뉴에 다음 세 종류의 항목이 함께 표시됩니다.

| 태그 | 의미 | 삭제 방식 |
|------|------|----------|
| `[app]` | `/Applications` 등에 설치된 일반 macOS 앱(.app) | 본체 + `~/Library` 잔여를 휴지통/sudo rm 으로 정리 |
| `[cask]` | Homebrew cask 로 설치된 GUI 앱 | `brew uninstall --cask` + cask 의 **zap** 메타데이터(작성자 명시 잔여 경로) + `~/Library` 매칭 통합 정리 |
| `[formula]` | Homebrew formula (CLI 도구) | `brew uninstall` 만 수행 (의존자가 있으면 brew가 거부) |

`-b` 가 켜진 동안에는 `/opt/homebrew/Caskroom`, `/usr/local/Caskroom` 디렉토리의 `.app` 직접 검색은 비활성화되어 cask 항목과 중복되지 않습니다.

## 앱 탐색 위치

기본 모드:

- `/Applications` (서브디렉토리 포함, depth 4)
- `~/Applications`
- `/opt/homebrew/Caskroom`, `/usr/local/Caskroom` (Homebrew Cask 디렉토리의 .app)

`-b` 모드에서는:

- 위 + `brew list --cask`, `brew list --formula` 결과
- Caskroom 디렉토리 직접 검색은 자동 비활성화

`-a` 모드에서는 위 위치에 더해 Spotlight(`mdfind`) 인덱스 전체를 사용합니다. 다음 위치는 자동으로 제외됩니다.

- `/System/`, `/Library/Apple/` (SIP·시스템 컴포넌트)
- `/Library/Image Capture/Support/` (Image Capture 보조 컴포넌트)
- `*/DerivedData/`, `*/Build/Products/`, `*/build/ios/`, `*/build/macos/` (Xcode·Flutter 빌드 산출물)
- `*-iphoneos/`, `*-iphonesimulator/`
- `*.app/Contents/` (앱 번들 내부 보조 앱)
- `~/Library/Caches/`, `~/Library/Application Support/` 등의 캐시 사본
- 휴지통

## 삭제 대상 위치

선택한 앱의 Bundle ID 또는 앱 이름과 일치하는 파일을 다음 위치에서 찾아 함께 삭제합니다.

사용자 영역 (휴지통 이동):

- `~/Library/Application Support`
- `~/Library/Caches`
- `~/Library/Preferences`
- `~/Library/Logs`
- `~/Library/Saved Application State`
- `~/Library/Containers`
- `~/Library/Group Containers`
- `~/Library/HTTPStorages`
- `~/Library/WebKit`
- `~/Library/Cookies`
- `~/Library/LaunchAgents`

시스템 영역 (sudo로 직접 삭제):

- `/Library/Application Support`
- `/Library/Caches`
- `/Library/Preferences`
- `/Library/LaunchAgents`
- `/Library/LaunchDaemons`
- `/Library/PrivilegedHelperTools`

## 안전 장치

- 기본 동작은 확인 프롬프트가 필요한 대화형 모드입니다.
- 사용자 영역은 곧장 지우지 않고 휴지통으로 이동시켜 복구할 수 있습니다.
- Bundle ID 매칭은 정확/접두 일치만, 앱 이름 매칭은 정확 일치만 사용해 오탐을 줄였습니다.
- `/`, `/Library`, `/Applications`, `$HOME`, `$HOME/Library`, `$HOME/Documents` 등 시스템·홈 디렉토리 자체에 대한 삭제는 자동 차단됩니다.
- broken symlink는 목록에서 자동 제외되어 깨진 경로를 잘못 처리하지 않습니다.
- AppleScript 인자는 `argv`로 전달되어 따옴표·특수문자가 포함된 경로에서도 안전합니다.

## 동작 흐름

1. 설치된 항목 목록을 표시합니다 (`-b` 시 cask/formula 포함).
2. 번호 또는 fzf로 항목을 선택합니다.
3. 항목 종류에 따라 분기합니다.
   - `[app]`: `Info.plist` 에서 Bundle ID 추출 → `~/Library`, `/Library` 에서 잔여 수집 → 미리보기 → 휴지통/직접 삭제
   - `[cask]`: `brew info --json=v2` 로 `.app` 이름과 `zap` 메타데이터 파싱 → zap 경로 + Bundle ID/이름 매칭 통합 → 실재 검사 → 미리보기 → `brew uninstall --cask` (실패해도 잔여 정리는 계속) + 잔여 정리
   - `[formula]`: 의존자 안내(잘리면 "외 N개" 표시) → 미리보기 → `brew uninstall`

## 라이선스

자유롭게 사용·수정·배포할 수 있습니다.
