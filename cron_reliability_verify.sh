#!/bin/bash

# Cron Reliability Verification Script
# Usage: GATEWAY_PORT=42617 AUTH_TOKEN=zc_yourtoken ./cron_reliability_verify.sh [total_minutes] [poll_interval_minutes]

set -e

# Configuration
TOTAL_MINUTES=${1:-180}
POLL_INTERVAL_MINUTES=${2:-5}
GATEWAY_PORT=${GATEWAY_PORT:-42617}
AUTH_TOKEN=${AUTH_TOKEN:-"zc_03fdd83f79219e8542beb5ceca7655a76fae5f9eb67216d012e793058de1a995"}
API_BASE="http://localhost:${GATEWAY_PORT}/api/sops"

# Output files
RESULTS_CSV="results.csv"
SCRIPT_LOG="script.log"
STUCK_SIGNATURES_LOG="stuck_signatures.log"

# Initialize rate limiting
declare -a REQUEST_TIMESTAMPS=()
RATE_LIMIT=14  # max 14 requests per 60 seconds
RATE_WINDOW=60  # 60 second window

# Initialize log files
echo "timestamp,sop_name,status,run_id" > "$RESULTS_CSV"
echo "Cron Reliability Verification - $(date)" > "$SCRIPT_LOG"
echo "Total watch time: ${TOTAL_MINUTES} minutes, Poll interval: ${POLL_INTERVAL_MINUTES} minutes" >> "$SCRIPT_LOG"
echo "Rate limit: ${RATE_LIMIT} requests per ${RATE_WINDOW} seconds" >> "$SCRIPT_LOG"
echo "" >> "$SCRIPT_LOG"
> "$STUCK_SIGNATURES_LOG"

# SOPs to monitor
SOPS=("role_audit" "subscription_check" "welcome_outreach")

log() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" | tee -a "$SCRIPT_LOG"
}

rate_limited_curl() {
    url="$1"
    
    # Check rate limit
    current_time=$(date +%s)
    
    # Remove timestamps older than RATE_WINDOW seconds
    new_timestamps=()
    for ts in "${REQUEST_TIMESTAMPS[@]}"; do
        if (( current_time - ts < RATE_WINDOW )); then
            new_timestamps+=("$ts")
        fi
    done
    REQUEST_TIMESTAMPS=("${new_timestamps[@]}")
    
    # If we've hit the limit, wait until oldest request ages out
    if (( ${#REQUEST_TIMESTAMPS[@]} >= RATE_LIMIT )); then
        oldest_ts=${REQUEST_TIMESTAMPS[0]}
        wait_time=$(( RATE_WINDOW - (current_time - oldest_ts) ))
        if (( wait_time > 0 )); then
            log "Rate limit reached: sleeping ${wait_time}s before next request"
            sleep "$wait_time"
            
            # Clean up old timestamps after waiting
            current_time=$(date +%s)
            new_timestamps=()
            for ts in "${REQUEST_TIMESTAMPS[@]}"; do
                if (( current_time - ts < RATE_WINDOW )); then
                    new_timestamps+=("$ts")
                fi
            done
            REQUEST_TIMESTAMPS=("${new_timestamps[@]}")
        fi
    fi
    
    # Make the request
    response=$(curl -s -H "Authorization: Bearer $AUTH_TOKEN" "$url")
    exit_code=$?
    
    # Record timestamp if successful
    if (( exit_code == 0 )); then
        REQUEST_TIMESTAMPS+=($(date +%s))
    fi
    
    echo "$response"
    return $exit_code
}

check_sop_status() {
    sop_name="$1"
    url="${API_BASE}/runs"
    
    log "Checking status for ${sop_name}..."
    response=$(rate_limited_curl "$url")
    
    if [ -z "$response" ]; then
        log "ERROR: No response from API for ${sop_name}"
        echo "$(date '+%Y-%m-%d %H:%M:%S'),${sop_name},ERROR,no_response" >> "$RESULTS_CSV"
        return 1
    fi
    
    # Check if SOP subsystem is enabled
    if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
        error_msg=$(echo "$response" | jq -r '.error')
        if [[ "$error_msg" == *"SOP subsystem not enabled"* ]]; then
            log "ERROR: SOP subsystem not enabled. Please enable SOP in config."
            echo "$(date '+%Y-%m-%d %H:%M:%S'),${sop_name},ERROR,sop_subsystem_disabled" >> "$RESULTS_CSV"
            return 1
        fi
        if [[ "$error_msg" == *"Unauthorized"* ]]; then
            log "ERROR: Authentication failed. Check AUTH_TOKEN."
            echo "$(date '+%Y-%m-%d %H:%M:%S'),${sop_name},ERROR,auth_failed" >> "$RESULTS_CSV"
            return 1
        fi
    fi
    
    # Parse JSON with jq - handle different response formats
    if echo "$response" | jq -e '.runs' > /dev/null 2>&1; then
        # Response has .runs field (array) - filter by sop_name and get most recent
        status=$(echo "$response" | jq -r --arg sop "$sop_name" '.runs[] | select(.sop_name == $sop) | .status' | head -1)
        run_id=$(echo "$response" | jq -r --arg sop "$sop_name" '.runs[] | select(.sop_name == $sop) | .run_id' | head -1)
        if [ -z "$status" ]; then
            log "${sop_name} status: no_runs (no runs yet)"
            echo "$(date '+%Y-%m-%d %H:%M:%S'),${sop_name},no_runs," >> "$RESULTS_CSV"
            return 0
        fi
    elif echo "$response" | jq -e '.[0]' > /dev/null 2>&1; then
        # Direct array response
        status=$(echo "$response" | jq -r '.[0].status // empty')
        run_id=$(echo "$response" | jq -r '.[0].id // empty')
    else
        # Object response or single item
        status=$(echo "$response" | jq -r '.status // empty')
        run_id=$(echo "$response" | jq -r '.id // empty')
    fi
    
    if [ -z "$status" ]; then
        log "WARNING: Could not parse status for ${sop_name}. Response: $response"
        echo "$(date '+%Y-%m-%d %H:%M:%S'),${sop_name},PARSE_ERROR," >> "$RESULTS_CSV"
        return 1
    fi
    
    log "${sop_name} status: ${status} (run_id: ${run_id})"
    echo "$(date '+%Y-%m-%d %H:%M:%S'),${sop_name},${status},${run_id}" >> "$RESULTS_CSV"
    
    return 0
}

check_stuck_signatures() {
    # Check daemon log for stuck signatures
    log_dir="/Users/adarsh/.zeroclaw/logs"
    
    if [ -d "$log_dir" ]; then
        log "Checking daemon logs for stuck signatures in ${log_dir}..."
        
        # Search for failure signatures in recent log files
        signatures=(
            "no agent loop available to execute"
            "agent: command not found"
            "cooldown or concurrency limit reached"
        )
        
        for log_file in "$log_dir"/*.log; do
            if [ -f "$log_file" ]; then
                for sig in "${signatures[@]}"; do
                    if grep -q "$sig" "$log_file"; then
                        log "WARNING: Found stuck signature in $(basename $log_file): ${sig}"
                        echo "$(date '+%Y-%m-%d %H:%M:%S') - $(basename $log_file) - ${sig}" >> "$STUCK_SIGNATURES_LOG"
                    fi
                done
            fi
        done
    else
        log "Daemon log directory not found at ${log_dir}, skipping stuck signature check"
    fi
}

# Main monitoring loop
log "Starting monitoring loop..."
log "Monitoring SOPs: ${SOPS[*]}"

end_time=$(($(date +%s) + TOTAL_MINUTES * 60))
poll_interval_seconds=$((POLL_INTERVAL_MINUTES * 60))

while (( $(date +%s) < end_time )); do
    log "=== Polling cycle at $(date '+%Y-%m-%d %H:%M:%S') ==="
    
    for sop in "${SOPS[@]}"; do
        check_sop_status "$sop"
    done
    
    check_stuck_signatures
    
    remaining_seconds=$((end_time - $(date +%s)))
    if (( remaining_seconds > poll_interval_seconds )); then
        log "Sleeping for ${POLL_INTERVAL_MINUTES} minutes..."
        sleep "$poll_interval_seconds"
    else
        log "Approaching end time, finishing..."
        break
    fi
done

log "=== Monitoring complete ==="
log "Results written to ${RESULTS_CSV}"
log "Full log written to ${SCRIPT_LOG}"
log "Stuck signatures written to ${STUCK_SIGNATURES_LOG}"

# Display summary
echo ""
echo "=== Summary ==="
echo "Total duration monitored: ${TOTAL_MINUTES} minutes"
echo "Poll interval: ${POLL_INTERVAL_MINUTES} minutes"
echo "Results saved to: ${RESULTS_CSV}"
echo "Log saved to: ${SCRIPT_LOG}"
echo "Stuck signatures saved to: ${STUCK_SIGNATURES_LOG}"
echo ""
echo "Remember to manually verify Discord side-effects:"
echo "- Check for posted summary messages"
echo "- Verify role changes after each completed cycle"
