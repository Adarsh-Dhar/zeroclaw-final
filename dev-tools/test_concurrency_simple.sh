#!/bin/bash

# Simple Concurrency Test for ZeroClaw - Test #1 (Highest Priority)
# Tests the claim-release mechanism by triggering multiple SOP runs concurrently
# This validates that no permanent lockout occurs when runs fail or complete

set -e

echo "=== Simple Concurrency Test for ZeroClaw ==="
echo "Testing claim-release mechanism under concurrent load"
echo ""

# Pre-cleanup to ensure clean environment
echo "Pre-cleanup: removing any existing zeroclaw processes..."
pkill -9 zeroclaw 2>/dev/null || true
sleep 2

# Start daemon in background with actual config
echo "Starting daemon with actual config directory..."
CONFIG_DIR="/Users/adarsh/.zeroclaw"
/opt/homebrew/bin/zeroclaw daemon --config-dir "$CONFIG_DIR" > /tmp/test-daemon-concurrency-simple.log 2>&1 &
DAEMON_PID=$!
echo "Daemon started with PID: $DAEMON_PID"
echo "Waiting 20 seconds for daemon to fully initialize and load SOPs..."
sleep 20

# Get pairing code
echo "Getting pairing code..."
PAIR_CODE=$(curl -s -X POST http://127.0.0.1:42617/admin/paircode/new 2>/dev/null | jq -r '.pairing_code' 2>/dev/null || echo "")
echo "Pairing code: $PAIR_CODE"

if [ -z "$PAIR_CODE" ] || [ "$PAIR_CODE" == "null" ]; then
    echo "❌ ERROR: Failed to get pairing code. Daemon may not be fully initialized."
    echo "Waiting additional 10 seconds and retrying..."
    sleep 10
    PAIR_CODE=$(curl -s -X POST http://127.0.0.1:42617/admin/paircode/new 2>/dev/null | jq -r '.pairing_code' 2>/dev/null || echo "")
    echo "Retry pairing code: $PAIR_CODE"
    
    if [ -z "$PAIR_CODE" ] || [ "$PAIR_CODE" == "null" ]; then
        echo "❌ FATAL ERROR: Could not obtain pairing code. Aborting test."
        kill $DAEMON_PID 2>/dev/null || true
        exit 1
    fi
fi

# Pair and get token
echo "Pairing..."
TOKEN=$(curl -s -X POST http://127.0.0.1:42617/pair \
  -H "X-Pairing-Code: $PAIR_CODE" \
  -H "Content-Type: application/json" 2>/dev/null | jq -r '.token' 2>/dev/null || echo "")
echo "Token obtained: ${TOKEN:0:20}..."

if [ -z "$TOKEN" ] || [ "$TOKEN" == "null" ]; then
    echo "❌ FATAL ERROR: Could not obtain token. Aborting test."
    kill $DAEMON_PID 2>/dev/null || true
    exit 1
fi

echo ""
echo "=== CONCURRENCY TEST STARTING ==="
echo "Will trigger 5 concurrent role_audit SOP runs to test claim-release mechanism"
echo ""

# Array to store run IDs
declare -a RUN_IDS

# Trigger 5 concurrent runs using role_audit
for i in {1..5}; do
    echo "Triggering run #$i for role_audit..."
    RESPONSE=$(curl -s -X POST http://127.0.0.1:42617/api/sops/role_audit/run \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $TOKEN" \
      -d '{}' 2>/dev/null)
    
    if echo "$RESPONSE" | grep -q "run_id"; then
        RUN_ID=$(echo "$RESPONSE" | jq -r '.run_id' 2>/dev/null || echo "unknown")
        RUN_IDS[$i]=$RUN_ID
        echo "✅ Run #$i triggered successfully: $RUN_ID"
    else
        echo "❌ Run #$i failed to trigger: $RESPONSE"
    fi
    
    # Small delay between triggers to simulate realistic concurrent load
    sleep 0.5
done

echo ""
echo "All 5 runs triggered. Waiting 20 seconds for runs to complete/fail..."
sleep 20

# Check status of all runs
echo ""
echo "=== CHECKING RUN STATUSES ==="
STATUS_RESPONSE=$(curl -s http://127.0.0.1:42617/api/sops/runs \
  -H "Authorization: Bearer $TOKEN" 2>/dev/null)

echo "Current run status:"
echo "$STATUS_RESPONSE" | jq '.' 2>/dev/null || echo "$STATUS_RESPONSE"

# Count runs by status
RUNNING_COUNT=$(echo "$STATUS_RESPONSE" | jq '[.runs[]? | select(.status == "running")] | length' 2>/dev/null || echo "0")
FAILED_COUNT=$(echo "$STATUS_RESPONSE" | jq '[.runs[]? | select(.status == "Failed" or .status == "failed")] | length' 2>/dev/null || echo "0")
COMPLETED_COUNT=$(echo "$STATUS_RESPONSE" | jq '[.runs[]? | select(.status == "completed" or .status == "Completed")] | length' 2>/dev/null || echo "0")

echo ""
echo "Status summary:"
echo "Running: $RUNNING_COUNT"
echo "Failed: $FAILED_COUNT"
echo "Completed: $COMPLETED_COUNT"

# Check for stuck runs (running > 10 minutes)
echo ""
echo "=== CHECKING FOR STUCK RUNS ==="
if [[ "$OSTYPE" == "darwin"* ]]; then
    TEN_MINUTES_AGO=$(date -v-10M -Iseconds)
else
    TEN_MINUTES_AGO=$(date -d '10 minutes ago' -Iseconds)
fi

STUCK_RUNS=$(echo "$STATUS_RESPONSE" | jq ".runs[]? | select(.status == \"running\" and .started_at < \"$TEN_MINUTES_AGO\")" 2>/dev/null || echo "")

if [ -n "$STUCK_RUNS" ] && [ "$STUCK_RUNS" != "null" ]; then
    echo "❌ STUCK RUNS DETECTED (running > 10 minutes):"
    echo "$STUCK_RUNS"
    STUCK_RUNS_FOUND=true
else
    echo "✅ No stuck runs detected"
    STUCK_RUNS_FOUND=false
fi

# Now try to trigger a new run - this should succeed if claim-release is working
echo ""
echo "=== TESTING CLAIM-RELEASE MECHANISM ==="
echo "Attempting to trigger a new run after the concurrent test..."
RESPONSE_NEW=$(curl -s -X POST http://127.0.0.1:42617/api/sops/role_audit/run \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{}' 2>/dev/null)

echo "New run response: $RESPONSE_NEW"

if echo "$RESPONSE_NEW" | grep -q "cooldown\|concurrency\|limit\|already running"; then
    echo ""
    echo "❌ CONCURRENCY TEST FAILED: New run blocked"
    echo "The claim-release mechanism is not working properly - runs are not releasing claims."
    TEST_RESULT="FAILED"
elif echo "$RESPONSE_NEW" | grep -q "run_id"; then
    echo ""
    echo "✅ CONCURRENCY TEST PASSED: New run succeeded"
    echo "The claim-release mechanism is working properly - previous runs released their claims."
    TEST_RESULT="PASSED"
else
    echo ""
    echo "⚠️  UNEXPECTED RESPONSE: $RESPONSE_NEW"
    TEST_RESULT="INCONCLUSIVE"
fi

# Final verification - check if any runs are still stuck
echo ""
echo "=== FINAL VERIFICATION ==="
echo "Waiting additional 20 seconds to ensure all runs complete..."
sleep 20

FINAL_STATUS=$(curl -s http://127.0.0.1:42617/api/sops/runs \
  -H "Authorization: Bearer $TOKEN" 2>/dev/null)

FINAL_RUNNING=$(echo "$FINAL_STATUS" | jq '[.runs[]? | select(.status == "running")] | length' 2>/dev/null || echo "0")
echo "Final running count: $FINAL_RUNNING"

if [ "$FINAL_RUNNING" -gt 0 ]; then
    echo "❌ FINAL VERIFICATION FAILED: $FINAL_RUNNING runs still stuck in 'running' state"
    echo "Runs that are still running:"
    echo "$FINAL_STATUS" | jq '.runs[]? | select(.status == "running")' 2>/dev/null || echo "Could not parse stuck runs"
    echo "Full status response:"
    echo "$FINAL_STATUS"
    if [ "$TEST_RESULT" == "PASSED" ]; then
        TEST_RESULT="FAILED"
    fi
else
    echo "✅ FINAL VERIFICATION PASSED: No runs stuck in 'running' state"
fi

# Check daemon logs for claim/release patterns
echo ""
echo "=== CHECKING DAEMON LOGS ==="
echo "Recent claim/release log entries:"
tail -200 /tmp/test-daemon-concurrency-simple.log | grep -i "claim\|release\|finish_run" || echo "No claim/release logs found"

# Cleanup
echo ""
echo "=== CLEANUP ==="
echo "Stopping daemon..."
kill $DAEMON_PID 2>/dev/null || true
sleep 5
pkill -9 zeroclaw 2>/dev/null || true
ps aux | grep '[z]eroclaw' | awk '{print $2}' | xargs kill -9 2>/dev/null || true

# Run comprehensive cleanup
echo "Running comprehensive cleanup..."
if [ -f "/Users/adarsh/Documents/zeroclaw/dev-tools/cleanup_zeroclaw.sh" ]; then
    /Users/adarsh/Documents/zeroclaw/dev-tools/cleanup_zeroclaw.sh
fi

# Final result
echo ""
echo "=== CONCURRENCY TEST RESULT: $TEST_RESULT ==="
echo ""
if [ "$TEST_RESULT" == "PASSED" ]; then
    echo "✅ SUCCESS: Claim-release mechanism working correctly"
    echo "   - All concurrent runs completed or failed gracefully"
    echo "   - No runs stuck in 'running' state"
    echo "   - New runs can be triggered after concurrent load"
elif [ "$TEST_RESULT" == "FAILED" ]; then
    echo "❌ FAILURE: Claim-release mechanism broken"
    echo "   - Runs are not releasing claims properly"
    echo "   - New runs may be blocked by stuck runs"
    echo "   - This indicates a permanent lockout risk"
else
    echo "⚠️  INCONCLUSIVE: Unable to determine test result"
    echo "   - Check logs and API responses for more details"
fi

echo ""
echo "Test completed. Logs saved to: /tmp/test-daemon-concurrency-simple.log"

# Exit with appropriate code
if [ "$TEST_RESULT" == "PASSED" ]; then
    exit 0
elif [ "$TEST_RESULT" == "FAILED" ]; then
    exit 1
else
    exit 2
fi
