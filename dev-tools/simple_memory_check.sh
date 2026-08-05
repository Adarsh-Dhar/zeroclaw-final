#!/bin/bash

# Simple memory check for ZeroClaw daemon
# Takes 3 samples over 30 seconds to detect obvious memory growth

echo "=== Simple Memory Check ==="
echo "Taking 3 samples over 30 seconds..."
echo ""

SAMPLES=()
for i in {1..3}; do
    CURRENT_TIME=$(date -Iseconds)
    DAEMON_INFO=$(ps aux | grep '[z]eroclaw daemon' | head -1)
    
    if [ -n "$DAEMON_INFO" ]; then
        MEMORY_KB=$(echo "$DAEMON_INFO" | awk '{print $6}')
        MEMORY_MB=$((MEMORY_KB / 1024))
        CPU_PERCENT=$(echo "$DAEMON_INFO" | awk '{print $3}')
        
        echo "Sample $i [$CURRENT_TIME]: Memory: ${MEMORY_MB}MB, CPU: ${CPU_PERCENT}%"
        SAMPLES+=("$MEMORY_MB")
    else
        echo "Sample $i [$CURRENT_TIME]: No daemon process found"
        SAMPLES+=("0")
    fi
    
    if [ $i -lt 3 ]; then
        sleep 15
    fi
done

echo ""
echo "=== Analysis ==="
if [ ${#SAMPLES[@]} -eq 3 ]; then
    FIRST=${SAMPLES[0]}
    LAST=${SAMPLES[2]}
    GROWTH=$((LAST - FIRST))
    
    echo "First sample: ${FIRST}MB"
    echo "Last sample: ${LAST}MB"
    echo "Growth: ${GROWTH}MB over 30 seconds"
    
    if [ $GROWTH -gt 10 ]; then
        echo "⚠️  WARNING: Significant memory growth detected (>10MB in 30s)"
    elif [ $GROWTH -gt 5 ]; then
        echo "⚠️  CAUTION: Moderate memory growth detected (>5MB in 30s)"
    else
        echo "✅ Memory growth within acceptable range"
    fi
else
    echo "Could not collect enough samples for analysis"
fi