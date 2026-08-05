# Pool Migration Test Scripts

A set of bash scripts to help set up and test Ceph pool migrations between different pool types (replicated ↔ erasure-coded).

## Overview

These scripts simplify the process of testing pool migrations in a Ceph development environment. They handle pool creation, data population, migration setup, and progress monitoring.

### Scripts Included

1. **`setup-source-pool.sh`** - Creates and populates a source pool with test data
2. **`setup-target-pool.sh`** - Creates target pool and initiates migration
3. **`check-migration-status.sh`** - Monitors migration progress
4. **`migration-helpers.sh`** - Shared helper functions (sourced by other scripts)

## Prerequisites

- Ceph cluster running via `vstart.sh` (e.g., `MON=2 OSD=5 MGR=1`)
- Run scripts from the `build/` directory
- Min compat client set to `umbrella` or later (required for pool migration)

```bash
# Set min compat client if not already set
ceph osd set-require-min-compat-client umbrella
```

## Supported Migration Types

✅ **Replicated → Replicated** (rep → rep)  
✅ **Erasure-Coded → Erasure-Coded** (ec → ec)  
✅ **Replicated → Erasure-Coded** (rep → ec)  
✅ **Erasure-Coded → Replicated** (ec → rep)

## Quick Start

### Basic Workflow

```bash
# 1. Start your cluster (if not already running)
./restart_cluster.sh

# 2. Create a replicated source pool with test data
./setup-source-pool.sh --pool-type rep --pool-name mypool

# 3. Preview migration to EC pool (dry-run)
./setup-target-pool.sh --source-pool mypool --target-type ec --dry-run

# 4. Execute the migration
./setup-target-pool.sh --source-pool mypool --target-type ec --execute

# 5. Monitor migration progress
./check-migration-status.sh --source-pool mypool --watch
```

## Detailed Usage

### 1. Creating Source Pools

#### Replicated Pool with Default Settings

```bash
./setup-source-pool.sh \
    --pool-type rep \
    --pool-name test-rep-pool
```

This creates:
- Replicated pool with size=3
- 32 PGs
- Populated with test data using `rados bench` (30 seconds)

#### Replicated Pool with Custom Configuration

```bash
./setup-source-pool.sh \
    --pool-type rep \
    --pool-name custom-rep-pool \
    --size 2 \
    --pg-num 64 \
    --populate-method put \
    --object-count 200 \
    --object-size 1M \
    --object-prefix mydata
```

#### Erasure-Coded Pool

```bash
./setup-source-pool.sh \
    --pool-type ec \
    --pool-name test-ec-pool \
    --ec-k 2 \
    --ec-m 1 \
    --pg-num 32 \
    --bench-duration 60
```

#### Empty Pool (No Data)

```bash
./setup-source-pool.sh \
    --pool-type rep \
    --pool-name empty-pool \
    --no-populate
```

### 2. Setting Up Migration

#### Preview Migration (Dry-Run)

```bash
./setup-target-pool.sh \
    --source-pool test-rep-pool \
    --target-type ec \
    --dry-run
```

This shows:
- Source and target pool configurations
- Commands that will be executed
- Migration type
- No actual changes are made

#### Execute Migration

```bash
./setup-target-pool.sh \
    --source-pool test-rep-pool \
    --target-type ec \
    --execute
```

With confirmation prompt (default):
```bash
./setup-target-pool.sh \
    --source-pool test-rep-pool \
    --target-type ec \
    --execute
# Will prompt: "Do you want to proceed with migration setup? [y/N]:"
```

Skip confirmation:
```bash
./setup-target-pool.sh \
    --source-pool test-rep-pool \
    --target-type ec \
    --execute \
    --auto-confirm
```

#### Custom Target Pool Configuration

```bash
./setup-target-pool.sh \
    --source-pool test-rep-pool \
    --target-pool my-custom-target \
    --target-type ec \
    --ec-k 3 \
    --ec-m 2 \
    --pg-num 64 \
    --execute
```

### 3. Monitoring Migration

#### Single Status Check

```bash
./check-migration-status.sh --source-pool test-rep-pool
```

#### Continuous Monitoring (Watch Mode)

```bash
./check-migration-status.sh \
    --source-pool test-rep-pool \
    --watch
```

With custom refresh interval:
```bash
./check-migration-status.sh \
    --source-pool test-rep-pool \
    --watch \
    --interval 10
```

With verbose PG details:
```bash
./check-migration-status.sh \
    --source-pool test-rep-pool \
    --verbose
```

## Complete Examples

### Example 1: Replicated → Replicated Migration

```bash
# Create source pool (size=3)
./setup-source-pool.sh \
    --pool-type rep \
    --pool-name rep-source \
    --size 3 \
    --object-count 100

# Migrate to different size (size=2)
./setup-target-pool.sh \
    --source-pool rep-source \
    --target-type rep \
    --size 2 \
    --execute

# Monitor
./check-migration-status.sh \
    --source-pool rep-source \
    --watch
```

### Example 2: Erasure-Coded → Erasure-Coded Migration

```bash
# Create EC source pool (k=2, m=1)
./setup-source-pool.sh \
    --pool-type ec \
    --pool-name ec-source \
    --ec-k 2 \
    --ec-m 1 \
    --bench-duration 60

# Migrate to different EC profile (k=3, m=2)
./setup-target-pool.sh \
    --source-pool ec-source \
    --target-type ec \
    --ec-k 3 \
    --ec-m 2 \
    --execute

# Monitor
./check-migration-status.sh \
    --source-pool ec-source \
    --watch
```

### Example 3: Replicated → Erasure-Coded Migration

```bash
# Create replicated source
./setup-source-pool.sh \
    --pool-type rep \
    --pool-name rep-to-ec \
    --size 3 \
    --populate-method put \
    --object-count 50

# Migrate to EC pool
./setup-target-pool.sh \
    --source-pool rep-to-ec \
    --target-type ec \
    --ec-k 2 \
    --ec-m 1 \
    --execute

# Monitor
./check-migration-status.sh \
    --source-pool rep-to-ec \
    --watch
```

### Example 4: Erasure-Coded → Replicated Migration

```bash
# Create EC source
./setup-source-pool.sh \
    --pool-type ec \
    --pool-name ec-to-rep \
    --ec-k 2 \
    --ec-m 1

# Migrate to replicated pool
./setup-target-pool.sh \
    --source-pool ec-to-rep \
    --target-type rep \
    --size 3 \
    --execute

# Monitor
./check-migration-status.sh \
    --source-pool ec-to-rep \
    --watch
```

## Script Options Reference

### setup-source-pool.sh

```
Required:
  --pool-type <rep|ec>           Pool type

Pool Configuration:
  --pool-name <name>             Pool name (default: migration-source-pool)
  --pg-num <num>                 PG count (default: 32)
  --pgp-num <num>                PGP count (default: same as pg-num)

Replicated Options:
  --size <num>                   Replication size (default: 3)
  --min-size <num>               Min size (default: size-1)

EC Options:
  --ec-profile <name>            EC profile name (auto-generated)
  --ec-k <num>                   Data chunks (default: 2)
  --ec-m <num>                   Coding chunks (default: 1)
  --ec-plugin <name>             Plugin (default: jerasure)
  --no-ec-overwrites             Disable EC overwrites

Data Population:
  --populate-method <bench|put>  Method (default: bench)
  --object-count <num>           Objects for 'put' (default: 100)
  --object-size <size>           Object size (default: 4M)
  --object-prefix <prefix>       Prefix (default: test-obj)
  --bench-duration <sec>         Bench duration (default: 30)
  --bench-threads <num>          Bench threads (default: 4)
  --no-populate                  Skip data population

Other:
  --verbose                      Verbose output
  --help                         Show help
```

### setup-target-pool.sh

```
Required:
  --source-pool <name>           Source pool name
  --target-type <rep|ec>         Target pool type

Target Configuration:
  --target-pool <name>           Target name (default: <source>-migrated)
  --pg-num <num>                 PG count (auto-calculated)
  --pgp-num <num>                PGP count (default: same as pg-num)

Replicated Options:
  --size <num>                   Replication size (default: 3)
  --min-size <num>               Min size (default: size-1)

EC Options:
  --ec-profile <name>            EC profile name (auto-generated)
  --ec-k <num>                   Data chunks (default: 2)
  --ec-m <num>                   Coding chunks (default: 1)
  --ec-plugin <name>             Plugin (default: jerasure)

Execution:
  --dry-run                      Preview only (default)
  --execute                      Execute migration
  --auto-confirm                 Skip confirmation
  --verbose                      Verbose output
  --help                         Show help
```

### check-migration-status.sh

```
Required:
  --source-pool <name>           Source pool name

Optional:
  --target-pool <name>           Target pool (auto-detected)
  --watch                        Continuous monitoring
  --interval <sec>               Refresh interval (default: 5)
  --verbose                      Detailed PG info
  --help                         Show help
```

## Configuration Files

Scripts save pool configurations to `.pool-migration-config/` directory:

```
build/.pool-migration-config/
├── pool-name-1.conf
├── pool-name-2.conf
└── ...
```

These files store:
- Pool name and type
- PG count
- Size/EC parameters
- Object count
- Creation timestamp

## Troubleshooting

### Migration Not Starting

**Problem**: Target pool created but migration not progressing

**Solutions**:
1. Check min compat client:
   ```bash
   ceph osd dump | grep require_min_compat_client
   ```
2. Set to umbrella if needed:
   ```bash
   ceph osd set-require-min-compat-client umbrella
   ```

### Pool Already Exists

**Problem**: "Pool already exists" error

**Solutions**:
1. Choose a different name:
   ```bash
   --pool-name different-name
   ```
2. Or delete existing pool:
   ```bash
   ceph osd pool delete pool-name pool-name --yes-i-really-really-mean-it
   ```

### Cluster Not Running

**Problem**: "Ceph cluster not found" error

**Solutions**:
1. Start cluster:
   ```bash
   ./restart_cluster.sh
   ```
2. Verify you're in build/ directory:
   ```bash
   pwd  # Should show /work/ceph/build
   ```

### PGs Not Active

**Problem**: PGs stuck in creating/peering state

**Solutions**:
1. Wait a bit longer (can take 30-60 seconds)
2. Check OSD status:
   ```bash
   ceph osd tree
   ceph -s
   ```
3. Check for errors:
   ```bash
   ceph health detail
   ```

## Tips and Best Practices

### Testing Different Scenarios

1. **Start small**: Use small object counts for initial testing
   ```bash
   --object-count 10
   ```

2. **Use dry-run first**: Always preview before executing
   ```bash
   --dry-run
   ```

3. **Monitor actively**: Use watch mode during migration
   ```bash
   --watch
   ```

### Performance Considerations

1. **Bench vs Put**: 
   - `rados bench` is faster for large datasets
   - `rados put` gives more control over object names

2. **PG Count**: 
   - More PGs = better distribution but more overhead
   - Default 32 is good for testing

3. **Object Size**:
   - Larger objects = faster population but less granular progress
   - 4M is a good balance for testing

### Cleanup

Remove test pools when done:
```bash
# Delete pools
ceph osd pool delete source-pool source-pool --yes-i-really-really-mean-it
ceph osd pool delete target-pool target-pool --yes-i-really-really-mean-it

# Clean up config files
rm -rf .pool-migration-config/
```

## Integration with Existing Workflow

These scripts integrate seamlessly with your existing cluster setup:

```bash
# Your existing workflow
./restart_cluster.sh
./re_setup_cluster.sh

# Add migration testing
./setup-source-pool.sh --pool-type rep --pool-name test1
./setup-target-pool.sh --source-pool test1 --target-type ec --execute
./check-migration-status.sh --source-pool test1 --watch
```

## Additional Resources

- [Ceph Pool Operations Documentation](../../doc/rados/operations/pools.rst)
- [Pool Migration Test Code](../../src/test/librados/list.cc)
- [OSD Monitor Migration Code](../../src/mon/OSDMonitor.cc)

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review Ceph logs: `build/out/mon.*.log`, `build/out/osd.*.log`
3. Check cluster status: `ceph -s`, `ceph health detail`

## License

These scripts are part of the Ceph project and follow the same license.