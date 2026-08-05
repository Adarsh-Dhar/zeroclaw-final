#!/bin/bash

# Long-term soak test for detecting drift over time
# This script runs the health monitoring for 3-7 days and analyzes trends

set -e

echo "=== Long-term Soak Test Setup ==="
echo ""

# Configuration
TEST_DURATION_DAYS=${1:-3}  # Default 3 days, can be overridden
HEALTH_SCRIPT="/Users/adarsh/Documents/zeroclaw/dev-tools/health_snapshot.sh"
CRON_ENTRY="0 * * * * $HEALTH_SCRIPT"
TREND_FILE="/Users/adarsh/Documents/zeroclaw/dev-tools/health_trend.log"

echo "Test duration: $TEST_DURATION_DAYS days"
echo "Health script: $HEALTH_SCRIPT"
echo "Trend file: $TREND_FILE"
echo ""

# Check if daemon is running
echo "Checking if ZeroClaw daemon is running..."
if pgrep -f "zeroclaw daemon" > /dev/null; then
    echo "✅ Daemon is running"
else
    echo "❌ Daemon is not running. Starting daemon..."
    /opt/homebrew/bin/zeroclaw daemon --config-dir /Users/adarsh/Documents/zeroclaw > /tmp/soak-test-daemon.log 2>&1 &
    DAEMON_PID=$!
    echo "Daemon started with PID: $DAEMON_PID"
    sleep 10
fi

# Get current crontab
echo ""
echo "Checking current crontab..."
CURRENT_CRON=$(crontab -l 2>/dev/null || echo "")

# Check if health snapshot is already scheduled
if echo "$CURRENT_CRON" | grep -q "$HEALTH_SCRIPT"; then
    echo "⚠️  Health snapshot already scheduled in crontab"
    echo "Current entry:"
    echo "$CURRENT_CRON" | grep "$HEALTH_SCRIPT"
    echo ""
    echo "Would you like to keep the existing schedule? (y/n)"
    read -r response
    if [ "$response" != "y" ]; then
        echo "Removing existing entry..."
        crontab -l 2>/dev/null | grep -v "$HEALTH_SCRIPT" | crontab -
    fi
fi

# Add health snapshot to crontab
echo ""
echo "Adding health snapshot to crontab (hourly)..."
(crontab -l 2>/dev/null | grep -v "$HEALTH_SCRIPT"; echo "$CRON_ENTRY") | crontab -
echo "✅ Health snapshot scheduled for hourly execution"

# Run initial snapshot
echo ""
echo "Running initial health snapshot..."
$HEALTH_SCRIPT
echo "✅ Initial snapshot completed"

# Display monitoring instructions
echo ""
echo "=== Soak Test Started ==="
echo ""
echo "The daemon will run uninterrupted for $TEST_DURATION_DAYS days."
echo "Health snapshots will be captured hourly to: $TREND_FILE"
echo ""
echo "Monitoring checklist:"
echo "  1. Check daemon logs: tail -f /Users/adarsh/.zeroclaw/logs/daemon.log"
echo "  2. Monitor memory: watch -n 60 'ps aux | grep zeroclaw'"
echo "  3. Review trend data: tail -f $TREND_FILE"
echo "  4. Check for stuck runs: curl -s http://127.0.0.1:42617/api/sops/runs"
echo ""
echo "After $TEST_DURATION_DAYS days, run:"
echo "  bash /Users/adarsh/Documents/zeroclaw/analyze_soak_results.sh"
echo ""
echo "To stop the test early:"
echo "  1. Remove crontab entry: crontab -l | grep -v health_snapshot | crontab -"
echo "  2. Stop daemon: pkill -9 zeroclaw"
echo "  3. Analyze results: bash /Users/adarsh/Documents/zeroclaw/analyze_soak_results.sh"
echo ""
echo "Press Enter to confirm test start, or Ctrl+C to cancel..."
read -r

echo ""
echo "✅ Soak test started at $(date)"
echo "Expected completion: $(date -v+${TEST_DURATION_DAYS}d)"