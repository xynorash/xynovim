#!/usr/bin/env bash
# Run the spec files in tests/ headless, each in its own nvim process.
#
# Usage: scripts/test.sh [options] [pattern...]
#   pattern       only spec files whose path contains it (several = any of them)
#   --list        print the spec files and exit
#   --coverage    collect Lua line coverage of the repo's own modules, print the
#                 per-file report afterwards (several times slower)
#   --timeout N   hard timeout per spec file in seconds (default 120,
#                 or $TEST_TIMEOUT); a hung file fails, the suite goes on
#   -v, --verbose print the full output of every spec file, not only failures
#
# Isolation: the config is this checkout (linked into a temp XDG_CONFIG_HOME),
# XDG_STATE_HOME and XDG_CACHE_HOME are temp dirs (no shada, undo, lsp.log or
# local-history leaks into your real ones), XDG_DATA_HOME is the REAL one: the
# plugins are not reinstalled. A fresh machine (CI) must run scripts/bootstrap.sh
# first. Specs needing rust-analyzer/cargo/bwrap/tmux skip with a message when
# they are missing (XYNO_TEST_SKIP_RUST=1 forces the Rust ones to skip).
# Exit status: 0 all passed (skips allowed), 1 any failure/timeout, 2 usage/setup.
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
timeout_s=${TEST_TIMEOUT:-120}
list=0 cov=0 verbose=0
patterns=()
while [ $# -gt 0 ]; do
  case $1 in
    --list) list=1 ;;
    --coverage) cov=1 ;;
    --timeout)
      shift
      [ $# -gt 0 ] || { echo "test.sh: --timeout needs seconds" >&2; exit 2; }
      timeout_s=$1
      ;;
    -v | --verbose) verbose=1 ;;
    -h | --help) sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*) echo "test.sh: unknown option $1" >&2; exit 2 ;;
    *) patterns+=("$1") ;;
  esac
  shift
done

specs=()
for f in "$repo"/tests/*_spec.lua; do
  [ -e "$f" ] || continue
  rel=${f#"$repo"/}
  if [ ${#patterns[@]} -gt 0 ]; then
    hit=0
    for p in "${patterns[@]}"; do [[ $rel == *$p* ]] && hit=1; done
    [ $hit = 1 ] || continue
  fi
  specs+=("$rel")
done

if [ $list = 1 ]; then
  printf '%s\n' "${specs[@]}"
  exit 0
fi
if [ ${#specs[@]} -eq 0 ]; then
  echo "test.sh: no spec file matches ${patterns[*]:-(none found in tests/)}" >&2
  exit 2
fi
if ! command -v nvim >/dev/null 2>&1; then
  echo "test.sh: nvim not found" >&2
  exit 2
fi

data=${XDG_DATA_HOME:-$HOME/.local/share}
if [ ! -d "$data/nvim/lazy/lazy.nvim" ]; then
  echo "test.sh: no plugins in $data/nvim/lazy. Run scripts/bootstrap.sh first" >&2
  echo "  (with this checkout linked as the config: ln -s '$repo' ~/.config/nvim)." >&2
  exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/xynotest.XXXXXX")
export XYNO_TMUX_PREFIX=xynotest-$$
lock_before=$work/lazy-lock.before
cp "$repo/lazy-lock.json" "$lock_before"

cleanup() {
  # leftover tmux servers of the specs
  if command -v tmux >/dev/null 2>&1; then
    for s in "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$XYNO_TMUX_PREFIX"-*; do
      [ -S "$s" ] || continue
      tmux -L "$(basename "$s")" kill-server >/dev/null 2>&1
      rm -f "$s" # the dead server leaves its socket file behind
    done
  fi
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$work"/{config,state,cache,tmp,cov}
ln -s "$repo" "$work/config/nvim"
export XDG_CONFIG_HOME=$work/config XDG_STATE_HOME=$work/state XDG_CACHE_HOME=$work/cache
export XDG_DATA_HOME=$data
export XYNO_TEST_TMP=$work/tmp
export TMPDIR=$work/tmp
export XYNO_COV_ROOTS="$work/config/nvim:$(readlink -f "$repo")"

echo "xynovim tests: ${#specs[@]} spec file(s), timeout ${timeout_s}s each"
if [ "${XYNO_TEST_SKIP_RUST:-}" = 1 ]; then
  echo "  XYNO_TEST_SKIP_RUST=1 (Rust specs will skip)"
elif command -v rust-analyzer >/dev/null 2>&1 && rust-analyzer --version >/dev/null 2>&1 && command -v cargo >/dev/null 2>&1; then
  echo "  rust-analyzer + cargo: found (Rust specs run)"
else
  echo "  rust-analyzer/cargo: NOT usable (Rust specs will skip)"
fi
[ $cov = 1 ] && echo "  coverage: on"

set -m # every nvim gets its own process group, so leftovers can be killed
tot_pass=0 tot_fail=0 tot_skip=0 failed_files=()
t_all=$(date +%s)
for rel in "${specs[@]}"; do
  log=$work/$(basename "$rel").log
  args=(--headless)
  extra=()
  if [ $cov = 1 ]; then
    args+=(--cmd "luafile $repo/tests/coverage_hook.lua")
    extra+=(XYNO_COV_OUT="$work/cov/$(basename "$rel" .lua).json")
  fi
  t0=$(date +%s)
  # A slow spec states its own limit in a "-- xyno-timeout: N" line near the top
  # (it is never lower than the global one).
  spec_to=$(head -n 15 "$repo/$rel" | sed -n 's/^-- xyno-timeout: *\([0-9][0-9]*\).*/\1/p' | head -n1)
  eff_to=$timeout_s
  [ -n "$spec_to" ] && [ "$spec_to" -gt "$eff_to" ] && eff_to=$spec_to
  # (a subshell, so bash does not print "Killed" when the timeout has to use -9)
  (env XYNO_SPEC="$repo/$rel" ${extra[@]+"${extra[@]}"} \
    timeout -k 5 "$eff_to" nvim "${args[@]}" -S "$repo/tests/runner.lua" \
    </dev/null >"$log" 2>&1) &
  pid=$!
  # A spec that printed its result but whose nvim does not exit (seen once in a
  # while, cause unknown) must not eat the whole timeout: 30 s of grace, then the
  # process group is killed and the printed result counts, with a note.
  seen="" hung=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ -z "$seen" ] && grep -aq '^XYNO_RESULT ' "$log"; then seen=$SECONDS; fi
    if [ -n "$seen" ] && [ $((SECONDS - seen)) -ge 30 ]; then
      hung=1
      kill -TERM -- "-$pid" 2>/dev/null
      sleep 3
      kill -KILL -- "-$pid" 2>/dev/null
      break
    fi
    sleep 0.5
  done
  wait "$pid"
  rc=$?
  [ $hung = 1 ] && rc=0
  kill -TERM -- "-$pid" 2>/dev/null || true # stragglers (language servers...)
  secs=$(($(date +%s) - t0))

  res=$(grep -a '^XYNO_RESULT ' "$log" | tail -n1)
  if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
    status="TIMEOUT"; p=0; f=1; s=0
  elif [ -z "$res" ]; then
    status="CRASH"; p=0; f=1; s=0
  else
    p=$(sed -n 's/.*passed=\([0-9]*\).*/\1/p' <<<"$res")
    f=$(sed -n 's/.*failed=\([0-9]*\).*/\1/p' <<<"$res")
    s=$(sed -n 's/.*skipped=\([0-9]*\).*/\1/p' <<<"$res")
    if [ "$f" -gt 0 ] || [ "$rc" != 0 ]; then status="FAIL"; [ "$f" -eq 0 ] && f=1; else status="PASS"; fi
  fi
  tot_pass=$((tot_pass + p)); tot_fail=$((tot_fail + f)); tot_skip=$((tot_skip + s))
  printf '%-7s %s  %s passed, %s failed, %s skipped (%ss)\n' "$status" "$rel" "$p" "$f" "$s" "$secs"
  [ $hung = 1 ] && echo "    NOTE: nvim did not exit 30 s after the result line and was killed (the result above counts)"
  [ "$status" = PASS ] || failed_files+=("$rel")

  if [ "$verbose" = 1 ]; then
    sed 's/^/    | /' "$log"
  else
    grep -a -E '^(SKIP|FAIL)|^       ' "$log" | sed 's/^/    /'
    if [ "$status" = TIMEOUT ] || [ "$status" = CRASH ]; then
      echo "    ($status, exit $rc; last output)"
      tail -n 15 "$log" | sed 's/^/    | /'
    fi
  fi
done

if [ $cov = 1 ]; then
  echo
  nvim -l "$repo/scripts/coverage.lua" "$repo" "$work/cov"
fi

if ! cmp -s "$lock_before" "$repo/lazy-lock.json"; then
  echo "WARNING: lazy-lock.json changed during the run (git diff lazy-lock.json)"
fi

echo
echo "total: $tot_pass passed, $tot_fail failed, $tot_skip skipped in $(($(date +%s) - t_all))s"
if [ ${#failed_files[@]} -gt 0 ]; then
  echo "failed: ${failed_files[*]}"
  exit 1
fi
exit 0
