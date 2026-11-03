#!/bin/bash
# The static checks, the same for a person, the pre-commit hook and CI.
#
#   Tools/check.sh changed [FILE...]   Swift files changed against HEAD and untracked ones, or just FILEs
#   Tools/check.sh changed --staged    staged Swift files (the pre-commit hook)
#   Tools/check.sh full                every Swift file (CI)
#   Tools/check.sh shrink              drop baseline entries that no file needs any more; never adds one
#   Tools/check.sh baseline            rewrite .swiftlint-baseline.json and .slop-baseline.json from every file
#
# Steps: SwiftLint against its ratchet baseline, slop-check (comment policy and reasoned escape hatches) against its
# baseline, public hygiene and import boundaries. No formatter is enforced. Every step runs, so one pass reports
# everything. The vendored C under CLibOMEMO is never checked.
#
# A baseline only shrinks: CI fails a pull request whose baselines grew, or that changes these checks, unless a
# maintainer adds the baseline-growth-approved label. Rewrite them only after rebasing onto a main whose code changed.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

usage() {
  sed -n '3,7s/^# //p' "$0" >&2
  exit 2
}

mode=${1:-}
[ $# -gt 0 ] && shift
staged=0
files=()
case "$mode" in
  changed)
    for arg in "$@"; do
      case "$arg" in
        --staged) staged=1 ;;
        -*) usage ;;
        *) files+=("$arg") ;;
      esac
    done
    ;;
  full | shrink | baseline) [ $# -eq 0 ] || usage ;;
  *) usage ;;
esac

# Paths are printed unquoted, so a file name with non-ASCII characters is not skipped.
candidates() {
  local git=(git -c core.quotePath=false)
  if [ "$mode" != changed ]; then
    "${git[@]}" ls-files --cached --others --exclude-standard
  elif [ ${#files[@]} -gt 0 ]; then
    printf '%s\n' "${files[@]}"
  elif [ "$staged" -eq 1 ]; then
    "${git[@]}" diff --cached --name-only --diff-filter=d
  else
    "${git[@]}" diff --name-only --diff-filter=d HEAD
    "${git[@]}" ls-files --others --exclude-standard
  fi
}

swift_files=()
config_changed=0
while IFS= read -r f; do
  case "$f" in
    .swiftlint.yml | .swiftlint-baseline.json | .slop-baseline.json | Tools/*) config_changed=1 ;;
  esac
  case "$f" in
    *.swift) ;;
    *) continue ;;
  esac
  case "$f" in
    Packages/OMEMOCrypto/Sources/CLibOMEMO/* | */.build/* | build/*) continue ;;
  esac
  [ -f "$f" ] && swift_files+=("$f")
done < <(candidates | sort -u)

# A change to the checks themselves is checked against every file.
if [ "$mode" = changed ] && [ "$config_changed" -eq 1 ]; then
  exec "$0" full
fi

slop=Tools/slop-check/.build/release/slop-check
if [ ! -x "$slop" ] || [ -n "$(find Tools/slop-check/Sources Tools/slop-check/Package.swift -newer "$slop" -print -quit)" ]; then
  echo "building slop-check (the first build compiles swift-syntax and takes a few minutes)" >&2
  swift build -c release --package-path Tools/slop-check -q >&2 || exit 2
fi

if [ "$mode" = shrink ]; then
  python3 -I Tools/lint-ratchet.py --shrink >/dev/null
  "$slop" --baseline .slop-baseline.json --shrink-baseline "${swift_files[@]}" >/dev/null
  git diff --stat -- .swiftlint-baseline.json .slop-baseline.json
  exit 0
fi
if [ "$mode" = baseline ]; then
  python3 -I Tools/lint-ratchet.py --write || exit 2
  "$slop" --write-baseline .slop-baseline.json "${swift_files[@]}" || exit 2
  echo "review the baseline diff; a pull request whose baselines grew needs the baseline-growth-approved label"
  exit 0
fi

failed=0
step() {
  local name=$1 out
  shift
  if ! out=$("$@" 2>&1); then
    printf '%s failed:\n%s\n\n' "$name" "$out"
    failed=1
  elif [ -n "$out" ]; then
    printf '%s\n' "$out"
  fi
}

# A full run also fails while a baseline holds entries the code no longer needs, so a fix is locked in with it.
if [ "$mode" = full ]; then
  step SwiftLint python3 -I Tools/lint-ratchet.py --fail-on-fixed
  step slop-check "$slop" --baseline .slop-baseline.json --fail-on-fixed "${swift_files[@]}"
  step "Import boundaries" python3 -I Tools/import-boundaries.py
elif [ ${#swift_files[@]} -gt 0 ]; then
  step SwiftLint python3 -I Tools/lint-ratchet.py "${swift_files[@]}"
  step slop-check "$slop" --baseline .slop-baseline.json "${swift_files[@]}"
  step "Import boundaries" python3 -I Tools/import-boundaries.py "${swift_files[@]}"
fi
step "Public hygiene" python3 -I Tools/public-hygiene.py
exit "$failed"
