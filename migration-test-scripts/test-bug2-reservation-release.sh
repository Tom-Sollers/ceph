#!/bin/bash
#
# test-bug2-reservation-release.sh
#
# Tests that the source PG releases the target PG's reservation when
# migration is suspended (e.g. due to TooFull).
#
# Pass criteria:
#   - While migration is suspended (retry interval), the target PG
#     must NOT show "migrating" in its PG state.
#   - When migration resumes, "migrating" reappears.
#
# Usage: ./test-bug2-reservation-release.sh
#

set -e

SOURCE_POOL="bug2-src"
TARGET_POOL="bug2-tgt"
EC_PROFILE="bug2-ec-profile"
RETRY_INTERVAL=120   # seconds - long enough to observe the suspended state

cleanup() {
  echo ""
  echo "=== Cleanup ==="
  echo "Restoring full ratios..."
  ceph osd set-nearfull-ratio 0.85 2>/dev/null || true
  ceph osd set-full-ratio 0.95 2>/dev/null || true
  ceph osd set-backfillfull-ratio 0.90 2>/dev/null || true

  echo "Restoring migration retry interval..."
  ceph config rm osd osd_pool_migration_retry_interval 2>/dev/null || true

  echo "Deleting test pools..."
  ceph osd pool delete "$TARGET_POOL" "$TARGET_POOL" --yes-i-really-really-mean-it 2>/dev/null || true
  ceph osd pool delete "$SOURCE_POOL" "$SOURCE_POOL" --yes-i-really-really-mean-it 2>/dev/null || true
  ceph osd erasure-code-profile rm "$EC_PROFILE" 2>/dev/null || true

  echo "Cleanup done."
}
trap cleanup EXIT

echo "=== Bug 2 Test: Target reservation released when migration suspends ==="
echo ""

# --- Prerequisites ---
echo "--- Prerequisites ---"
ceph osd set-require-min-compat-client umbrella
ceph config set global enable_experimental_unrecoverable_data_corrupting_features "poolmigration"
echo "OK"
echo ""

# --- Set a long retry interval so we have time to observe the suspended state ---
echo "--- Setting retry interval to ${RETRY_INTERVAL}s ---"
ceph config set osd osd_pool_migration_retry_interval $RETRY_INTERVAL
echo "OK"
echo ""

# --- Create source pool (replicated, 1 PG, a handful of objects) ---
echo "--- Creating source pool: $SOURCE_POOL ---"
ceph osd pool create "$SOURCE_POOL" 1 1 replicated
ceph osd pool set "$SOURCE_POOL" size 3 --yes-i-really-mean-it
ceph osd pool application enable "$SOURCE_POOL" rados

echo "Populating source pool with test objects..."
for i in $(seq 1 20); do
  echo "testdata-$i" | rados -p "$SOURCE_POOL" put "obj-$i" -
done
echo "Source pool ready. Objects: $(rados -p "$SOURCE_POOL" ls | wc -l)"
echo ""

# --- Create target pool and start migration ---
echo "--- Creating target pool and starting migration ---"
ceph osd erasure-code-profile set "$EC_PROFILE" plugin=jerasure k=2 m=1 crush-failure-domain=osd
ceph osd pool create "$TARGET_POOL" 1 1 erasure "$EC_PROFILE" --migrate-from-pool "$SOURCE_POOL"
ceph osd pool application enable "$TARGET_POOL" rados

echo "Waiting for migration to start..."
for i in $(seq 1 30); do
  migrating=$(ceph pg ls-by-pool "$TARGET_POOL" 2>/dev/null | grep -c "migrating" || true)
  if [ "$migrating" -gt 0 ]; then
    echo "Migration active - target PG is in 'migrating' state"
    break
  fi
  sleep 1
done
echo ""

# --- Trigger TooFull to suspend migration ---
echo "--- Triggering TooFull to suspend migration ---"
echo "Setting full ratio very low to force TooFull..."
ceph osd set-nearfull-ratio 0.001
ceph osd set-backfillfull-ratio 0.001
ceph osd set-full-ratio 0.002

echo "Waiting up to 30s for migration to suspend..."
suspended=false
for i in $(seq 1 30); do
  migrating=$(ceph pg ls-by-pool "$TARGET_POOL" 2>/dev/null | grep -c "migrating" || true)
  if [ "$migrating" -eq 0 ]; then
    suspended=true
    echo "Migration suspended after ${i}s"
    break
  fi
  sleep 1
done
echo ""

# --- Check result ---
echo "--- Checking target PG state ---"
ceph pg ls-by-pool "$TARGET_POOL"
echo ""

if [ "$suspended" = true ]; then
  echo "PASS: Target PG released its reservation - 'migrating' is gone while suspended"
else
  echo "FAIL: Target PG is still showing 'migrating' after migration should have suspended"
  echo "      This indicates the reservation was NOT released (Bug 2 not fixed)"
  exit 1
fi
echo ""

# --- Restore ratios and confirm migration resumes ---
echo "--- Restoring full ratios so migration can resume ---"
ceph osd set-nearfull-ratio 0.85
ceph osd set-backfillfull-ratio 0.90
ceph osd set-full-ratio 0.95

echo "Waiting up to ${RETRY_INTERVAL}s for migration to resume..."
resumed=false
for i in $(seq 1 $RETRY_INTERVAL); do
  migrating=$(ceph pg ls-by-pool "$TARGET_POOL" 2>/dev/null | grep -c "migrating" || true)
  if [ "$migrating" -gt 0 ]; then
    resumed=true
    echo "Migration resumed after ${i}s"
    break
  fi
  sleep 1
done

if [ "$resumed" = true ]; then
  echo "PASS: Migration resumed correctly after retry interval"
else
  echo "WARN: Migration did not resume within ${RETRY_INTERVAL}s - check cluster health"
fi
echo ""

echo "=== Test complete ==="
