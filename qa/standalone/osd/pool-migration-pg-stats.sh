#!/usr/bin/env bash
#
# Copyright (C) 2025 IBM <contact@ibm.com>
#
# Author: Tom Sollers <tom.sollers@ibm.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU Library Public License as published by
# the Free Software Foundation; either version 2, or (at your option)
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Library Public License for more details.
#
# Test that pool migration preserves PG stats and "ceph df" numbers.
#
# The scenario:
#   1. Create a source pool and write objects, take snapshots, delete
#      objects (creating whiteouts), and verify snaptrim completes.
#   2. Capture the aggregate pool-level stats (object counts, bytes used,
#      clones, whiteouts) reported by both "ceph df" and "pg dump".
#   3. Create a target pool with --migrate-from-pool to start migration.
#   4. Wait for migration to complete fully (all PGs active+clean).
#   5. Assert the same aggregate stats are reported for the target pool.
#

source $CEPH_ROOT/qa/standalone/ceph-helpers.sh

function run() {
    local dir=$1
    shift

    export CEPH_MON="127.0.0.1:7148" # git grep '\<7148\>' : there must be only one
    export CEPH_ARGS
    CEPH_ARGS+="--fsid=$(uuidgen) --auth-supported=none "
    CEPH_ARGS+="--mon-host=$CEPH_MON "

    local funcs=${@:-$(set | sed -n -e 's/^\(TEST_[0-9a-z_]*\) .*/\1/p')}
    for func in $funcs ; do
        setup $dir || return 1
        $func $dir || return 1
        teardown $dir || return 1
    done
}

##
# Sum a numeric field across all PGs belonging to a given pool.
#
# @param pool_id  numeric pool id
# @param jq_field jq path under each pg_stats entry, e.g. '.stat_sum.num_objects'
# @return 0 on success, prints sum to stdout
##
function pool_pg_stat_sum() {
    local pool_id=$1
    local jq_field=$2
    ceph --format json pg dump pgs 2>/dev/null | \
        jq "[.pg_stats[] | select(.pgid | startswith(\"${pool_id}.\")) | ${jq_field}] | add // 0"
}

function pool_object_count() {
    local pool=$1
    rados -p "$pool" ls 2>/dev/null | wc -l
}

function pool_snapshot_count() {
    local pool=$1
    rados -p "$pool" lssnap 2>/dev/null | awk 'NR > 1 {count++} END {print count+0}'
}

function dump_pool_pg_stats() {
    local pool_id=$1
    local label=$2
    echo "[TEST] ${label}: per-PG stats for pool id=${pool_id}"
    ceph --format json pg dump pgs 2>/dev/null | jq -r \
        ".pg_stats[] | select(.pgid | startswith(\"${pool_id}.\")) | [
            .pgid,
            .state,
            (.stat_sum.num_objects // 0),
            (.stat_sum.num_bytes // 0),
            (.stat_sum.num_object_clones // 0),
            (.stat_sum.num_whiteouts // 0)
        ] | @tsv" | \
        while IFS=$'\t' read -r pgid state num_objects num_bytes num_clones num_whiteouts; do
            echo "[TEST]   pg=${pgid} state=${state} objects=${num_objects} bytes=${num_bytes} clones=${num_clones} whiteouts=${num_whiteouts}"
        done
}

function dump_pool_rados_listing() {
    local pool=$1
    local label=$2
    echo "[TEST] ${label}: object listing for pool ${pool}"
    local count=0
    while IFS= read -r obj; do
        [ -n "$obj" ] || continue
        echo "[TEST]   obj=${obj}"
        count=$((count + 1))
    done < <(rados -p "$pool" ls 2>/dev/null | sort)
    echo "[TEST]   total_listed_objects=${count}"
}

function dump_pool_snapshots() {
    local pool=$1
    local label=$2
    echo "[TEST] ${label}: snapshots for pool ${pool}"
    local out
    out=$(rados -p "$pool" lssnap 2>&1) || true
    while IFS= read -r line; do
        echo "[TEST]   ${line}"
    done <<< "$out"
}

function dump_pool_diagnostics() {
    local pool=$1
    local pool_id=$2
    local label=$3

    echo "[TEST] ===== ${label} diagnostics for pool ${pool} (id=${pool_id}) ====="
    echo "[TEST]   aggregate_pg_num_objects=$(pool_pg_stat_sum "$pool_id" ".stat_sum.num_objects")"
    echo "[TEST]   aggregate_pg_num_bytes=$(pool_pg_stat_sum "$pool_id" ".stat_sum.num_bytes")"
    echo "[TEST]   aggregate_pg_num_object_clones=$(pool_pg_stat_sum "$pool_id" ".stat_sum.num_object_clones")"
    echo "[TEST]   aggregate_pg_num_whiteouts=$(pool_pg_stat_sum "$pool_id" ".stat_sum.num_whiteouts")"
    echo "[TEST]   rados_ls_count=$(pool_object_count "$pool")"
    echo "[TEST]   snapshot_count=$(pool_snapshot_count "$pool")"
    echo "[TEST]   ceph_df_bytes_used=$(ceph df --format json | jq ".pools[] | select(.name==\"${pool}\") | .stats.bytes_used")"
    dump_pool_pg_stats "$pool_id" "$label"
    dump_pool_rados_listing "$pool" "$label"
    dump_pool_snapshots "$pool" "$label"
    echo "[TEST] ===== end ${label} diagnostics ====="
}

# Migration can take longer than the default WAIT_FOR_CLEAN_TIMEOUT; give it
# at least 5 minutes.
MIGRATION_TIMEOUT=${MIGRATION_TIMEOUT:-300}

##
# Wait until all PGs in the cluster are active+clean (no migrating states).
# Uses a simple polling loop with a configurable timeout.
#
# @param timeout  seconds to wait (default: $MIGRATION_TIMEOUT)
# @return 0 if clean, 1 on timeout
##
function wait_for_migration_complete() {
    local src_pool=$1
    local tgt_pool=$2
    local src_pool_id=$3
    local tgt_pool_id=$4
    local timeout=${5:-$MIGRATION_TIMEOUT}
    local -i loop=0
    local stable_loops=0

    echo "Waiting for pool migration to complete (timeout ${timeout}s)..."
    while true; do
        flush_pg_stats || return 1

        local migrating
        migrating=$(ceph --format json pg dump pgs 2>/dev/null | \
            jq '[.pg_stats[] | select(
                (.state | contains("migrating")) or
                (.state | contains("migration_wait")) or
                (.state | contains("migration_toofull"))
            )] | length')

        local src_objects tgt_objects src_ls tgt_ls
        src_objects=$(pool_pg_stat_sum "$src_pool_id" ".stat_sum.num_objects")
        tgt_objects=$(pool_pg_stat_sum "$tgt_pool_id" ".stat_sum.num_objects")
        src_ls=$(pool_object_count "$src_pool")
        tgt_ls=$(pool_object_count "$tgt_pool")

        echo "[TEST]   loop=${loop} migrating_pgs=${migrating} src_pg_objects=${src_objects} tgt_pg_objects=${tgt_objects} src_ls=${src_ls} tgt_ls=${tgt_ls}"

        if [ "$migrating" = "0" ]; then
            stable_loops=$((stable_loops + 1))
            if [ "$stable_loops" -ge 2 ]; then
                echo "Migration complete: no PGs in migration state for two consecutive checks"
                return 0
            fi
        else
            stable_loops=0
        fi

        sleep 2
        loop=$((loop + 1))
        if [ $loop -gt $((timeout / 2)) ]; then
            echo "Timeout waiting for migration to complete"
            dump_pool_diagnostics "$src_pool" "$src_pool_id" "timeout-source"
            dump_pool_diagnostics "$tgt_pool" "$tgt_pool_id" "timeout-target"
            ceph report
            return 1
        fi
    done
}

##
# TEST: replicated → replicated pool migration preserves PG stats.
#
# Creates objects, snapshots, and deletes (whiteouts) in a replicated source
# pool, records the aggregate stats, migrates to a new replicated pool, and
# asserts the stats are preserved on the target.
##
function TEST_rep_to_rep_pg_stats_preserved() {
    local dir=$1
    local OSDS=3
    local PGNUM=4
    local src_pool="migration-src"
    local tgt_pool="migration-tgt"
    local objects=10

    # ------------------------------------------------------------------ setup
    run_mon $dir a --osd_pool_default_size=$OSDS || return 1
    run_mgr $dir x || return 1
    for osd in $(seq 0 $((OSDS - 1))); do
        run_osd $dir $osd || return 1
    done

    # pool migration is an experimental feature
    ceph config set global enable_experimental_unrecoverable_data_corrupting_features \
        poolmigration || return 1
    # require umbrella client for pool migration
    ceph osd set-require-min-compat-client umbrella --yes-i-really-mean-it || return 1

    # disable scrubs to keep stats stable during the test
    ceph osd set noscrub     || return 1
    ceph osd set nodeep-scrub || return 1

    # ------------------------------------------------------- create source pool
    create_pool $src_pool $PGNUM $PGNUM replicated || return 1
    ceph osd pool application enable $src_pool rados || return 1
    wait_for_clean || return 1

    local src_pool_id
    src_pool_id=$(ceph osd dump --format json | \
        jq -r ".pools[] | select(.pool_name==\"${src_pool}\") | .pool")

    # ------------------------------------------- write initial set of objects
    local testdata="$dir/testdata"
    dd if=/dev/urandom of="$testdata" bs=4096 count=4 2>/dev/null

    for i in $(seq 1 $objects); do
        rados -p $src_pool put obj${i} "$testdata" || return 1
    done

    # ---------------------------------------------- take a snapshot (clones)
    rados -p $src_pool mksnap snap1 || return 1

    # overwrite all objects so each head object now has a clone under snap1
    local testdata2="$dir/testdata2"
    dd if=/dev/urandom of="$testdata2" bs=4096 count=4 2>/dev/null
    for i in $(seq 1 $objects); do
        rados -p $src_pool put obj${i} "$testdata2" || return 1
    done

    # ---------------------------------------------- delete half the objects
    # Deleting a head object while a snapshot clone exists creates a whiteout.
    for i in $(seq 1 $((objects / 2))); do
        rados -p $src_pool rm obj${i} || return 1
    done

    # Let stats settle and snaptrim queue drain
    wait_for_clean || return 1
    flush_pg_stats  || return 1

    # -------------------------------- capture pre-migration aggregate stats
    local pre_num_objects
    local pre_num_bytes
    local pre_num_object_clones
    local pre_num_whiteouts

    pre_num_objects=$(pool_pg_stat_sum "$src_pool_id" ".stat_sum.num_objects")
    pre_num_bytes=$(pool_pg_stat_sum "$src_pool_id" ".stat_sum.num_bytes")
    pre_num_object_clones=$(pool_pg_stat_sum "$src_pool_id" ".stat_sum.num_object_clones")
    pre_num_whiteouts=$(pool_pg_stat_sum "$src_pool_id" ".stat_sum.num_whiteouts")

    echo "Pre-migration stats for pool ${src_pool} (id=${src_pool_id}):"
    echo "  num_objects:       $pre_num_objects"
    echo "  num_bytes:         $pre_num_bytes"
    echo "  num_object_clones: $pre_num_object_clones"
    echo "  num_whiteouts:     $pre_num_whiteouts"

    # Sanity-check: we should have objects, clones, and whiteouts
    test "$pre_num_objects"       -gt 0 || { echo "ERROR: expected objects > 0";       return 1; }
    test "$pre_num_object_clones" -gt 0 || { echo "ERROR: expected clones > 0";         return 1; }
    test "$pre_num_whiteouts"     -gt 0 || { echo "ERROR: expected whiteouts > 0";      return 1; }

    # Also record the "ceph df" bytes_used for the source pool
    local pre_ceph_df_bytes_used
    pre_ceph_df_bytes_used=$(ceph df --format json | \
        jq ".pools[] | select(.name==\"${src_pool}\") | .stats.bytes_used")

    echo "  ceph df bytes_used: $pre_ceph_df_bytes_used"
    test "$pre_ceph_df_bytes_used" -gt 0 || { echo "ERROR: expected ceph df bytes_used > 0"; return 1; }

    # --------------------------------------------------- start pool migration
    # Create the target pool with --migrate-from-pool; migration starts automatically.
    create_pool $tgt_pool $PGNUM $PGNUM replicated --migrate-from-pool $src_pool || return 1
    ceph osd pool application enable $tgt_pool rados || return 1

    local tgt_pool_id
    tgt_pool_id=$(ceph osd dump --format json | \
        jq -r ".pools[] | select(.pool_name==\"${tgt_pool}\") | .pool")

    echo "Migration: ${src_pool} (${src_pool_id}) → ${tgt_pool} (${tgt_pool_id})"

    # ------------------------------------------- wait for migration to finish
    wait_for_migration_complete "$src_pool" "$tgt_pool" "$src_pool_id" "$tgt_pool_id" || return 1
    wait_for_clean || return 1
    flush_pg_stats  || return 1

    dump_pool_diagnostics "$src_pool" "$src_pool_id" "post-migration-source"
    dump_pool_diagnostics "$tgt_pool" "$tgt_pool_id" "post-migration-target"

    # -------------------------------- capture post-migration aggregate stats
    local post_num_objects
    local post_num_bytes
    local post_num_object_clones
    local post_num_whiteouts

    post_num_objects=$(pool_pg_stat_sum "$tgt_pool_id" ".stat_sum.num_objects")
    post_num_bytes=$(pool_pg_stat_sum "$tgt_pool_id" ".stat_sum.num_bytes")
    post_num_object_clones=$(pool_pg_stat_sum "$tgt_pool_id" ".stat_sum.num_object_clones")
    post_num_whiteouts=$(pool_pg_stat_sum "$tgt_pool_id" ".stat_sum.num_whiteouts")

    echo "Post-migration stats for pool ${tgt_pool} (id=${tgt_pool_id}):"
    echo "  num_objects:       $post_num_objects"
    echo "  num_bytes:         $post_num_bytes"
    echo "  num_object_clones: $post_num_object_clones"
    echo "  num_whiteouts:     $post_num_whiteouts"

    local post_ceph_df_bytes_used
    post_ceph_df_bytes_used=$(ceph df --format json | \
        jq ".pools[] | select(.name==\"${tgt_pool}\") | .stats.bytes_used")
    echo "  ceph df bytes_used: $post_ceph_df_bytes_used"

    # -------------------------------------------------------- assert equality
    echo "Comparing pre- and post-migration stats..."

    test "$post_num_objects"       = "$pre_num_objects" || {
        echo "FAIL: num_objects mismatch: pre=$pre_num_objects post=$post_num_objects"
        return 1
    }
    test "$post_num_bytes"         = "$pre_num_bytes" || {
        echo "FAIL: num_bytes mismatch: pre=$pre_num_bytes post=$post_num_bytes"
        return 1
    }
    test "$post_num_object_clones" = "$pre_num_object_clones" || {
        echo "FAIL: num_object_clones mismatch: pre=$pre_num_object_clones post=$post_num_object_clones"
        return 1
    }
    test "$post_num_whiteouts"     = "$pre_num_whiteouts" || {
        echo "FAIL: num_whiteouts mismatch: pre=$pre_num_whiteouts post=$post_num_whiteouts"
        return 1
    }
    test "$post_ceph_df_bytes_used" = "$pre_ceph_df_bytes_used" || {
        echo "FAIL: ceph df bytes_used mismatch: pre=$pre_ceph_df_bytes_used post=$post_ceph_df_bytes_used"
        return 1
    }

    echo "PASS: all stats match after pool migration"

    # Clean up pools explicitly so teardown is clean
    delete_pool $tgt_pool
    delete_pool $src_pool

    return 0
}

##
# TEST: replicated → replicated migration preserves stats after snap is removed
# post-migration (i.e. snaptrim on the target pool also works correctly).
##
function TEST_rep_to_rep_stats_after_snaptrim() {
    local dir=$1
    local OSDS=3
    local PGNUM=4
    local src_pool="migration-snaptrim-src"
    local tgt_pool="migration-snaptrim-tgt"
    local objects=8

    # ------------------------------------------------------------------ setup
    run_mon $dir a --osd_pool_default_size=$OSDS || return 1
    run_mgr $dir x || return 1
    for osd in $(seq 0 $((OSDS - 1))); do
        run_osd $dir $osd || return 1
    done

    ceph config set global enable_experimental_unrecoverable_data_corrupting_features \
        poolmigration || return 1
    ceph osd set-require-min-compat-client umbrella --yes-i-really-mean-it || return 1

    ceph osd set noscrub      || return 1
    ceph osd set nodeep-scrub || return 1

    # ------------------------------------------------------- create source pool
    create_pool $src_pool $PGNUM $PGNUM replicated || return 1
    ceph osd pool application enable $src_pool rados || return 1
    wait_for_clean || return 1

    local src_pool_id
    src_pool_id=$(ceph osd dump --format json | \
        jq -r ".pools[] | select(.pool_name==\"${src_pool}\") | .pool")

    # ------------------------------------------- write objects and snapshot
    local testdata="$dir/testdata"
    dd if=/dev/urandom of="$testdata" bs=4096 count=2 2>/dev/null
    for i in $(seq 1 $objects); do
        rados -p $src_pool put obj${i} "$testdata" || return 1
    done

    rados -p $src_pool mksnap snap1 || return 1

    local testdata2="$dir/testdata2"
    dd if=/dev/urandom of="$testdata2" bs=4096 count=2 2>/dev/null
    for i in $(seq 1 $objects); do
        rados -p $src_pool put obj${i} "$testdata2" || return 1
    done

    wait_for_clean  || return 1
    flush_pg_stats  || return 1

    # Capture pre-migration stats (snapshot still live)
    local pre_num_objects
    local pre_num_object_clones
    pre_num_objects=$(pool_pg_stat_sum "$src_pool_id" ".stat_sum.num_objects")
    pre_num_object_clones=$(pool_pg_stat_sum "$src_pool_id" ".stat_sum.num_object_clones")

    echo "Pre-migration (with live snapshot):"
    echo "  num_objects:       $pre_num_objects"
    echo "  num_object_clones: $pre_num_object_clones"
    test "$pre_num_object_clones" -gt 0 || { echo "ERROR: expected clones > 0"; return 1; }

    # ------------------------------------------------- migrate to target pool
    create_pool $tgt_pool $PGNUM $PGNUM replicated --migrate-from-pool $src_pool || return 1
    ceph osd pool application enable $tgt_pool rados || return 1

    local tgt_pool_id
    tgt_pool_id=$(ceph osd dump --format json | \
        jq -r ".pools[] | select(.pool_name==\"${tgt_pool}\") | .pool")

    wait_for_migration_complete "$src_pool" "$tgt_pool" "$src_pool_id" "$tgt_pool_id" || return 1
    wait_for_clean  || return 1
    flush_pg_stats  || return 1

    dump_pool_diagnostics "$src_pool" "$src_pool_id" "post-migration-source"
    dump_pool_diagnostics "$tgt_pool" "$tgt_pool_id" "post-migration-target"

    # Post-migration with snapshot still live: clones must be preserved
    local post_num_objects
    local post_num_object_clones
    post_num_objects=$(pool_pg_stat_sum "$tgt_pool_id" ".stat_sum.num_objects")
    post_num_object_clones=$(pool_pg_stat_sum "$tgt_pool_id" ".stat_sum.num_object_clones")

    echo "Post-migration (snapshot still live on target):"
    echo "  num_objects:       $post_num_objects"
    echo "  num_object_clones: $post_num_object_clones"

    test "$post_num_objects"       = "$pre_num_objects" || {
        echo "FAIL: num_objects mismatch after migration: pre=$pre_num_objects post=$post_num_objects"
        return 1
    }
    test "$post_num_object_clones" = "$pre_num_object_clones" || {
        echo "FAIL: num_object_clones mismatch after migration: pre=$pre_num_object_clones post=$post_num_object_clones"
        return 1
    }

    # ---- Now remove the snapshot on the target pool; snaptrim should run
    rados -p $tgt_pool rmsnap snap1 || return 1
    wait_for_clean  || return 1
    flush_pg_stats  || return 1

    local trimmed_num_objects
    local trimmed_num_object_clones
    trimmed_num_objects=$(pool_pg_stat_sum "$tgt_pool_id" ".stat_sum.num_objects")
    trimmed_num_object_clones=$(pool_pg_stat_sum "$tgt_pool_id" ".stat_sum.num_object_clones")

    echo "Post-snaptrim stats (target pool, snap removed):"
    echo "  num_objects:       $trimmed_num_objects"
    echo "  num_object_clones: $trimmed_num_object_clones"

    # After snaptrim: clones must be gone, head objects remain
    test "$trimmed_num_object_clones" = "0" || {
        echo "FAIL: expected num_object_clones=0 after snaptrim, got $trimmed_num_object_clones"
        return 1
    }
    test "$trimmed_num_objects" = "$objects" || {
        echo "FAIL: expected num_objects=$objects after snaptrim, got $trimmed_num_objects"
        return 1
    }

    echo "PASS: stats correct after snaptrim on migrated pool"

    delete_pool $tgt_pool
    delete_pool $src_pool

    return 0
}

##
# Helper: capture the full set of stats for a pool into a set of named
# variables.  All variables are echoed as "key=value" lines so callers can
# eval them.
#
# @param pool      pool name
# @param pool_id   numeric pool id
##
function capture_pool_stats() {
    local pool=$1
    local pool_id=$2

    flush_pg_stats || return 1

    local num_objects
    local num_bytes
    local num_object_clones
    local num_whiteouts
    local num_objects_dirty
    local df_bytes_used
    local df_objects

    num_objects=$(pool_pg_stat_sum "$pool_id" ".stat_sum.num_objects")
    num_bytes=$(pool_pg_stat_sum "$pool_id" ".stat_sum.num_bytes")
    num_object_clones=$(pool_pg_stat_sum "$pool_id" ".stat_sum.num_object_clones")
    num_whiteouts=$(pool_pg_stat_sum "$pool_id" ".stat_sum.num_whiteouts")
    num_objects_dirty=$(pool_pg_stat_sum "$pool_id" ".stat_sum.num_objects_dirty")
    df_bytes_used=$(ceph df --format json | \
        jq ".pools[] | select(.name==\"${pool}\") | .stats.bytes_used")
    df_objects=$(ceph df --format json | \
        jq ".pools[] | select(.name==\"${pool}\") | .stats.objects")

    echo "num_objects=${num_objects}"
    echo "num_bytes=${num_bytes}"
    echo "num_object_clones=${num_object_clones}"
    echo "num_whiteouts=${num_whiteouts}"
    echo "num_objects_dirty=${num_objects_dirty}"
    echo "df_bytes_used=${df_bytes_used}"
    echo "df_objects=${df_objects}"
}

##
# Helper: print a captured stats block with a label prefix.
##
function print_stats() {
    local label=$1
    shift
    echo "[TEST] ${label}:"
    for kv in "$@"; do
        echo "[TEST]   ${kv}"
    done
}

##
# TEST: full workload (writes, multiple snapshots, deletes → whiteouts) then
# pool migration, asserting PG stats and "ceph df" numbers are preserved.
#
# Scenario:
#   1.  Create a replicated source pool.
#   2.  Write a set of objects.
#   3.  Take snap1.  Overwrite all objects (creating clones under snap1).
#   4.  Take snap2.  Delete a subset of objects (whiteouts under snap1+snap2).
#   5.  Write a fresh batch of objects (no snapshot covering them).
#   6.  Flush stats; capture aggregate PG stats + ceph df for the source pool.
#   7.  Sanity-assert: objects > 0, clones > 0, whiteouts > 0.
#   8.  Create target pool with --migrate-from-pool; wait for completion.
#   9.  Flush stats; capture aggregate PG stats + ceph df for the target pool.
#  10.  Assert every stat captured in step 6 equals the stat in step 9.
##
function TEST_full_workload_pg_stats_preserved() {
    local dir=$1
    local OSDS=3
    local PGNUM=8
    local src_pool="mig-full-src"
    local tgt_pool="mig-full-tgt"
    local objects=16   # initial object count; must be even for the delete half

    # ------------------------------------------------------------------ setup
    run_mon $dir a --osd_pool_default_size=$OSDS || return 1
    run_mgr $dir x || return 1
    for osd in $(seq 0 $((OSDS - 1))); do
        run_osd $dir $osd || return 1
    done

    ceph config set global enable_experimental_unrecoverable_data_corrupting_features \
        poolmigration || return 1
    ceph osd set-require-min-compat-client umbrella --yes-i-really-mean-it || return 1

    # Disable scrubs to keep stats stable during the test
    ceph osd set noscrub      || return 1
    ceph osd set nodeep-scrub || return 1

    # ------------------------------------------------------- create source pool
    create_pool $src_pool $PGNUM $PGNUM replicated || return 1
    ceph osd pool application enable $src_pool rados || return 1
    wait_for_clean || return 1

    local src_pool_id
    src_pool_id=$(ceph osd dump --format json | \
        jq -r ".pools[] | select(.pool_name==\"${src_pool}\") | .pool")

    echo "[TEST] Source pool=${src_pool} id=${src_pool_id} pgnum=${PGNUM}"

    # ------------------------------------ phase 1: write initial set of objects
    local testdata="$dir/testdata-v1"
    dd if=/dev/urandom of="$testdata" bs=4096 count=4 2>/dev/null

    echo "[TEST] Phase 1: writing ${objects} objects"
    for i in $(seq 1 $objects); do
        rados -p $src_pool put obj${i} "$testdata" || return 1
    done

    # ----------------------------------------- phase 2: snap1, then overwrite
    echo "[TEST] Phase 2: mksnap snap1, overwrite all objects"
    rados -p $src_pool mksnap snap1 || return 1

    local testdata2="$dir/testdata-v2"
    dd if=/dev/urandom of="$testdata2" bs=4096 count=4 2>/dev/null
    for i in $(seq 1 $objects); do
        rados -p $src_pool put obj${i} "$testdata2" || return 1
    done

    # ----------------------------------------- phase 3: snap2, then delete half
    # Deleting a head object while snapshot clones exist creates whiteouts.
    echo "[TEST] Phase 3: mksnap snap2, delete first half of objects (creates whiteouts)"
    rados -p $src_pool mksnap snap2 || return 1

    local half=$((objects / 2))
    for i in $(seq 1 $half); do
        rados -p $src_pool rm obj${i} || return 1
    done

    # -------------------------------------- phase 4: fresh objects (no snapshot)
    echo "[TEST] Phase 4: write ${half} extra objects not covered by any snapshot"
    local testdata3="$dir/testdata-v3"
    dd if=/dev/urandom of="$testdata3" bs=4096 count=2 2>/dev/null
    for i in $(seq 1 $half); do
        rados -p $src_pool put extra${i} "$testdata3" || return 1
    done

    # Let any pending work settle
    wait_for_clean  || return 1
    flush_pg_stats  || return 1

    # --------------------------------------------------------- capture pre-stats
    echo "[TEST] Capturing pre-migration stats for ${src_pool}..."
    local pre_stats
    pre_stats=$(capture_pool_stats "$src_pool" "$src_pool_id") || return 1
    eval "$pre_stats"

    local pre_num_objects=$num_objects
    local pre_num_bytes=$num_bytes
    local pre_num_object_clones=$num_object_clones
    local pre_num_whiteouts=$num_whiteouts
    local pre_num_objects_dirty=$num_objects_dirty
    local pre_df_bytes_used=$df_bytes_used
    local pre_df_objects=$df_objects

    print_stats "Pre-migration (source pool=${src_pool})" \
        "num_objects=${pre_num_objects}" \
        "num_bytes=${pre_num_bytes}" \
        "num_object_clones=${pre_num_object_clones}" \
        "num_whiteouts=${pre_num_whiteouts}" \
        "num_objects_dirty=${pre_num_objects_dirty}" \
        "df_bytes_used=${pre_df_bytes_used}" \
        "df_objects=${pre_df_objects}"

    dump_pool_diagnostics "$src_pool" "$src_pool_id" "pre-migration-source"

    # Sanity assertions: must have objects, clones, and whiteouts for the test
    # to be meaningful.
    test "$pre_num_objects"       -gt 0 || { echo "ERROR: expected num_objects > 0";       return 1; }
    test "$pre_num_object_clones" -gt 0 || { echo "ERROR: expected num_object_clones > 0"; return 1; }
    test "$pre_num_whiteouts"     -gt 0 || { echo "ERROR: expected num_whiteouts > 0";     return 1; }
    test "$pre_df_bytes_used"     -gt 0 || { echo "ERROR: expected df bytes_used > 0";     return 1; }
    test "$pre_df_objects"        -gt 0 || { echo "ERROR: expected df objects > 0";        return 1; }

    # -------------------------------------------------------- start migration
    echo "[TEST] Starting pool migration ${src_pool} → ${tgt_pool}"
    create_pool $tgt_pool $PGNUM $PGNUM replicated --migrate-from-pool $src_pool || return 1
    ceph osd pool application enable $tgt_pool rados || return 1

    local tgt_pool_id
    tgt_pool_id=$(ceph osd dump --format json | \
        jq -r ".pools[] | select(.pool_name==\"${tgt_pool}\") | .pool")

    echo "[TEST] Target pool=${tgt_pool} id=${tgt_pool_id}"

    # -------------------------------------------- wait for migration to finish
    wait_for_migration_complete \
        "$src_pool" "$tgt_pool" "$src_pool_id" "$tgt_pool_id" || return 1
    wait_for_clean  || return 1
    flush_pg_stats  || return 1

    # -------------------------------------------------------- capture post-stats
    echo "[TEST] Capturing post-migration stats for ${tgt_pool}..."
    local post_stats
    post_stats=$(capture_pool_stats "$tgt_pool" "$tgt_pool_id") || return 1
    eval "$post_stats"

    local post_num_objects=$num_objects
    local post_num_bytes=$num_bytes
    local post_num_object_clones=$num_object_clones
    local post_num_whiteouts=$num_whiteouts
    local post_num_objects_dirty=$num_objects_dirty
    local post_df_bytes_used=$df_bytes_used
    local post_df_objects=$df_objects

    dump_pool_diagnostics "$src_pool"  "$src_pool_id"  "post-migration-source"
    dump_pool_diagnostics "$tgt_pool"  "$tgt_pool_id"  "post-migration-target"

    print_stats "Post-migration (target pool=${tgt_pool})" \
        "num_objects=${post_num_objects}" \
        "num_bytes=${post_num_bytes}" \
        "num_object_clones=${post_num_object_clones}" \
        "num_whiteouts=${post_num_whiteouts}" \
        "num_objects_dirty=${post_num_objects_dirty}" \
        "df_bytes_used=${post_df_bytes_used}" \
        "df_objects=${post_df_objects}"

    # ---------------------------------------------------------------- compare
    echo "[TEST] Comparing pre- and post-migration stats..."
    local failed=0

    if [ "$post_num_objects" != "$pre_num_objects" ]; then
        echo "FAIL: num_objects: pre=${pre_num_objects} post=${post_num_objects}"
        failed=1
    fi
    if [ "$post_num_bytes" != "$pre_num_bytes" ]; then
        echo "FAIL: num_bytes: pre=${pre_num_bytes} post=${post_num_bytes}"
        failed=1
    fi
    if [ "$post_num_object_clones" != "$pre_num_object_clones" ]; then
        echo "FAIL: num_object_clones: pre=${pre_num_object_clones} post=${post_num_object_clones}"
        failed=1
    fi
    if [ "$post_num_whiteouts" != "$pre_num_whiteouts" ]; then
        echo "FAIL: num_whiteouts: pre=${pre_num_whiteouts} post=${post_num_whiteouts}"
        failed=1
    fi
    if [ "$post_df_bytes_used" != "$pre_df_bytes_used" ]; then
        echo "FAIL: ceph df bytes_used: pre=${pre_df_bytes_used} post=${post_df_bytes_used}"
        failed=1
    fi
    if [ "$post_df_objects" != "$pre_df_objects" ]; then
        echo "FAIL: ceph df objects: pre=${pre_df_objects} post=${post_df_objects}"
        failed=1
    fi

    if [ "$failed" != "0" ]; then
        echo "[TEST] One or more stat comparisons FAILED"
        return 1
    fi

    echo "PASS: all PG stats and ceph df numbers match after full-workload pool migration"

    delete_pool $tgt_pool
    delete_pool $src_pool

    return 0
}

main pool-migration-pg-stats "$@"

# Local Variables:
# compile-command: "cd ../.. ; make -j4 && \
#   ../qa/standalone/osd/pool-migration-pg-stats.sh"
# End:
