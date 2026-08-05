# Pool Migration Testing Guide

This guide provides specific examples for testing the scenarios mentioned in your requirements:
- Replica → EC
- Classic EC → Fast EC  
- EC → EC with different profiles (K, M, stripe_unit)
- Testing with 1 PG and mixed RADOS operations

## Prerequisites

```bash
# Ensure cluster is running
./restart_cluster.sh

# Verify min compat client is set
ceph osd set-require-min-compat-client umbrella
```

## Test Scenario 1: Replica → EC Migration

### Test with 1 PG and Mixed RADOS Ops

```bash
# Create replicated source pool with 1 PG
./setup-source-pool.sh \
    --pool-type rep \
    --pool-name rep-to-ec-test \
    --pg-num 1 \
    --size 3 \
    --bench-duration 60 \
    --bench-threads 4

# Migrate to EC pool
./setup-target-pool.sh \
    --source-pool rep-to-ec-test \
    --target-type ec \
    --ec-k 2 \
    --ec-m 1 \
    --pg-num 1 \
    --execute

# Monitor migration
./check-migration-status.sh \
    --source-pool rep-to-ec-test \
    --watch
```

## Test Scenario 2: Classic EC → Fast EC Migration

Classic EC has `allow_ec_overwrites=false`, Fast EC has `allow_ec_overwrites=true`.

```bash
# Create Classic EC pool (overwrites disabled)
./setup-source-pool.sh \
    --pool-type ec \
    --pool-name classic-ec-pool \
    --pg-num 1 \
    --ec-k 2 \
    --ec-m 1 \
    --no-ec-overwrites \
    --bench-duration 60

# Migrate to Fast EC pool (overwrites enabled, default)
./setup-target-pool.sh \
    --source-pool classic-ec-pool \
    --target-type ec \
    --ec-k 2 \
    --ec-m 1 \
    --pg-num 1 \
    --execute

# Monitor
./check-migration-status.sh \
    --source-pool classic-ec-pool \
    --watch
```

**Note**: The target pool will have `allow_ec_overwrites=true` by default (Fast EC mode).

## Test Scenario 3: EC → EC with Different K Values

```bash
# Create source EC pool with k=2, m=1
./setup-source-pool.sh \
    --pool-type ec \
    --pool-name ec-k2m1 \
    --pg-num 1 \
    --ec-k 2 \
    --ec-m 1 \
    --bench-duration 60

# Migrate to EC pool with k=3, m=2
./setup-target-pool.sh \
    --source-pool ec-k2m1 \
    --target-type ec \
    --ec-k 3 \
    --ec-m 2 \
    --pg-num 1 \
    --execute

# Monitor
./check-migration-status.sh \
    --source-pool ec-k2m1 \
    --watch
```

## Test Scenario 4: EC → EC with Different stripe_unit

```bash
# Create source EC pool with 4K stripe unit
./setup-source-pool.sh \
    --pool-type ec \
    --pool-name ec-stripe-4k \
    --pg-num 1 \
    --ec-k 2 \
    --ec-m 1 \
    --ec-stripe-unit 4K \
    --bench-duration 60

# Migrate to EC pool with 8K stripe unit
./setup-target-pool.sh \
    --source-pool ec-stripe-4k \
    --target-type ec \
    --ec-k 2 \
    --ec-m 1 \
    --ec-stripe-unit 8K \
    --pg-num 1 \
    --execute

# Monitor
./check-migration-status.sh \
    --source-pool ec-stripe-4k \
    --watch
```

## Test Scenario 5: EC → EC Changing K, M, and stripe_unit

```bash
# Create source: k=2, m=1, stripe_unit=4K
./setup-source-pool.sh \
    --pool-type ec \
    --pool-name ec-complex-source \
    --pg-num 1 \
    --ec-k 2 \
    --ec-m 1 \
    --ec-stripe-unit 4K \
    --bench-duration 60

# Migrate to: k=3, m=2, stripe_unit=8K
./setup-target-pool.sh \
    --source-pool ec-complex-source \
    --target-type ec \
    --ec-k 3 \
    --ec-m 2 \
    --ec-stripe-unit 8K \
    --pg-num 1 \
    --execute

# Monitor
./check-migration-status.sh \
    --source-pool ec-complex-source \
    --watch
```

## Test Scenario 6: Fast EC → Classic EC

```bash
# Create Fast EC pool (overwrites enabled, default)
./setup-source-pool.sh \
    --pool-type ec \
    --pool-name fast-ec-pool \
    --pg-num 1 \
    --ec-k 2 \
    --ec-m 1 \
    --bench-duration 60

# Migrate to Classic EC pool (overwrites disabled)
./setup-target-pool.sh \
    --source-pool fast-ec-pool \
    --target-type ec \
    --ec-k 2 \
    --ec-m 1 \
    --no-ec-overwrites \
    --pg-num 1 \
    --execute

# Monitor
./check-migration-status.sh \
    --source-pool fast-ec-pool \
    --watch
```

## Comprehensive Test Matrix

Here's a complete test matrix covering all combinations:

### 1 PG Tests with Mixed RADOS Operations

| Test # | Source Type | Source Config | Target Type | Target Config | Command |
|--------|-------------|---------------|-------------|---------------|---------|
| 1 | Replicated | size=3 | EC | k=2,m=1 | See Scenario 1 |
| 2 | EC Classic | k=2,m=1,no-overwrites | EC Fast | k=2,m=1,overwrites | See Scenario 2 |
| 3 | EC | k=2,m=1 | EC | k=3,m=2 | See Scenario 3 |
| 4 | EC | k=2,m=1,stripe=4K | EC | k=2,m=1,stripe=8K | See Scenario 4 |
| 5 | EC | k=2,m=1,stripe=4K | EC | k=3,m=2,stripe=8K | See Scenario 5 |
| 6 | EC Fast | k=2,m=1,overwrites | EC Classic | k=2,m=1,no-overwrites | See Scenario 6 |

## Running Mixed RADOS Operations

The `rados bench` command (used by default with `--populate-method bench`) automatically generates a mixture of RADOS operations including:
- Write operations
- Object creation
- Metadata updates
- Various object sizes

For more control over the operation mix, you can manually run additional operations after pool creation:

```bash
# After creating the pool, run additional operations
POOL_NAME="your-pool-name"

# Write operations
rados -p $POOL_NAME bench 30 write --no-cleanup

# Read operations
rados -p $POOL_NAME bench 30 seq

# Random read operations  
rados -p $POOL_NAME bench 30 rand

# Create specific objects
for i in {1..100}; do
    echo "test data $i" | rados -p $POOL_NAME put test-obj-$i -
done

# List objects
rados -p $POOL_NAME ls

# Get object stats
rados -p $POOL_NAME stat test-obj-1
```

## Verification After Migration

After migration completes, verify data integrity:

```bash
SOURCE_POOL="source-pool-name"
TARGET_POOL="target-pool-name"

# Compare object counts
echo "Source objects:"
rados -p $SOURCE_POOL ls | wc -l

echo "Target objects:"
rados -p $TARGET_POOL ls | wc -l

# Verify specific objects
rados -p $SOURCE_POOL ls | head -10 | while read obj; do
    echo "Checking $obj..."
    rados -p $TARGET_POOL stat $obj
done

# Check pool statistics
ceph df | grep -E "$SOURCE_POOL|$TARGET_POOL"
```

## Monitoring During Migration

### Real-time Monitoring

```bash
# Watch migration progress
./check-migration-status.sh --source-pool <pool> --watch

# Or use ceph commands directly
watch -n 2 'ceph pg ls-by-pool <target-pool> | grep migrating'

# Monitor cluster health
watch -n 2 'ceph -s'
```

### Check PG States

```bash
# View PG states for target pool
ceph pg ls-by-pool <target-pool>

# Count migrating PGs
ceph pg ls-by-pool <target-pool> | grep -c migrating

# View detailed PG info
ceph pg dump | grep <target-pool>
```

## Troubleshooting

### Migration Not Progressing

```bash
# Check PG states
ceph pg ls-by-pool <target-pool>

# Check OSD status
ceph osd tree
ceph osd stat

# Check for blocked operations
ceph health detail

# View migration-related logs
grep -i migration build/out/mon.*.log | tail -50
grep -i migration build/out/osd.*.log | tail -50
```

### Performance Issues

```bash
# Check OSD performance
ceph osd perf

# Check slow operations
ceph daemon osd.0 dump_ops_in_flight

# Monitor bandwidth
ceph osd pool stats <pool-name>
```

## Cleanup After Testing

```bash
# Delete test pools
SOURCE_POOL="your-source-pool"
TARGET_POOL="your-target-pool"

ceph osd pool delete $SOURCE_POOL $SOURCE_POOL --yes-i-really-really-mean-it
ceph osd pool delete $TARGET_POOL $TARGET_POOL --yes-i-really-really-mean-it

# Clean up configuration files
rm -rf .pool-migration-config/

# Verify cleanup
ceph osd pool ls
```

## Quick Reference Commands

```bash
# Create 1 PG replicated pool with mixed ops
./setup-source-pool.sh --pool-type rep --pool-name test1 --pg-num 1 --bench-duration 60

# Create 1 PG EC pool with custom config
./setup-source-pool.sh --pool-type ec --pool-name test2 --pg-num 1 --ec-k 2 --ec-m 1 --ec-stripe-unit 4K

# Preview migration
./setup-target-pool.sh --source-pool test1 --target-type ec --pg-num 1 --dry-run

# Execute migration
./setup-target-pool.sh --source-pool test1 --target-type ec --pg-num 1 --execute

# Monitor
./check-migration-status.sh --source-pool test1 --watch
```

## Notes

1. **1 PG Testing**: Using `--pg-num 1` is recommended for focused testing as mentioned in your requirements
2. **Mixed RADOS Ops**: The `rados bench` command provides a good mixture of operations by default
3. **stripe_unit**: Now fully supported via `--ec-stripe-unit` parameter
4. **Fast vs Classic EC**: Controlled via `--no-ec-overwrites` flag (Fast EC is default)
5. **Monitoring**: Use `--watch` mode for continuous monitoring during migration

## Expected Behavior

- Migration starts automatically when target pool is created with `--migrate-from-pool`
- Objects are copied from source to target pool
- Source pool objects are deleted after successful copy
- PG states will show "migrating" during the process
- Migration completes when all objects are transferred
- Both pools remain accessible during migration (source for reads, target for new writes)