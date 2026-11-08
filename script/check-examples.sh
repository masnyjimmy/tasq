#!/bin/sh
set -eu

fail=0
for f in docs/src/examples/*.tasq; do
    [ -e "$f" ] || continue
    case "$f" in
        *.fail.tasq)
            if ./zig-out/bin/tasq --check -f "$f" >/dev/null 2>&1; then
                echo "SHOULD FAIL but passed: $f"; fail=1
            fi ;;
        *)
            ./zig-out/bin/tasq --check -f "$f" || { echo "FAILED: $f"; fail=1; } ;;
    esac
done
exit $fail