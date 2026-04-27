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
#   결과는 "<type>\t<identifier>" 형태로 출력 (type: app|cask|formula)
#   기본: /Applications, ~/Applications, Homebrew Cask 디렉토리의 .app
#   --all: Spotlight 인덱스 전체
#   --brew: brew list --cask, --formula 추가 (Caskroom 직접 검색은 비활성화)
# ─────────────────────────────────────────────────────────────
list_apps() {
    local include_all="${1:-0}"
    local include_brew="${2:-0}"

    # 기본 .app 검색 루트
    local -a roots=(
        "/Applications"
        "$HOME/Applications"
    )
    # brew 모드가 아닐 때만 Caskroom 도 .app 검색에 포함
    if (( ! include_brew )); then
        roots+=("/opt/homebrew/Caskroom" "/usr/local/Caskroom")
    fi

    {
        local root
        for root in "${roots[@]}"; do
            [[ -d "$root" ]] || continue
            # -L symlink 따라감, -type d 실제 번들만(broken 자동 제외)
            find -L "$root" -maxdepth 4 -name "*.app" -type d -not -path "*/Contents/*" 2>/dev/null \
                | awk -v OFS='\t' '{print "app", $0}'
        done

        # --all: Spotlight 인덱스
        if (( include_all )) && command -v mdfind &>/dev/null; then
            mdfind "kMDItemContentType == 'com.apple.application-bundle'" 2>/dev/null \
                | awk -v OFS='\t' '
                    /\/Contents\// { next }
                    /^\/System\// { next }
                    /^\/Library\/Apple\// { next }
                    /^\/Library\/Image Capture\/Support\// { next }
                    /\/DerivedData\// { next }
                    /\/build\/ios\// { next }
                    /\/build\/macos\// { next }
                    /\/Build\/Products\// { next }
                    /\/Library\/Caches\// { next }
                    /\/Library\/Application Support\// { next }
                    /\/Library\/Application Scripts\// { next }
                    /\/Library\/Developer\// { next }
                    /\/\.Trash\// { next }
                    /-iphoneos\// { next }
                    /-iphonesimulator\// { next }
                    { print "app", $0 }
                  '
        fi

        # --brew: brew list 결과
        if (( include_brew )) && command -v brew &>/dev/null; then
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
    done < <(list_apps "$INCLUDE_ALL" "$INCLUDE_BREW")

    if (( ${#apps[@]} == 0 )); then
        echo -e "${RED}항목을 찾을 수 없습니다.${NC}" >&2
        exit 1
    fi

    # fzf 가 있으면 사용 — 표시는 "[type] name", 마지막 필드 두 개(type, identifier)는 hidden
    if command -v fzf &>/dev/null; then
        local choice
        choice=$(printf '%s\n' "${apps[@]}" \
            | awk -F'\t' -v OFS='\t' '
                {
                    type=$1; id=$2
                    if (type == "app") {
                        name = id; sub(/.*\//, "", name); sub(/\.app$/, "", name)
                    } else {
                        name = id
                    }
                    display = sprintf("[%-7s] %s", type, name)
                    print display, type, id
                }' \
            | fzf --prompt="삭제할 항목 검색: " \
                  --height=60% --reverse --border \
                  --header="↑↓ 이동 / Enter 선택 / Esc 취소" \
                  --delimiter=$'\t' --with-nth=1)
        # 선택된 라인의 마지막 두 필드 = "type\tidentifier"
        if [[ -n "$choice" ]]; then
            local _type _id
            _type=$(printf '%s' "$choice" | awk -F'\t' '{print $2}')
            _id=$(printf '%s' "$choice"   | awk -F'\t' '{print $3}')
            printf '%s\t%s\n' "$_type" "$_id"
        fi
        return
    fi

    # fzf 없으면 번호 메뉴
    echo -e "${BOLD}${BLUE}선택 가능한 항목 (${#apps[@]}개)${NC}" >&2
    local mode_hint="/Applications, ~/Applications"
    (( INCLUDE_BREW )) || mode_hint+=", Homebrew Cask 디렉토리"
    (( INCLUDE_ALL ))  && mode_hint+=" + Spotlight 전체"
    (( INCLUDE_BREW )) && mode_hint+=" + brew cask/formula"
    echo -e "${DIM}(${mode_hint})${NC}" >&2
    if ! (( INCLUDE_ALL )) || ! (( INCLUDE_BREW )); then
        local hints=""
        (( INCLUDE_ALL ))  || hints+=" -a"
        (( INCLUDE_BREW )) || hints+=" -b"
        [[ -n "$hints" ]] && echo -e "${DIM}더 보려면:$hints${NC}" >&2
    fi
    echo "" >&2

    # 메뉴 출력 — AWK 로 type 인식 + 동명이앱(.app) 검출
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

    if [[ "$choice" == "q" || -z "$choice" ]]; then
        echo "취소되었습니다." >&2
        exit 0
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#apps[@]} )); then
        echo -e "${RED}잘못된 선택입니다.${NC}" >&2
        exit 1
    fi

    # apps[i] 는 이미 "type\tidentifier" 형식
    printf '%s\n' "${apps[$((choice-1))]}"
}

# ─────────────────────────────────────────────────────────────
# 처리: .app 항목
# ─────────────────────────────────────────────────────────────
handle_app() {
    local app_path="$1"

    if [[ -z "$app_path" ]] || [[ ! -e "$app_path" ]]; then
        echo -e "${RED}유효한 앱이 아닙니다: $app_path${NC}" >&2
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
    local t
    for t in "${unique_targets[@]}"; do
        local size_str owner
        size_str=$(du -sh "$t" 2>/dev/null | awk '{print $1}')
        owner=$([[ "$t" =~ ^(/Library|/Applications)(/|$) ]] && echo "${YELLOW}[sudo]${NC} " || echo "")
        printf "  ${owner}%-8s %s\n" "${size_str:-?}" "$t"
    done
    echo ""

    if (( ! ASSUME_YES )) && (( ! DRY_RUN )); then
        local confirm
        echo -e "${RED}${BOLD}정말 삭제하시겠습니까?${NC}"
        prompt_input "[y/N] " confirm
        if [[ ! "$confirm" =~ ^[yY]$ ]]; then
            echo "취소되었습니다."
            exit 0
        fi
    fi

    echo ""
    echo -e "${BOLD}삭제 진행 중...${NC}"
    local fail=0
    for t in "${unique_targets[@]}"; do
        local needs_sudo=0
        [[ "$t" =~ ^(/Library|/Applications)(/|$) ]] && needs_sudo=1
        (( needs_sudo )) && [[ -O "$t" ]] && needs_sudo=0
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

# ─────────────────────────────────────────────────────────────
# 처리: brew cask
#   - brew uninstall --cask 로 본체+brew 메타데이터 정리
#   - 추가로 ~/Library 잔여를 (가능하면) 함께 정리
# ─────────────────────────────────────────────────────────────
handle_cask() {
    local cask="$1"

    if ! command -v brew &>/dev/null; then
        echo -e "${RED}brew 명령을 찾을 수 없습니다.${NC}" >&2
        exit 1
    fi

    # brew info 출력에서 .app 이름 추출 (가능한 경우)
    local app_name="" bundle_id="" app_path=""
    app_name=$(brew info --cask "$cask" 2>/dev/null \
        | grep -oE '[A-Za-z0-9._ -]+\.app' | head -1 \
        | sed 's/\.app$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if [[ -n "$app_name" ]]; then
        local p
        for p in "/Applications/${app_name}.app" "$HOME/Applications/${app_name}.app"; do
            [[ -d "$p" ]] && app_path="$p" && break
        done
        [[ -n "$app_path" ]] && bundle_id=$(get_bundle_id "$app_path")
    fi

    echo ""
    echo -e "${BOLD}선택한 Cask${NC}"
    echo -e "  이름      : ${CYAN}$cask${NC}"
    [[ -n "$app_name" ]]  && echo -e "  앱 이름   : $app_name"
    [[ -n "$bundle_id" ]] && echo -e "  Bundle ID : $bundle_id"
    echo ""

    # ~/Library, /Library 잔여 검색 (앱 이름/Bundle ID 둘 다 있을 때만 의미 있음)
    local -a targets=()
    if [[ -n "$app_name" ]] || [[ -n "$bundle_id" ]]; then
        echo -e "${BOLD}관련 파일 검색 중...${NC}"
        while IFS= read -r f; do
            [[ -n "$f" ]] && targets+=("$f")
        done < <(find_related "${app_name:-}" "${bundle_id:-}")
    fi

    echo ""
    echo -e "${BOLD}${YELLOW}수행할 작업${NC}"
    echo -e "  1) ${CYAN}brew uninstall --cask $cask${NC}"
    if (( ${#targets[@]} > 0 )); then
        echo -e "  2) 잔여 파일 ${#targets[@]}개 삭제:"
        local t
        for t in "${targets[@]}"; do
            local size_str owner
            size_str=$(du -sh "$t" 2>/dev/null | awk '{print $1}')
            owner=$([[ "$t" =~ ^/Library(/|$) ]] && echo "${YELLOW}[sudo]${NC} " || echo "")
            printf "     ${owner}%-8s %s\n" "${size_str:-?}" "$t"
        done
    else
        echo -e "  ${DIM}(추가 잔여 파일 없음 또는 자동 매칭 불가)${NC}"
    fi
    echo ""

    if (( ! ASSUME_YES )) && (( ! DRY_RUN )); then
        local confirm
        echo -e "${RED}${BOLD}정말 삭제하시겠습니까?${NC}"
        prompt_input "[y/N] " confirm
        if [[ ! "$confirm" =~ ^[yY]$ ]]; then
            echo "취소되었습니다."
            exit 0
        fi
    fi

    echo ""
    echo -e "${BOLD}진행 중...${NC}"

    # 1) brew uninstall --cask
    if (( DRY_RUN )); then
        echo -e "  ${DIM}[dry-run] brew uninstall --cask $cask${NC}"
    else
        if ! brew uninstall --cask "$cask"; then
            echo -e "${RED}brew uninstall --cask 실패${NC}"
            return 1
        fi
    fi

    # 2) 잔여 파일 정리
    local fail=0
    if (( ${#targets[@]} > 0 )); then
        local t
        for t in "${targets[@]}"; do
            local needs_sudo=0
            [[ "$t" =~ ^/Library(/|$) ]] && needs_sudo=1
            (( needs_sudo )) && [[ -O "$t" ]] && needs_sudo=0
            trash_or_remove "$t" "$needs_sudo" || ((fail++))
        done
    fi

    echo ""
    if (( DRY_RUN )); then
        echo -e "${YELLOW}DRY-RUN 완료.${NC}"
    elif (( fail == 0 )); then
        echo -e "${GREEN}${BOLD}✓ Cask '${cask}' 삭제 완료${NC}"
    else
        echo -e "${YELLOW}brew uninstall 은 성공, 잔여 파일 ${fail}개 실패${NC}"
    fi
}

# ─────────────────────────────────────────────────────────────
# 처리: brew formula
#   - brew uninstall <name> 만 사용
#   - ~/Library 잔여는 검색하지 않음 (formula는 거의 사용 안 함)
# ─────────────────────────────────────────────────────────────
handle_formula() {
    local formula="$1"

    if ! command -v brew &>/dev/null; then
        echo -e "${RED}brew 명령을 찾을 수 없습니다.${NC}" >&2
        exit 1
    fi

    echo ""
    echo -e "${BOLD}선택한 Formula${NC}"
    echo -e "  이름      : ${CYAN}$formula${NC}"
    echo ""

    # 의존성 체크 — 안내만, 실제 차단은 brew 가 함
    local users
    users=$(brew uses --installed "$formula" 2>/dev/null | head -10)
    if [[ -n "$users" ]]; then
        echo -e "${YELLOW}이 패키지에 의존하는 다른 formula:${NC}"
        printf '%s\n' "$users" | awk '{print "  - " $0}'
        echo -e "${DIM}(brew는 의존자가 있으면 uninstall 을 거부할 수 있습니다)${NC}"
        echo ""
    fi

    echo -e "${BOLD}${YELLOW}수행할 작업${NC}"
    echo -e "  ${CYAN}brew uninstall $formula${NC}"
    echo ""

    if (( ! ASSUME_YES )) && (( ! DRY_RUN )); then
        local confirm
        echo -e "${RED}${BOLD}정말 삭제하시겠습니까?${NC}"
        prompt_input "[y/N] " confirm
        if [[ ! "$confirm" =~ ^[yY]$ ]]; then
            echo "취소되었습니다."
            exit 0
        fi
    fi

    echo ""
    if (( DRY_RUN )); then
        echo -e "  ${DIM}[dry-run] brew uninstall $formula${NC}"
        echo ""
        echo -e "${YELLOW}DRY-RUN 완료.${NC}"
        return 0
    fi

    if brew uninstall "$formula"; then
        echo ""
        echo -e "${GREEN}${BOLD}✓ Formula '${formula}' 삭제 완료${NC}"
    else
        echo ""
        echo -e "${RED}brew uninstall 실패 (의존성 또는 권한 문제일 수 있습니다)${NC}"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────
# 메인 흐름
# ─────────────────────────────────────────────────────────────
main() {
    echo -e "${BOLD}${BLUE}╔═══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║   macOS App Cleaner — clearapp.sh    ║${NC}"
    echo -e "${BOLD}${BLUE}╚═══════════════════════════════════════╝${NC}"
    (( DRY_RUN )) && echo -e "${YELLOW}※ DRY-RUN 모드: 실제 삭제는 일어나지 않습니다.${NC}"
    if (( INCLUDE_BREW )) && ! command -v brew &>/dev/null; then
        echo -e "${YELLOW}※ -b 옵션이 켜졌지만 brew 명령을 찾을 수 없습니다. brew 항목은 표시되지 않습니다.${NC}"
    fi
    echo ""

    local selected
    selected=$(select_app)

    if [[ -z "$selected" ]]; then
        echo -e "${RED}유효한 항목을 선택하지 않았습니다.${NC}" >&2
        exit 1
    fi

    # "type\tidentifier" 분해
    local type identifier
    type="${selected%%$'\t'*}"
    identifier="${selected#*$'\t'}"

    case "$type" in
        app)     handle_app "$identifier" ;;
        cask)    handle_cask "$identifier" ;;
        formula) handle_formula "$identifier" ;;
        *)       echo -e "${RED}알 수 없는 type: $type${NC}" >&2; exit 1 ;;
    esac
}

main "$@"
