# SPDX-License-Identifier: GPL-2.0-or-later
# Sourced by the fuzz_*.sh scripts: replay the seeds listed in seeds.txt
# for one fuzz.py mode before the random run. A seed given on the command
# line is a deliberate reproduction and skips this, as does
# CETRAFS_FUZZ_NO_SEED_REPLAY=1.
#
# fuzz_replay_seeds <mode> <fuzz.py arguments other than --iters/--seed>
# Returns nonzero (after rewriting that seed's <last failed>) on the
# first listed seed that fails again.
fuzz_replay_seeds() {
    local mode="$1" f="$HERE/seeds.txt" fz seed iters first last note now tmp
    shift
    [ "${CETRAFS_FUZZ_NO_SEED_REPLAY:-0}" = 1 ] && return 0
    [ -f "$f" ] || return 0
    while read -r fz seed iters first last note; do
        case "$fz" in '' | \#*) continue ;; esac
        [ "$fz" = "$mode" ] || continue
        echo "== listed seed $seed: $iters iterations (first found $first, last failed $last)"
        if ! python3 "$HERE/fuzz.py" "$mode" "$@" --iters "$iters" --seed "$seed"; then
            now="$(date -u +%Y-%m-%dT%H:%MZ)"
            tmp="$f.tmp.$$"
            # POSIX awk only (mawk on the test boxes): the comment lines and
            # every other line stay byte for byte.
            awk -v m="$mode" -v s="$seed" -v n="$now" \
                '$1 == m && $2 == s && $1 !~ /^#/ { $5 = n } { print }' "$f" >"$tmp" && mv "$tmp" "$f"
            echo "== listed seed $seed FAILED again: its last-failed date in seeds.txt is now $now -- commit it"
            return 1
        fi
    done <"$f"
    return 0
}
