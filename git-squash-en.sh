#!/usr/bin/env bash
#
# git-squash.sh - Squash commits on the current branch
#
# Usage:
#   1) Squash ALL commits on the branch (relative to main/master):
#      ./git-squash.sh
#
#   2) Squash a specific range of commits (keeps code state of to_commit):
#      ./git-squash.sh <from_commit> <to_commit>
#
#   3) Specify base branch (default: auto-detect main/master/develop):
#      ./git-squash.sh --base origin/develop
#
# Notes:
#   - The script preserves the code state of the LAST commit exactly
#   - After squashing, you need `git push --force-with-lease` to update remote
#   - A backup branch is created before any changes
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
    err "Not a git repository!"
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    err "Working directory is dirty. Please commit or stash your changes first."
    exit 1
fi

CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null)
if [ -z "$CURRENT_BRANCH" ]; then
    err "Currently in detached HEAD state. Please checkout a branch."
    exit 1
fi

# ──────────────────────────── Parse arguments ────────────────────────────
BASE_BRANCH=""
FROM_COMMIT=""
TO_COMMIT=""
SQUASH_MESSAGE=""

print_usage() {
    echo "Usage:"
    echo "  $0                              # Squash all commits on branch"
    echo "  $0 <from_commit> <to_commit>    # Squash from commit A to commit B"
    echo "  $0 --base <branch>              # Specify base branch"
    echo "  $0 -m \"commit message\"          # Custom commit message"
    echo ""
    echo "Options:"
    echo "  --base <branch>    Base branch (default: auto-detect main/master/develop)"
    echo "  -m <message>       Commit message for the squashed commit"
    echo "  -h, --help         Show this help"
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
                err "Too many arguments. Use -h for help."
                exit 1
            fi
            shift
            ;;
    esac
done

# ──────────────────────────── Detect base branch ────────────────────────────
detect_base_branch() {
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
    err "Could not detect base branch (main/master/develop). Use --base to specify."
    exit 1
}

# ──────────────────────────── Mode 1: Squash range (from..to) ────────────────────────────
squash_range() {
    local from="$1"
    local to="$2"

    # Validate commits
    if ! git rev-parse --verify "$from" &>/dev/null; then
        err "Commit does not exist: $from"
        exit 1
    fi
    if ! git rev-parse --verify "$to" &>/dev/null; then
        err "Commit does not exist: $to"
        exit 1
    fi

    local from_short
    local to_short
    from_short=$(git rev-parse --short "$from")
    to_short=$(git rev-parse --short "$to")

    # Count commits in range
    local count
    count=$(git rev-list --count "$from".."$to")
    if [ "$count" -eq 0 ]; then
        err "No commits found between $from_short and $to_short"
        exit 1
    fi

    info "Squashing $count commits: $from_short -> $to_short"
    info "Preserving code state of commit: $to_short"

    # Show commits to be squashed
    echo ""
    info "Commits to be squashed:"
    git log --oneline "$from".."$to" | while read -r line; do
        echo "  $line"
    done
    echo ""

    # Confirm
    read -r -p "$(echo -e "${YELLOW}Are you sure you want to continue? (y/N): ${NC}")" confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        info "Cancelled."
        exit 0
    fi

    # Create backup
    local backup_branch="backup/${CURRENT_BRANCH}_$(date +%Y%m%d_%H%M%S)"
    git branch "$backup_branch"
    ok "Created backup branch: $backup_branch"

    # Get commit message
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

    # Perform squash via soft reset + commit-tree
    # 1. Save the tree (file state) of the target commit (to)
    local target_tree
    target_tree=$(git rev-parse "$to^{tree}")

    # 2. Save current HEAD position
    local original_head
    original_head=$(git rev-parse HEAD)

    # 3. Soft reset to the "from" commit (the boundary before our range)
    git reset --soft "$from"

    # 4. Create a new commit with the exact tree of the "to" commit
    local new_commit
    new_commit=$(git commit-tree "$target_tree" -p "$(git rev-parse HEAD)" -m "$msg")

    # 5. Point HEAD to the new squashed commit
    git reset --hard "$new_commit"

    # 6. If there are commits after "to" in the original branch, cherry-pick them back
    local remaining
    remaining=$(git rev-list --reverse "$to".."$original_head" 2>/dev/null || true)
    if [ -n "$remaining" ]; then
        info "Cherry-picking commits after the squashed range..."
        for commit in $remaining; do
            git cherry-pick "$commit" || {
                err "Cherry-pick failed at $commit. Resolve conflicts and run 'git cherry-pick --continue'"
                exit 1
            }
        done
    fi

    ok "Squash successful!"
    info "New commit: $(git log -1 --oneline)"
    warn "Use 'git push --force-with-lease' to update remote"
    info "Backup branch: $backup_branch (delete with: git branch -D $backup_branch)"
}

# ──────────────────────────── Mode 2: Squash all branch commits ────────────────────────────
squash_all() {
    if [ -z "$BASE_BRANCH" ]; then
        BASE_BRANCH=$(detect_base_branch)
    fi

    info "Current branch: $CURRENT_BRANCH"
    info "Base branch:    $BASE_BRANCH"

    # Find merge-base (the point where the branch diverged)
    local merge_base
    merge_base=$(git merge-base "$BASE_BRANCH" HEAD)
    local merge_base_short
    merge_base_short=$(git rev-parse --short "$merge_base")

    # Count commits
    local count
    count=$(git rev-list --count "$merge_base"..HEAD)

    if [ "$count" -eq 0 ]; then
        info "No commits on branch $CURRENT_BRANCH relative to $BASE_BRANCH"
        exit 0
    fi

    if [ "$count" -eq 1 ]; then
        info "Only 1 commit on branch. Nothing to squash."
        exit 0
    fi

    info "Found $count commits since $merge_base_short"

    # Show commit list
    echo ""
    info "Commits on branch $CURRENT_BRANCH:"
    git log --oneline "$merge_base"..HEAD | while read -r line; do
        echo "  $line"
    done
    echo ""

    # Confirm
    read -r -p "$(echo -e "${YELLOW}Squash all $count commits into 1? (y/N): ${NC}")" confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        info "Cancelled."
        exit 0
    fi

    # Create backup
    local backup_branch="backup/${CURRENT_BRANCH}_$(date +%Y%m%d_%H%M%S)"
    git branch "$backup_branch"
    ok "Created backup branch: $backup_branch"

    # Get commit message
    local msg
    if [ -n "$SQUASH_MESSAGE" ]; then
        msg="$SQUASH_MESSAGE"
    else
        # Default to the last commit message
        msg=$(git log -1 --format="%s" HEAD)
        echo ""
        info "Choose commit message:"
        echo "  1) Keep last commit message: \"$msg\""
        echo "  2) Combine all messages"
        echo "  3) Enter a new message"
        read -r -p "$(echo -e "${CYAN}Choose (1/2/3) [1]: ${NC}")" choice
        case "${choice:-1}" in
            2)
                msg=$(git log --format="- %s" "$merge_base"..HEAD | tac)
                msg="squash: $CURRENT_BRANCH"$'\n\n'"$msg"
                ;;
            3)
                read -r -p "$(echo -e "${CYAN}Enter commit message: ${NC}")" msg
                if [ -z "$msg" ]; then
                    err "Message cannot be empty."
                    exit 1
                fi
                ;;
            1|"")
                ;; # keep default msg
            *)
                err "Invalid choice."
                exit 1
                ;;
        esac
    fi

    # Perform squash via soft reset
    # Preserves current code state (HEAD), only resets history
    git reset --soft "$merge_base"
    git commit -m "$msg"

    ok "Squash successful! $count commits -> 1 commit"
    info "New commit: $(git log -1 --oneline)"
    warn "Use 'git push --force-with-lease' to update remote"
    info "Backup branch: $backup_branch (delete with: git branch -D $backup_branch)"
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
