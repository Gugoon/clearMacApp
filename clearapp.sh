#!/bin/bash
#
# clearapp.sh - macOS 설치된 앱을 깔끔하게 삭제하는 스크립트
#
# 사용법:
#   ./clearapp.sh              # 대화형 모드
#   ./clearapp.sh -y           # 확인 없이 삭제 (위험!)
#   ./clearapp.sh -n           # dry-run (실제로 삭제하지 않음)
#   ./clearapp.sh -h           # 도움말
#

set -uo pipefail

# ─────────────────────────────────────────────────────────────
# 색상 정의
# ─────────────────────────────────────────────────────────────
readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly YELLOW=$'\033[1;33m'
readonly BLUE=$'\033[0;34m'
readonly CYAN=$'\033[0;36m'
readonly BOLD=$'\033[1m'
readonly DIM=$'\033[2m'
readonly NC=$'\033[0m'

# ─────────────────────────────────────────────────────────────
# 옵션 파싱
# ─────────────────────────────────────────────────────────────
ASSUME_YES=0
DRY_RUN=0
INCLUDE_ALL=0

usage() {
    cat <<EOF
${BOLD}clearapp.sh${NC} - macOS 앱 깔끔히 삭제

${BOLD}사용법:${NC}
  $0 [옵션]

${BOLD}옵션:${NC}
  -a, --all       모든 위치의 앱을 Spotlight로 검색 (시스템/빌드산출물 제외)
  -y, --yes       삭제 전 확인 생략 (주의!)
  -n, --dry-run   실제 삭제 없이 대상 파일만 출력
  -h, --help      이 도움말 표시

${BOLD}앱 탐색 위치:${NC}
  기본:
    /Applications (하위 폴더 포함)
    ~/Applications
    /opt/homebrew/Caskroom, /usr/local/Caskroom (Homebrew Cask)
  --all 사용 시:
    위 + Spotlight가 인식한 모든 .app
    (단 /System, ~/Library/Developer/DerivedData, *.app/Contents/* 등은 자동 제외)

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
        -a|--all)     INCLUDE_ALL=1; shift ;;
        -y|--yes)     ASSUME_YES=1;  shift ;;
        -n|--dry-run) DRY_RUN=1;     shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            echo "알 수 없는 옵션: $1"; usage; exit 1 ;;
    esac
done

# ─────────────────────────────────────────────────────────────
# 환경 확인
# ─────────────────────────────────────────────────────────────
if [[ "$(uname)" != "Darwin" ]]; then
    echo -e "${RED}이 스크립트는 macOS 전용입니다.${NC}" >&2
    exit 1
fi

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
# 유틸: 사용자 입력 받기
#   - prompt 는 stderr 로 출력해서 stdout 캡쳐(`$()`)에 섞이지 않게 함
#   - stdin 에서 읽으므로 터미널/파이프/redirect 모두 동일하게 동작
# ─────────────────────────────────────────────────────────────
prompt_input() {
    local prompt="$1"
    local __varname="$2"
    printf '%s' "$prompt" >&2
    IFS= read -r "$__varname" || return 1
}

# ─────────────────────────────────────────────────────────────
# 유틸: 앱 목록 가져오기
#   기본: /Applications, ~/Applications, Homebrew Cask
#   --all: Spotlight 인덱스 전체 (노이즈 필터링)
# ─────────────────────────────────────────────────────────────
list_apps() {
    local include_all="${1:-0}"

    # 기본 검색 루트
    local -a roots=(
        "/Applications"
        "$HOME/Applications"
        "/opt/homebrew/Caskroom"
        "/usr/local/Caskroom"
    )

    {
        local root
        for root in "${roots[@]}"; do
            [[ -d "$root" ]] || continue
            # 서브디렉토리 포함 (Setapp, Utilities, Cask 버전 폴더 등)
            # -L: symlink 따라감, -type d: 실제 디렉토리(번들)만 — broken symlink 자동 제외
            # -not -path: .app 번들 내부의 보조 앱 제외
            find -L "$root" -maxdepth 4 -name "*.app" -type d -not -path "*/Contents/*" 2>/dev/null
        done

        # --all 모드: Spotlight 인덱스 추가
        if (( include_all )) && command -v mdfind &>/dev/null; then
            mdfind "kMDItemContentType == 'com.apple.application-bundle'" 2>/dev/null \
                | awk '
                    /\/Contents\// { next }                       # 앱 번들 내부
                    /^\/System\// { next }                        # SIP 시스템 앱
                    /^\/Library\/Apple\// { next }                # Apple 관리 시스템 컴포넌트
                    /^\/Library\/Image Capture\/Support\// { next } # Image Capture 보조
                    /\/DerivedData\// { next }                    # Xcode 빌드 산출물
                    /\/build\/ios\// { next }                     # Flutter/iOS 빌드
                    /\/build\/macos\// { next }                   # Flutter/macOS 빌드
                    /\/Build\/Products\// { next }                # Xcode workspace 빌드
                    /\/Library\/Caches\// { next }
                    /\/Library\/Application Support\// { next }
                    /\/Library\/Application Scripts\// { next }
                    /\/Library\/Developer\// { next }
                    /\/\.Trash\// { next }                        # 휴지통
                    /-iphoneos\// { next }                        # 시뮬레이터/디바이스 빌드
                    /-iphonesimulator\// { next }
                    { print }
                  '
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
# ─────────────────────────────────────────────────────────────
trash_or_remove() {
    local target="$1"
    local needs_sudo="$2"  # 0 또는 1

    # 위험 경로 가드 — trailing slash 정규화 후 비교
    local normalized="${target%/}"
    local _forbidden
    for _forbidden in \
        "" "/" \
        "/Applications" "/Library" "/System" "/Users" \
        "/private" "/usr" "/bin" "/sbin" "/etc" "/var" "/opt" "/tmp" \
        "$HOME" \
        "$HOME/Library" "$HOME/Documents" "$HOME/Desktop" "$HOME/Downloads" \
        "$HOME/Movies" "$HOME/Music" "$HOME/Pictures" "$HOME/Public"
    do
        if [[ "$normalized" == "${_forbidden%/}" ]]; then
            echo -e "  ${RED}✗${NC} 위험 경로 거부: $target" >&2
            return 1
        fi
    done

    if (( DRY_RUN )); then
        echo -e "  ${DIM}[dry-run] 삭제 예정: $target${NC}"
        return 0
    fi

    # 사용자 영역은 osascript 로 휴지통 이동 (argv 전달 — path injection 방지)
    if (( needs_sudo == 0 )) && command -v osascript &>/dev/null; then
        if osascript - "$target" <<'APPLESCRIPT' &>/dev/null
on run argv
    set p to item 1 of argv
    tell application "Finder" to delete (POSIX file p as alias)
end run
APPLESCRIPT
        then
            echo -e "  ${GREEN}✓${NC} 휴지통으로 이동: $target"
            return 0
        fi
    fi

    # 시스템 영역이거나 osascript 실패 시 직접 삭제 (eval 없이)
    local rc=0
    if (( needs_sudo )); then
        sudo rm -rf -- "$target" || rc=$?
    else
        rm -rf -- "$target" || rc=$?
    fi

    if (( rc == 0 )); then
        echo -e "  ${GREEN}✓${NC} 삭제됨: $target"
    else
        echo -e "  ${RED}✗${NC} 실패: $target"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────
# 관련 파일 찾기 (Bundle ID + 앱 이름 기준)
# ─────────────────────────────────────────────────────────────
find_related() {
    local app_name="$1"
    local bundle_id="$2"
    local -a all_locations=("${USER_LOCATIONS[@]}" "${SYSTEM_LOCATIONS[@]}")

    local -a results=()
    local loc

    for loc in "${all_locations[@]}"; do
        [[ -d "$loc" ]] || continue

        # Bundle ID 기준 매칭 (정확/접두 매칭만 → 오탐 줄임)
        if [[ -n "$bundle_id" ]]; then
            while IFS= read -r -d '' f; do
                results+=("$f")
            done < <(find "$loc" -maxdepth 1 \
                \( -name "${bundle_id}" \
                -o -name "${bundle_id}.*" \
                -o -name "${bundle_id}.savedState" \
                -o -name "${bundle_id}.binarycookies" \) \
                -print0 2>/dev/null)
        fi

        # 앱 이름 기준 매칭 (정확 일치만)
        while IFS= read -r -d '' f; do
            results+=("$f")
        done < <(find "$loc" -maxdepth 1 -iname "${app_name}" -print0 2>/dev/null)
    done

    # 중복 제거 후 출력
    if (( ${#results[@]} > 0 )); then
        printf '%s\n' "${results[@]}" | sort -u
    fi
}

# ─────────────────────────────────────────────────────────────
# 앱 선택 UI
# ─────────────────────────────────────────────────────────────
select_app() {
    local -a apps=()
    while IFS= read -r line; do
        apps+=("$line")
    done < <(list_apps "$INCLUDE_ALL")

    if (( ${#apps[@]} == 0 )); then
        echo -e "${RED}설치된 앱을 찾을 수 없습니다.${NC}" >&2
        exit 1
    fi

    # fzf 가 있으면 사용 — 탭 구분자로 이름과 경로 분리
    if command -v fzf &>/dev/null; then
        local choice
        choice=$(printf '%s\n' "${apps[@]}" \
            | awk -F/ -v OFS='\t' '{name=$NF; sub(/\.app$/,"",name); print name, $0}' \
            | fzf --prompt="삭제할 앱 검색: " \
                  --height=60% --reverse --border \
                  --header="↑↓ 이동 / Enter 선택 / Esc 취소" \
                  --delimiter=$'\t' --with-nth=1)
        # 첫 탭 이후의 경로 추출
        [[ -n "$choice" ]] && printf '%s\n' "${choice#*$'\t'}"
        return
    fi

    # fzf 없으면 번호 메뉴 — 동명이앱이 있으면 경로도 표시
    echo -e "${BOLD}${BLUE}설치된 앱 목록 (${#apps[@]}개)${NC}" >&2
    if (( INCLUDE_ALL )); then
        echo -e "${DIM}(--all 모드: Spotlight 전체 인덱스 + 노이즈 필터)${NC}" >&2
    else
        echo -e "${DIM}(/Applications, ~/Applications, Homebrew Cask · 더 보려면 -a 옵션)${NC}" >&2
    fi
    echo "" >&2

    # AWK로 동명이앱 검출 후 메뉴 출력 (bash 3.2 호환)
    printf '%s\n' "${apps[@]}" \
        | awk -v cyan="$CYAN" -v dim="$DIM" -v nc="$NC" '
            {
                paths[NR] = $0
                n = $0
                sub(/.*\//, "", n)
                sub(/\.app$/, "", n)
                names[NR] = n
                count[n]++
            }
            END {
                for (i=1; i<=NR; i++) {
                    n = names[i]
                    p = paths[i]
                    d = p
                    sub(/\/[^\/]*$/, "", d)
                    if (count[n] > 1)
                        printf "  %s%3d%s) %s %s(%s)%s\n", cyan, i, nc, n, dim, d, nc
                    else
                        printf "  %s%3d%s) %s\n", cyan, i, nc, n
                }
            }
          ' >&2
    echo "" >&2

    local choice
    prompt_input "삭제할 앱 번호를 입력하세요 (q: 종료): " choice

    if [[ "$choice" == "q" || -z "$choice" ]]; then
        echo "취소되었습니다." >&2
        exit 0
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#apps[@]} )); then
        echo -e "${RED}잘못된 선택입니다.${NC}" >&2
        exit 1
    fi

    echo "${apps[$((choice-1))]}"
}

# ─────────────────────────────────────────────────────────────
# 메인 흐름
# ─────────────────────────────────────────────────────────────
main() {
    echo -e "${BOLD}${BLUE}╔═══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║   macOS App Cleaner — clearapp.sh    ║${NC}"
    echo -e "${BOLD}${BLUE}╚═══════════════════════════════════════╝${NC}"
    (( DRY_RUN )) && echo -e "${YELLOW}※ DRY-RUN 모드: 실제 삭제는 일어나지 않습니다.${NC}"
    echo ""

    local app_path
    app_path=$(select_app)

    if [[ -z "$app_path" ]] || [[ ! -e "$app_path" ]]; then
        echo -e "${RED}유효한 앱을 선택하지 않았습니다.${NC}" >&2
        exit 1
    fi

    local app_name bundle_id
    app_name=$(basename "$app_path" .app)
    bundle_id=$(get_bundle_id "$app_path")

    echo ""
    echo -e "${BOLD}선택한 앱${NC}"
    echo -e "  이름      : ${CYAN}$app_name${NC}"
    echo -e "  경로      : $app_path"
    echo -e "  Bundle ID : ${bundle_id:-${DIM}(읽을 수 없음)${NC}}"
    echo ""

    # 관련 파일 수집
    echo -e "${BOLD}관련 파일 검색 중...${NC}"
    local -a targets=("$app_path")
    while IFS= read -r f; do
        [[ -n "$f" ]] && targets+=("$f")
    done < <(find_related "$app_name" "$bundle_id")

    # 중복 제거
    local -a unique_targets=()
    local seen
    while IFS= read -r seen; do
        unique_targets+=("$seen")
    done < <(printf '%s\n' "${targets[@]}" | awk '!x[$0]++')

    echo ""
    echo -e "${BOLD}${YELLOW}삭제 대상 (${#unique_targets[@]}개)${NC}"
    local total_size=0
    for t in "${unique_targets[@]}"; do
        local size_str
        size_str=$(du -sh "$t" 2>/dev/null | awk '{print $1}')
        local owner
        owner=$([[ "$t" =~ ^(/Library|/Applications)(/|$) ]] && echo "${YELLOW}[sudo]${NC} " || echo "")
        printf "  ${owner}%-8s %s\n" "${size_str:-?}" "$t"
    done
    echo ""

    # 확인
    if (( ! ASSUME_YES )) && (( ! DRY_RUN )); then
        local confirm
        echo -e "${RED}${BOLD}정말 삭제하시겠습니까?${NC}"
        prompt_input "[y/N] " confirm
        if [[ ! "$confirm" =~ ^[yY]$ ]]; then
            echo "취소되었습니다."
            exit 0
        fi
    fi

    # 실제 삭제
    echo ""
    echo -e "${BOLD}삭제 진행 중...${NC}"
    local fail=0
    for t in "${unique_targets[@]}"; do
        local needs_sudo=0
        [[ "$t" =~ ^(/Library|/Applications)(/|$) ]] && needs_sudo=1
        # /Applications 이지만 사용자가 owner인 경우는 sudo 불필요할 수 있음
        if (( needs_sudo )) && [[ -O "$t" ]]; then
            needs_sudo=0
        fi
        trash_or_remove "$t" "$needs_sudo" || ((fail++))
    done

    echo ""
    if (( DRY_RUN )); then
        echo -e "${YELLOW}DRY-RUN 완료. 실제 삭제는 -n 옵션을 빼고 다시 실행하세요.${NC}"
    elif (( fail == 0 )); then
        echo -e "${GREEN}${BOLD}✓ ${app_name} 삭제 완료${NC}"
    else
        echo -e "${YELLOW}일부 항목 삭제 실패: ${fail}개 (권한 문제일 수 있습니다)${NC}"
    fi
}

main "$@"
