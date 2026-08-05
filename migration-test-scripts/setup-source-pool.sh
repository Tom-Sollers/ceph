#!/bin/bash
#
# setup-source-pool.sh - Create and populate a source pool for migration testing
#
# This script creates a Ceph pool (replicated or erasure-coded) and populates
# it with test data, preparing it for pool migration testing.
#
# Usage: ./setup-source-pool.sh --pool-type <rep|ec> [options]
#

set -e

# Source helper functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/migration-helpers.sh"

#
# Default values
#
POOL_TYPE=""
POOL_NAME="migration-source-pool"
PG_NUM=32
PGP_NUM=""
SIZE=3
MIN_SIZE=""
EC_PROFILE=""
EC_K=2
EC_M=1
EC_PLUGIN="jerasure"
EC_STRIPE_UNIT=""
ALLOW_EC_OVERWRITES="true"
POPULATE_METHOD="bench"
OBJECT_COUNT=100
OBJECT_SIZE="4M"
OBJECT_PREFIX="test-obj"
BENCH_DURATION=30
BENCH_THREADS=4
NO_POPULATE=false
VERBOSE=false

#
# Usage function
#
usage() {
    cat << EOF
Usage: $0 --pool-type <rep|ec> [OPTIONS]

Create and populate a source pool for migration testing.

Required Arguments:
  --pool-type <rep|ec>           Pool type: replicated (rep) or erasure-coded (ec)

Pool Configuration:
  --pool-name <name>             Pool name (default: migration-source-pool)
  --pg-num <num>                 Number of PGs (default: 32)
  --pgp-num <num>                Number of PGPs (default: same as pg-num)

Replicated Pool Options:
  --size <num>                   Replication size (default: 3)
  --min-size <num>               Min size (default: size-1)

Erasure-Coded Pool Options:
  --ec-profile <name>            EC profile name (default: auto-generated)
  --ec-k <num>                   EC data chunks (default: 2)
  --ec-m <num>                   EC coding chunks (default: 1)
  --ec-plugin <name>             EC plugin (default: jerasure)
  --ec-stripe-unit <size>        EC stripe unit, e.g., 4K, 8K (default: Ceph default)
  --no-ec-overwrites             Disable EC overwrites (Fast EC disabled)
                                 Note: EC overwrites enabled by default (Fast EC mode)

Data Population Options:
  --populate-method <bench|put>  Method: rados bench or rados put (default: bench)
  --object-count <num>           Number of objects for 'put' method (default: 100)
  --object-size <size>           Object size, e.g., 4M, 1G (default: 4M)
  --object-prefix <prefix>       Object name prefix (default: test-obj)
  --bench-duration <sec>         Duration for 'bench' method (default: 30)
  --bench-threads <num>          Threads for bench (default: 4)
  --no-populate                  Create pool but don't add data

Other Options:
  --verbose                      Verbose output
  --help                         Show this help message

Examples:
  # Create replicated pool with 1 PG for testing
  $0 --pool-type rep --pool-name mypool --pg-num 1

  # Create EC pool with custom stripe unit (Classic EC)
  $0 --pool-type ec --ec-k 2 --ec-m 1 --ec-stripe-unit 4K --no-ec-overwrites

  # Create Fast EC pool (overwrites enabled, default)
  $0 --pool-type ec --ec-k 2 --ec-m 1

  # Create EC pool with different K value and stripe unit
  $0 --pool-type ec --ec-k 3 --ec-m 2 --ec-stripe-unit 8K

EOF
    exit 0
}

#
# Parse command line arguments
#
while [[ $# -gt 0 ]]; do
    case $1 in
        --pool-type)
            POOL_TYPE="$2"
            shift 2
            ;;
        --pool-name)
            POOL_NAME="$2"
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
        --populate-method)
            POPULATE_METHOD="$2"
            shift 2
            ;;
        --object-count)
            OBJECT_COUNT="$2"
            shift 2
            ;;
        --object-size)
            OBJECT_SIZE="$2"
            shift 2
            ;;
        --object-prefix)
            OBJECT_PREFIX="$2"
            shift 2
            ;;
        --bench-duration)
            BENCH_DURATION="$2"
            shift 2
            ;;
        --bench-threads)
            BENCH_THREADS="$2"
            shift 2
            ;;
        --no-populate)
            NO_POPULATE=true
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

print_header "POOL MIGRATION - SOURCE POOL SETUP"

# Check required arguments
if [ -z "$POOL_TYPE" ]; then
    print_error "Pool type is required. Use --pool-type <rep|ec>"
    exit 1
fi

# Validate pool type
if ! validate_pool_type "$POOL_TYPE"; then
    exit 1
fi

# Validate numeric parameters
validate_positive_integer "$PG_NUM" "pg-num" || exit 1
validate_positive_integer "$SIZE" "size" || exit 1
validate_positive_integer "$EC_K" "ec-k" || exit 1
validate_positive_integer "$EC_M" "ec-m" || exit 1
validate_positive_integer "$OBJECT_COUNT" "object-count" || exit 1
validate_positive_integer "$BENCH_DURATION" "bench-duration" || exit 1
validate_positive_integer "$BENCH_THREADS" "bench-threads" || exit 1

# Set defaults
[ -z "$PGP_NUM" ] && PGP_NUM="$PG_NUM"
[ -z "$MIN_SIZE" ] && MIN_SIZE=$((SIZE - 1))
[ -z "$EC_PROFILE" ] && EC_PROFILE="ec-profile-${POOL_NAME}"

# Check cluster
print_subheader "Validating Cluster"
if ! check_cluster_running; then
    exit 1
fi
print_success "Cluster is running"

# Check if pool already exists
if check_pool_exists "$POOL_NAME"; then
    print_error "Pool '$POOL_NAME' already exists"
    print_info "Choose a different name or delete the existing pool first"
    exit 1
fi
print_success "Pool name is available"

# Check min compat client
if ! check_min_compat_client; then
    print_warning "Pool migration requires min_compat_client umbrella or later"
    print_info "You can set it with: ceph osd set-require-min-compat-client umbrella"
fi

#
# Display configuration
#
print_subheader "Configuration"
echo "Pool Name:        $POOL_NAME"
echo "Pool Type:        $POOL_TYPE"
echo "PG Count:         $PG_NUM"
echo "PGP Count:        $PGP_NUM"

if [ "$POOL_TYPE" = "rep" ]; then
    echo "Replication Size: $SIZE"
    echo "Min Size:         $MIN_SIZE"
else
    echo "EC Profile:       $EC_PROFILE"
    echo "EC K (data):      $EC_K"
    echo "EC M (coding):    $EC_M"
    echo "EC Plugin:        $EC_PLUGIN"
    if [ -n "$EC_STRIPE_UNIT" ]; then
        echo "EC Stripe Unit:   $EC_STRIPE_UNIT"
    else
        echo "EC Stripe Unit:   (Ceph default)"
    fi
    if [ "$ALLOW_EC_OVERWRITES" = "true" ]; then
        echo "EC Mode:          Fast EC (overwrites enabled)"
    else
        echo "EC Mode:          Classic EC (overwrites disabled)"
    fi
fi

if [ "$NO_POPULATE" = false ]; then
    echo ""
    echo "Data Population:"
    echo "  Method:         $POPULATE_METHOD"
    if [ "$POPULATE_METHOD" = "bench" ]; then
        echo "  Duration:       ${BENCH_DURATION}s"
        echo "  Threads:        $BENCH_THREADS"
        echo "  Object Size:    $OBJECT_SIZE"
    else
        echo "  Object Count:   $OBJECT_COUNT"
        echo "  Object Size:    $OBJECT_SIZE"
        echo "  Object Prefix:  $OBJECT_PREFIX"
    fi
fi

echo ""

#
# Create pool
#
print_subheader "Creating Pool"

if [ "$POOL_TYPE" = "rep" ]; then
    # Create replicated pool
    print_info "Creating replicated pool..."
    if [ "$VERBOSE" = true ]; then
        ceph osd pool create "$POOL_NAME" "$PG_NUM" "$PGP_NUM" replicated
    else
        ceph osd pool create "$POOL_NAME" "$PG_NUM" "$PGP_NUM" replicated >/dev/null 2>&1
    fi
    print_success "Pool created"
    
    print_info "Setting pool size to $SIZE..."
    ceph osd pool set "$POOL_NAME" size "$SIZE" --yes-i-really-mean-it >/dev/null 2>&1
    print_success "Size configured"
    
    print_info "Setting min_size to $MIN_SIZE..."
    ceph osd pool set "$POOL_NAME" min_size "$MIN_SIZE" >/dev/null 2>&1
    print_success "Min size configured"
    
else
    # Create erasure-coded pool
    print_info "Creating erasure code profile..."
    
    # Build EC profile command
    EC_PROFILE_CMD="ceph osd erasure-code-profile set $EC_PROFILE plugin=$EC_PLUGIN k=$EC_K m=$EC_M crush-failure-domain=osd"
    
    # Add stripe_unit if specified
    if [ -n "$EC_STRIPE_UNIT" ]; then
        EC_PROFILE_CMD="$EC_PROFILE_CMD stripe_unit=$EC_STRIPE_UNIT"
        print_info "Using custom stripe unit: $EC_STRIPE_UNIT"
    fi
    
    if [ "$VERBOSE" = true ]; then
        eval "$EC_PROFILE_CMD"
    else
        eval "$EC_PROFILE_CMD" >/dev/null 2>&1
    fi
    print_success "EC profile created"
    
    print_info "Creating erasure-coded pool..."
    if [ "$VERBOSE" = true ]; then
        ceph osd pool create "$POOL_NAME" "$PG_NUM" "$PGP_NUM" erasure "$EC_PROFILE"
    else
        ceph osd pool create "$POOL_NAME" "$PG_NUM" "$PGP_NUM" erasure "$EC_PROFILE" >/dev/null 2>&1
    fi
    print_success "Pool created"
    
    if [ "$ALLOW_EC_OVERWRITES" = "true" ]; then
        print_info "Enabling EC overwrites (Fast EC mode)..."
        ceph osd pool set "$POOL_NAME" allow_ec_overwrites true >/dev/null 2>&1
        print_success "Fast EC mode enabled"
    else
        print_info "EC overwrites disabled (Classic EC mode)"
    fi
fi

# Enable application
print_info "Enabling rados application..."
ceph osd pool application enable "$POOL_NAME" rados >/dev/null 2>&1 || true
print_success "Application enabled"

# Wait for PGs to become active
wait_for_pgs_active "$POOL_NAME" 60

#
# Populate pool with data
#
if [ "$NO_POPULATE" = false ]; then
    print_subheader "Populating Pool with Test Data"
    
    if [ "$POPULATE_METHOD" = "bench" ]; then
        print_info "Running rados bench (${BENCH_DURATION}s)..."
        print_info "This will create test objects with mixed RADOS operations..."
        
        if [ "$VERBOSE" = true ]; then
            rados -p "$POOL_NAME" bench "$BENCH_DURATION" write \
                --no-cleanup \
                -t "$BENCH_THREADS" \
                -b "$OBJECT_SIZE"
        else
            rados -p "$POOL_NAME" bench "$BENCH_DURATION" write \
                --no-cleanup \
                -t "$BENCH_THREADS" \
                -b "$OBJECT_SIZE" >/dev/null 2>&1
        fi
        
        print_success "Bench completed"
        
    else
        # Use rados put method
        print_info "Creating test data file..."
        temp_file="/tmp/pool-migration-test-data-$$"
        dd if=/dev/urandom of="$temp_file" bs="$OBJECT_SIZE" count=1 2>/dev/null
        print_success "Test data file created"
        
        print_info "Uploading $OBJECT_COUNT objects..."
        count=0
        for i in $(seq 1 "$OBJECT_COUNT"); do
            obj_name=$(printf "${OBJECT_PREFIX}-%04d" $i)
            rados -p "$POOL_NAME" put "$obj_name" "$temp_file" 2>/dev/null
            count=$((count + 1))
            
            # Show progress every 10 objects
            if [ $((count % 10)) -eq 0 ] || [ $count -eq "$OBJECT_COUNT" ]; then
                printf "\r  Progress: %d/%d objects" $count "$OBJECT_COUNT"
            fi
        done
        echo ""
        
        rm -f "$temp_file"
        print_success "Objects uploaded"
    fi
    
    # Get actual object count
    sleep 2
    ACTUAL_OBJECT_COUNT=$(get_pool_object_count "$POOL_NAME")
    print_success "Pool populated with $ACTUAL_OBJECT_COUNT objects"
else
    ACTUAL_OBJECT_COUNT=0
    print_info "Skipping data population (--no-populate specified)"
fi

#
# Save configuration
#
print_subheader "Saving Configuration"

save_pool_config "$POOL_NAME" "$POOL_TYPE" "$PG_NUM" "$SIZE" "$EC_K" "$EC_M" "$ACTUAL_OBJECT_COUNT"

#
# Display summary
#
print_header "SOURCE POOL SETUP COMPLETE"

echo "Pool Details:"
echo "  Name:           $POOL_NAME"
echo "  Type:           $POOL_TYPE"
if [ "$POOL_TYPE" = "rep" ]; then
    echo "  Size:           $SIZE"
else
    echo "  EC Profile:     k=$EC_K, m=$EC_M"
    if [ -n "$EC_STRIPE_UNIT" ]; then
        echo "  Stripe Unit:    $EC_STRIPE_UNIT"
    fi
    if [ "$ALLOW_EC_OVERWRITES" = "true" ]; then
        echo "  EC Mode:        Fast EC (overwrites enabled)"
    else
        echo "  EC Mode:        Classic EC (overwrites disabled)"
    fi
fi
echo "  PG Count:       $PG_NUM"
echo "  Objects:        $ACTUAL_OBJECT_COUNT"

if [ "$ACTUAL_OBJECT_COUNT" -gt 0 ]; then
    pool_data=$(get_pool_data_size "$POOL_NAME")
    echo "  Data Size:      $pool_data"
fi

echo ""
print_success "Pool is ready for migration testing!"
echo ""
echo "Next Steps:"
echo "  1. Verify pool contents:"
echo "     rados -p $POOL_NAME ls | head"
echo ""
echo "  2. Set up migration to target pool:"
echo "     ./setup-target-pool.sh --source-pool $POOL_NAME --target-type <rep|ec>"
echo ""

# Made with Bob
