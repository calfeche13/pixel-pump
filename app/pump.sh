#!/usr/bin/env bash

# ==============================================================================
# ENVIRONMENT VARIABLES (Overridden via docker-compose)
# ==============================================================================
VAULT_DIR="/vault"
SYNC_DIR="/sync"
BATCH_GB=${BATCH_GB:-10}
MIN_THRESHOLD_GB=${MIN_THRESHOLD_GB:-1.5}
CHECK_INTERVAL=${CHECK_INTERVAL:-120}
# ==============================================================================

echo "=== PIXEL PUMP INITIALIZING ==="

# --- 1. PRE-FLIGHT CHECKS ---
if [ ! -d "$VAULT_DIR" ]; then
    echo "FATAL ERROR: Vault directory ($VAULT_DIR) does not exist or is not mounted."
    exit 1
fi

if [ ! -d "$SYNC_DIR" ]; then
    echo "FATAL ERROR: Sync directory ($SYNC_DIR) does not exist or is not mounted."
    exit 1
fi

if [ ! -w "$SYNC_DIR" ]; then
    echo "FATAL ERROR: Sync directory ($SYNC_DIR) is not writable. Check Docker volume permissions."
    exit 1
fi

# Convert GB to Bytes (Using awk to safely handle decimal inputs)
BATCH_BYTES=$(awk -v b="$BATCH_GB" 'BEGIN { printf("%.0f", b * 1073741824) }')
MIN_BYTES=$(awk -v m="$MIN_THRESHOLD_GB" 'BEGIN { printf("%.0f", m * 1073741824) }')

get_dir_size() {
    # Using GNU du syntax, suppress error output to prevent log spam if files are deleted mid-scan
    echo $(du -sk "$1" 2>/dev/null | awk '{print $1 * 1024}')
}

echo "Vault Directory: $VAULT_DIR"
echo "Sync Directory: $SYNC_DIR"
echo "Batch Target: ${BATCH_GB} GB"
echo "Refill Threshold: ${MIN_THRESHOLD_GB} GB"
echo "Check Interval: ${CHECK_INTERVAL}s"
echo "Monitoring $SYNC_DIR..."
echo "==============================="

while true; do
    CURRENT_SIZE=$(get_dir_size "$SYNC_DIR")
    
    # Fallback in case du fails to return a size
    if [ -z "$CURRENT_SIZE" ]; then
        CURRENT_SIZE=0
    fi
    
    # If the sync folder drops below the minimum threshold, refill it
    if [ "$CURRENT_SIZE" -lt "$MIN_BYTES" ]; then
        
        # Check if there are still valid files left in the vault
        if [ -n "$(find "$VAULT_DIR" -maxdepth 1 -type f -not -name '.*' | head -n 1)" ]; then
            
            SPACE_TO_FILL=$((BATCH_BYTES - CURRENT_SIZE))
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Sync folder dropped to $(awk -v s="$CURRENT_SIZE" 'BEGIN { printf("%.2f", s / 1073741824) }')GB. Refilling..."
            
            ADDED_BYTES=0
            
            # Loop through files and safely move them
            while IFS= read -r -d '' file; do
                
                # --- 2. SAFE STAT CHECK ---
                if ! FILE_SIZE=$(stat -c%s "$file" 2>/dev/null); then
                    echo "Warning: Could not read size of $file. Skipping."
                    continue
                fi
                
                if [ $((ADDED_BYTES + FILE_SIZE)) -le "$SPACE_TO_FILL" ]; then
                    
                    # --- 3. MOVE VALIDATION ---
                    if mv "$file" "$SYNC_DIR/"; then
                        ADDED_BYTES=$((ADDED_BYTES + FILE_SIZE))
                    else
                        echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: Failed to move $(basename "$file"). Pausing batch to prevent loop."
                        break # Break the inner loop, sleep, and try again next cycle
                    fi
                else
                    break # Batch is full
                fi
            done < <(find "$VAULT_DIR" -maxdepth 1 -type f -not -name '.*' -print0)
            
            echo "Added $(awk -v s="$ADDED_BYTES" 'BEGIN { printf("%.2f", s / 1073741824) }')GB to queue. Waiting for upload and purge..."
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Media Vault is completely empty! Pipeline finished."
            sleep infinity
        fi
    fi
    
    sleep "$CHECK_INTERVAL"
done