#!/bin/bash

# Final concurrency test using role_audit (max_concurrent=1) to properly test concurrency guard

set -e

echo "=== Testing Concurrency Guard and Claim-Release ==="
echo ""

# Pre-cleanup
echo "Pre-cleanup: removing any existing zeroclaw processes..."
pkill -9 zeroclaw 2>/dev/null || true
sleep 2

# Start daemon
echo "Starting daemon with project config..."
/opt/homebrew/bin/zeroclaw daemon --config-dir /Users/adarsh/Documents/zeroclaw > /tmp/test-concurrency-final.log 2>&1 &
DAEMON_PID=$!
echo "Daemon started with PID: $DAEMON_PID"
sleep 10

# Get pairing token
echo "Getting pairing token..."
PAIR_CODE=$(curl -s -X POST http://127.0.0.1:42617/admin/paircode/new | jq -r '.pairing_code')
TOKEN=$(curl -s -X POST http://127.0.0.1:42617/pair \
  -H "X-Pairing-Code: $PAIR_CODE" \
  -H "Content-Type: application/json" | jq -r '.token')
echo "Token obtained: ${TOKEN:0:20}..."

# Check SOP status
echo ""
echo "Checking SOP status..."
curl -s http://127.0.0.1:42617/api/sops -H "Authorization: Bearer $TOKEN" | jq '.sops[].name'

# Trigger first run (role_audit has max_concurrent=1)
echo ""
echo "Triggering first role_audit run (max_concurrent=1)..."
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

# Immediately try second trigger (should be rejected by concurrency guard)
echo ""
echo "Immediately attempting second trigger (should be rejected by concurrency guard)..."
RESPONSE2=$(curl -s -X POST http://127.0.0.1:42617/api/sops/role_audit/run \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{}')
echo "Second trigger response: $RESPONSE2"

if echo "$RESPONSE2" | grep -q "cooldown\|concurrency\|limit\|Skipped\|Coalesced"; then
    echo "✅ Concurrency guard correctly rejected second trigger"
    CONCURRENCY_GUARD_WORKING=true
elif echo "$RESPONSE2" | grep -q "run_id"; then
    echo "❌ Second trigger succeeded (concurrency guard NOT working - max_concurrent=1 should reject)"
    CONCURRENCY_GUARD_WORKING=false
else
    echo "⚠️  Unexpected response: $RESPONSE2"
    CONCURRENCY_GUARD_WORKING=false
fi

# Wait for first run to complete
echo ""
echo "Waiting 20 seconds for first run to complete..."
sleep 20

# Check run status
echo ""
echo "Checking run status..."
STATUS_RESPONSE=$(curl -s http://127.0.0.1:42617/api/sops/runs \
  -H "Authorization: Bearer $TOKEN")
echo "Status response: $STATUS_RESPONSE"

# Try third trigger (should succeed if claim was released)
echo ""
echo "Attempting third trigger after completion (test claim release)..."
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
    echo "❌ Concurrency guard: FAILED"
fi

if [ "$CLAIM_RELEASE_WORKING" = true ]; then
    echo "✅ Claim release: WORKING"
else
    echo "❌ Claim release: FAILED"
fi

echo ""
echo "=== Test Complete ==="
