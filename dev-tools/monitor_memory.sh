#!/bin/bash

# Memory monitoring script for ZeroClaw daemon
# Tracks memory usage patterns over time to detect leaks

set -e

LOG_FILE="/Users/adarsh/Documents/zeroclaw/dev-tools/memory_trend.log"
MONITOR_DURATION=60  # 1 minute for quick test
SAMPLE_INTERVAL=5   # Sample every 5 seconds

echo "=== ZeroClaw Memory Monitoring ==="
echo "Duration: $MONITOR_DURATION seconds"
echo "Sample interval: $SAMPLE_INTERVAL seconds"
echo ""

START_TIME=$(date +%s)
END_TIME=$((START_TIME + MONITOR_DURATION))

echo "Starting memory monitoring at $(date)"
echo "Log file: $LOG_FILE"
echo ""

echo "=== $(date -Iseconds) ===" >> "$LOG_FILE"
echo "Memory Monitoring Session Started" >> "$LOG_FILE"
echo "Duration: ${MONITOR_DURATION}s, Interval: ${SAMPLE_INTERVAL}s" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

while [ $(date +%s) -lt $END_TIME ]; do
    CURRENT_TIME=$(date -Iseconds)
    
    # Get daemon process info
    DAEMON_INFO=$(ps aux | grep '[z]eroclaw daemon' | head -1)
    
    if [ -n "$DAEMON_INFO" ]; then
        MEMORY_KB=$(echo "$DAEMON_INFO" | awk '{print $6}')
        MEMORY_MB=$((MEMORY_KB / 1024))
        CPU_PERCENT=$(echo "$DAEMON_INFO" | awk '{print $3}')
        
        echo "[$CURRENT_TIME] Memory: ${MEMORY_MB}MB, CPU: ${CPU_PERCENT}%"
        echo "[$CURRENT_TIME] Memory: ${MEMORY_MB}MB, CPU: ${CPU_PERCENT%" >> "$LOG_FILE"
    else
        echo "[$CURRENT_TIME] No daemon process found"
        echo "[$CURRENT_TIME] No daemon process found" >> "$LOG_FILE"
    fi
    
    # System memory info
    SYSTEM_MEM=$(vm_stat | grep "Pages free" | awk '{print $3}' | sed 's/\.//')
    if [ -n "$SYSTEM_MEM" ]; then
        # Convert pages to MB (assuming 4KB pages)
        SYSTEM_FREE_MB=$((SYSTEM_MEM * 4 / 1024))
        echo "System free memory: ${SYSTEM_FREE_MB}MB"
        echo "System free memory: ${SYSTEM_FREE_MB}MB" >> "$LOG_FILE"
    fi
    
    echo "" >> "$LOG_FILE"
    
    sleep $SAMPLE_INTERVAL
done

echo ""
echo "=== Monitoring Complete ==="
echo "Results logged to: $LOG_FILE"
echo ""
echo "Analyzing memory growth pattern..."

# Simple analysis
if [ -f "$LOG_FILE" ]; then
    FIRST_SAMPLE=$(grep "Memory:" "$LOG_FILE" | head -1 | grep -oP '\d+(?=MB)' || echo "0")
    LAST_SAMPLE=$(grep "Memory:" "$LOG_FILE" | tail -1 | grep -oP '\d+(?=MB)' || echo "0")
    
    if [ "$FIRST_SAMPLE" != "0" ] && [ "$LAST_SAMPLE" != "0" ]; then
        GROWTH=$((LAST_SAMPLE - FIRST_SAMPLE))
        SAMPLES=$(grep -c "Memory:" "$LOG_FILE")
        DURATION_SECONDS=$((SAMPLES * SAMPLE_INTERVAL))
        # Calculate growth rate in MB/second
        if [ $DURATION_SECONDS -gt 0 ]; then
            GROWTH_RATE_MB_PER_SEC=$((GROWTH * 100 / DURATION_SECONDS))
            GROWTH_RATE=$((GROWTH_RATE_MB_PER_SEC / 100))
        else
            GROWTH_RATE=0
        fi
        
        echo "Memory growth: ${GROWTH}MB over ${DURATION_SECONDS}s"
        echo "Samples collected: $SAMPLES"
        
        if [ $GROWTH -gt 50 ]; then
            echo "⚠️  WARNING: High memory growth detected (>50MB)"
        elif [ $GROWTH -gt 20 ]; then
            echo "⚠️  CAUTION: Moderate memory growth detected (>20MB)"
        else
            echo "✅ Memory growth within acceptable range"
        fi
    fi
fi