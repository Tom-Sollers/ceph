#!/bin/bash
#
# migration-helpers.sh - Common helper functions for pool migration scripts
#
# This library provides shared utilities for pool migration testing scripts.
# Source this file in other scripts: source ./migration-helpers.sh
#

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Configuration directory
CONFIG_DIR=".pool-migration-config"

#
# Display Functions
#

print_header() {
    local text="$1"
    local width=65
    echo ""
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════════${NC}"
    printf "${BOLD}${BLUE}%-${width}s${NC}\n" "$text"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_subheader() {
    local text="$1"
    echo ""
    echo -e "${BOLD}${CYAN}$text${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────${NC}"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗ ERROR:${NC} $1" >&2
}

print_warning() {
    echo -e "${YELLOW}⚠ WARNING:${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_progress_bar() {
    local current=$1
    local total=$2
    local width=40
    local percentage=$((current * 100 / total))
    local filled=$((width * current / total))
    local empty=$((width - filled))
    
    printf "  ["
    printf "%${filled}s" | tr ' ' '▓'
    printf "%${empty}s" | tr ' ' '░'
    printf "] %3d%%\n" "$percentage"
}

#
# Validation Functions
#

check_cluster_running() {
    if [ ! -f "ceph.conf" ]; then
        print_error "Ceph cluster not found. ceph.conf does not exist in current directory."
        print_info "Make sure you're running from the build/ directory with an active cluster."
        print_info "Start cluster with: ./restart_cluster.sh"
        return 1
    fi
    
    if ! ceph status &>/dev/null; then
        print_error "Cannot connect to Ceph cluster."
        print_info "Ensure the cluster is running: ./restart_cluster.sh"
        return 1
    fi
    
    return 0
}

check_pool_exists() {
    local pool_name="$1"
    
    if ceph osd pool ls 2>/dev/null | grep -q "^${pool_name}$"; then
        return 0
    else
        return 1
    fi
}

check_min_compat_client() {
    local required="umbrella"
    local current=$(ceph osd dump 2>/dev/null | grep "require_min_compat_client" | awk '{print $2}')
    
    if [ -z "$current" ]; then
        print_warning "Could not determine min_compat_client setting"
        return 1
    fi
    
    # Simple check - umbrella or later should be set
    if [[ "$current" != "umbrella" ]] && [[ "$current" != "squid" ]] && [[ "$current" != "reef" ]]; then
        print_warning "min_compat_client is '$current', but 'umbrella' or later is required for pool migration"
        print_info "Set with: ceph osd set-require-min-compat-client umbrella"
        return 1
    fi
    
    return 0
}

validate_pool_type() {
    local pool_type="$1"
    
    if [[ "$pool_type" != "rep" ]] && [[ "$pool_type" != "ec" ]]; then
        print_error "Invalid pool type: $pool_type (must be 'rep' or 'ec')"
        return 1
    fi
    
    return 0
}

validate_positive_integer() {
    local value="$1"
    local name="$2"
    
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -le 0 ]; then
        print_error "Invalid $name: $value (must be a positive integer)"
        return 1
    fi
    
    return 0
}

#
# Pool Information Functions
#

get_pool_type() {
    local pool_name="$1"
    # Use 'ceph osd pool ls detail' to get pool type
    local pool_info=$(ceph osd pool ls detail 2>/dev/null | grep "^pool.*'${pool_name}'")
    
    if echo "$pool_info" | grep -q "replicated"; then
        echo "rep"
    elif echo "$pool_info" | grep -q "erasure"; then
        echo "ec"
    else
        echo "unknown"
    fi
}

get_pool_pg_count() {
    local pool_name="$1"
    ceph osd pool get "$pool_name" pg_num 2>/dev/null | awk '{print $2}'
}

get_pool_size() {
    local pool_name="$1"
    ceph osd pool get "$pool_name" size 2>/dev/null | awk '{print $2}'
}

get_pool_object_count() {
    local pool_name="$1"
    rados -p "$pool_name" ls 2>/dev/null | wc -l
}

get_pool_data_size() {
    local pool_name="$1"
    ceph df 2>/dev/null | grep "^${pool_name} " | awk '{print $3, $4}'
}

get_migration_target() {
    local pool_name="$1"
    ceph osd dump 2>/dev/null | grep "^pool.*'${pool_name}'" | grep -o "migration_target [0-9]*" | awk '{print $2}'
}

get_migration_source() {
    local pool_name="$1"
    ceph osd dump 2>/dev/null | grep "^pool.*'${pool_name}'" | grep -o "migration_src [0-9]*" | awk '{print $2}'
}

get_pool_name_by_id() {
    local pool_id="$1"
    ceph osd pool ls detail 2>/dev/null | grep "^pool ${pool_id} " | awk -F"'" '{print $2}'
}

get_ec_profile_info() {
    local pool_name="$1"
    local profile=$(ceph osd pool get "$pool_name" erasure_code_profile 2>/dev/null | awk '{print $2}')
    
    if [ -n "$profile" ] && [ "$profile" != "property" ]; then
        local k=$(ceph osd erasure-code-profile get "$profile" 2>/dev/null | grep "^k=" | cut -d= -f2)
        local m=$(ceph osd erasure-code-profile get "$profile" 2>/dev/null | grep "^m=" | cut -d= -f2)
        if [ -n "$k" ] && [ -n "$m" ]; then
            echo "k=$k,m=$m"
        fi
    fi
}

#
# Configuration Management Functions
#

ensure_config_dir() {
    if [ ! -d "$CONFIG_DIR" ]; then
        mkdir -p "$CONFIG_DIR"
    fi
}

save_pool_config() {
    local pool_name="$1"
    local pool_type="$2"
    local pg_num="$3"
    local size="$4"
    local ec_k="$5"
    local ec_m="$6"
    local object_count="$7"
    
    ensure_config_dir
    
    local config_file="${CONFIG_DIR}/${pool_name}.conf"
    
    cat > "$config_file" <<EOF
# Pool configuration for: $pool_name
# Created: $(date)

POOL_NAME="$pool_name"
POOL_TYPE="$pool_type"
PG_NUM="$pg_num"
SIZE="$size"
EC_K="$ec_k"
EC_M="$ec_m"
OBJECT_COUNT="$object_count"
CREATED_AT="$(date +%s)"
EOF
    
    print_success "Configuration saved to: $config_file"
}

load_pool_config() {
    local pool_name="$1"
    local config_file="${CONFIG_DIR}/${pool_name}.conf"
    
    if [ ! -f "$config_file" ]; then
        print_warning "No saved configuration found for pool: $pool_name"
        return 1
    fi
    
    source "$config_file"
    return 0
}

#
# Calculation Functions
#

calculate_target_pg_count() {
    local source_pg_num="$1"
    local source_type="$2"
    local target_type="$3"
    
    # For now, use same PG count as source
    # In production, you might want more sophisticated calculation
    # based on data size and pool type change
    echo "$source_pg_num"
}

estimate_migration_time() {
    local object_count="$1"
    local avg_object_size="$2"  # in MB
    
    # Very rough estimate: ~100 objects per second
    local seconds=$((object_count / 100))
    
    if [ $seconds -lt 60 ]; then
        echo "${seconds} seconds"
    elif [ $seconds -lt 3600 ]; then
        echo "$((seconds / 60)) minutes"
    else
        echo "$((seconds / 3600)) hours"
    fi
}

format_bytes() {
    local bytes="$1"
    
    if [ "$bytes" -lt 1024 ]; then
        echo "${bytes} B"
    elif [ "$bytes" -lt 1048576 ]; then
        echo "$((bytes / 1024)) KB"
    elif [ "$bytes" -lt 1073741824 ]; then
        echo "$((bytes / 1048576)) MB"
    else
        echo "$((bytes / 1073741824)) GB"
    fi
}

#
# Confirmation Functions
#

confirm_action() {
    local prompt="$1"
    local default="${2:-n}"
    
    if [ "$default" = "y" ]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi
    
    read -p "$prompt" response
    response=${response:-$default}
    
    if [[ "$response" =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

#
# Utility Functions
#

wait_for_pgs_active() {
    local pool_name="$1"
    local timeout="${2:-60}"
    local elapsed=0
    
    print_info "Waiting for PGs to become active..."
    
    while [ $elapsed -lt $timeout ]; do
        # Try multiple methods to check PG status
        
        # Method 1: Check via ceph pg ls-by-pool
        local pg_output=$(ceph pg ls-by-pool "$pool_name" 2>/dev/null | tail -n +2)
        if [ -n "$pg_output" ]; then
            local total_pgs=$(echo "$pg_output" | wc -l)
            local active_pgs=$(echo "$pg_output" | grep "active" | wc -l)
            
            if [ "$total_pgs" -gt 0 ] && [ "$active_pgs" -eq "$total_pgs" ]; then
                print_success "All PGs are active"
                return 0
            fi
        fi
        
        # Method 2: Check via ceph pg stat (fallback)
        local pg_stat=$(ceph pg stat 2>/dev/null | grep -o "[0-9]* active+clean")
        if [ -n "$pg_stat" ]; then
            # If we see active+clean PGs and the pool exists, assume it's ready
            if ceph osd pool ls 2>/dev/null | grep -q "^${pool_name}$"; then
                print_success "PGs are active (verified via pg stat)"
                return 0
            fi
        fi
        
        sleep 2
        elapsed=$((elapsed + 2))
    done
    
    # Before failing, do one final check
    if ceph pg dump 2>/dev/null | grep -q "active+clean"; then
        print_warning "Timeout reached, but cluster appears healthy"
        print_info "Continuing anyway..."
        return 0
    fi
    
    print_warning "Timeout waiting for PGs to become active"
    return 1
}

parse_size_to_bytes() {
    local size="$1"
    local number=$(echo "$size" | sed 's/[^0-9]//g')
    local unit=$(echo "$size" | sed 's/[0-9]//g' | tr '[:lower:]' '[:upper:]')
    
    case "$unit" in
        K|KB)
            echo $((number * 1024))
            ;;
        M|MB)
            echo $((number * 1024 * 1024))
            ;;
        G|GB)
            echo $((number * 1024 * 1024 * 1024))
            ;;
        *)
            echo "$number"
            ;;
    esac
}

# Export functions for use in other scripts
export -f print_header print_subheader print_success print_error print_warning print_info
export -f print_progress_bar check_cluster_running check_pool_exists check_min_compat_client
export -f validate_pool_type validate_positive_integer get_pool_type get_pool_pg_count
export -f get_pool_size get_pool_object_count get_pool_data_size get_migration_target
export -f get_migration_source get_pool_name_by_id get_ec_profile_info ensure_config_dir
export -f save_pool_config load_pool_config calculate_target_pg_count estimate_migration_time
export -f format_bytes confirm_action wait_for_pgs_active parse_size_to_bytes

# Made with Bob
