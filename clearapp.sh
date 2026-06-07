#!/bin/bash
#
# clearapp.sh - macOS 설치된 앱을 깔끔하게 삭제하는 스크립트
#
# 사용법:
#   ./clearapp.sh              # 대화형 모드
#   ./clearapp.sh -a           # Spotlight 인덱스 전체에서 앱 탐색
#   ./clearapp.sh -b           # Homebrew cask/formula 포함
#   ./clearapp.sh -y           # 확인 없이 삭제 (위험!)
#   ./clearapp.sh -n           # dry-run (실제로 삭제하지 않음)
#   ./clearapp.sh -h           # 도움말
#   (단축 옵션은 -ab, -yn 처럼 묶어서 쓸 수 있음)
#

# set -e 는 의도적으로 사용하지 않는다.
#   - du/grep -c/find 등 보조 명령의 비치명적 실패가 스크립트를 중단시키지 않게 하고,
#   - 삭제 실패는 각 함수가 fail 카운터 + return 1 로 명시적으로 전파한다.
set -uo pipefail

# ─────────────────────────────────────────────────────────────
# 색상 정의 — TTY 출력일 때만 색을 입힌다 (파이프/리다이렉트/NO_COLOR 시 무색)
# ─────────────────────────────────────────────────────────────
if [[ -t 1 && -t 2 && -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    NC=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
fi
readonly RED GREEN YELLOW BLUE CYAN BOLD DIM NC

# ─────────────────────────────────────────────────────────────
# 옵션 파싱
# ─────────────────────────────────────────────────────────────
ASSUME_YES=0
DRY_RUN=0
INCLUDE_ALL=0
INCLUDE_BREW=0

usage() {
    cat <<EOF
${BOLD}clearapp.sh${NC} - macOS 앱 깔끔히 삭제

${BOLD}사용법:${NC}
  $0 [옵션]

${BOLD}옵션:${NC}
  -a, --all       모든 위치의 앱을 Spotlight로 검색 (시스템/빌드산출물 제외)
  -b, --brew      Homebrew cask/formula 포함 (brew uninstall 사용)
  -y, --yes       삭제 전 확인 생략 (주의!)
  -n, --dry-run   실제 삭제 없이 대상 파일만 출력
  -h, --help      이 도움말 표시
  (단축 옵션은 -ab, -yn 처럼 묶어 쓸 수 있습니다)

${BOLD}앱 탐색 위치:${NC}
  기본:
    /Applications (하위 폴더 포함)
    ~/Applications
    /opt/homebrew/Caskroom, /usr/local/Caskroom (Homebrew Cask 디렉토리 .app)
  --all:
    위 + Spotlight가 인식한 모든 .app (시스템/빌드산출물 자동 제외)
  --brew:
    + brew list --cask    (cask 항목)
    + brew list --formula (formula 항목)
    삭제 시 'brew uninstall [--cask] <name>' 사용으로 메타데이터까지 정리
    cask 디렉토리의 .app 직접 검색은 끔 (cask 항목으로 일원화)
    단, brew 미설치 시에는 Caskroom .app 직접 검색을 유지한다.

${BOLD}삭제 대상 (관련 파일) 위치:${NC}
  ~/Library/{Application Support,Caches,Preferences,Logs,
            Saved Application State,Containers,Group Containers,
            HTTPStorages,WebKit,Cookies,LaunchAgents}
  /Library/{Application Support,Caches,Preferences,
           LaunchAgents,LaunchDaemons,PrivilegedHelperTools}
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--all)     INCLUDE_ALL=1;  shift ;;
        -b|--brew)    INCLUDE_BREW=1; shift ;;
        -y|--yes)     ASSUME_YES=1;   shift ;;
        -n|--dry-run) DRY_RUN=1;      shift ;;
        -h|--help)    usage; exit 0 ;;
        --)           shift; break ;;
        -[a-z][a-z]*) # 묶음 단축 옵션 분해: -ab → -a -b
                      _bundle="$1"; shift
                      set -- "${_bundle:0:2}" "-${_bundle:2}" "$@"
                      ;;
        *)            echo "알 수 없는 옵션: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# ─────────────────────────────────────────────────────────────
# 환경 확인
# ─────────────────────────────────────────────────────────────
if [[ "$(uname)" != "Darwin" ]]; then
    echo "${RED}이 스크립트는 macOS 전용입니다.${NC}" >&2
    exit 1
fi

# brew 가용성은 한 번만 판정해 재사용
HAS_BREW=0
command -v brew &>/dev/null && HAS_BREW=1
readonly HAS_BREW

# ─────────────────────────────────────────────────────────────
# 검색 대상 디렉토리
# ─────────────────────────────────────────────────────────────
USER_LOCATIONS=(
    "$HOME/Library/Application Support"
    "$HOME/Library/Caches"
    "$HOME/Library/Preferences"
    "$HOME/Library/Logs"
    "$HOME/Library/Saved Application State"
    "$HOME/Library/Containers"
    "$HOME/Library/Group Containers"
    "$HOME/Library/HTTPStorages"
    "$HOME/Library/WebKit"
    "$HOME/Library/Cookies"
    "$HOME/Library/LaunchAgents"
)

SYSTEM_LOCATIONS=(
    "/Library/Application Support"
    "/Library/Caches"
    "/Library/Preferences"
    "/Library/LaunchAgents"
    "/Library/LaunchDaemons"
    "/Library/PrivilegedHelperTools"
)

# ─────────────────────────────────────────────────────────────
# 유틸: 경로 정규화 (연속 슬래시 축약 + 후행 슬래시 제거)
#   심볼릭 링크는 따라가지 않는다(가드는 최상위/시스템 토큰 비교가 목적).
# ─────────────────────────────────────────────────────────────
normalize_path() {
    local p="$1"
    # 연속 슬래시 축약 — replacement 를 변수로 전달해 백슬래시 이스케이프 함정 회피
    local dd="//" s="/"
    while [[ "$p" == *"$dd"* ]]; do p="${p//$dd/$s}"; done
    [[ "$p" != "/" ]] && p="${p%/}"
    printf '%s' "$p"
}

# ─────────────────────────────────────────────────────────────
# 유틸: 디렉토리 용량(du -sh)을 2초 타임아웃으로 측정
#   - App Sandbox 컨테이너(~/Library/Containers/*)의 Data 는 firmlink 구조라
#     du 가 거대 트리를 순회하며 사실상 멈출 수 있어 perl alarm 으로 상한을 둔다.
#   - 타임아웃/실패 시 '?' 를 반환 (표시 전용이므로 정확성에 영향 없음)
# ─────────────────────────────────────────────────────────────
du_safe() {
    local target="$1" sz=""
    if command -v perl &>/dev/null; then
        sz=$(perl -e 'alarm 2; exec @ARGV' du -sh -- "$target" 2>/dev/null | awk '{print $1; exit}')
    else
        # perl 부재 시 firmlink 컨테이너 무한 순회 위험이 있어 용량 측정을 생략('?')
        sz=""
    fi
    printf '%s' "${sz:-?}"
}

# ─────────────────────────────────────────────────────────────
# 유틸: 사용자 입력 받기
#   - prompt 는 stderr 로 출력해서 stdout 캡쳐에 섞이지 않게 함
# ─────────────────────────────────────────────────────────────
prompt_input() {
    local prompt="$1"
    local __varname="$2"
    printf '%s' "$prompt" >&2
    # shellcheck disable=SC2229  # 의도된 indirect read (변수명을 인자로 받음)
    IFS= read -r "$__varname" || return 1
}

# ─────────────────────────────────────────────────────────────
# 유틸: 앱 목록 가져오기
#   결과는 "<type>\t<identifier>" 형태로 출력 (type: app|cask|formula)
#   - find/mdfind 는 -print0/-0 로 받아 개행 포함 경로는 목록에서 안전하게 제외
#   - --brew 라도 brew 미설치 시에는 Caskroom .app 직접 검색을 유지
# ─────────────────────────────────────────────────────────────
list_apps() {
    local include_all="${1:-0}"
    local include_brew="${2:-0}"

    local -a roots=(
        "/Applications"
        "$HOME/Applications"
    )
    # brew 항목으로 일원화할 수 있을 때(=-b + brew 존재)만 Caskroom 직접 검색을 끈다.
    if (( ! include_brew )) || (( ! HAS_BREW )); then
        roots+=("/opt/homebrew/Caskroom" "/usr/local/Caskroom")
    fi

    {
        local root p
        for root in "${roots[@]}"; do
            [[ -d "$root" ]] || continue
            while IFS= read -r -d '' p; do
                case "$p" in *$'\n'*) continue ;; esac   # 개행 포함 경로 제외
                printf 'app\t%s\n' "$p"
            done < <(find -L "$root" -maxdepth 4 -name "*.app" -type d -not -path "*/Contents/*" -print0 2>/dev/null)
        done

        # --all: Spotlight 인덱스 (NUL 구분으로 안전 처리)
        if (( include_all )) && command -v mdfind &>/dev/null; then
            while IFS= read -r -d '' p; do
                case "$p" in *$'\n'*) continue ;; esac
                case "$p" in
                    */Contents/*)                       continue ;;
                    /System/*)                          continue ;;
                    /Library/Apple/*)                   continue ;;
                    "/Library/Image Capture/Support/"*) continue ;;
                    */DerivedData/*)                    continue ;;
                    */build/ios/*)                      continue ;;
                    */build/macos/*)                    continue ;;
                    */Build/Products/*)                 continue ;;
                    */Library/Caches/*)                 continue ;;
                    */Library/Application\ Support/*)    continue ;;
                    */Library/Application\ Scripts/*)    continue ;;
                    */Library/Developer/*)              continue ;;
                    */.Trash/*)                         continue ;;
                    *-iphoneos/*)                       continue ;;
                    *-iphonesimulator/*)                continue ;;
                esac
                printf 'app\t%s\n' "$p"
            done < <(mdfind "kMDItemContentType == 'com.apple.application-bundle'" -0 2>/dev/null)
        fi

        # --brew: brew list 결과 (brew 가 실제로 있을 때만)
        if (( include_brew )) && (( HAS_BREW )); then
            brew list --cask 2>/dev/null    | awk -v OFS='\t' '$0!=""{print "cask", $0}'
            brew list --formula 2>/dev/null | awk -v OFS='\t' '$0!=""{print "formula", $0}'
        fi
    } | sort -u
}

# ─────────────────────────────────────────────────────────────
# 유틸: Bundle ID 읽기
# ─────────────────────────────────────────────────────────────
get_bundle_id() {
    local app_path="$1"
    local plist="$app_path/Contents/Info.plist"
    [[ -f "$plist" ]] || { echo ""; return; }
    /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null || echo ""
}

# ─────────────────────────────────────────────────────────────
# 유틸: 휴지통으로 이동 (가능하면), 안되면 rm -rf
#   인자: <target> <needs_sudo:0|1> [action:trash|delete]
#   - action=delete 이면 휴지통을 거치지 않고 직접 삭제 (cask zap delete 의미 준수)
#   - 경로/이름은 echo -e 가 아니라 printf '%s' 로 출력 (백슬래시 이스케이프 미해석)
# ─────────────────────────────────────────────────────────────
trash_or_remove() {
    local target="$1"
    local needs_sudo="$2"
    local action="${3:-trash}"

    # (0a) 절대경로만 허용 — 상대경로 조각이 cwd 기준으로 삭제되는 것을 방어
    if [[ "$target" != /* ]]; then
        printf '  %s✗%s 비절대 경로 거부: %s\n' "$RED" "$NC" "$target" >&2
        return 1
    fi

    local normalized
    normalized=$(normalize_path "$target")

    # (0b) 상위경로(..) 컴포넌트 포함 차단
    case "/$normalized/" in
        *"/../"*)
            printf '  %s✗%s 위험 경로 거부(상위경로): %s\n' "$RED" "$NC" "$target" >&2
            return 1 ;;
    esac

    # (1) 정확 일치 차단 — 디렉토리 자체는 금지하되 하위는 허용
    local _forbidden
    for _forbidden in \
        "" "/" \
        "/Applications" "/Library" "/System" "/Users" \
        "/private" "/usr" "/bin" "/sbin" "/etc" "/var" "/opt" "/tmp" \
        "$HOME" \
        "$HOME/Library" "$HOME/Documents" "$HOME/Desktop" "$HOME/Downloads" \
        "$HOME/Movies" "$HOME/Music" "$HOME/Pictures" "$HOME/Public"
    do
        # 기준값도 정규화해 비교 — $HOME 에 후행 슬래시가 있어도($HOME=/Users/x/) 정확히 매칭
        if [[ "$normalized" == "$(normalize_path "$_forbidden")" ]]; then
            printf '  %s✗%s 위험 경로 거부: %s\n' "$RED" "$NC" "$target" >&2
            return 1
        fi
    done

    # (2) 시스템 영역 prefix 차단 — 자신과 하위 모두 금지
    local _prefix
    for _prefix in "/System/" "/private/" "/bin/" "/sbin/" "/etc/" "/var/"; do
        if [[ "$normalized/" == "$_prefix"* ]]; then
            printf '  %s✗%s 시스템 경로 거부: %s\n' "$RED" "$NC" "$target" >&2
            return 1
        fi
    done
    # /usr, /opt 는 Homebrew Caskroom 하위만 허용하고 나머지는 차단
    case "$normalized/" in
        /usr/local/Caskroom/*|/opt/homebrew/Caskroom/*) ;;
        /usr/*|/opt/*)
            printf '  %s✗%s 시스템 경로 거부: %s\n' "$RED" "$NC" "$target" >&2
            return 1 ;;
    esac

    # (3) 민감 경로 차단 — zap 등 외부 입력이 가리킬 수 있는 곳
    local _sensitive _sn
    for _sensitive in \
        "$HOME/.ssh" "$HOME/.gnupg" "$HOME/.aws" "$HOME/.config" \
        "$HOME/Library/Keychains"
    do
        _sn=$(normalize_path "$_sensitive")   # 기준값 정규화 ($HOME 후행 슬래시 대응)
        if [[ "$normalized" == "$_sn" || "$normalized/" == "$_sn/"* ]]; then
            printf '  %s✗%s 민감 경로 거부: %s\n' "$RED" "$NC" "$target" >&2
            return 1
        fi
    done

    if (( DRY_RUN )); then
        printf '  %s[dry-run] 삭제 예정: %s%s\n' "$DIM" "$target" "$NC"
        return 0
    fi

    # 사용자 영역 + trash 액션이면 osascript 로 휴지통 이동 (argv 전달 — injection 방지)
    if [[ "$action" != "delete" ]] && (( needs_sudo == 0 )) && command -v osascript &>/dev/null; then
        if osascript - "$target" <<'APPLESCRIPT' &>/dev/null
on run argv
    set p to item 1 of argv
    tell application "Finder" to delete (POSIX file p as alias)
end run
APPLESCRIPT
        then
            printf '  %s✓%s 휴지통으로 이동: %s\n' "$GREEN" "$NC" "$target"
            return 0
        fi
    fi

    # 시스템 영역 / delete 액션 / osascript 실패 시 직접 삭제 (eval 없이)
    local rc=0
    if (( needs_sudo )); then
        sudo rm -rf -- "$target" || rc=$?
    else
        rm -rf -- "$target" || rc=$?
    fi

    if (( rc == 0 )); then
        printf '  %s✓%s 삭제됨: %s\n' "$GREEN" "$NC" "$target"
        return 0
    else
        printf '  %s✗%s 실패: %s\n' "$RED" "$NC" "$target" >&2
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────
# 관련 파일 찾기 (Bundle ID + 앱 이름 기준)
#   출력: NUL 구분 (개행 포함 파일명 안전)
#   - Bundle ID: 정확 + 알려진 확장자 화이트리스트만 (형제 식별자 오탐 방지)
#   - Group Containers: <TeamID>.<bundle_id> 접미 형태 추가 매칭
#   - 앱 이름: glob 해석 없이 basename 정확 비교(대소문자 무시), 사용자 영역에만 적용
# ─────────────────────────────────────────────────────────────
find_related() {
    local app_name="$1"
    local bundle_id="$2"

    local -a results=()
    local -a all_locations=("${USER_LOCATIONS[@]}" "${SYSTEM_LOCATIONS[@]}")
    local loc f base

    # Bundle ID 기반 (사용자/시스템 영역 모두)
    if [[ -n "$bundle_id" ]]; then
        for loc in "${all_locations[@]}"; do
            [[ -d "$loc" ]] || continue
            while IFS= read -r -d '' f; do
                results+=("$f")
            done < <(find "$loc" -maxdepth 1 \
                \( -name "${bundle_id}" \
                -o -name "${bundle_id}.plist" \
                -o -name "${bundle_id}.savedState" \
                -o -name "${bundle_id}.binarycookies" \) \
                -print0 2>/dev/null)

            # Group Containers 등은 <TeamID>.<bundle_id> 형태
            case "$loc" in
                */Group\ Containers|*/HTTPStorages)
                    while IFS= read -r -d '' f; do
                        results+=("$f")
                    done < <(find "$loc" -maxdepth 1 \
                        \( -name "*.${bundle_id}" \
                        -o -name "*.${bundle_id}.plist" \
                        -o -name "*.${bundle_id}.savedState" \
                        -o -name "*.${bundle_id}.binarycookies" \) \
                        -print0 2>/dev/null)
                    ;;
            esac
        done
    fi

    # 앱 이름 기반 (정확 비교, 대소문자 무시) — 사용자 영역에만 (시스템 공통단어 오탐 방지)
    if [[ -n "$app_name" ]]; then
        shopt -s nocasematch
        for loc in "${USER_LOCATIONS[@]}"; do
            [[ -d "$loc" ]] || continue
            while IFS= read -r -d '' f; do
                base="${f##*/}"
                [[ "$base" == "$app_name" ]] && results+=("$f")
            done < <(find "$loc" -maxdepth 1 -mindepth 1 -print0 2>/dev/null)
        done
        shopt -u nocasematch
    fi

    # 중복 제거(순서 보존, bash 3.2 호환) 후 NUL 출력
    local -a uniq=()
    local r u exists
    for r in "${results[@]+"${results[@]}"}"; do
        exists=0
        for u in "${uniq[@]+"${uniq[@]}"}"; do
            [[ "$u" == "$r" ]] && { exists=1; break; }
        done
        (( exists )) || uniq+=("$r")
    done
    (( ${#uniq[@]} > 0 )) && printf '%s\0' "${uniq[@]}"
}

# ─────────────────────────────────────────────────────────────
# 앱 선택 UI — 선택 결과는 전역 SELECTED("type\tid")에 저장
#   반환코드: 0=선택됨, 1=오류(항목없음/잘못된 선택), 2=취소
#   ($() 서브셸이 아니라 직접 호출하므로 흐름제어 반환이 main 까지 전달됨)
# ─────────────────────────────────────────────────────────────
SELECTED=""
select_app() {
    SELECTED=""
    local -a apps=()
    local line
    while IFS= read -r line; do
        apps+=("$line")
    done < <(list_apps "$INCLUDE_ALL" "$INCLUDE_BREW")

    if (( ${#apps[@]} == 0 )); then
        printf '%s항목을 찾을 수 없습니다.%s\n' "$RED" "$NC" >&2
        return 1
    fi

    # 공통 헤더 (stderr)
    printf '%s%s선택 가능한 항목 (%s개)%s\n' "$BOLD" "$BLUE" "${#apps[@]}" "$NC" >&2
    local mode_hint="/Applications, ~/Applications"
    if (( ! INCLUDE_BREW )) || (( ! HAS_BREW )); then
        mode_hint+=", Homebrew Cask 디렉토리"
    fi
    (( INCLUDE_ALL )) && mode_hint+=" + Spotlight 전체"
    (( INCLUDE_BREW )) && (( HAS_BREW )) && mode_hint+=" + brew cask/formula"
    printf '%s(%s)%s\n' "$DIM" "$mode_hint" "$NC" >&2
    if (( ! INCLUDE_ALL )) || (( ! INCLUDE_BREW )); then
        local hints=""
        (( INCLUDE_ALL ))  || hints+=" -a"
        (( INCLUDE_BREW )) || hints+=" -b"
        [[ -n "$hints" ]] && printf '%s더 보려면:%s%s\n' "$DIM" "$hints" "$NC" >&2
    fi
    echo "" >&2

    # fzf 가 있으면 사용 — 표시는 "[type] name", 동명이앱은 경로 힌트 부가
    if command -v fzf &>/dev/null; then
        local choice
        choice=$(printf '%s\n' "${apps[@]}" \
            | awk -F'\t' -v OFS='\t' '
                {
                    type[NR]=$1; id[NR]=$2
                    if ($1=="app") { n=$2; sub(/.*\//,"",n); sub(/\.app$/,"",n); name[NR]=n; cnt[n]++ }
                    else { name[NR]=$2 }
                }
                END {
                    for (i=1;i<=NR;i++) {
                        if (type[i]=="app" && cnt[name[i]]>1) {
                            p=id[i]; sub(/\/[^\/]*$/,"",p)
                            disp=sprintf("[%-7s] %s (%s)", type[i], name[i], p)
                        } else {
                            disp=sprintf("[%-7s] %s", type[i], name[i])
                        }
                        print disp, type[i], id[i]
                    }
                }' \
            | fzf --prompt="삭제할 항목 검색: " \
                  --height=60% --reverse --border \
                  --header="↑↓ 이동 / Enter 선택 / Esc 취소 (${#apps[@]}개)" \
                  --delimiter=$'\t' --with-nth=1)
        # Esc/빈 선택 = 취소
        if [[ -z "$choice" ]]; then
            return 2
        fi
        local _type _id
        _type=$(printf '%s' "$choice" | awk -F'\t' '{print $(NF-1)}')
        _id=$(printf '%s'   "$choice" | awk -F'\t' '{print $NF}')
        SELECTED="${_type}"$'\t'"${_id}"
        return 0
    fi

    # fzf 없으면 번호 메뉴
    printf '%s\n' "${apps[@]}" \
        | awk -F'\t' -v cyan="$CYAN" -v dim="$DIM" -v nc="$NC" '
            {
                type[NR] = $1
                id[NR]   = $2
                if ($1 == "app") {
                    n = $2; sub(/.*\//, "", n); sub(/\.app$/, "", n)
                    display[NR] = n
                    names[NR]   = n
                    count[n]++
                } else {
                    display[NR] = $2
                    names[NR]   = ""
                }
            }
            END {
                for (i=1; i<=NR; i++) {
                    t = type[i]; d = display[i]
                    if (t == "app" && count[names[i]] > 1) {
                        p = id[i]; sub(/\/[^\/]*$/, "", p)
                        printf "  %s%3d%s) [%-7s] %s %s(%s)%s\n", cyan, i, nc, t, d, dim, p, nc
                    } else {
                        printf "  %s%3d%s) [%-7s] %s\n", cyan, i, nc, t, d
                    }
                }
            }
          ' >&2
    echo "" >&2

    local choice
    prompt_input "삭제할 항목 번호를 입력하세요 (q: 종료): " choice

    # 취소 의도 입력에 관대하게 (앞뒤 공백 제거 + 대소문자/quit 허용)
    local trimmed="$choice"
    trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    case "$trimmed" in
        q|Q|quit|Quit|QUIT|exit|"") return 2 ;;
    esac

    # 10# 강제로 8진수 해석 방지 (예: "010")
    if ! [[ "$trimmed" =~ ^[0-9]+$ ]] || (( 10#$trimmed < 1 || 10#$trimmed > ${#apps[@]} )); then
        printf '%s잘못된 선택입니다.%s\n' "$RED" "$NC" >&2
        return 1
    fi

    SELECTED="${apps[$((10#$trimmed-1))]}"
    return 0
}

# ─────────────────────────────────────────────────────────────
# 처리: .app 항목
#   반환: 0=성공/dry-run, 1=일부 실패 (호출자에 전파)
# ─────────────────────────────────────────────────────────────
handle_app() {
    local app_path="$1"

    if [[ -z "$app_path" ]] || [[ ! -e "$app_path" ]]; then
        printf '%s유효한 앱이 아닙니다: %s%s\n' "$RED" "$app_path" "$NC" >&2
        exit 1
    fi

    local app_name bundle_id
    app_name=$(basename "$app_path" .app)
    bundle_id=$(get_bundle_id "$app_path")

    echo ""
    printf '%s선택한 앱%s\n' "$BOLD" "$NC"
    printf '  이름      : %s%s%s\n' "$CYAN" "$app_name" "$NC"
    printf '  경로      : %s\n' "$app_path"
    if [[ -n "$bundle_id" ]]; then
        printf '  Bundle ID : %s\n' "$bundle_id"
    else
        printf '  Bundle ID : %s(읽을 수 없음)%s\n' "$DIM" "$NC"
    fi
    echo ""

    printf '%s관련 파일 검색 중...%s\n' "$BOLD" "$NC"
    local -a targets=("$app_path")
    local f
    while IFS= read -r -d '' f; do
        [[ -n "$f" ]] && targets+=("$f")
    done < <(find_related "$app_name" "$bundle_id")

    # 중복 제거 + 절대경로/존재(깨진 링크 포함) 검사
    local -a unique_targets=()
    local t u exists
    for t in "${targets[@]}"; do
        [[ "$t" == /* ]] || continue
        [[ -e "$t" || -L "$t" ]] || continue
        exists=0
        for u in "${unique_targets[@]+"${unique_targets[@]}"}"; do
            [[ "$u" == "$t" ]] && { exists=1; break; }
        done
        (( exists )) || unique_targets+=("$t")
    done

    echo ""
    printf '%s%s삭제 대상 (%s개)%s\n' "$BOLD" "$YELLOW" "${#unique_targets[@]}" "$NC"
    local size_str needs_sudo_disp
    for t in "${unique_targets[@]+"${unique_targets[@]}"}"; do
        size_str=$(du_safe "$t")
        needs_sudo_disp=0
        [[ "$t" =~ ^(/Library|/Applications)(/|$) ]] && needs_sudo_disp=1
        (( needs_sudo_disp )) && [[ -O "$t" ]] && needs_sudo_disp=0
        if (( needs_sudo_disp )); then
            printf '  %s[sudo]%s %-8s %s\n' "$YELLOW" "$NC" "${size_str:-?}" "$t"
        else
            printf '         %-8s %s\n' "${size_str:-?}" "$t"
        fi
    done
    echo ""

    if (( ! ASSUME_YES )) && (( ! DRY_RUN )); then
        local confirm
        printf '%s%s정말 삭제하시겠습니까?%s\n' "$RED" "$BOLD" "$NC"
        prompt_input "[y/N] " confirm
        if [[ ! "$confirm" =~ ^[yY]$ ]]; then
            echo "취소되었습니다."
            exit 0
        fi
    fi

    echo ""
    printf '%s삭제 진행 중...%s\n' "$BOLD" "$NC"
    local fail=0 needs_sudo
    for t in "${unique_targets[@]+"${unique_targets[@]}"}"; do
        needs_sudo=0
        [[ "$t" =~ ^(/Library|/Applications)(/|$) ]] && needs_sudo=1
        (( needs_sudo )) && [[ -O "$t" ]] && needs_sudo=0
        trash_or_remove "$t" "$needs_sudo" "trash" || ((fail += 1))
    done

    echo ""
    if (( DRY_RUN )); then
        printf '%sDRY-RUN 완료. 실제 삭제는 -n 옵션을 빼고 다시 실행하세요.%s\n' "$YELLOW" "$NC"
        return 0
    elif (( fail == 0 )); then
        printf '%s%s✓ %s 삭제 완료%s\n' "$GREEN" "$BOLD" "$app_name" "$NC"
        return 0
    else
        printf '%s일부 항목 삭제 실패: %s개 (권한 문제일 수 있습니다)%s\n' "$YELLOW" "$fail" "$NC" >&2
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────
# 유틸: brew cask 의 .app 이름들 추출 (인자로 받은 JSON 사용)
#   - app artifact 의 target(설치명) 우선, 없으면 app 소스의 basename
#   - jq → python3 → grep fallback (모두 basename 으로 정규화)
# ─────────────────────────────────────────────────────────────
get_cask_apps() {
    local json="$1"
    [[ -z "$json" ]] && return 1

    if command -v jq &>/dev/null; then
        printf '%s' "$json" | jq -r '
            .casks[0].artifacts[]? | objects | select(.app != null) |
            ( (.target // empty),
              (.app[]? | if type=="object" then (.target // empty) else . end) )
            | strings | sub(".*/"; "")
        ' 2>/dev/null
        return
    fi

    if command -v python3 &>/dev/null; then
        printf '%s' "$json" | python3 -c '
import sys, json, os
def base(s):
    return os.path.basename(s.rstrip("/")) if isinstance(s, str) else None
try:
    data = json.load(sys.stdin)
    casks = data.get("casks", [])
    out = []
    if casks:
        for art in casks[0].get("artifacts", []) or []:
            if isinstance(art, dict) and art.get("app") is not None:
                b = base(art.get("target"))
                if b: out.append(b)
                for app in art.get("app", []) or []:
                    if isinstance(app, str):
                        b = base(app)
                        if b: out.append(b)
                    elif isinstance(app, dict):
                        b = base(app.get("target"))
                        if b: out.append(b)
    for o in out:
        print(o)
except Exception:
    pass
' 2>/dev/null
        return
    fi

    # 최후 fallback: JSON 큰따옴표 사이의 *.app 이름을 basename 으로 추출
    printf '%s' "$json" | grep -oE '"[^"]+\.app"' | sed -e 's/"//g' -e 's#.*/##' | sort -u
}

# ─────────────────────────────────────────────────────────────
# 유틸: brew cask 의 zap 정보 추출 (인자로 받은 JSON 사용)
#   - trash/delete/rmdir 액션을 모두 처리 (단일 문자열/배열 모두 수용)
#   - ~ 는 $HOME 으로 확장
#   - 출력: "<action>\t<absolute_path>" (action: trash|delete; rmdir→trash)
# ─────────────────────────────────────────────────────────────
get_cask_zap() {
    local json="$1"
    [[ -z "$json" ]] && return 1

    if command -v jq &>/dev/null; then
        printf '%s' "$json" | jq -r --arg home "$HOME" '
            def norm(a):
                (a // empty)
                | (if type=="array" then .[] else . end)
                | strings
                | sub("^~"; $home);
            .casks[0].artifacts[]? | objects | .zap[]? | objects |
              (norm(.trash)  | "trash\t"  + .),
              (norm(.delete) | "delete\t" + .),
              (norm(.rmdir)  | "trash\t"  + .)
        ' 2>/dev/null
        return
    fi

    if command -v python3 &>/dev/null; then
        printf '%s' "$json" | python3 -c '
import sys, json, os
try:
    data = json.load(sys.stdin)
    casks = data.get("casks", [])
    if casks:
        for art in casks[0].get("artifacts", []) or []:
            if isinstance(art, dict):
                for zap in art.get("zap", []) or []:
                    if isinstance(zap, dict):
                        for key, action in (("trash","trash"),("delete","delete"),("rmdir","trash")):
                            val = zap.get(key)
                            if isinstance(val, str):
                                paths = [val]
                            elif isinstance(val, list):
                                paths = val
                            else:
                                paths = []
                            for p in paths:
                                if isinstance(p, str):
                                    print(f"{action}\t{os.path.expanduser(p)}")
except Exception:
    pass
' 2>/dev/null
        return
    fi

    return 1
}

# ─────────────────────────────────────────────────────────────
# 유틸: 경로 스트림(stdin: "action\tpath")을 글로브 확장 + 실재검사
#   - 글로브(* ? [) 포함 경로는 compgen 으로 안전하게 확장
#   - 존재(깨진 링크 포함)하는 항목만 통과
#   출력: "action\tpath"
# ─────────────────────────────────────────────────────────────
expand_and_check() {
    local action raw g
    while IFS=$'\t' read -r action raw; do
        [[ -z "$raw" ]] && continue
        case "$raw" in
            *[\*\?\[]*)
                # 글로브 메타가 있어도 리터럴로 실존하면 그대로 통과
                # (대괄호 등이 든 실제 파일명 'App[Beta].plist' 보호)
                if [[ -e "$raw" || -L "$raw" ]]; then
                    printf '%s\t%s\n' "$action" "$raw"
                else
                    while IFS= read -r g; do
                        [[ -n "$g" && ( -e "$g" || -L "$g" ) ]] && printf '%s\t%s\n' "$action" "$g"
                    done < <(compgen -G "$raw" 2>/dev/null)
                fi
                ;;
            *)
                [[ -e "$raw" || -L "$raw" ]] && printf '%s\t%s\n' "$action" "$raw"
                ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────
# 처리: brew cask
#   - brew info JSON 1회 캡처 후 .app/zap 파싱
#   - app target 리네임/다중 .app/zap 글로브/zap delete 액션 모두 처리
#   - 반환: 0=성공/dry-run, 1=실패 (brew 또는 잔여 정리 실패)
# ─────────────────────────────────────────────────────────────
handle_cask() {
    local cask="$1"

    if ! command -v brew &>/dev/null; then
        printf '%sbrew 명령을 찾을 수 없습니다.%s\n' "$RED" "$NC" >&2
        exit 1
    fi

    # brew info JSON 한 번만 캡처
    local json
    json=$(brew info --json=v2 --cask "$cask" 2>/dev/null)

    # 1) .app 파일명(설치명 basename) 추출 + 중복 제거
    local -a app_filenames=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && app_filenames+=("$line")
    done < <(get_cask_apps "$json")
    if (( ${#app_filenames[@]} > 0 )); then
        local -a _uniq=()
        local a ex
        for a in "${app_filenames[@]}"; do
            ex=0
            for u in "${_uniq[@]+"${_uniq[@]}"}"; do [[ "$u" == "$a" ]] && { ex=1; break; }; done
            (( ex )) || _uniq+=("$a")
        done
        app_filenames=("${_uniq[@]}")
    fi

    # 2) 모든 .app 에 대해 경로/Bundle ID 탐색 + 잔여 매칭 (대표값은 첫 유효치)
    local app_name="" bundle_id="" app_path=""
    local -a matched=()
    local fn an bn ap p f
    for fn in "${app_filenames[@]+"${app_filenames[@]}"}"; do
        an="${fn%.app}"
        ap=""
        for p in "/Applications/$fn" "$HOME/Applications/$fn"; do
            [[ -d "$p" ]] && { ap="$p"; break; }
        done
        bn=""
        [[ -n "$ap" ]] && bn=$(get_bundle_id "$ap")
        [[ -z "$app_name" ]] && app_name="$an"
        [[ -z "$app_path" && -n "$ap" ]] && app_path="$ap"
        [[ -z "$bundle_id" && -n "$bn" ]] && bundle_id="$bn"
        if [[ -n "$an" || -n "$bn" ]]; then
            while IFS= read -r -d '' f; do
                [[ -n "$f" ]] && matched+=("$f")
            done < <(find_related "$an" "$bn")
        fi
    done

    # 3) zap 정보 (action 보존)
    local -a zap_trash=() zap_delete=()
    local _action _path
    while IFS=$'\t' read -r _action _path; do
        [[ -z "$_path" ]] && continue
        if [[ "$_action" == "delete" ]]; then
            zap_delete+=("$_path")
        else
            zap_trash+=("$_path")
        fi
    done < <(get_cask_zap "$json")

    # 4) 통합 → 중복 제거(path 기준, delete > trash(zap) > matched 우선) → tpaths/tactions
    #    - zap 경로만 글로브 펼침(expand_and_check)
    #    - matched(find_related 가 돌려준 실존 리터럴)는 펼침 없이 직접 합류해
    #      대괄호 등 글로브 문자/개행이 든 실제 파일명도 보존
    local -a tpaths=() tactions=()
    local _x _dup _p
    # (a) zap: delete 우선, 글로브 펼침
    while IFS=$'\t' read -r _action _path; do
        [[ -n "$_path" && "$_path" == /* ]] || continue
        _dup=0
        for _x in "${tpaths[@]+"${tpaths[@]}"}"; do [[ "$_x" == "$_path" ]] && { _dup=1; break; }; done
        (( _dup )) || { tpaths+=("$_path"); tactions+=("$_action"); }
    done < <(
        {
            for _p in "${zap_delete[@]+"${zap_delete[@]}"}"; do printf 'delete\t%s\n' "$_p"; done
            for _p in "${zap_trash[@]+"${zap_trash[@]}"}";   do printf 'trash\t%s\n'  "$_p"; done
        } | expand_and_check
    )
    # (b) matched: 실존 절대경로만, 글로브 펼침 없이 직접 합류
    for _path in "${matched[@]+"${matched[@]}"}"; do
        [[ "$_path" == /* && ( -e "$_path" || -L "$_path" ) ]] || continue
        _dup=0
        for _x in "${tpaths[@]+"${tpaths[@]}"}"; do [[ "$_x" == "$_path" ]] && { _dup=1; break; }; done
        (( _dup )) || { tpaths+=("$_path"); tactions+=("trash"); }
    done

    echo ""
    printf '%s선택한 Cask%s\n' "$BOLD" "$NC"
    printf '  이름      : %s%s%s\n' "$CYAN" "$cask" "$NC"
    [[ -n "$app_name" ]]  && printf '  앱 이름   : %s\n' "$app_name"
    [[ -n "$bundle_id" ]] && printf '  Bundle ID : %s\n' "$bundle_id"
    if (( ${#app_filenames[@]} > 1 )); then
        printf '  추가 .app : %s\n' "${app_filenames[*]:1}"
    fi
    local zc=$(( ${#zap_trash[@]} + ${#zap_delete[@]} ))
    (( zc > 0 )) && printf '  zap 항목  : %s개 %s(cask 작성자 명시)%s\n' "$zc" "$DIM" "$NC"
    echo ""

    printf '%s%s수행할 작업%s\n' "$BOLD" "$YELLOW" "$NC"
    printf '  1) %sbrew uninstall --cask %s%s\n' "$CYAN" "$cask" "$NC"
    if (( ${#tpaths[@]} > 0 )); then
        printf '  2) 잔여 파일 %s개 삭제:\n' "${#tpaths[@]}"
        local i t act size_str needs_sudo_disp
        for i in "${!tpaths[@]}"; do
            t="${tpaths[$i]}"; act="${tactions[$i]}"
            size_str=$(du_safe "$t")
            needs_sudo_disp=0
            [[ "$t" =~ ^(/Library|/Applications)(/|$) ]] && needs_sudo_disp=1
            (( needs_sudo_disp )) && [[ -O "$t" ]] && needs_sudo_disp=0
            if (( needs_sudo_disp )); then
                printf '     %s[sudo]%s %-8s %s\n' "$YELLOW" "$NC" "${size_str:-?}" "$t"
            elif [[ "$act" == "delete" ]]; then
                printf '     %s[영구]%s %-8s %s\n' "$RED" "$NC" "${size_str:-?}" "$t"
            else
                printf '            %-8s %s\n' "${size_str:-?}" "$t"
            fi
        done
    else
        printf '  %s(추가 잔여 파일 없음)%s\n' "$DIM" "$NC"
    fi
    echo ""

    if (( ! ASSUME_YES )) && (( ! DRY_RUN )); then
        local confirm
        printf '%s%s정말 삭제하시겠습니까?%s\n' "$RED" "$BOLD" "$NC"
        prompt_input "[y/N] " confirm
        if [[ ! "$confirm" =~ ^[yY]$ ]]; then
            echo "취소되었습니다."
            exit 0
        fi
    fi

    echo ""
    printf '%s진행 중...%s\n' "$BOLD" "$NC"

    # 1) brew uninstall --cask — 실패해도 잔여 정리는 계속 진행
    local brew_failed=0
    if (( DRY_RUN )); then
        printf '  %s[dry-run] brew uninstall --cask %s%s\n' "$DIM" "$cask" "$NC"
    else
        if ! brew uninstall --cask "$cask"; then
            printf '%s  ! brew uninstall --cask 실패 — 이미 제거되었거나 다른 이유일 수 있습니다.%s\n' "$YELLOW" "$NC" >&2
            printf '%s  잔여 파일 정리는 계속 진행합니다.%s\n' "$DIM" "$NC" >&2
            brew_failed=1
        fi
    fi

    # 2) 잔여 파일 정리
    local fail=0
    if (( ${#tpaths[@]} > 0 )); then
        local i t act needs_sudo
        for i in "${!tpaths[@]}"; do
            t="${tpaths[$i]}"; act="${tactions[$i]}"
            needs_sudo=0
            [[ "$t" =~ ^(/Library|/Applications)(/|$) ]] && needs_sudo=1
            (( needs_sudo )) && [[ -O "$t" ]] && needs_sudo=0
            trash_or_remove "$t" "$needs_sudo" "$act" || ((fail += 1))
        done
    fi

    echo ""
    if (( DRY_RUN )); then
        printf '%sDRY-RUN 완료.%s\n' "$YELLOW" "$NC"
        return 0
    elif (( brew_failed == 0 )) && (( fail == 0 )); then
        printf '%s%s✓ Cask '\''%s'\'' 삭제 완료%s\n' "$GREEN" "$BOLD" "$cask" "$NC"
        return 0
    elif (( brew_failed )) && (( fail == 0 )); then
        printf '%sbrew uninstall 은 실패했지만 잔여 파일 %s개는 정리되었습니다.%s\n' "$YELLOW" "${#tpaths[@]}" "$NC" >&2
        return 1
    elif (( brew_failed == 0 )) && (( fail > 0 )); then
        printf '%sbrew uninstall 은 성공, 잔여 파일 %s개 실패%s\n' "$YELLOW" "$fail" "$NC" >&2
        return 1
    else
        printf '%sbrew uninstall 실패 + 잔여 파일 %s개 실패%s\n' "$RED" "$fail" "$NC" >&2
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────
# 처리: brew formula
#   - brew uninstall <name> 만 수행 (잔여 파일은 수집하지 않음)
#   - 반환: 0=성공/dry-run, 1=실패
# ─────────────────────────────────────────────────────────────
handle_formula() {
    local formula="$1"

    if ! command -v brew &>/dev/null; then
        printf '%sbrew 명령을 찾을 수 없습니다.%s\n' "$RED" "$NC" >&2
        exit 1
    fi

    echo ""
    printf '%s선택한 Formula%s\n' "$BOLD" "$NC"
    printf '  이름      : %s%s%s\n' "$CYAN" "$formula" "$NC"
    echo ""

    # 의존성 체크 — 안내만, 실제 차단은 brew 가 함
    local users_all users_count
    users_all=$(brew uses --installed "$formula" 2>/dev/null)
    users_count=$(printf '%s' "$users_all" | grep -c .)
    if (( users_count > 0 )); then
        printf '%s이 패키지에 의존하는 다른 formula (%s개):%s\n' "$YELLOW" "$users_count" "$NC"
        printf '%s\n' "$users_all" | head -10 | awk '{print "  - " $0}'
        if (( users_count > 10 )); then
            printf '  %s... 외 %s개%s\n' "$DIM" "$(( users_count - 10 ))" "$NC"
        fi
        printf '%s(brew는 의존자가 있으면 uninstall 을 거부할 수 있습니다)%s\n' "$DIM" "$NC"
        echo ""
    fi

    printf '%s%s수행할 작업%s\n' "$BOLD" "$YELLOW" "$NC"
    printf '  %sbrew uninstall %s%s %s(이 명령만 실행하며 잔여 파일은 수집하지 않습니다)%s\n' \
        "$CYAN" "$formula" "$NC" "$DIM" "$NC"
    echo ""

    if (( ! ASSUME_YES )) && (( ! DRY_RUN )); then
        local confirm
        printf '%s%s정말 삭제하시겠습니까?%s\n' "$RED" "$BOLD" "$NC"
        prompt_input "[y/N] " confirm
        if [[ ! "$confirm" =~ ^[yY]$ ]]; then
            echo "취소되었습니다."
            exit 0
        fi
    fi

    echo ""
    if (( DRY_RUN )); then
        printf '  %s[dry-run] brew uninstall %s%s\n' "$DIM" "$formula" "$NC"
        echo ""
        printf '%sDRY-RUN 완료.%s\n' "$YELLOW" "$NC"
        return 0
    fi

    if brew uninstall "$formula"; then
        echo ""
        printf '%s%s✓ Formula '\''%s'\'' 삭제 완료%s\n' "$GREEN" "$BOLD" "$formula" "$NC"
        return 0
    else
        echo ""
        printf '%sbrew uninstall 실패 (의존성 또는 권한 문제일 수 있습니다)%s\n' "$RED" "$NC" >&2
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────
# 메인 흐름
# ─────────────────────────────────────────────────────────────
main() {
    printf '%s%s╔═══════════════════════════════════════╗%s\n' "$BOLD" "$BLUE" "$NC"
    printf '%s%s║   macOS App Cleaner — clearapp.sh    ║%s\n' "$BOLD" "$BLUE" "$NC"
    printf '%s%s╚═══════════════════════════════════════╝%s\n' "$BOLD" "$BLUE" "$NC"
    (( DRY_RUN )) && printf '%s※ DRY-RUN 모드: 실제 삭제는 일어나지 않습니다.%s\n' "$YELLOW" "$NC"
    if (( INCLUDE_BREW )) && (( ! HAS_BREW )); then
        printf '%s※ -b 옵션이 켜졌지만 brew 명령을 찾을 수 없습니다. 기본 .app 검색만 수행됩니다.%s\n' "$YELLOW" "$NC" >&2
    fi
    echo ""

    select_app
    local rc=$?
    case $rc in
        0) ;;                                   # SELECTED 채워짐
        2) echo "취소되었습니다."; exit 0 ;;     # 정상 취소
        *) exit 1 ;;                            # 오류 (메시지는 select_app 이 이미 출력)
    esac

    # "type\tidentifier" 분해
    local type identifier
    type="${SELECTED%%$'\t'*}"
    identifier="${SELECTED#*$'\t'}"

    # case 가 main 의 마지막 명령이므로 handle_* 의 반환값이 스크립트 종료코드로 전파된다.
    case "$type" in
        app)     handle_app "$identifier" ;;
        cask)    handle_cask "$identifier" ;;
        formula) handle_formula "$identifier" ;;
        *)       printf '%s알 수 없는 type: %s%s\n' "$RED" "$type" "$NC" >&2; exit 1 ;;
    esac
}

# 직접 실행될 때만 main 호출 (source 시에는 함수만 로드되어 단위 테스트가 가능)
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
