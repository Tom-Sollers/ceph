#!/bin/bash
#
# test-listing-during-migration.sh
#
# Tests object listing correctness across a pool migration:
#
#   1.  Create source pool (rep or ec), populate with OBJECT_COUNT named objects
#   2.  List source pool → save as baseline (pre-migration)
#   3.  Create target pool (rep or ec) with --migrate-from-pool (starts migration)
#   4.  Wait until >50% migrated, then list mid-migration → mid list
#   5.  Wait for migration to fully complete
#   6.  List objects post-migration → post list
#   7.  Compare mid and post lists against baseline, print results
#   8.  Clean up only if --clean-up is passed (always kept on failure)
#
# Run from the cluster build/ directory where ceph.conf lives:
#   ./test-listing-during-migration.sh [OPTIONS]
#

set -uo pipefail

# ---------------------------------------------------------------------------
# Source shared helpers
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/migration-helpers.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
OBJECT_COUNT=2000
OBJECT_SIZE="256K"
OBJECT_PREFIX="listtest-obj"
MAX_WAIT=600
DO_CLEANUP=false
VERBOSE=false
SRC_PG_OVERRIDE=""
TGT_PG_OVERRIDE=""
SRC_TYPE="rep"        # --src-type rep|ec
TGT_TYPE="rep"        # --tgt-type rep|ec
EC_K=2                # EC data chunks (k)
EC_M=1                # EC coding chunks (m)

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Test object listing correctness during and after pool migration.

Pool type options:
  --src-type rep|ec     Source pool type (default: rep)
  --tgt-type rep|ec     Target pool type (default: rep)
  --ec-k N              EC data chunks, used when src or tgt is ec (default: $EC_K)
  --ec-m N              EC coding chunks, used when src or tgt is ec (default: $EC_M)

Other options:
  --object-count N      Objects to populate in source pool (default: $OBJECT_COUNT)
  --src-pg N, --spg N   Fix source pool PG count (default: random)
  --tgt-pg N, --tpg N   Fix target pool PG count (default: random, != source)
  --clean-up            Delete pools and lists after a passing test
  --verbose             Print extra detail during the run
  --help                Show this help message

Examples:
  $0 --src-type rep --tgt-type ec      # replicated → EC
  $0 --src-type ec  --tgt-type rep     # EC → replicated
  $0 --src-type ec  --tgt-type ec      # EC → EC
  $0                                   # rep → rep (default)
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --object-count)  OBJECT_COUNT="$2";    shift 2 ;;
        --src-pg|--spg)  SRC_PG_OVERRIDE="$2"; shift 2 ;;
        --tgt-pg|--tpg)  TGT_PG_OVERRIDE="$2"; shift 2 ;;
        --src-type)      SRC_TYPE="$2";         shift 2 ;;
        --tgt-type)      TGT_TYPE="$2";         shift 2 ;;
        --ec-k)          EC_K="$2";             shift 2 ;;
        --ec-m)          EC_M="$2";             shift 2 ;;
        --clean-up)      DO_CLEANUP=true;       shift   ;;
        --verbose)       VERBOSE=true;          shift   ;;
        --help)          usage ;;
        *) print_error "Unknown option: $1"; echo "Use --help for usage."; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
SRC_POOL=""
TGT_POOL=""
SRC_EC_PROFILE=""
TGT_EC_PROFILE=""
TMP_DATA_FILE=""
RESULTS_DIR=""
FAIL_COUNT=0

# ---------------------------------------------------------------------------
# Cleanup — pools and lists only deleted when --clean-up passed + test passed
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code=$?

    [ -n "$TMP_DATA_FILE" ] && rm -f "$TMP_DATA_FILE"

    if [ "$DO_CLEANUP" = true ] && [ "$FAIL_COUNT" -eq 0 ]; then
        if [ -n "$SRC_POOL" ] || [ -n "$TGT_POOL" ]; then
            print_subheader "Cleaning Up Pools"
        fi
        if [ -n "$TGT_POOL" ] && check_pool_exists "$TGT_POOL" 2>/dev/null; then
            print_info "Deleting target pool: $TGT_POOL"
            ceph osd pool delete "$TGT_POOL" "$TGT_POOL" \
                --yes-i-really-really-mean-it >/dev/null 2>&1 || true
            print_success "Target pool deleted"
        fi
        if [ -n "$SRC_POOL" ] && check_pool_exists "$SRC_POOL" 2>/dev/null; then
            print_info "Deleting source pool: $SRC_POOL"
            ceph osd pool delete "$SRC_POOL" "$SRC_POOL" \
                --yes-i-really-really-mean-it >/dev/null 2>&1 || true
            print_success "Source pool deleted"
        fi
        [ -n "$RESULTS_DIR" ] && [ -d "$RESULTS_DIR" ] && rm -rf "$RESULTS_DIR"
    else
        if [ -n "$SRC_POOL" ] || [ -n "$TGT_POOL" ]; then
            print_info "Pools left in place:"
            [ -n "$SRC_POOL" ] && echo "  Source : $SRC_POOL"
            [ -n "$TGT_POOL" ] && echo "  Target : $TGT_POOL"
        fi
        [ -n "$RESULTS_DIR" ] && [ -d "$RESULTS_DIR" ] && \
            print_info "Lists preserved in: $RESULTS_DIR"
    fi

    exit "$exit_code"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helper: is a migration currently running? (grep ceph status)
# ---------------------------------------------------------------------------
migration_running() {
    ceph status 2>/dev/null | grep -q "pool migrating"
}

# ---------------------------------------------------------------------------
# Helper: list objects in a pool (unsorted — order is part of what we test)
# ---------------------------------------------------------------------------
list_objects_to_file() {
    local pool="$1"
    local outfile="$2"
    rados -p "$pool" ls 2>/dev/null > "$outfile"
}

# ---------------------------------------------------------------------------
# Helper: compare actual list against baseline, report PASS/FAIL
# ---------------------------------------------------------------------------
compare_to_baseline() {
    local label="$1"
    local actual="$2"
    local baseline="$3"

    local actual_count baseline_count missing extra
    actual_count=$(wc -l < "$actual")
    baseline_count=$(wc -l < "$baseline")
    missing=$(( baseline_count - $(grep -cFxf "$baseline" "$actual" || true) ))
    extra=$(( actual_count   - $(grep -cFxf "$actual"   "$baseline" || true) ))

    if [ "$missing" -eq 0 ] && [ "$extra" -eq 0 ]; then
        print_success "[PASS] $label"
        echo "         Listed: $actual_count  Baseline: $baseline_count  Missing: 0  Extra: 0"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        print_error "[FAIL] $label"
        echo "         Listed: $actual_count  Baseline: $baseline_count  Missing: $missing  Extra: $extra"
        if [ "$missing" -gt 0 ]; then
            echo "         In baseline but missing from listing (first 20):"
            grep -Fxvf "$actual" "$baseline" | head -20 | sed 's/^/           /'
        fi
        if [ "$extra" -gt 0 ]; then
            echo "         In listing but not in baseline (first 20):"
            grep -Fxvf "$baseline" "$actual" | head -20 | sed 's/^/           /'
        fi
    fi
}

# ===========================================================================
# MAIN
# ===========================================================================

print_header "LISTING-DURING-MIGRATION TEST"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
print_subheader "Preflight"

if ! check_cluster_running; then exit 1; fi
print_success "Cluster is reachable"
ceph tell mon.\* injectargs '--mon-allow-pool-delete=true' >/dev/null 2>&1 || true

# Validate pool types
if ! validate_pool_type "$SRC_TYPE"; then exit 1; fi
if ! validate_pool_type "$TGT_TYPE"; then exit 1; fi

# Resolve PG counts
if [ -n "$SRC_PG_OVERRIDE" ] && ! [[ "$SRC_PG_OVERRIDE" =~ ^[1-9][0-9]*$ ]]; then
    print_error "--src-pg must be a positive integer"; exit 1
fi
if [ -n "$TGT_PG_OVERRIDE" ] && ! [[ "$TGT_PG_OVERRIDE" =~ ^[1-9][0-9]*$ ]]; then
    print_error "--tgt-pg must be a positive integer"; exit 1
fi

PG_OPTIONS=(1 2 4 8 16 32)

if [ -n "$SRC_PG_OVERRIDE" ]; then
    SRC_PG="$SRC_PG_OVERRIDE"
    print_info "Source PGs: $SRC_PG (fixed)"
else
    SRC_PG=${PG_OPTIONS[$((RANDOM % ${#PG_OPTIONS[@]}))]}
    print_info "Source PGs: $SRC_PG (random)"
fi

if [ -n "$TGT_PG_OVERRIDE" ]; then
    TGT_PG="$TGT_PG_OVERRIDE"
    print_info "Target PGs: $TGT_PG (fixed)"
    [ "$TGT_PG" -eq "$SRC_PG" ] && \
        print_warning "Same PG count on both pools — PG-change path won't be exercised"
else
    TGT_PG=$SRC_PG
    while [ "$TGT_PG" -eq "$SRC_PG" ]; do
        TGT_PG=${PG_OPTIONS[$((RANDOM % ${#PG_OPTIONS[@]}))]}
    done
    print_info "Target PGs: $TGT_PG (random, != source)"
fi

UNIQUE_ID="${RANDOM}"
SRC_POOL="listtest-src-${UNIQUE_ID}"
TGT_POOL="listtest-tgt-${UNIQUE_ID}"
RESULTS_DIR="$(pwd)/test-results/$(date +%Y%m%d-%H%M%S)-${UNIQUE_ID}"
mkdir -p "$RESULTS_DIR"

echo ""
echo "  Source pool : $SRC_POOL  ($SRC_PG PGs, $SRC_TYPE)"
echo "  Target pool : $TGT_POOL  ($TGT_PG PGs, $TGT_TYPE)"
echo "  Objects     : $OBJECT_COUNT  ($OBJECT_SIZE each)"
[ "$SRC_TYPE" = "ec" ] || [ "$TGT_TYPE" = "ec" ] && \
    echo "  EC profile  : k=$EC_K m=$EC_M"
echo "  Results dir : $RESULTS_DIR"
echo ""

# ---------------------------------------------------------------------------
# Step 1 — Create and populate source pool
# ---------------------------------------------------------------------------
print_subheader "Step 1: Create and populate source pool ($SRC_TYPE)"

if [ "$SRC_TYPE" = "ec" ]; then
    SRC_EC_PROFILE="ec-profile-${SRC_POOL}"
    ceph osd erasure-code-profile set "$SRC_EC_PROFILE" \
        k="$EC_K" m="$EC_M" crush-failure-domain=osd >/dev/null 2>&1
    ceph osd pool create "$SRC_POOL" "$SRC_PG" "$SRC_PG" erasure "$SRC_EC_PROFILE" >/dev/null 2>&1
    # allow_ec_overwrites is required for rados put to work on an EC pool
    ceph osd pool set "$SRC_POOL" allow_ec_overwrites true >/dev/null 2>&1
else
    ceph osd pool create "$SRC_POOL" "$SRC_PG" "$SRC_PG" replicated >/dev/null 2>&1
    ceph osd pool set "$SRC_POOL" size 1 --yes-i-really-mean-it >/dev/null 2>&1
    ceph osd pool set "$SRC_POOL" min_size 1 >/dev/null 2>&1
fi
ceph osd pool application enable "$SRC_POOL" rados >/dev/null 2>&1 || true
print_success "Pool created: $SRC_POOL ($SRC_TYPE)"
wait_for_pgs_active "$SRC_POOL" 60

TMP_DATA_FILE=$(mktemp /tmp/listing-test-data-XXXXXX)
dd if=/dev/urandom of="$TMP_DATA_FILE" bs="$OBJECT_SIZE" count=1 2>/dev/null

# Upload in parallel batches of 16 to go faster while keeping object names
# deterministic (needed for the baseline comparison to be meaningful).
BATCH=16
PIDS=()
COUNT=0
for i in $(seq -w 1 "$OBJECT_COUNT"); do
    rados -p "$SRC_POOL" put "${OBJECT_PREFIX}-${i}" "$TMP_DATA_FILE" 2>/dev/null &
    PIDS+=($!)
    COUNT=$((COUNT + 1))
    # When the batch is full, wait for all of them before starting the next
    if [ "${#PIDS[@]}" -ge "$BATCH" ]; then
        for pid in "${PIDS[@]}"; do wait "$pid" || true; done
        PIDS=()
        printf "\r  Uploaded: %d / %d" "$COUNT" "$OBJECT_COUNT"
    fi
done
# Wait for any remaining jobs in the last partial batch
for pid in "${PIDS[@]}"; do wait "$pid" || true; done
echo ""
print_success "All $OBJECT_COUNT objects written"

# ---------------------------------------------------------------------------
# Step 2 — Baseline list (pre-migration)
# ---------------------------------------------------------------------------
print_subheader "Step 2: Pre-migration listing (baseline)"

BASELINE="${RESULTS_DIR}/1-baseline.txt"
list_objects_to_file "$SRC_POOL" "$BASELINE"
BASELINE_COUNT=$(wc -l < "$BASELINE")
[ "$BASELINE_COUNT" -ne "$OBJECT_COUNT" ] && \
    print_warning "Expected $OBJECT_COUNT but listed $BASELINE_COUNT — using actual as baseline"
print_success "Baseline saved: $BASELINE ($BASELINE_COUNT objects)"

# ---------------------------------------------------------------------------
# Step 3 — Start migration
# ---------------------------------------------------------------------------
print_subheader "Step 3: Start migration ($SRC_TYPE → $TGT_TYPE)"

if [ "$TGT_TYPE" = "ec" ]; then
    TGT_EC_PROFILE="ec-profile-${TGT_POOL}"
    ceph osd erasure-code-profile set "$TGT_EC_PROFILE" \
        k="$EC_K" m="$EC_M" crush-failure-domain=osd >/dev/null 2>&1
    ceph osd pool create "$TGT_POOL" "$TGT_PG" "$TGT_PG" erasure "$TGT_EC_PROFILE" \
        --migrate-from-pool "$SRC_POOL" >/dev/null 2>&1
    ceph osd pool set "$TGT_POOL" allow_ec_overwrites true >/dev/null 2>&1
else
    ceph osd pool create "$TGT_POOL" "$TGT_PG" "$TGT_PG" replicated \
        --migrate-from-pool "$SRC_POOL" >/dev/null 2>&1
    ceph osd pool set "$TGT_POOL" size 1 --yes-i-really-mean-it >/dev/null 2>&1
    ceph osd pool set "$TGT_POOL" min_size 1 >/dev/null 2>&1
fi
print_success "Migration started: $SRC_POOL ($SRC_TYPE) → $TGT_POOL ($TGT_TYPE)"

# ---------------------------------------------------------------------------
# Step 4 — Wait until >50% migrated, then take mid-migration listing
# ---------------------------------------------------------------------------
print_subheader "Step 4: Waiting for >50% migration progress..."

MID_LIST="${RESULTS_DIR}/2-mid-migration.txt"
MID_TAKEN=false
ELAPSED=0

while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
    # Pull the status line, e.g:
    #   "Pool migration: 1054/2000 objects migrated (52.700%), 1 pool migrating, 16 pgs migrating"
    STATUS=$(ceph status 2>/dev/null | grep "pool migrating" | xargs || true)

    # Extract the integer part of the percentage  e.g. "52" from "52.700%"
    PCT=$(echo "$STATUS" | grep -o '([0-9]*\.[0-9]*%)' | grep -o '[0-9]*' | head -1 || true)

    printf "\r  %s" "$STATUS"

    if [ -n "$PCT" ] && [ "$PCT" -ge 50 ]; then
        echo ""
        print_success "Migration is at ${PCT}% — taking mid-migration listing now"
        list_objects_to_file "$SRC_POOL" "$MID_LIST"
        MID_TAKEN=true
        break
    fi

    # Migration finished before we hit 50% — list immediately
    if ! migration_running; then
        echo ""
        print_warning "Migration completed before reaching 50% — listing now"
        list_objects_to_file "$SRC_POOL" "$MID_LIST"
        MID_TAKEN=true
        break
    fi

    sleep 1
    ELAPSED=$((ELAPSED + 1))
done
echo ""

if [ "$MID_TAKEN" = false ]; then
    print_warning "Timed out waiting for 50% — taking listing now"
    list_objects_to_file "$SRC_POOL" "$MID_LIST"
fi

MID_COUNT=$(wc -l < "$MID_LIST")
print_success "Mid-migration list saved: $MID_LIST ($MID_COUNT objects)"

# ---------------------------------------------------------------------------
# Step 5 — Wait for migration to complete
# ---------------------------------------------------------------------------
print_subheader "Step 5: Waiting for migration to complete..."

ELAPSED=0
while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
    if ! migration_running; then
        print_success "Migration complete (after ~${ELAPSED}s)"
        break
    fi
    STATUS=$(ceph status 2>/dev/null | grep "pool migrating" | xargs || true)
    printf "\r  %s" "$STATUS"
    sleep 3
    ELAPSED=$((ELAPSED + 3))
done
echo ""

[ "$ELAPSED" -ge "$MAX_WAIT" ] && \
    print_warning "Migration did not finish within ${MAX_WAIT}s"

sleep 2

# ---------------------------------------------------------------------------
# Step 6 — Post-migration listing
# ---------------------------------------------------------------------------
print_subheader "Step 6: Post-migration listing"

POST_LIST="${RESULTS_DIR}/3-post-migration.txt"
list_objects_to_file "$SRC_POOL" "$POST_LIST"
POST_COUNT=$(wc -l < "$POST_LIST")
print_success "Post-migration list saved: $POST_LIST ($POST_COUNT objects)"

# ---------------------------------------------------------------------------
# Step 7 — Results
# ---------------------------------------------------------------------------
print_header "TEST RESULTS"

echo "  Source pool  : $SRC_POOL ($SRC_PG PGs, $SRC_TYPE)"
echo "  Target pool  : $TGT_POOL ($TGT_PG PGs, $TGT_TYPE)"
echo "  Baseline     : $BASELINE_COUNT objects  →  $BASELINE"
echo "  Mid-migration: $MID_COUNT objects        →  $MID_LIST"
echo "  Post-migr.   : $POST_COUNT objects        →  $POST_LIST"
echo ""

compare_to_baseline "Mid-migration listing"  "$MID_LIST"  "$BASELINE"
echo ""
compare_to_baseline "Post-migration listing" "$POST_LIST" "$BASELINE"
echo ""

if [ "$FAIL_COUNT" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}ALL 2 CHECKS PASSED${NC}"
else
    echo -e "  ${RED}${BOLD}${FAIL_COUNT} of 2 CHECKS FAILED${NC}"
    echo ""
    print_info "Lists preserved in: $RESULTS_DIR"
fi
echo ""

[ "$FAIL_COUNT" -eq 0 ] && exit 0 || exit 1

# Made with Bob
