#!/bin/sh
# Run the update-elilo test suites: sh tests/run.sh
# Needs only POSIX sh, coreutils, awk, grep and sed; no root, no real disks.
# Fixtures and logs go to tests/work/ (removed and recreated on each run).

cd "$(dirname "$0")" || exit 1
rm -rf work; mkdir -p work
total=0
for t in t-*.sh; do
    name=${t%.sh}
    if sh "$t" > "work/$name.log" 2>&1; then
        echo "pass  $name ($(grep -c '^  ok ' "work/$name.log") checks)"
    else
        total=$((total + 1))
        echo "FAIL  $name, see tests/work/$name.log:"
        grep '^  FAIL ' "work/$name.log"
    fi
done
[ $total -eq 0 ] && echo "all suites passed"
exit $total
