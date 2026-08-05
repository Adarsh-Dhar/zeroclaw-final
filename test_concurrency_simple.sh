#!/bin/bash

# Simple concurrency test using CLI tools
# Tests the concurrency guard by rapid-fire triggering and checking responses

set -e

echo "=== Testing Concurrency Guard (CLI-based) ==="
echo ""

# Pre-cleanup
echo "Pre-cleanup: removing any existing zeroclaw processes..."
pkill -9 zeroclaw 2>/dev/null || true
sleep 2

# Start daemon
echo "Starting daemon with project config..."
/opt/homebrew/bin/zeroclaw daemon --config-dir /Users/adarsh/Documents/zeroclaw > /tmp/test-concurrency-daemon.log 2>&1 &
DAEMON_PID=$!
echo "Daemon started with PID: $DAEMON_PID"
sleep 5

# Get pairing token
echo "Getting pairing token..."
PAIR_CODE=$(curl -s -X POST http://127.0.0.1:42617/admin/paircode/new | jq -r '.pairing_code')
TOKEN=$(curl -s -X POST http://127.0.0.1:42617/pair \
  -H "X-Pairing-Code: $PAIR_CODE" \
  -H "Content-Type: application/json" | jq -r '.token')
echo "Token obtained: ${TOKEN:0:20}..."

# Check for active runs first
echo ""
echo "Checking initial SOP runs status..."
curl -s http://127.0.0.1:42617/api/sops/runs \
  -H "Authorization: Bearer $TOKEN" | jq '.'

# Trigger first run
echo ""
echo "Triggering first run..."
RESPONSE1=$(curl -s -X POST http://127.0.0.1:42617/api/sops/role_audit/run \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{}')
echo "First trigger response: $RESPONSE1"

if echo "$RESPONSE1" | grep -q "run_id"; then
    echo "✅ First trigger succeeded"
    RUN_ID1=$(echo "$RESPONSE1" | jq -r '.run_id')
    echo "Run ID: $RUN_ID1"
else
    echo "❌ First trigger failed: $RESPONSE1"
    kill $DAEMON_PID 2>/dev/null || true
    exit 1
fi

# Immediately try second trigger (should be rejected if concurrency guard works)
echo ""
echo "Immediately attempting second trigger (should be rejected by concurrency guard)..."
RESPONSE2=$(curl -s -X POST http://127.0.0.1:42617/api/sops/role_audit/run \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{}')
echo "Second trigger response: $RESPONSE2"

if echo "$RESPONSE2" | grep -q "cooldown\|concurrency\|limit\|Skipped"; then
    echo "✅ Concurrency guard correctly rejected second trigger"
    CONCURRENCY_GUARD_WORKING=true
elif echo "$RESPONSE2" | grep -q "run_id"; then
    echo "⚠️  Second trigger succeeded (concurrency guard may not be working)"
    CONCURRENCY_GUARD_WORKING=false
else
    echo "⚠️  Unexpected response: $RESPONSE2"
    CONCURRENCY_GUARD_WORKING=false
fi

# Wait for first run to complete
echo ""
echo "Waiting 30 seconds for first run to complete..."
sleep 30

# Check run status
echo ""
echo "Checking run status..."
curl -s http://127.0.0.1:42617/api/sops/runs \
  -H "Authorization: Bearer $TOKEN" | jq '.'

# Try third trigger (should succeed now if claim was released)
echo ""
echo "Attempting third trigger after completion (should succeed if claim released)..."
RESPONSE3=$(curl -s -X POST http://127.0.0.1:42617/api/sops/role_audit/run \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{}')
echo "Third trigger response: $RESPONSE3"

if echo "$RESPONSE3" | grep -q "run_id"; then
    echo "✅ Third trigger succeeded (claim was released)"
    CLAIM_RELEASE_WORKING=true
else
    echo "❌ Third trigger failed (claim may not have been released)"
    CLAIM_RELEASE_WORKING=false
fi

# Cleanup
echo ""
echo "Stopping daemon..."
kill $DAEMON_PID 2>/dev/null || true
sleep 2
pkill -9 zeroclaw 2>/dev/null || true

# Summary
echo ""
echo "=== Test Summary ==="
if [ "$CONCURRENCY_GUARD_WORKING" = true ]; then
    echo "✅ Concurrency guard: WORKING"
else
    echo "❌ Concurrency guard: FAILED/INCONCLUSIVE"
fi

if [ "$CLAIM_RELEASE_WORKING" = true ]; then
    echo "✅ Claim release: WORKING"
else
    echo "❌ Claim release: FAILED"
fi

echo ""
echo "=== Test Complete ==="
