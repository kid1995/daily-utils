#!/usr/bin/env bash
#
# git-squash.sh - Gộp (squash) commits trên branch hiện tại
#
# Cách dùng:
#   1) Gộp TẤT CẢ commits trên branch (so với main/master):
#      ./git-squash.sh
#
#   2) Gộp từ commit A đến commit B (giữ trạng thái code của B):
#      ./git-squash.sh <from_commit> <to_commit>
#
#   3) Chỉ định base branch (mặc định: tự detect main/master/develop):
#      ./git-squash.sh --base origin/develop
#
# Lưu ý:
#   - Script sẽ giữ nguyên trạng thái code của commit CUỐI CÙNG
#   - Sau khi squash, bạn cần `git push --force-with-lease` để update remote
#   - Script tạo backup branch trước khi thực hiện
#
set -euo pipefail

# ──────────────────────────── Colors ────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ──────────────────────────── Pre-checks ────────────────────────────
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    err "Không phải git repository!"
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    err "Working directory không sạch. Hãy commit hoặc stash changes trước."
    exit 1
fi

CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null)
if [ -z "$CURRENT_BRANCH" ]; then
    err "Đang ở trạng thái detached HEAD. Hãy checkout một branch."
    exit 1
fi

# ──────────────────────────── Parse arguments ────────────────────────────
BASE_BRANCH=""
FROM_COMMIT=""
TO_COMMIT=""
SQUASH_MESSAGE=""

print_usage() {
    echo "Cách dùng:"
    echo "  $0                              # Squash tất cả commits trên branch"
    echo "  $0 <from_commit> <to_commit>    # Squash từ commit A đến commit B"
    echo "  $0 --base <branch>              # Chỉ định base branch"
    echo "  $0 -m \"commit message\"          # Tuỳ chỉnh commit message"
    echo ""
    echo "Options:"
    echo "  --base <branch>    Base branch (default: auto-detect main/master/develop)"
    echo "  -m <message>       Commit message cho squashed commit"
    echo "  -h, --help         Hiển thị help"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base)
            BASE_BRANCH="$2"
            shift 2
            ;;
        -m)
            SQUASH_MESSAGE="$2"
            shift 2
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            if [ -z "$FROM_COMMIT" ]; then
                FROM_COMMIT="$1"
            elif [ -z "$TO_COMMIT" ]; then
                TO_COMMIT="$1"
            else
                err "Quá nhiều arguments. Dùng -h để xem help."
                exit 1
            fi
            shift
            ;;
    esac
done

# ──────────────────────────── Detect base branch ────────────────────────────
detect_base_branch() {
    # Thử tìm base branch từ remote
    for candidate in main master develop; do
        if git rev-parse --verify "origin/$candidate" &>/dev/null; then
            echo "origin/$candidate"
            return
        fi
        if git rev-parse --verify "$candidate" &>/dev/null; then
            echo "$candidate"
            return
        fi
    done
    err "Không tìm được base branch (main/master/develop). Dùng --base để chỉ định."
    exit 1
}

# ──────────────────────────── Mode 1: Squash range (from..to) ────────────────────────────
squash_range() {
    local from="$1"
    local to="$2"

    # Validate commits
    if ! git rev-parse --verify "$from" &>/dev/null; then
        err "Commit không tồn tại: $from"
        exit 1
    fi
    if ! git rev-parse --verify "$to" &>/dev/null; then
        err "Commit không tồn tại: $to"
        exit 1
    fi

    local from_short
    local to_short
    from_short=$(git rev-parse --short "$from")
    to_short=$(git rev-parse --short "$to")

    # Đếm commits trong range
    local count
    count=$(git rev-list --count "$from".."$to")
    if [ "$count" -eq 0 ]; then
        err "Không có commits nào giữa $from_short và $to_short"
        exit 1
    fi

    info "Gộp $count commits: $from_short → $to_short"
    info "Giữ trạng thái code của commit: $to_short"

    # Hiển thị danh sách commits sẽ bị squash
    echo ""
    info "Các commits sẽ được gộp:"
    git log --oneline "$from".."$to" | while read -r line; do
        echo "  $line"
    done
    echo ""

    # Xác nhận
    read -r -p "$(echo -e "${YELLOW}Bạn có chắc chắn muốn tiếp tục? (y/N): ${NC}")" confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        info "Đã huỷ."
        exit 0
    fi

    # Tạo backup
    local backup_branch="backup/${CURRENT_BRANCH}_$(date +%Y%m%d_%H%M%S)"
    git branch "$backup_branch"
    ok "Đã tạo backup branch: $backup_branch"

    # Lấy commit message
    local msg
    if [ -n "$SQUASH_MESSAGE" ]; then
        msg="$SQUASH_MESSAGE"
    else
        msg=$(git log -1 --format="%s" "$to")
        read -r -p "$(echo -e "${CYAN}Commit message [${msg}]: ${NC}")" custom_msg
        if [ -n "$custom_msg" ]; then
            msg="$custom_msg"
        fi
    fi

    # Thực hiện squash bằng soft reset
    # 1. Lưu tree (trạng thái file) của commit cuối (to)
    local target_tree
    target_tree=$(git rev-parse "$to^{tree}")

    # 2. Lưu vị trí HEAD hiện tại
    local original_head
    original_head=$(git rev-parse HEAD)

    # 3. Reset về commit trước "from" (parent của from, tức commit đầu tiên trong range)
    #    Giữ nguyên working directory ở trạng thái "to"
    git reset --soft "$from"

    # 4. Tạo commit mới với tree của "to" commit
    #    Dùng git commit-tree để tạo commit chính xác với tree mong muốn
    local new_commit
    new_commit=$(git commit-tree "$target_tree" -p "$(git rev-parse HEAD)" -m "$msg")

    # 5. Update HEAD tới commit mới
    git reset --hard "$new_commit"

    # 6. Nếu còn commits sau "to" trong branch gốc, cherry-pick chúng lại
    local remaining
    remaining=$(git rev-list --reverse "$to".."$original_head" 2>/dev/null || true)
    if [ -n "$remaining" ]; then
        info "Cherry-pick lại các commits sau range..."
        for commit in $remaining; do
            git cherry-pick "$commit" || {
                err "Cherry-pick thất bại tại $commit. Hãy resolve conflicts rồi chạy 'git cherry-pick --continue'"
                exit 1
            }
        done
    fi

    ok "Squash thành công!"
    info "Commit mới: $(git log -1 --oneline)"
    warn "Dùng 'git push --force-with-lease' để update remote"
    info "Backup branch: $backup_branch (xoá bằng: git branch -D $backup_branch)"
}

# ──────────────────────────── Mode 2: Squash all branch commits ────────────────────────────
squash_all() {
    if [ -z "$BASE_BRANCH" ]; then
        BASE_BRANCH=$(detect_base_branch)
    fi

    info "Branch hiện tại: $CURRENT_BRANCH"
    info "Base branch:     $BASE_BRANCH"

    # Tìm merge-base (commit đầu tiên mà branch tách ra)
    local merge_base
    merge_base=$(git merge-base "$BASE_BRANCH" HEAD)
    local merge_base_short
    merge_base_short=$(git rev-parse --short "$merge_base")

    # Đếm commits
    local count
    count=$(git rev-list --count "$merge_base"..HEAD)

    if [ "$count" -eq 0 ]; then
        info "Không có commits nào trên branch $CURRENT_BRANCH so với $BASE_BRANCH"
        exit 0
    fi

    if [ "$count" -eq 1 ]; then
        info "Chỉ có 1 commit trên branch. Không cần squash."
        exit 0
    fi

    info "Tìm thấy $count commits kể từ $merge_base_short"

    # Hiển thị danh sách commits
    echo ""
    info "Các commits trên branch $CURRENT_BRANCH:"
    git log --oneline "$merge_base"..HEAD | while read -r line; do
        echo "  $line"
    done
    echo ""

    # Xác nhận
    read -r -p "$(echo -e "${YELLOW}Gộp tất cả $count commits thành 1? (y/N): ${NC}")" confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        info "Đã huỷ."
        exit 0
    fi

    # Tạo backup
    local backup_branch="backup/${CURRENT_BRANCH}_$(date +%Y%m%d_%H%M%S)"
    git branch "$backup_branch"
    ok "Đã tạo backup branch: $backup_branch"

    # Lấy commit message
    local msg
    if [ -n "$SQUASH_MESSAGE" ]; then
        msg="$SQUASH_MESSAGE"
    else
        # Mặc định lấy message của commit cuối cùng
        msg=$(git log -1 --format="%s" HEAD)
        echo ""
        info "Chọn commit message:"
        echo "  1) Giữ message commit cuối: \"$msg\""
        echo "  2) Gộp tất cả messages"
        echo "  3) Nhập message mới"
        read -r -p "$(echo -e "${CYAN}Chọn (1/2/3) [1]: ${NC}")" choice
        case "${choice:-1}" in
            2)
                msg=$(git log --format="- %s" "$merge_base"..HEAD | tac)
                msg="squash: $CURRENT_BRANCH"$'\n\n'"$msg"
                ;;
            3)
                read -r -p "$(echo -e "${CYAN}Nhập commit message: ${NC}")" msg
                if [ -z "$msg" ]; then
                    err "Message không được để trống."
                    exit 1
                fi
                ;;
            1|"")
                ;; # giữ nguyên msg
            *)
                err "Lựa chọn không hợp lệ."
                exit 1
                ;;
        esac
    fi

    # Thực hiện squash bằng soft reset
    # Giữ nguyên trạng thái code hiện tại (HEAD), chỉ reset history
    git reset --soft "$merge_base"
    git commit -m "$msg"

    ok "Squash thành công! $count commits → 1 commit"
    info "Commit mới: $(git log -1 --oneline)"
    warn "Dùng 'git push --force-with-lease' để update remote"
    info "Backup branch: $backup_branch (xoá bằng: git branch -D $backup_branch)"
}

# ──────────────────────────── Main ────────────────────────────
echo ""
echo "╔══════════════════════════════════════╗"
echo "║        Git Squash Tool v1.0          ║"
echo "╚══════════════════════════════════════╝"
echo ""

if [ -n "$FROM_COMMIT" ] && [ -n "$TO_COMMIT" ]; then
    squash_range "$FROM_COMMIT" "$TO_COMMIT"
else
    squash_all
fi
