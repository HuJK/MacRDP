#!/usr/bin/env bash
#
# freerdp-fork-assemble.sh — (re)build the integration branch we actually
# build against, from a clean base plus every single-fix branch.
#
# Policy:
#   * `master`               tracks upstream FreeRDP (bump it deliberately).
#   * `hujk/fix/<bug>`        ONE branch per bug, each PR-able on its own.
#                            EDIT FIXES HERE — never on macrdp-fork.
#   * `macrdp-fork`          = master + merge of every hujk/fix/* branch.
#                            Has no content of its own; this script
#                            regenerates it from scratch on every run.
#
# The MacRDP submodule is pinned to `macrdp-fork`. Workflow:
#   1. edit/commit on a hujk/fix/* branch
#   2. ./scripts/freerdp-fork-assemble.sh        # rebuilds macrdp-fork
#   3. ./scripts/vendor-freerdp.sh build         # compiles it
#
# Adding a new fix = create a new `hujk/fix/<bug>` branch off master; this
# script picks it up automatically (it merges every hujk/fix/* branch).
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRDP="$REPO_ROOT/ThirdParty/FreeRDP"
BASE="${BASE:-master}"            # override: BASE=somebranch ./...
INTEGRATION="macrdp-fork"

cd "$FRDP"

# Refuse to clobber uncommitted work — fixes must be committed on their
# own branch first.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "error: FreeRDP working tree is dirty. Commit your fix on its" >&2
  echo "       hujk/fix/* branch before assembling macrdp-fork." >&2
  exit 1
fi

FIXES=()
while IFS= read -r _b; do
  [ -n "$_b" ] && FIXES+=("$_b")
done < <(git for-each-ref --format='%(refname:short)' 'refs/heads/hujk/fix/*' | sort)
if [ "${#FIXES[@]}" -eq 0 ]; then
  echo "error: no hujk/fix/* branches found." >&2
  exit 1
fi

echo "Base:    $BASE ($(git rev-parse --short "$BASE"))"
echo "Fixes:   ${FIXES[*]}"

# Fresh integration branch from BASE, then merge each fix.
git checkout -B "$INTEGRATION" "$BASE" >/dev/null
for fix in "${FIXES[@]}"; do
  if ! git merge --no-ff --no-edit "$fix" >/dev/null 2>&1; then
    git merge --abort 2>/dev/null || true
    echo "error: merging '$fix' into $INTEGRATION conflicts." >&2
    echo "       Fixes should touch disjoint code; resolve the overlap." >&2
    exit 1
  fi
  echo "  merged $fix"
done

echo ""
echo "$INTEGRATION assembled at $(git rev-parse --short HEAD):"
git --no-pager log --oneline "$BASE..$INTEGRATION" | sed 's/^/  /'
echo ""
echo "Now build:  ./scripts/vendor-freerdp.sh build"
