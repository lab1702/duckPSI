#!/bin/sh
# Run from the repository root. Each expected error needs a fresh DuckDB process.
set -eu

checks=0
check_error() {
    label=$1
    expected=$2
    sql=$3
    if output=$(duckdb -c '.read psi_macros.sql' -c "$sql" 2>&1); then
        printf 'FAIL: %s unexpectedly succeeded\n' "$label" >&2
        exit 1
    fi
    case "$output" in
        *"$expected"*) printf 'PASS: %s\n' "$label" ;;
        *) printf 'FAIL: %s\n%s\n' "$label" "$output" >&2; exit 1 ;;
    esac
    checks=$((checks + 1))
}

for macro in psi psi_detail psi_cat psi_cat_detail psi_all; do
    case "$macro" in
        psi|psi_detail) reserved=_psi_ref_vals ;;
        psi_cat|psi_cat_detail) reserved=_psi_cat_ref_counts ;;
        psi_all) reserved=_psi_all_ref_long ;;
    esac
    for name in "$reserved" "\"$reserved\"" "main.\"$reserved\"" "\"memory\".\"main\".\"$reserved\""; do
        case "$macro" in
            psi_all) call="$macro('r', '$name')" ;;
            *) call="$macro('r', '$name', 'v')" ;;
        esac
        check_error "$macro rejects $name" 'reserved' \
            "CREATE TABLE r AS SELECT 100::DOUBLE v FROM range(100);
             CREATE TABLE $reserved AS SELECT 0::DOUBLE v FROM range(100);
             SELECT * FROM $call;"
    done
done

check_error 'continuous invalid bins' 'bins must be >= 1' \
    "CREATE TABLE r(x DOUBLE); SELECT * FROM psi('r', 'r', 'x', bins := 0);"
check_error 'sweep invalid bins' 'bins must be >= 1' \
    "CREATE TABLE r(x DOUBLE); INSERT INTO r VALUES (1);
     SELECT * FROM psi_all('r', 'r', bins := -1);"
check_error 'ambiguous table' 'matches more than one table' \
    "CREATE SCHEMA s; CREATE TABLE r(x DOUBLE); CREATE TABLE s.r(x DOUBLE);
     INSERT INTO r VALUES (1); SELECT * FROM psi_all('r', 'main.r');"

printf '%s error-path checks passed\n' "$checks"
