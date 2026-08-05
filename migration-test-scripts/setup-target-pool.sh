#!/bin/bash
#
# setup-target-pool.sh - Create target pool and set up migration
#
# This script creates a target pool with --migrate-from-pool parameter,
# which initiates pool migration from the source pool.
#
# Usage: ./setup-target-pool.sh --source-pool <name> --target-type <rep|ec> [options]
#

set -e

# Source helper functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/migration-helpers.sh"

#
# Default values
#
SOURCE_POOL=""
TARGET_POOL=""
TARGET_TYPE=""
PG_NUM=""
PGP_NUM=""
SIZE=3
MIN_SIZE=""
EC_PROFILE=""
EC_K=2
EC_M=1
EC_PLUGIN="jerasure"
EC_STRIPE_UNIT=""
ALLOW_EC_OVERWRITES="true"
DRY_RUN=true
AUTO_CONFIRM=false
VERBOSE=false

#
# Usage function
#
usage() {
    cat << EOF
Usage: $0 --source-pool <name> --target-type <rep|ec> [OPTIONS]

Create target pool and set up migration from source pool.

Required Arguments:
  --source-pool <name>           Source pool name
  --target-type <rep|ec>         Target pool type: replicated (rep) or erasure-coded (ec)

Target Pool Configuration:
  --target-pool <name>           Target pool name (default: <source>-migrated)
  --pg-num <num>                 Target PG count (default: auto-calculate from source)
  --pgp-num <num>                Target PGP count (default: same as pg-num)

Replicated Target Options:
  --size <num>                   Replication size (default: 3)
  --min-size <num>               Min size (default: size-1)

Erasure-Coded Target Options:
  --ec-profile <name>            EC profile name (default: auto-generated)
  --ec-k <num>                   EC data chunks (default: 2)
  --ec-m <num>                   EC coding chunks (default: 1)
  --ec-plugin <name>             EC plugin (default: jerasure)
  --ec-stripe-unit <size>        EC stripe unit, e.g., 4K, 8K (default: Ceph default)
  --no-ec-overwrites             Disable EC overwrites (Fast EC disabled)
                                 Note: EC overwrites enabled by default (Fast EC mode)

Execution Options:
  --dry-run                      Show commands without executing (default)
  --execute                      Execute migration setup immediately
  --auto-confirm                 Skip confirmation prompt
  --verbose                      Verbose output
  --help                         Show this help message

Examples:
  # Preview migration from replicated to EC pool
  $0 --source-pool mypool --target-type ec --dry-run

  # Execute migration from replicated to EC pool
  $0 --source-pool mypool --target-type ec --execute

  # Migrate EC pool to replicated with custom size
  $0 --source-pool ecpool --target-type rep --size 2 --execute

EOF
    exit 0
}

#
# Parse command line arguments
#
while [[ $# -gt 0 ]]; do
    case $1 in
        --source-pool)
            SOURCE_POOL="$2"
            shift 2
            ;;
        --target-pool)
            TARGET_POOL="$2"
            shift 2
            ;;
        --target-type)
            TARGET_TYPE="$2"
            shift 2
            ;;
        --pg-num)
            PG_NUM="$2"
            shift 2
            ;;
        --pgp-num)
            PGP_NUM="$2"
            shift 2
            ;;
        --size)
            SIZE="$2"
            shift 2
            ;;
        --min-size)
            MIN_SIZE="$2"
            shift 2
            ;;
        --ec-profile)
            EC_PROFILE="$2"
            shift 2
            ;;
        --ec-k)
            EC_K="$2"
            shift 2
            ;;
        --ec-m)
            EC_M="$2"
            shift 2
            ;;
        --ec-plugin)
            EC_PLUGIN="$2"
            shift 2
            ;;
        --ec-stripe-unit)
            EC_STRIPE_UNIT="$2"
            shift 2
            ;;
        --no-ec-overwrites)
            ALLOW_EC_OVERWRITES="false"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --execute)
            DRY_RUN=false
            shift
            ;;
        --auto-confirm)
            AUTO_CONFIRM=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --help)
            usage
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

#
# Validation
#

if [ "$DRY_RUN" = true ]; then
    print_header "POOL MIGRATION SETUP - DRY RUN"
else
    print_header "POOL MIGRATION SETUP - EXECUTE"
fi

# Check required arguments
if [ -z "$SOURCE_POOL" ]; then
    print_error "Source pool is required. Use --source-pool <name>"
    exit 1
fi

if [ -z "$TARGET_TYPE" ]; then
    print_error "Target type is required. Use --target-type <rep|ec>"
    exit 1
fi

# Validate target type
if ! validate_pool_type "$TARGET_TYPE"; then
    exit 1
fi

# Set default target pool name
[ -z "$TARGET_POOL" ] && TARGET_POOL="${SOURCE_POOL}-migrated"

# Set defaults
[ -z "$MIN_SIZE" ] && MIN_SIZE=$((SIZE - 1))
[ -z "$EC_PROFILE" ] && EC_PROFILE="ec-profile-${TARGET_POOL}"

# Check cluster
print_subheader "Validating Cluster and Source Pool"
if ! check_cluster_running; then
    exit 1
fi
print_success "Cluster is running"

# Check source pool exists
if ! check_pool_exists "$SOURCE_POOL"; then
    print_error "Source pool '$SOURCE_POOL' does not exist"
    print_info "Create it first with: ./setup-source-pool.sh"
    exit 1
fi
print_success "Source pool exists"

# Check target pool doesn't exist
if check_pool_exists "$TARGET_POOL"; then
    print_error "Target pool '$TARGET_POOL' already exists"
    print_info "Choose a different name or delete the existing pool first"
    exit 1
fi
print_success "Target pool name is available"

# Check min compat client
if ! check_min_compat_client; then
    print_error "Pool migration requires min_compat_client umbrella or later"
    print_info "Set it with: ceph osd set-require-min-compat-client umbrella"
    exit 1
fi
print_success "Min compat client is compatible"

# Get source pool information
SOURCE_TYPE=$(get_pool_type "$SOURCE_POOL")
SOURCE_PG_NUM=$(get_pool_pg_count "$SOURCE_POOL")
SOURCE_OBJECT_COUNT=$(get_pool_object_count "$SOURCE_POOL")
SOURCE_DATA_SIZE=$(get_pool_data_size "$SOURCE_POOL")

if [ "$SOURCE_TYPE" = "rep" ]; then
    SOURCE_SIZE=$(get_pool_size "$SOURCE_POOL")
    SOURCE_DETAILS="replicated (size=$SOURCE_SIZE)"
elif [ "$SOURCE_TYPE" = "ec" ]; then
    SOURCE_EC_INFO=$(get_ec_profile_info "$SOURCE_POOL")
    if [ -n "$SOURCE_EC_INFO" ]; then
        SOURCE_DETAILS="erasure-coded ($SOURCE_EC_INFO)"
    else
        SOURCE_DETAILS="erasure-coded"
    fi
else
    SOURCE_DETAILS="unknown"
fi

# Calculate target PG count if not specified
if [ -z "$PG_NUM" ]; then
    PG_NUM=$(calculate_target_pg_count "$SOURCE_PG_NUM" "$SOURCE_TYPE" "$TARGET_TYPE")
    print_info "Auto-calculated target PG count: $PG_NUM"
fi

[ -z "$PGP_NUM" ] && PGP_NUM="$PG_NUM"

# Validate numeric parameters
validate_positive_integer "$PG_NUM" "pg-num" || exit 1
validate_positive_integer "$SIZE" "size" || exit 1
validate_positive_integer "$EC_K" "ec-k" || exit 1
validate_positive_integer "$EC_M" "ec-m" || exit 1

#
# Display migration plan
#
print_subheader "Migration Plan"

echo "Source Pool: $SOURCE_POOL"
echo "  Type:           $SOURCE_DETAILS"
echo "  PG Count:       $SOURCE_PG_NUM"
echo "  Objects:        $SOURCE_OBJECT_COUNT"
if [ -n "$SOURCE_DATA_SIZE" ]; then
    echo "  Data Size:      $SOURCE_DATA_SIZE"
fi

echo ""
echo "Target Pool: $TARGET_POOL"
echo "  Type:           $TARGET_TYPE"
if [ "$TARGET_TYPE" = "rep" ]; then
    echo "  Size:           $SIZE"
    echo "  Min Size:       $MIN_SIZE"
else
    echo "  EC Profile:     $EC_PROFILE"
    echo "  EC K (data):    $EC_K"
    echo "  EC M (coding):  $EC_M"
    echo "  EC Plugin:      $EC_PLUGIN"
    if [ -n "$EC_STRIPE_UNIT" ]; then
        echo "  Stripe Unit:    $EC_STRIPE_UNIT"
    else
        echo "  Stripe Unit:    (Ceph default)"
    fi
    if [ "$ALLOW_EC_OVERWRITES" = "true" ]; then
        echo "  EC Mode:        Fast EC (overwrites enabled)"
    else
        echo "  EC Mode:        Classic EC (overwrites disabled)"
    fi
fi
echo "  PG Count:       $PG_NUM"
echo "  PGP Count:      $PGP_NUM"

echo ""
echo "Migration Type: $SOURCE_TYPE → $TARGET_TYPE"

#
# Generate commands
#
print_subheader "Commands to Execute"

COMMANDS=()

if [ "$TARGET_TYPE" = "rep" ]; then
    # Replicated target pool
    COMMANDS+=("ceph osd pool create $TARGET_POOL $PG_NUM $PGP_NUM replicated --migrate-from-pool $SOURCE_POOL")
    COMMANDS+=("ceph osd pool set $TARGET_POOL size $SIZE --yes-i-really-mean-it")
    COMMANDS+=("ceph osd pool set $TARGET_POOL min_size $MIN_SIZE")
else
    # Erasure-coded target pool
    EC_PROFILE_CMD="ceph osd erasure-code-profile set $EC_PROFILE plugin=$EC_PLUGIN k=$EC_K m=$EC_M crush-failure-domain=osd"
    if [ -n "$EC_STRIPE_UNIT" ]; then
        EC_PROFILE_CMD="$EC_PROFILE_CMD stripe_unit=$EC_STRIPE_UNIT"
    fi
    COMMANDS+=("$EC_PROFILE_CMD")
    COMMANDS+=("ceph osd pool create $TARGET_POOL $PG_NUM $PGP_NUM erasure $EC_PROFILE --migrate-from-pool $SOURCE_POOL")
    if [ "$ALLOW_EC_OVERWRITES" = "true" ]; then
        COMMANDS+=("ceph osd pool set $TARGET_POOL allow_ec_overwrites true")
    fi
fi

COMMANDS+=("ceph osd pool application enable $TARGET_POOL rados")

# Display commands
for cmd in "${COMMANDS[@]}"; do
    echo "  $cmd"
done

echo ""
print_warning "Migration will start automatically once target pool is created!"
echo ""

#
# Execute or exit
#
if [ "$DRY_RUN" = true ]; then
    print_info "This was a dry run. No changes were made."
    echo ""
    echo "To execute this migration, run:"
    echo "  $0 --source-pool $SOURCE_POOL --target-type $TARGET_TYPE --execute"
    echo ""
    exit 0
fi

#
# Confirmation prompt
#
if [ "$AUTO_CONFIRM" = false ]; then
    echo ""
    if ! confirm_action "Do you want to proceed with migration setup?" "n"; then
        print_info "Migration setup cancelled"
        exit 0
    fi
    echo ""
fi

#
# Execute commands
#
print_subheader "Executing Migration Setup"

for cmd in "${COMMANDS[@]}"; do
    print_info "Running: $cmd"
    if [ "$VERBOSE" = true ]; then
        eval "$cmd"
    else
        eval "$cmd" >/dev/null 2>&1
    fi
    print_success "Command completed"
done

# Wait for PGs to stabilize
print_info "Waiting for PGs to stabilize..."
sleep 5
wait_for_pgs_active "$TARGET_POOL" 60

#
# Save configuration
#
print_subheader "Saving Configuration"

save_pool_config "$TARGET_POOL" "$TARGET_TYPE" "$PG_NUM" "$SIZE" "$EC_K" "$EC_M" "0"

#
# Check initial migration status
#
print_subheader "Initial Migration Status"

sleep 2

# Get current status
TARGET_OBJECT_COUNT=$(get_pool_object_count "$TARGET_POOL")
TARGET_PG_STATE=$(ceph pg ls-by-pool "$TARGET_POOL" 2>/dev/null | grep -c "migrating" || echo "0")

echo "Source Pool:"
echo "  Objects:        $SOURCE_OBJECT_COUNT"
echo ""
echo "Target Pool:"
echo "  Objects:        $TARGET_OBJECT_COUNT"
echo "  Migrating PGs:  $TARGET_PG_STATE"

if [ "$TARGET_PG_STATE" -gt 0 ]; then
    print_success "Migration has started!"
else
    print_info "Migration will begin shortly"
fi

#
# Display summary
#
print_header "MIGRATION SETUP COMPLETE"

echo "Migration Details:"
echo "  Source:         $SOURCE_POOL ($SOURCE_TYPE)"
echo "  Target:         $TARGET_POOL ($TARGET_TYPE)"
echo "  Status:         Active"
echo ""

print_success "Target pool created and migration initiated!"
echo ""
echo "Next Steps:"
echo "  1. Monitor migration progress:"
echo "     ./check-migration-status.sh --source-pool $SOURCE_POOL --target-pool $TARGET_POOL"
echo ""
echo "  2. Watch migration in real-time:"
echo "     ./check-migration-status.sh --source-pool $SOURCE_POOL --target-pool $TARGET_POOL --watch"
echo ""
echo "  3. Check pool status:"
echo "     ceph osd pool ls detail | grep -E '$SOURCE_POOL|$TARGET_POOL'"
echo ""
echo "  4. View PG states:"
echo "     ceph pg ls-by-pool $TARGET_POOL"
echo ""

# Made with Bob
