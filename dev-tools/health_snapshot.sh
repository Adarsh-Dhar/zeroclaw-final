#!/bin/bash

# Health snapshot script for long-term monitoring
# Captures system metrics, daemon status, and SOP run health
# Intended to be run periodically (e.g., hourly via cron)

set -e

SCRIPT_DIR="/Users/adarsh/Documents/zeroclaw/dev-tools"
LOG_FILE="$SCRIPT_DIR/health_trend.log"
DAEMON_LOG_DIR="/Users/adarsh/.zeroclaw/logs"
AUTH_TOKEN="zc_$(grep -A 5 '\[gateway\]' /Users/adarsh/.zeroclaw/config.toml | grep 'paired_tokens' | head -1 || echo '')"

cd "$SCRIPT_DIR"

echo "=== $(date -u +"%Y-%m-%d %H:%M:%S UTC") ===" >> "$LOG_FILE"

# Process memory/CPU
echo "--- Process Metrics ---" >> "$LOG_FILE"
ps aux | grep '[z]eroclaw' >> "$LOG_FILE" 2>/dev/null || echo "No zeroclaw processes running" >> "$LOG_FILE"

# Log file sizes
echo "" >> "$LOG_FILE"
echo "--- Log File Sizes ---" >> "$LOG_FILE"
if [ -d "$DAEMON_LOG_DIR" ]; then
    du -sh "$DAEMON_LOG_DIR"/*.log >> "$LOG_FILE" 2>/dev/null || echo "No log files found" >> "$LOG_FILE"
else
    echo "Log directory not found: $DAEMON_LOG_DIR" >> "$LOG_FILE"
fi

# Count stuck runs (older than 10 minutes still in 'running')
echo "" >> "$LOG_FILE"
echo "--- SOP Run Status ---" >> "$LOG_FILE"
if command -v curl &> /dev/null; then
    # Try to get run status from API if daemon is running
    if curl -sf http://127.0.0.1:42617/health > /dev/null 2>&1; then
        # Get auth token if needed
        if [ -z "$AUTH_TOKEN" ]; then
            PAIR_CODE=$(curl -s -X POST http://127.0.0.1:42617/admin/paircode/new | jq -r '.pairing_code' 2>/dev/null)
            AUTH_TOKEN=$(curl -s -X POST http://127.0.0.1:42617/pair \
              -H "X-Pairing-Code: $PAIR_CODE" \
              -H "Content-Type: application/json" | jq -r '.token' 2>/dev/null)
        fi
        
        if [ -n "$AUTH_TOKEN" ]; then
            RUNS=$(curl -s http://127.0.0.1:42617/api/sops/runs \
              -H "Authorization: Bearer $AUTH_TOKEN" 2>/dev/null)
            
            if [ -n "$RUNS" ]; then
                echo "$RUNS" | jq '.' >> "$LOG_FILE" 2>/dev/null || echo "Could not parse runs JSON" >> "$LOG_FILE"
                
                # Count total runs
                TOTAL_RUNS=$(echo "$RUNS" | jq '.runs | length' 2>/dev/null || echo "0")
                echo "Total runs: $TOTAL_RUNS" >> "$LOG_FILE"
                
                # Check for stuck runs (running > 10 minutes)
                CURRENT_TIME=$(date +%s)
                STUCK_COUNT=0
                echo "$RUNS" | jq -r '.runs[] | select(.status == "running") | {run_id, started_at}' 2>/dev/null | while read -r line; do
                    if [ -n "$line" ]; then
                        STARTED_AT=$(echo "$line" | jq -r '.started_at' 2>/dev/null)
                        if [ -n "$STARTED_AT" ]; then
                            START_TIME=$(date -d "$STARTED_AT" +%s 2>/dev/null || echo "0")
                            ELAPSED=$((CURRENT_TIME - START_TIME))
                            if [ $ELAPSED -gt 600 ]; then
                                echo "STUCK RUN: $line (elapsed: ${ELAPSED}s)" >> "$LOG_FILE"
                                STUCK_COUNT=$((STUCK_COUNT + 1))
                            fi
                        fi
                    fi
                done
                echo "Stuck runs (>10 min): $STUCK_COUNT" >> "$LOG_FILE"
            else
                echo "Could not fetch runs" >> "$LOG_FILE"
            fi
        else
            echo "Could not obtain auth token" >> "$LOG_FILE"
        fi
    else
        echo "Daemon not running" >> "$LOG_FILE"
    fi
else
    echo "curl not available" >> "$LOG_FILE"
fi

# Memory usage summary
echo "" >> "$LOG_FILE"
echo "--- Memory Summary ---" >> "$LOG_FILE"
if command -v vm_stat &> /dev/null; then
    vm_stat >> "$LOG_FILE" 2>/dev/null || echo "vm_stat not available" >> "$LOG_FILE"
else
    free -h >> "$LOG_FILE" 2>/dev/null || echo "free not available" >> "$LOG_FILE"
fi

# Disk usage
echo "" >> "$LOG_FILE"
echo "--- Disk Usage ---" >> "$LOG_FILE"
df -h >> "$LOG_FILE" 2>/dev/null || echo "df not available" >> "$LOG_FILE"

echo "" >> "$LOG_FILE"
echo "=== End of Snapshot ===" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

echo "Health snapshot captured at $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
echo "Log file: $LOG_FILE"
echo "Working directory: $SCRIPT_DIR"
