#!/bin/bash

# Analyze long-term soak test results for drift detection
# This script examines the health_trend.log for anomalies

set -e

echo "=== Analyzing Long-term Soak Test Results ==="
echo ""

TREND_FILE="/Users/adarsh/Documents/zeroclaw/dev-tools/health_trend.log"

if [ ! -f "$TREND_FILE" ]; then
    echo "❌ Trend file not found: $TREND_FILE"
    echo "Run the soak test first: bash /Users/adarsh/Documents/zeroclaw/test_long_term_soak.sh"
    exit 1
fi

echo "Analyzing trend data from: $TREND_FILE"
echo ""

# Test 1: Memory growth analysis
echo "=== Memory Growth Analysis ==="
echo "Checking for memory leaks..."
MEM_SAMPLES=$(grep -o 'zeroclaw.*[0-9.]*.*%' "$TREND_FILE" | head -20)
if [ -n "$MEM_SAMPLES" ]; then
    echo "Memory samples found. Checking for exponential growth..."
    echo "Recent samples:"
    echo "$MEM_SAMPLES"
    echo ""
    echo "✅ Memory data available for manual analysis"
else
    echo "⚠️  No memory samples found in trend log"
fi

# Test 2: Log file growth analysis
echo ""
echo "=== Log File Growth Analysis ==="
echo "Checking for unbounded log growth..."
LOG_SIZES=$(grep -o 'daemon.log.*[0-9.]*[KMG]' "$TREND_FILE" | tail -10)
if [ -n "$LOG_SIZES" ]; then
    echo "Log size samples:"
    echo "$LOG_SIZES"
    echo ""
    echo "✅ Log growth data available for manual analysis"
else
    echo "⚠️  No log size samples found"
fi

# Test 3: Stuck runs analysis
echo ""
echo "=== Stuck Runs Analysis ==="
echo "Checking for runs stuck in 'running' status..."
STUCK_RUNS=$(grep -i "stuck" "$TREND_FILE" | tail -5)
if [ -n "$STUCK_RUNS" ]; then
    echo "⚠️  Stuck runs detected:"
    echo "$STUCK_RUNS"
    STUCK_DETECTED=true
else
    echo "✅ No stuck runs detected"
    STUCK_DETECTED=false
fi

# Test 4: Total run count analysis
echo ""
echo "=== Run Count Analysis ==="
echo "Checking run count trends..."
RUN_COUNTS=$(grep "Total runs:" "$TREND_FILE" | tail -10)
if [ -n "$RUN_COUNTS" ]; then
    echo "Run count samples:"
    echo "$RUN_COUNTS"
    echo ""
    echo "✅ Run count data available for manual analysis"
else
    echo "⚠️  No run count samples found"
fi

# Test 5: Disk space analysis
echo ""
echo "=== Disk Space Analysis ==="
echo "Checking disk space trends..."
DISK_SAMPLES=$(grep -A 2 "Disk Usage" "$TREND_FILE" | grep -v "Disk Usage" | tail -10)
if [ -n "$DISK_SAMPLES" ]; then
    echo "Disk space samples:"
    echo "$DISK_SAMPLES"
    echo ""
    echo "✅ Disk space data available for manual analysis"
else
    echo "⚠️  No disk space samples found"
fi

# Summary
echo ""
echo "=== Analysis Summary ==="

ISSUES=0

if [ "$STUCK_DETECTED" = true ]; then
    echo "❌ CRITICAL: Stuck runs detected - claim-release may be broken"
    ISSUES=$((ISSUES + 1))
else
    echo "✅ No stuck runs detected"
fi

if [ -n "$MEM_SAMPLES" ]; then
    echo "✅ Memory data collected - manual review required for leak detection"
else
    echo "⚠️  Insufficient memory data for analysis"
fi

if [ -n "$LOG_SIZES" ]; then
    echo "✅ Log growth data collected - manual review required"
else
    echo "⚠️  Insufficient log growth data for analysis"
fi

echo ""
echo "Pass conditions:"
echo "  - Zero runs stuck in 'running' > 10 minutes"
echo "  - Memory growth roughly linear, not exponential"
echo "  - Log file growth proportional to run count"
echo "  - No disk space exhaustion"
echo ""

if [ $ISSUES -eq 0 ]; then
    echo "✅ No critical issues detected"
    echo "Review the trend data manually for subtle trends"
else
    echo "❌ $ISSUES critical issue(s) detected"
    echo "Investigate claim-release mechanism if stuck runs found"
fi

echo ""
echo "=== Analysis Complete ==="
echo ""
echo "For detailed review, examine: $TREND_FILE"
