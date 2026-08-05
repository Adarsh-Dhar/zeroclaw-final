#!/bin/bash

# Generic cleanup script for ZeroClaw test environments
# Ensures no zombie processes remain after testing

echo "=== ZeroClaw Cleanup ==="

# Kill all zeroclaw processes
echo "Killing all zeroclaw processes..."
pkill -9 zeroclaw 2>/dev/null || true
sleep 2

# Force kill any remaining processes
echo "Force killing any remaining processes..."
ps aux | grep '[z]eroclaw' | awk '{print $2}' | xargs kill -9 2>/dev/null || true

# Clean up temporary log files
echo "Cleaning up temporary log files..."
rm -f /tmp/test-daemon*.log 2>/dev/null || true
rm -f /tmp/daemon*.log 2>/dev/null || true

# Verify cleanup
REMAINING=$(ps aux | grep '[z]eroclaw' | wc -l)
if [ "$REMAINING" -eq 0 ]; then
    echo "✅ Cleanup successful - no zeroclaw processes remaining"
else
    echo "⚠️  $REMAINING zeroclaw processes still running"
    ps aux | grep '[z]eroclaw'
fi

echo "=== Cleanup Complete ==="