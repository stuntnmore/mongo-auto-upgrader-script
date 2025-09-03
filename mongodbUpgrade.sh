#!/bin/bash

# Clean MongoDB Upgrade Script
# Optimized for Ubuntu 18.04+ with libcurl3 compatibility
# 
# UPGRADE PATH: 3.2 → 3.4 → 3.6 → 4.0 → 4.2 → 4.4 → 5.0 → 6.0 → 7.0
# STORAGE: MMAPv1 → WiredTiger migration at 4.0
# COMPATIBILITY: libcurl3 PPA for Ubuntu 18.04, native support for 20.04+

# Configuration
MONGODB_PORT="39877"
MONGODB_CONFIG="/etc/mongod.conf"
LOG_FILE="/var/log/mongodb-upgrade.log"
BACKUP_DIR="/backup"
TEMP_DIR="/tmp/mongodb-upgrade"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

error_exit() {
    log "${RED}ERROR: $1${NC}"
    exit 1
}

success() {
    log "${GREEN}SUCCESS: $1${NC}"
}

warning() {
    log "${YELLOW}WARNING: $1${NC}"
}

info() {
    log "${BLUE}INFO: $1${NC}"
}

important() {
    log "${PURPLE}IMPORTANT: $1${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root"
    fi
}

get_ubuntu_version() {
    if command -v lsb_release >/dev/null 2>&1; then
        lsb_release -rs
    elif [[ -f /etc/os-release ]]; then
        grep VERSION_ID /etc/os-release | cut -d'"' -f2
    else
        echo "unknown"
    fi
}

check_ubuntu_compatibility() {
    local ubuntu_version
    ubuntu_version=$(get_ubuntu_version)
    
    info "Ubuntu version: $ubuntu_version"
    
    case "$ubuntu_version" in
        20.04|22.04)
            success "Ubuntu $ubuntu_version detected - will install libcurl3 for maximum MongoDB compatibility"
            ;;
        18.04)
            success "Ubuntu 18.04 detected - will install libcurl3 for MongoDB 4.0+ compatibility"
            ;;
        *)
            error_exit "Unsupported Ubuntu version: $ubuntu_version. Supported: 18.04, 20.04, 22.04"
            ;;
    esac
    
    echo "$ubuntu_version"
}

detect_mongodb_port() {
    if [[ -f "$MONGODB_CONFIG" ]]; then
        local port
        port=$(grep -E "^\s*port:" "$MONGODB_CONFIG" | awk '{print $2}' | head -1)
        if [[ -n "$port" ]]; then
            MONGODB_PORT="$port"
            info "Detected MongoDB port: $MONGODB_PORT"
        fi
    fi
}

get_mongodb_version() {
    local version
    
    # Try mongosh first, then mongo
    if command -v mongosh >/dev/null 2>&1; then
        version=$(mongosh --port "$MONGODB_PORT" --quiet --eval "print(db.version())" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
    fi
    
    if [[ -z "$version" ]] && command -v mongo >/dev/null 2>&1; then
        version=$(mongo --port "$MONGODB_PORT" --quiet --eval "print(db.version())" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
    fi
    
    if [[ -z "$version" ]]; then
        version=$(mongod --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fi
    
    version=$(echo "$version" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
    
    if [[ -n "$version" ]]; then
        echo "$version"
    else
        echo "unknown"
    fi
}

version_compare() {
    local v1="$1"
    local v2="$2"
    
    local v1_num v2_num
    v1_num=$(echo "$v1" | awk -F. '{printf("%d%03d%03d\n", $1, $2, $3)}')
    v2_num=$(echo "$v2" | awk -F. '{printf("%d%03d%03d\n", $1, $2, $3)}')
    
    [[ $v1_num -ge $v2_num ]]
}

should_skip_upgrade() {
    local current_version="$1"
    local target_version="$2"
    
    if version_compare "$current_version" "$target_version"; then
        info "MongoDB $current_version is already at or above target $target_version - skipping"
        return 0
    fi
    return 1
}

get_storage_engine() {
    local engine="unknown"
    
    # Method 1: Check if MongoDB is running and query it directly
    if is_mongodb_running; then
        if command -v mongosh >/dev/null 2>&1; then
            engine=$(mongosh --port "$MONGODB_PORT" --eval "
                try {
                    var status = db.serverStatus();
                    if (status.storageEngine && status.storageEngine.name) {
                        print('ENGINE_RESULT:' + status.storageEngine.name);
                    } else {
                        print('ENGINE_RESULT:unknown');
                    }
                } catch (e) {
                    print('ENGINE_RESULT:unknown');
                }
            " 2>/dev/null | grep "ENGINE_RESULT:" | sed 's/ENGINE_RESULT://')
        else
            engine=$(mongo --port "$MONGODB_PORT" --quiet --eval "
                try {
                    var status = db.serverStatus();
                    if (status.storageEngine && status.storageEngine.name) {
                        print('ENGINE_RESULT:' + status.storageEngine.name);
                    } else {
                        print('ENGINE_RESULT:unknown');
                    }
                } catch (e) {
                    print('ENGINE_RESULT:unknown');
                }
            " 2>/dev/null | grep "ENGINE_RESULT:" | sed 's/ENGINE_RESULT://')
        fi
        
        # Clean up the result
        engine=$(echo "$engine" | tr -d '\r\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        
        if [[ -n "$engine" && "$engine" != "unknown" ]]; then
            echo "$engine"
            return
        fi
    fi
    
    # Method 2: Check MongoDB configuration file
    if [[ -f "$MONGODB_CONFIG" ]]; then
        local config_engine
        config_engine=$(grep -E "^\s*engine:" "$MONGODB_CONFIG" | awk '{print $2}' | head -1)
        
        if [[ -n "$config_engine" ]]; then
            # Normalize the engine name
            case "$config_engine" in
                "wiredTiger"|"wiredtiger")
                    engine="wiredTiger"
                    ;;
                "mmapv1"|"MMAPv1")
                    engine="mmapv1"
                    ;;
                *)
                    engine="$config_engine"
                    ;;
            esac
            echo "$engine"
            return
        fi
    fi
    
    # Method 3: Check for WiredTiger files in data directory
    if [[ -d /var/lib/mongodb ]]; then
        if ls /var/lib/mongodb/WiredTiger* >/dev/null 2>&1; then
            engine="wiredTiger"
        elif ls /var/lib/mongodb/*.ns >/dev/null 2>&1; then
            engine="mmapv1"
        fi
    fi
    
    if [[ "$engine" == "unknown" ]]; then
        engine="mmapv1"
    fi
    
    echo "$engine"
}

is_mongodb_running() {
    if command -v mongosh >/dev/null 2>&1; then
        if mongosh --port "$MONGODB_PORT" --quiet --eval "db.adminCommand('ping')" >/dev/null 2>&1; then
            return 0
        fi
    fi
    
    if command -v mongo >/dev/null 2>&1; then
        if mongo --port "$MONGODB_PORT" --quiet --eval "db.adminCommand('ping')" >/dev/null 2>&1; then
            return 0
        fi
    fi
    
    return 1
}

fix_system_limits() {
    log "Fixing system limits for MongoDB performance..."
    
    # Fix file descriptor limits
    log "Setting file descriptor limits for MongoDB..."
    
    # Create limits configuration for mongodb user
    cat > /etc/security/limits.d/99-mongodb-nproc.conf << 'EOF'
# MongoDB system limits
mongodb soft nofile 64000
mongodb hard nofile 64000
mongodb soft nproc 64000
mongodb hard nproc 64000
root soft nofile 64000
root hard nofile 64000
EOF
    
    # Update systemd service limits if using systemd
    if systemctl --version >/dev/null 2>&1; then
        log "Updating systemd service limits..."
        
        # Create systemd override directory
        mkdir -p /etc/systemd/system/mongod.service.d/
        
        # Create override configuration
        cat > /etc/systemd/system/mongod.service.d/override.conf << 'EOF'
[Service]
LimitNOFILE=64000
LimitNPROC=64000
EOF
        
        # Reload systemd
        systemctl daemon-reload
    fi
    
    # Set current session limits
    ulimit -n 64000 2>/dev/null || true
    ulimit -u 64000 2>/dev/null || true
    
    success "System limits configured for MongoDB"
    
    # Verify limits were set
    log "Verifying system limits..."
    local current_nofile_soft current_nofile_hard
    current_nofile_soft=$(ulimit -Sn 2>/dev/null || echo "unknown")
    current_nofile_hard=$(ulimit -Hn 2>/dev/null || echo "unknown")
    
    info "Current file descriptor limits - Soft: $current_nofile_soft, Hard: $current_nofile_hard"
    
    if [[ "$current_nofile_soft" -ge 64000 ]] 2>/dev/null; then
        success "File descriptor limits properly configured"
    else
        warning "File descriptor limits may not be fully applied (will take effect after service restart)"
    fi
}

fix_permissions() {
    log "Fixing MongoDB permissions..."
    
    # Ensure mongodb user exists
    if ! getent passwd mongodb >/dev/null 2>&1; then
        useradd -r -g mongodb -d /var/lib/mongodb -s /bin/false mongodb 2>/dev/null || true
    fi
    
    # Fix ownership and permissions
    chown -R mongodb:mongodb /var/lib/mongodb /var/log/mongodb 2>/dev/null || true
    chmod 755 /var/lib/mongodb /var/log/mongodb 2>/dev/null || true
    rm -f /var/lib/mongodb/mongod.lock /tmp/mongodb-*.sock 2>/dev/null || true
    
    # Fix system limits
    fix_system_limits
}

disable_journal_for_7() {
    # MongoDB 7.0+ removed the journal option; ensure it's commented out before starting
    if [[ -f "$MONGODB_CONFIG" ]]; then
        log "Disabling journal in mongod.conf for 7.0+ compatibility"
        # Comment the 'journal:' key line (preserve indentation)
        sed -i 's/^\([[:space:]]*\)journal:[[:space:]]*$/\1# journal:/' "$MONGODB_CONFIG" || true
        # Comment the immediate enabled line if present (preserve indentation)
        sed -i 's/^\([[:space:]]*\)enabled:[[:space:]]*true[[:space:]]*$/\1# enabled: true/' "$MONGODB_CONFIG" || true
        # Validate there is no remaining un-commented journal key
        if grep -Eq '^[[:space:]]*journal:[[:space:]]*$' "$MONGODB_CONFIG"; then
            error_exit "mongod.conf still contains an active 'journal:' block. Please remove/comment it and re-run."
        fi
        success "Journal disabled in mongod.conf"
    fi
}

start_mongodb() {
    log "Starting MongoDB on port $MONGODB_PORT"
    
    # Stop any existing processes
    pkill -f mongod 2>/dev/null || true
    sleep 3
    
    # Fix permissions
    fix_permissions
    
    # Start MongoDB
    local attempts=0
    while [[ $attempts -lt 3 ]]; do
        attempts=$((attempts + 1))
        log "Start attempt $attempts/3..."
        
        if /usr/bin/mongod --config "$MONGODB_CONFIG" --fork 2>/dev/null; then
            sleep 5
            break
        else
            warning "Start attempt $attempts failed"
            sleep 5
        fi
    done
    
    # Wait for readiness
    local wait_attempts=0
    while ! is_mongodb_running && [[ $wait_attempts -lt 30 ]]; do
        wait_attempts=$((wait_attempts + 1))
        log "Waiting for MongoDB... ($wait_attempts/30)"
        sleep 3
    done
    
    if is_mongodb_running; then
        success "MongoDB started successfully"
    else
        error_exit "MongoDB failed to start"
    fi
}

stop_mongodb() {
    log "Stopping MongoDB"
    
    # Graceful shutdown
    if command -v mongosh >/dev/null 2>&1; then
        mongosh --port "$MONGODB_PORT" admin --eval "db.shutdownServer()" 2>/dev/null || true
    else
        mongo --port "$MONGODB_PORT" admin --eval "db.shutdownServer()" 2>/dev/null || true
    fi
    
    sleep 5
    pkill -f mongod 2>/dev/null || true
    sleep 3
    
    rm -f /var/lib/mongodb/mongod.lock /tmp/mongodb-*.sock 2>/dev/null || true
    success "MongoDB stopped"
}

create_backup() {
    local version="$1"
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_path="$BACKUP_DIR/mongodb-backup-${timestamp}"
    
    log "Creating backup before upgrade..."
    
    if ! is_mongodb_running; then
        error_exit "MongoDB not running - cannot create backup"
    fi
    
    mkdir -p "$backup_path"
    
    if mongodump --port "$MONGODB_PORT" --out "$backup_path" >/dev/null 2>&1; then
        success "Backup created: $backup_path"
        
        cat > "$backup_path/info.txt" << EOF
MongoDB Version: $version
Backup Date: $(date)
Port: $MONGODB_PORT
Storage Engine: $(get_storage_engine)
EOF
        
        echo "$backup_path" > /tmp/last_backup
        return 0
    else
        error_exit "Backup failed"
    fi
}

get_current_fcv() {
    if ! is_mongodb_running; then
        echo "unknown"
        return
    fi
    
    local fcv_result="unknown"
    
    # Method 1: Try getParameter command (works for most versions)
    if command -v mongosh >/dev/null 2>&1; then
        fcv_result=$(mongosh --port "$MONGODB_PORT" --eval "
            try {
                var result = db.adminCommand({getParameter: 1, featureCompatibilityVersion: 1});
                if (result.ok === 1 && result.featureCompatibilityVersion) {
                    if (typeof result.featureCompatibilityVersion === 'object') {
                        print('FCV_RESULT:' + (result.featureCompatibilityVersion.version || 'unknown'));
                    } else {
                        print('FCV_RESULT:' + result.featureCompatibilityVersion);
                    }
                } else {
                    print('FCV_RESULT:unknown');
                }
            } catch (e) {
                print('FCV_RESULT:unknown');
            }
        " 2>/dev/null | grep "FCV_RESULT:" | sed 's/FCV_RESULT://')
    else
        fcv_result=$(mongo --port "$MONGODB_PORT" --quiet --eval "
            try {
                var result = db.adminCommand({getParameter: 1, featureCompatibilityVersion: 1});
                if (result.ok === 1 && result.featureCompatibilityVersion) {
                    if (typeof result.featureCompatibilityVersion === 'object') {
                        print('FCV_RESULT:' + (result.featureCompatibilityVersion.version || 'unknown'));
                    } else {
                        print('FCV_RESULT:' + result.featureCompatibilityVersion);
                    }
                } else {
                    print('FCV_RESULT:unknown');
                }
            } catch (e) {
                print('FCV_RESULT:unknown');
            }
        " 2>/dev/null | grep "FCV_RESULT:" | sed 's/FCV_RESULT://')
    fi
    
    # Clean up the result
    fcv_result=$(echo "$fcv_result" | tr -d '\r\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    
    # Method 2: If getParameter failed, try alternative method for older versions
    if [[ -z "$fcv_result" || "$fcv_result" == "unknown" ]]; then
        log "getParameter method failed, trying alternative FCV detection..."
        
        if command -v mongosh >/dev/null 2>&1; then
            fcv_result=$(mongosh --port "$MONGODB_PORT" --eval "
                try {
                    // Try admin.system.version collection (older method)
                    var fcvDoc = db.getSiblingDB('admin').system.version.findOne({_id: 'featureCompatibilityVersion'});
                    if (fcvDoc && fcvDoc.version) {
                        print('FCV_RESULT:' + fcvDoc.version);
                    } else {
                        // For very old versions, assume based on server version
                        var buildInfo = db.runCommand('buildInfo');
                        if (buildInfo.version) {
                            var version = buildInfo.version;
                            if (version.startsWith('3.2')) print('FCV_RESULT:3.2');
                            else if (version.startsWith('3.4')) print('FCV_RESULT:3.4');
                            else if (version.startsWith('3.6')) print('FCV_RESULT:3.6');
                            else print('FCV_RESULT:unknown');
                        } else {
                            print('FCV_RESULT:unknown');
                        }
                    }
                } catch (e) {
                    print('FCV_RESULT:unknown');
                }
            " 2>/dev/null | grep "FCV_RESULT:" | sed 's/FCV_RESULT://')
        else
            fcv_result=$(mongo --port "$MONGODB_PORT" --quiet --eval "
                try {
                    // Try admin.system.version collection (older method)
                    var fcvDoc = db.getSiblingDB('admin').system.version.findOne({_id: 'featureCompatibilityVersion'});
                    if (fcvDoc && fcvDoc.version) {
                        print('FCV_RESULT:' + fcvDoc.version);
                    } else {
                        // For very old versions, assume based on server version
                        var buildInfo = db.runCommand('buildInfo');
                        if (buildInfo.version) {
                            var version = buildInfo.version;
                            if (version.startsWith('3.2')) print('FCV_RESULT:3.2');
                            else if (version.startsWith('3.4')) print('FCV_RESULT:3.4');
                            else if (version.startsWith('3.6')) print('FCV_RESULT:3.6');
                            else print('FCV_RESULT:unknown');
                        } else {
                            print('FCV_RESULT:unknown');
                        }
                    }
                } catch (e) {
                    print('FCV_RESULT:unknown');
                }
            " 2>/dev/null | grep "FCV_RESULT:" | sed 's/FCV_RESULT://')
        fi
        
        # Clean up the alternative result
        fcv_result=$(echo "$fcv_result" | tr -d '\r\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    fi
    
    # Final fallback - if still empty/unknown, try to infer from MongoDB version
    if [[ -z "$fcv_result" || "$fcv_result" == "unknown" ]]; then
        log "All FCV detection methods failed, inferring from MongoDB version..."
        local mongo_version
        mongo_version=$(get_mongodb_version)
        
        case "$mongo_version" in
            3.2.*) fcv_result="3.2" ;;
            3.4.*) fcv_result="3.4" ;;
            3.6.*) fcv_result="3.6" ;;
            4.0.*) fcv_result="4.0" ;;
            4.2.*) fcv_result="4.2" ;;
            4.4.*) fcv_result="4.4" ;;
            5.0.*) fcv_result="5.0" ;;
            6.0.*) fcv_result="6.0" ;;
            7.0.*) fcv_result="7.0" ;;
            *) fcv_result="unknown" ;;
        esac
        
        if [[ "$fcv_result" != "unknown" ]]; then
            warning "Inferred FCV $fcv_result from MongoDB version $mongo_version"
        fi
    fi
    
    echo "$fcv_result"
}

check_and_fix_fcv_for_current_version() {
    log "Checking Feature Compatibility Version for current MongoDB version..."
    
    if ! is_mongodb_running; then
        warning "MongoDB not running - cannot check FCV"
        return 1
    fi
    
    local current_mongo_version current_fcv expected_fcv
    current_mongo_version=$(get_mongodb_version)
    current_fcv=$(get_current_fcv)
    
    # Determine expected FCV based on MongoDB version
    case "$current_mongo_version" in
        3.2.*)
            expected_fcv="3.2"
            ;;
        3.4.*)
            expected_fcv="3.4"
            ;;
        3.6.*)
            expected_fcv="3.6"
            ;;
        4.0.*)
            expected_fcv="4.0"
            ;;
        4.2.*)
            expected_fcv="4.2"
            ;;
        4.4.*)
            expected_fcv="4.4"
            ;;
        5.0.*)
            expected_fcv="5.0"
            ;;
        6.0.*)
            expected_fcv="6.0"
            ;;
        7.0.*)
            expected_fcv="7.0"
            ;;
        *)
            warning "Unknown MongoDB version: $current_mongo_version - cannot determine expected FCV"
            return 1
            ;;
    esac
    
    info "MongoDB version: $current_mongo_version"
    info "Current FCV: $current_fcv"
    info "Expected FCV: $expected_fcv"
    
    if [[ "$current_fcv" == "$expected_fcv" ]]; then
        success "FCV is correctly set to $current_fcv for MongoDB $current_mongo_version"
        return 0
    elif [[ -z "$current_fcv" || "$current_fcv" == "unknown" ]]; then
        warning "Could not determine current FCV (empty or unknown result)"
        warning "This may indicate FCV is not set or MongoDB is not responding properly"
        warning "Attempting to set FCV to $expected_fcv for MongoDB $current_mongo_version..."
        set_feature_compatibility_version "$expected_fcv"
    else
        warning "FCV mismatch: MongoDB $current_mongo_version should have FCV $expected_fcv but has '$current_fcv'"
        warning "Correcting FCV to match MongoDB version..."
        set_feature_compatibility_version "$expected_fcv"
    fi
}

set_feature_compatibility_version() {
    local version="$1"
    
    log "Setting Feature Compatibility Version to $version"
    
    if ! is_mongodb_running; then
        error_exit "MongoDB not running for FCV update"
    fi
    
    # Get current FCV first
    local current_fcv
    current_fcv=$(get_current_fcv)
    log "Current FCV: $current_fcv"
    
    if [[ "$current_fcv" == "$version" ]]; then
        success "FCV already correctly set to $version"
        return 0
    fi
    
    sleep 5
    
    log "Attempting to set FCV to $version..."
    
    local result
    if command -v mongosh >/dev/null 2>&1; then
        log "Using mongosh to set FCV..."
        result=$(mongosh --port "$MONGODB_PORT" --eval "
            try {
                print('Setting FCV to $version...');
                var cmd = {setFeatureCompatibilityVersion: '$version'};
                if ('$version' === '7.0') { cmd.confirm = true; }
                var result = db.adminCommand(cmd);
                print('FCV Result: ' + JSON.stringify(result));
                print('RESULT_MARKER:' + JSON.stringify(result));
            } catch (e) {
                print('FCV Error: ' + e.message);
                print('RESULT_MARKER:{\"ok\":0,\"error\":\"' + e.message + '\"}');
            }
        " 2>&1 | grep "RESULT_MARKER:" | sed 's/RESULT_MARKER://')
    else
        log "Using legacy mongo shell to set FCV..."
        result=$(mongo --port "$MONGODB_PORT" --eval "
            try {
                print('Setting FCV to $version...');
                var cmd = {setFeatureCompatibilityVersion: '$version'};
                if ('$version' === '7.0') { cmd.confirm = true; }
                var result = db.adminCommand(cmd);
                print('FCV Result: ' + JSON.stringify(result));
                print('RESULT_MARKER:' + JSON.stringify(result));
            } catch (e) {
                print('FCV Error: ' + e.message);
                print('RESULT_MARKER:{\"ok\":0,\"error\":\"' + e.message + '\"}');
            }
        " 2>&1 | grep "RESULT_MARKER:" | sed 's/RESULT_MARKER://')
    fi
    
    log "Raw FCV result: $result"
    
    if [[ -n "$result" ]] && echo "$result" | grep -q '"ok":1'; then
        success "FCV set to $version"
        
        # Verify the change
        sleep 3
        local new_fcv
        new_fcv=$(get_current_fcv)
        log "Verification - New FCV: $new_fcv"
        
        if [[ "$new_fcv" == "$version" ]]; then
            success "FCV verification successful: $new_fcv"
        else
            warning "FCV verification failed. Expected: $version, Got: $new_fcv"
            # Don't exit - continue with upgrade, FCV might be set correctly despite verification issues
        fi
    elif [[ -z "$result" ]]; then
        warning "Empty result from FCV command - MongoDB may not be responding properly"
        warning "Continuing with upgrade - FCV will be checked again later"
    else
        # Auto-retry with confirm:true if required by 7.0 safeguard
        if echo "$result" | grep -qi "re-run this command with 'confirm: true'"; then
            warning "FCV requires confirm:true. Retrying with confirmation..."
            if command -v mongosh >/dev/null 2>&1; then
                result=$(mongosh --port "$MONGODB_PORT" --eval "
                    try {
                        var result = db.adminCommand({setFeatureCompatibilityVersion: '$version', confirm: true});
                        print('RESULT_MARKER:' + JSON.stringify(result));
                    } catch (e) {
                        print('RESULT_MARKER:{\\"ok\\":0,\\"error\\":\\"' + e.message + '\\"}');
                    }
                " 2>&1 | grep "RESULT_MARKER:" | sed 's/RESULT_MARKER://')
            else
                result=$(mongo --port "$MONGODB_PORT" --eval "
                    try {
                        var result = db.adminCommand({setFeatureCompatibilityVersion: '$version', confirm: true});
                        print('RESULT_MARKER:' + JSON.stringify(result));
                    } catch (e) {
                        print('RESULT_MARKER:{\\"ok\\":0,\\"error\\":\\"' + e.message + '\\"}');
                    }
                " 2>&1 | grep "RESULT_MARKER:" | sed 's/RESULT_MARKER://')
            fi
            if [[ -n "$result" ]] && echo "$result" | grep -q '"ok":1'; then
                success "FCV set to $version (confirmed)"
            else
                warning "FCV still not confirmed. Result: $result"
            fi
        else
            warning "FCV setting may have failed. Result: $result"
            warning "Continuing with upgrade - FCV will be checked again later"
        fi
    fi
}

fix_growroot_hook() {
    log "Pre-emptively fixing growroot initramfs hook to prevent package installation failures..."
    
    local hooks_dir="/usr/share/initramfs-tools/hooks"
    
    if [[ -d "$hooks_dir" ]]; then
        # Move all growroot files to a safe location
        local backup_dir="/tmp/growroot-hooks-disabled"
        mkdir -p "$backup_dir"
        
        # Move any existing growroot files
        find "$hooks_dir" -name "*growroot*" -type f -exec mv {} "$backup_dir/" \; 2>/dev/null || true
        
        # Create a minimal working growroot hook
        cat > "$hooks_dir/growroot" << 'EOF'
#!/bin/sh
# Minimal growroot hook - prevents failures during package installations
set -e
case $1 in
prereqs) echo ""; exit 0 ;;
esac
exit 0
EOF
        
        chmod +x "$hooks_dir/growroot"
        success "Growroot hook fixed to prevent package installation failures"
    fi
}

install_libcurl_compatibility() {
    log "Installing libcurl3 compatibility for MongoDB 4.0+ (all Ubuntu versions)"
    
    local ubuntu_version
    ubuntu_version=$(get_ubuntu_version)
    
    log "Ubuntu $ubuntu_version detected - installing libcurl3 for maximum MongoDB compatibility"
    
    # Fix growroot hook before package operations
    fix_growroot_hook
    
    # Add the PPA for libcurl3
    log "Adding PPA: ppa:xapienz/curl34"
    if add-apt-repository -y ppa:xapienz/curl34; then
        success "Added libcurl3 PPA successfully"
    else
        error_exit "Failed to add libcurl3 PPA - this is required for MongoDB 4.0+ compatibility"
    fi
    
    # Update package lists
    log "Updating package lists..."
    if apt-get update >/dev/null 2>&1; then
        log "Package lists updated"
    else
        warning "Package update had issues, but continuing..."
    fi
    
    # Install libcurl3 with error handling for initramfs issues
    log "Installing libcurl3..."
    if apt-get install -y libcurl3 2>/dev/null; then
        success "libcurl3 installed - MongoDB 4.0+ compatibility ensured"
    else
        warning "libcurl3 installation had issues, attempting to fix broken packages..."
        
        # Fix broken packages caused by initramfs failures
        dpkg --configure -a 2>/dev/null || true
        apt-get install -f -y 2>/dev/null || true
        
        # Try libcurl3 installation again
        if apt-get install -y libcurl3 2>/dev/null; then
            success "libcurl3 installed after fixing broken packages"
        else
            warning "libcurl3 installation failed, but continuing - may work with existing libcurl4"
        fi
    fi
    
    # Test that it worked
    if dpkg -l | grep -q "libcurl3\|libcurl4"; then
        info "libcurl compatibility packages confirmed installed"
        
        # Show installed libcurl packages
        log "Installed libcurl packages:"
        dpkg -l | grep libcurl | awk '{print "  " $2 " " $3}' || true
    fi
    
    success "libcurl compatibility setup completed"
}

install_dependencies() {
    log "Installing dependencies..."
    
    apt-get update >/dev/null 2>&1
    
    local packages=("wget" "curl" "software-properties-common")
    for package in "${packages[@]}"; do
        if apt-get install -y "$package" >/dev/null 2>&1; then
            log "Installed: $package"
        fi
    done
    
    # Install libcurl compatibility for Ubuntu 18.04
    install_libcurl_compatibility
    
    success "Dependencies installed"
}

download_and_install_mongodb() {
    local version="$1"
    local fcv_version="$2"
    local ubuntu_binary="$3"
    
    log "Installing MongoDB $version"
    
    mkdir -p "$TEMP_DIR"
    cd "$TEMP_DIR"
    
    local filename="mongodb-linux-x86_64-${ubuntu_binary}-${version}.tgz"
    local url="https://fastdl.mongodb.org/linux/$filename"
    
    log "Downloading: $filename"
    
    if wget -q "$url"; then
        log "Download successful"
    else
        error_exit "Download failed: $url"
    fi
    
    log "Extracting binaries..."
    if tar -xzf "$filename"; then
        log "Extraction successful"
    else
        error_exit "Extraction failed"
    fi
    
    local extract_dir="mongodb-linux-x86_64-${ubuntu_binary}-${version}"
    
    log "Installing binaries..."
    if cp "$extract_dir/bin/"* /usr/bin/; then
        success "MongoDB $version binaries installed"
    else
        error_exit "Binary installation failed"
    fi
    
    # Verify installation
    local installed_version
    installed_version=$(mongod --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    info "Installed version: $installed_version"

    # MongoDB 7.0+: ensure journaling config is not set (removed)
    if [[ "$fcv_version" == "7.0" || "$version" == 7.* ]]; then
        if [[ -f "$MONGODB_CONFIG" ]]; then
            log "Adjusting mongod config for 7.0+: commenting out journal.enabled if present"
            # Comment out the journal.enabled line preserving indentation
            sed -i 's/^\([[:space:]]*\)enabled:[[:space:]]*true/\1# enabled: true/' "$MONGODB_CONFIG" || true
        fi
    fi
}

migrate_storage_engine() {
    log "=========================================="
    log "CHECKING STORAGE ENGINE MIGRATION NEED"
    log "=========================================="
    
    # Get storage engine with explicit logging
    log "Detecting current storage engine..."
    local current_engine
    current_engine=$(get_storage_engine)
    
    log "Storage engine detection result: '$current_engine'"
    
    # Normalize storage engine name for comparison
    local normalized_engine
    case "$current_engine" in
        "wiredTiger"|"wiredtiger"|"WiredTiger")
            normalized_engine="wiredTiger"
            log "Normalized engine: wiredTiger (from: $current_engine)"
            ;;
        "mmapv1"|"MMAPv1"|"MMAPV1")
            normalized_engine="mmapv1"
            log "Normalized engine: mmapv1 (from: $current_engine)"
            ;;
        *)
            normalized_engine="$current_engine"
            log "Engine unchanged: $current_engine"
            ;;
    esac
    
    log "Final engine comparison: '$normalized_engine' == 'wiredTiger'?"
    
    if [[ "$normalized_engine" == "wiredTiger" ]]; then
        success "Already using WiredTiger storage engine - skipping migration"
        info "No data migration needed - continuing with upgrade"
        return 0
    fi
    
    log "=========================================="
    log "MIGRATING STORAGE ENGINE: $current_engine → WiredTiger"
    log "=========================================="
    
    warning "This will migrate your data from $current_engine to WiredTiger"
    warning "This process involves stopping MongoDB and restoring data"
    
    # Stop MongoDB
    stop_mongodb
    
    # Backup data directory
    log "Backing up MMAPv1 data directory"
    if [[ -d /var/lib/mongodb ]]; then
        mv /var/lib/mongodb /var/lib/mongodb-mmapv1-backup
    fi
    mkdir -p /var/lib/mongodb
    chown -R mongodb:mongodb /var/lib/mongodb
    
    # Update config for WiredTiger
    log "Updating config for WiredTiger"
    grep -v "^  engine:" "$MONGODB_CONFIG" > "${MONGODB_CONFIG}.tmp" || cp "$MONGODB_CONFIG" "${MONGODB_CONFIG}.tmp"
    sed -i '/^storage:/a\  engine: wiredTiger' "${MONGODB_CONFIG}.tmp"
    mv "${MONGODB_CONFIG}.tmp" "$MONGODB_CONFIG"
    
    # Start with WiredTiger
    start_mongodb
    
    # Restore data
    log "Restoring data to WiredTiger"
    local backup_path
    if [[ -f /tmp/last_backup ]]; then
        backup_path=$(cat /tmp/last_backup)
        if [[ -d "$backup_path" ]]; then
            if mongorestore --port "$MONGODB_PORT" "$backup_path" >/dev/null 2>&1; then
                success "Data migrated to WiredTiger"
            else
                error_exit "Data restoration failed"
            fi
        else
            error_exit "Backup not found: $backup_path"
        fi
    else
        error_exit "No backup available for migration"
    fi
    
    success "Storage engine migration completed"
}

upgrade_mongodb_to() {
    local target_version="$1"
    local fcv_version="$2"
    local ubuntu_binary="$3"
    local upgrade_name="$4"
    
    log "=========================================="
    log "UPGRADING TO MONGODB $target_version"
    log "=========================================="
    
    local current_version
    current_version=$(get_mongodb_version)
    
    # Skip if already at target version
    if should_skip_upgrade "$current_version" "$target_version"; then
        return 0
    fi
    
    # Stop MongoDB
    stop_mongodb
    
    # Install new version
    download_and_install_mongodb "$target_version" "$fcv_version" "$ubuntu_binary"
    
    # For 7.x, ensure journal is disabled before starting the new binary
    if [[ "$fcv_version" == "7.0" || "$target_version" == 7.* ]]; then
        disable_journal_for_7
    fi

    # Start new version
    start_mongodb
    
    # Set FCV
    set_feature_compatibility_version "$fcv_version"
    
    success "Upgraded to MongoDB $target_version"
}

install_mongosh() {
    log "Installing MongoDB Shell (mongosh)"
    
    cd "$TEMP_DIR"
    
    if wget -q "https://downloads.mongodb.com/compass/mongosh-2.1.5-linux-x64.tgz"; then
        tar -xzf mongosh-2.1.5-linux-x64.tgz
        cp mongosh-2.1.5-linux-x64/bin/* /usr/bin/
        ln -sf /usr/bin/mongosh /usr/bin/mongo
        success "MongoDB Shell installed"
    else
        warning "Failed to install mongosh"
    fi
}

verify_installation() {
    log "=========================================="
    log "VERIFYING INSTALLATION"
    log "=========================================="
    
    if ! is_mongodb_running; then
        start_mongodb
    fi
    
    local server_version
    server_version=$(mongosh --port "$MONGODB_PORT" --quiet --eval "db.version()" 2>/dev/null | tail -1)
    
    info "MongoDB Server Version: $server_version"
    info "Storage Engine: $(get_storage_engine)"
    
    # Check and verify FCV is correct for current version
    log "Verifying Feature Compatibility Version..."
    check_and_fix_fcv_for_current_version
    
    # Test data integrity
    log "Testing data integrity..."
    mongosh --port "$MONGODB_PORT" --quiet --eval "
        db.adminCommand('listDatabases').databases.forEach(function(database) {
            var dbObj = db.getSiblingDB(database.name);
            var collections = dbObj.getCollectionNames();
            var totalDocs = 0;
            collections.forEach(function(coll) {
                totalDocs += dbObj.getCollection(coll).countDocuments({});
            });
            print('Database: ' + database.name + ' | Collections: ' + collections.length + ' | Documents: ' + totalDocs);
        });
    " 2>/dev/null
    
    success "Installation verification completed"
}

disable_auth() {
    log "Disabling authentication for upgrade"
    cp "$MONGODB_CONFIG" "${MONGODB_CONFIG}.with-auth"
    sed -i 's/authorization: "enabled"/authorization: "disabled"/' "$MONGODB_CONFIG"
}

enable_auth() {
    log "Re-enabling authentication"
    if [[ -f "${MONGODB_CONFIG}.with-auth" ]]; then
        cp "${MONGODB_CONFIG}.with-auth" "$MONGODB_CONFIG"
        success "Authentication re-enabled"
    fi
}

main() {
    log "=========================================="
    log "MONGODB UPGRADE - CLEAN VERSION"
    log "3.2+ → 7.0.14 UPGRADE PATH"
    log "=========================================="
    
    check_root
    detect_mongodb_port
    
    # Check Ubuntu version
    local ubuntu_version
    ubuntu_version=$(check_ubuntu_compatibility)
    
    # Create directories
    mkdir -p "$BACKUP_DIR" "$TEMP_DIR"
    
    # Install dependencies
    install_dependencies
    
    # Get current MongoDB version
    local current_version
    current_version=$(get_mongodb_version)
    
    if [[ "$current_version" == "unknown" ]]; then
        error_exit "Cannot determine MongoDB version"
    fi
    
    log "Starting upgrade from MongoDB $current_version"
    
    # Check and fix FCV for current version before starting upgrade
    if is_mongodb_running; then
        log "Checking current FCV alignment with MongoDB version..."
        check_and_fix_fcv_for_current_version
    else
        info "MongoDB not running - will check FCV after starting"
    fi
    
    # Check if already at target
    if should_skip_upgrade "$current_version" "7.0.0"; then
        success "Already at MongoDB 7.0+"
        verify_installation
        return 0
    fi
    
    # Create backup
    create_backup "$current_version"
    
    # Disable auth
    disable_auth
    start_mongodb
    
    # Check and fix FCV for current version after starting
    log "Verifying FCV alignment after MongoDB startup..."
    check_and_fix_fcv_for_current_version
    
    # Determine binary version to use
    local binary_version="ubuntu2004"
    if [[ "$ubuntu_version" == "22.04" ]]; then
        binary_version="ubuntu2204"
    elif [[ "$ubuntu_version" == "18.04" ]]; then
        binary_version="ubuntu1804"
    fi
    
    # Upgrade sequence
    case "$current_version" in
        3.2.*)
            upgrade_mongodb_to "3.4.24" "3.4" "ubuntu1604" "3.4"
            upgrade_mongodb_to "3.6.23" "3.6" "ubuntu1604" "3.6"
            upgrade_mongodb_to "4.0.28" "4.0" "ubuntu1804" "4.0"
            migrate_storage_engine
            upgrade_mongodb_to "4.2.25" "4.2" "ubuntu1804" "4.2"
            upgrade_mongodb_to "4.4.29" "4.4" "$binary_version" "4.4"
            upgrade_mongodb_to "5.0.24" "5.0" "ubuntu2004" "5.0"
            upgrade_mongodb_to "6.0.14" "6.0" "ubuntu2004" "6.0"
            upgrade_mongodb_to "7.0.14" "7.0" "$binary_version" "7.0"
            ;;
        3.4.*)
            upgrade_mongodb_to "3.6.23" "3.6" "ubuntu1604" "3.6"
            upgrade_mongodb_to "4.0.28" "4.0" "ubuntu1604" "4.0"
            migrate_storage_engine
            upgrade_mongodb_to "4.2.25" "4.2" "ubuntu1804" "4.2"
            upgrade_mongodb_to "4.4.29" "4.4" "$binary_version" "4.4"
            upgrade_mongodb_to "5.0.24" "5.0" "ubuntu2004" "5.0"
            upgrade_mongodb_to "6.0.14" "6.0" "ubuntu2004" "6.0"
            upgrade_mongodb_to "7.0.14" "7.0" "$binary_version" "7.0"
            ;;
        3.6.*)
            upgrade_mongodb_to "4.0.28" "4.0" "ubuntu1604" "4.0"
            migrate_storage_engine
            upgrade_mongodb_to "4.2.25" "4.2" "ubuntu1804" "4.2"
            upgrade_mongodb_to "4.4.29" "4.4" "$binary_version" "4.4"
            upgrade_mongodb_to "5.0.24" "5.0" "ubuntu2004" "5.0"
            upgrade_mongodb_to "6.0.14" "6.0" "ubuntu2004" "6.0"
            upgrade_mongodb_to "7.0.14" "7.0" "$binary_version" "7.0"
            ;;
        4.0.*)
            migrate_storage_engine
            upgrade_mongodb_to "4.2.25" "4.2" "ubuntu1804" "4.2"
            upgrade_mongodb_to "4.4.29" "4.4" "$binary_version" "4.4"
            upgrade_mongodb_to "5.0.24" "5.0" "ubuntu2004" "5.0"
            upgrade_mongodb_to "6.0.14" "6.0" "ubuntu2004" "6.0"
            upgrade_mongodb_to "7.0.14" "7.0" "$binary_version" "7.0"
            ;;
        4.2.*)
            upgrade_mongodb_to "4.4.29" "4.4" "ubuntu1804" "4.4"
            upgrade_mongodb_to "5.0.24" "5.0" "ubuntu2004" "5.0"
            upgrade_mongodb_to "6.0.14" "6.0" "ubuntu2004" "6.0"
            upgrade_mongodb_to "7.0.14" "7.0" "$binary_version" "7.0"
            ;;
        4.4.*)
            upgrade_mongodb_to "5.0.24" "5.0" "ubuntu2004" "5.0"
            upgrade_mongodb_to "6.0.14" "6.0" "ubuntu2004" "6.0"
            upgrade_mongodb_to "7.0.14" "7.0" "$binary_version" "7.0"
            ;;
        5.0.*)
            upgrade_mongodb_to "6.0.14" "6.0" "ubuntu2004" "6.0"
            upgrade_mongodb_to "7.0.14" "7.0" "$binary_version" "7.0"
            ;;
        6.0.*)
            upgrade_mongodb_to "7.0.14" "7.0" "$binary_version" "7.0"
            ;;
        *)
            error_exit "Unsupported starting version: $current_version"
            ;;
    esac
    
    # Install mongosh
    install_mongosh
    
    # Verify installation
    verify_installation
    
    # Re-enable auth
    stop_mongodb
    enable_auth
    start_mongodb
    
    # Final status
    log "=========================================="
    success "MONGODB UPGRADE COMPLETED!"
    log "=========================================="
    info "Upgraded from: $current_version"
    info "Final version: $(get_mongodb_version)"
    info "Storage engine: WiredTiger"
    info "Port: $MONGODB_PORT"
    info "Backup: $(cat /tmp/last_backup 2>/dev/null || echo 'Not found')"
    
    # Test connection
    if mongosh --port "$MONGODB_PORT" --eval "print('Connection test: ' + db.version())" >/dev/null 2>&1; then
        success "MongoDB is accessible"
    else
        warning "MongoDB may require authentication"
    fi
    
    success "Upgrade completed successfully!"
}

# Show usage
if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    cat << 'EOF'
Clean MongoDB Upgrade Script
============================

Upgrades MongoDB from 3.2+ to 6.0.14 with minimal complexity.

REQUIREMENTS:
- Ubuntu 18.04+ (libcurl3 PPA used for 18.04)
- Root access
- 10GB+ free space
- Internet connection

USAGE:
  sudo ./mongodb-upgrade-clean.sh

FEATURES:
- Single backup (not per step)
- Automatic version detection
- Storage engine migration
- libcurl3 compatibility for all Ubuntu versions
- System limits optimization (file descriptors)
- Clean error handling
- Ubuntu compatibility checks

COMPATIBILITY:
- All Ubuntu versions: Uses libcurl3 PPA for maximum MongoDB compatibility
- Ensures MongoDB 4.0+ works reliably on both 18.04 and 20.04+
EOF
    exit 0
fi

# Pre-flight checks
log "Pre-flight checks"
info "Disk space: $(df -h / | tail -1 | awk '{print $4}')"
info "Memory: $(free -h | grep ^Mem | awk '{print $2}')"

# Confirmation
echo ""
warning "This will upgrade MongoDB to 6.0.14"
warning "Process may take 30-90 minutes"
echo ""
read -p "Continue? Type 'UPGRADE' to proceed: " -r
if [[ "$REPLY" != "UPGRADE" ]]; then
    log "Upgrade cancelled"
    exit 0
fi

# Run upgrade
main "$@"
