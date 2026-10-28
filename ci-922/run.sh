#!/usr/bin/env bash
# Ubuntu check for Raku/roast#922 (bug-coverage-stress flapper).
# Runs the moar-fudged test file the way a release would see it, before and after
# the two candidate fixes, and reports failures per test number.
#
# Usage: run.sh ROAST_DIR TEST_FILE ENUM_MODULE_FILE SOCKET_PATCH MODE
#   MODE=full : before + after, clean-precomp runs and parallel runs
#   MODE=enum : before only, clean-precomp runs (for the version comparison jobs)
# Env: CLEAN_RUNS (5) WORKERS (4) PER_WORKER (25) RUN_TIMEOUT (600) OUT (./results)
set -u
ROAST=$1 FILE=$2 ENUM=$3 PATCH=$4 MODE=$5
CLEAN_RUNS=${CLEAN_RUNS:-5} WORKERS=${WORKERS:-4} PER_WORKER=${PER_WORKER:-25}
RUN_TIMEOUT=${RUN_TIMEOUT:-600}
OUT=$(realpath -m "${OUT:-results}")
SUMMARY_MD=${GITHUB_STEP_SUMMARY:-/dev/null}
mkdir -p "$OUT/runs"
cd "$ROAST"

clear_precomp() { find . -name .precomp -type d -prune -exec rm -rf {} +; }

# One run of the fudged file; prints "STATUS|failing-tests" and keeps output on failure.
one_run() {
    local fudged=$1 tag=$2 o="$OUT/runs/$2.out" rc notok planned ran status=PASS
    timeout "$RUN_TIMEOUT" raku -I. "$fudged" > "$o" 2>&1
    rc=$?
    notok=$(grep -E '^not ok [0-9]+' "$o" | grep -v '# TODO' | sed -E 's/^not ok ([0-9]+).*/\1/' | tr '\n' ' ')
    planned=$(grep -m1 -E '^1\.\.[0-9]+' "$o" | sed 's/1\.\.//')
    ran=$(grep -cE '^(not )?ok [0-9]+' "$o")
    if [ "$rc" -ne 0 ] && ! { [ "$rc" -eq 1 ] && grep -q '^# FUDGED!' "$o"; }; then status=FAIL; fi
    [ -n "$notok" ] && status=FAIL
    [ -n "$planned" ] && [ "$planned" != "$ran" ] && status=FAIL
    [ "$rc" -eq 124 ] && status=TIMEOUT
    [ "$status" = PASS ] && rm -f "$o"
    echo "$status|$notok"
}
export -f one_run
export OUT RUN_TIMEOUT

report() {
    local phase=$1 kind=$2 file=$3 n fails
    n=$(wc -l < "$file")
    fails=$(grep -vc '^PASS|' "$file")
    echo "  $phase $kind: runs=$n failed=$fails"
    {
        echo "| $phase | $kind | $n | $fails | $(cut -d'|' -f2 "$file" | tr ' ' '\n' | grep -v '^$' | sort -n | uniq -c | awk '{printf "test %s: %s, ", $2, $1}' | sed 's/, $//') |"
    } >> "$OUT/table.md"
}

phase() {
    local p=$1 fudged
    fudged=$(perl fudge rakudo.moar "$FILE")
    echo "== $p: fudged file $fudged"
    echo "-- $p: '#=' lines in $ENUM: $(grep -c '#=' "$ENUM")"

    clear_precomp
    echo "-- $p: stderr of a fresh 'use' of the giant-enum module"
    raku -I"$(dirname "$ENUM")" -e "use $(basename "${ENUM%.*}")" 2> "$OUT/$p-enum-stderr.txt"
    echo "   $(wc -l < "$OUT/$p-enum-stderr.txt") stderr lines, $(grep -c 'Missing declarand' "$OUT/$p-enum-stderr.txt") 'Missing declarand' worries"
    head -4 "$OUT/$p-enum-stderr.txt" | sed 's/^/   | /'

    : > "$OUT/$p-clean.txt"
    for i in $(seq 1 "$CLEAN_RUNS"); do
        clear_precomp
        one_run "$fudged" "$p-clean-$i" >> "$OUT/$p-clean.txt"
    done
    report "$p" "clean .precomp, sequential" "$OUT/$p-clean.txt"

    if [ "$MODE" = full ]; then
        one_run "$fudged" "$p-warmup" > /dev/null
        seq 1 $((WORKERS * PER_WORKER)) | xargs -P "$WORKERS" -I{} bash -c "one_run '$fudged' '$p-par-{}'" > "$OUT/$p-par.txt"
        report "$p" "warm .precomp, $WORKERS parallel" "$OUT/$p-par.txt"
    fi
}

echo "raku: $(raku -v | head -1)"
echo "RAKUDO_RAKUAST=${RAKUDO_RAKUAST-<unset>}  roast: $(git rev-parse --short HEAD) $FILE  mode=$MODE"
{
    echo "### $FILE on $(git rev-parse --short HEAD), $(raku -e 'print $*RAKU.compiler.version'), RAKUDO_RAKUAST=${RAKUDO_RAKUAST-unset}"
    echo
    echo "| phase | runs | count | failed | failures per test number (non-TODO) |"
    echo "|---|---|---|---|---|"
} > "$OUT/table.md"

phase before

rc=0
if [ "$MODE" = full ]; then
    sed -i 's/#=/#/' "$ENUM"
    git apply "$PATCH"
    echo "== applied fixes:"
    git diff --stat
    phase after
    grep -vq '^PASS|' "$OUT"/after-*.txt && { echo "after: failures remain"; rc=1; }
fi

cat "$OUT/table.md" | tee -a "$SUMMARY_MD"
echo >> "$SUMMARY_MD"
exit $rc
