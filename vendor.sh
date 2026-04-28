#!/usr/bin/env bash
#
# Purpose:
#   Update one vendored git submodule and stage the parent repository gitlink.
#
# What it does:
#   - initializes the selected submodule if needed;
#   - refuses to update a dirty submodule working tree;
#   - fast-forwards the selected branch from its remote;
#   - stages only the updated submodules/<module> gitlink in the parent repo.
#
# When it is called:
#   Run manually when intentionally bumping a vendored dependency revision.
#   By default it updates submodules/sing-box.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

module="sing-box"
module_set=0
branch=""
remote="origin"
stage=1

usage() {
    cat <<'EOF'
Usage: ./vendor.sh [module] [--branch <branch>] [--remote <remote>] [--no-stage]

Updates a vendored submodule with a fast-forward merge and stages the parent
repository gitlink. If no module is provided, updates sing-box.

Examples:
  ./vendor.sh
  ./vendor.sh sing-box
  ./vendor.sh sing-box --branch dev-next
  ./vendor.sh submodules/sing-box --no-stage

Options:
  --branch <branch>  Branch to update. Defaults to the current submodule branch.
  --remote <remote>  Remote to fetch from. Defaults to origin.
  --no-stage         Do not run "git add submodules/<module>" in the parent repo.
  -h, --help         Show this help.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '==> %s\n' "$*"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --branch)
            [ "$#" -ge 2 ] || die "--branch requires a value"
            branch="$2"
            shift 2
            ;;
        --remote)
            [ "$#" -ge 2 ] || die "--remote requires a value"
            remote="$2"
            shift 2
            ;;
        --no-stage)
            stage=0
            shift
            ;;
        --*)
            die "unknown option: $1"
            ;;
        *)
            [ "$module_set" -eq 0 ] || die "only one module argument is supported"
            module="$1"
            module_set=1
            shift
            ;;
    esac
done

case "$branch" in
    -*)
        die "branch must not start with '-'"
        ;;
esac

case "$remote" in
    -*)
        die "remote must not start with '-'"
        ;;
esac

case "$module" in
    submodules/*)
        submodule_path="$module"
        ;;
    *)
        submodule_path="submodules/$module"
        ;;
esac

known_paths="$(git -C "$ROOT_DIR" config -f .gitmodules --get-regexp '^submodule\..*\.path$' \
    | awk '{ print $2 }')"

printf '%s\n' "$known_paths" | grep -Fxq "$submodule_path" \
    || die "unknown submodule path: $submodule_path"

submodule_dir="$ROOT_DIR/$submodule_path"
if [ -d "$submodule_dir/.git" ] || [ -f "$submodule_dir/.git" ]; then
    log "using existing $submodule_path checkout"
else
    log "initializing $submodule_path"
    git -C "$ROOT_DIR" submodule update --init "$submodule_path"
fi

[ -d "$submodule_dir/.git" ] || [ -f "$submodule_dir/.git" ] \
    || die "$submodule_path is not a git checkout after initialization"

dirty_status="$(git -C "$submodule_dir" status --porcelain=v1 --untracked-files=all)"
if [ -n "$dirty_status" ]; then
    printf '%s\n' "$dirty_status" >&2
    die "$submodule_path has local changes; commit, stash, or clean them first"
fi

if [ -z "$branch" ]; then
    branch="$(git -C "$submodule_dir" symbolic-ref --quiet --short HEAD || true)"
fi

[ -n "$branch" ] || die "$submodule_path is detached; pass --branch <branch>"

old_rev="$(git -C "$submodule_dir" rev-parse --short=12 HEAD)"

log "fetching $remote/$branch"
git -C "$submodule_dir" fetch --tags "$remote" "refs/heads/$branch"

if git -C "$submodule_dir" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$submodule_dir" checkout "$branch"
else
    git -C "$submodule_dir" checkout -B "$branch" FETCH_HEAD
fi

log "fast-forwarding $submodule_path"
git -C "$submodule_dir" merge --ff-only FETCH_HEAD

new_rev="$(git -C "$submodule_dir" rev-parse --short=12 HEAD)"

if [ "$stage" -eq 1 ]; then
    git -C "$ROOT_DIR" add "$submodule_path"
    log "staged $submodule_path"
else
    log "left $submodule_path unstaged"
fi

printf '%s: %s -> %s\n' "$submodule_path" "$old_rev" "$new_rev"
