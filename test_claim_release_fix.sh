#!/bin/bash

# Test script to verify claim-release bug fix (bypassing router issues)
# This directly tests the claim-release functionality using manual SOP triggers

set -e

echo "=== Testing Claim-Release Bug Fix (Router Bypass) ==="
echo ""

# Start daemon in background
echo "Starting daemon..."
cd /Users/adarsh/Documents/zeroclaw
./src/target/debug/zeroclaw daemon --config-dir . > /tmp/test-daemon-bypass.log 2>&1 &
DAEMON_PID=$!
echo "Daemon started with PID: $DAEMON_PID"
sleep 10

# Get pairing code
echo "Getting pairing code..."
PAIR_CODE=$(curl -s -X POST http://127.0.0.1:42617/admin/paircode/new | jq -r '.pairing_code')
echo "Pairing code: $PAIR_CODE"

# Pair and get token
echo "Pairing..."
TOKEN=$(curl -s -X POST http://127.0.0.1:42617/pair \
  -H "X-Pairing-Code: $PAIR_CODE" \
  -H "Content-Type: application/json" | jq -r '.token')
echo "Token obtained: ${TOKEN:0:20}..."

# Try to trigger role_audit manually
echo ""
echo "Attempting to trigger role_audit manually..."
RESPONSE=$(curl -s -X POST http://127.0.0.1:42617/api/sops/role_audit/run \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}')

echo "Response: $RESPONSE"

# Check for signature error
if echo "$RESPONSE" | grep -q "cooldown or concurrency limit reached"; then
    echo ""
    echo "❌ BUG STILL PRESENT: Concurrency limit reached (claim not released)"
    echo "This indicates the claim-release bug is still active."
elif echo "$RESPONSE" | grep -q "run_id"; then
    echo ""
    echo "✅ SUCCESS: Manual trigger worked"
    echo "The SOP engine matched the manual trigger and started a run."
    RUN_ID=$(echo "$RESPONSE" | jq -r '.run_id')
    echo "Run ID: $RUN_ID"
    
    # Wait for run to complete
    echo ""
    echo "Waiting 20 seconds for run to complete..."
    sleep 20
    
    # Try to trigger again - this should succeed if claim was released
    echo ""
    echo "Attempting to trigger role_audit again (to test claim release)..."
    RESPONSE2=$(curl -s -X POST http://127.0.0.1:42617/api/sops/role_audit/run \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d '{}')
    
    echo "Second trigger response: $RESPONSE2"
    
    if echo "$RESPONSE2" | grep -q "cooldown or concurrency limit reached"; then
        echo ""
        echo "❌ CLAIM-RELEASE BUG STILL PRESENT: Second trigger blocked"
        echo "The first run did not release its claim properly."
    elif echo "$RESPONSE2" | grep -q "run_id"; then
        echo ""
        echo "✅ CLAIM-RELEASE FIX VERIFIED: Second trigger succeeded"
        echo "The first run properly released its claim, allowing the second run to start."
        RUN_ID2=$(echo "$RESPONSE2" | jq -r '.run_id')
        echo "Second Run ID: $RUN_ID2"
    else
        echo ""
        echo "⚠️  UNEXPECTED SECOND RESPONSE: $RESPONSE2"
    fi
    
    # Check logs for claim release
    echo ""
    echo "Checking daemon logs for claim release..."
    tail -100 /tmp/test-daemon-bypass.log | grep -i "claim\|release\|finish_run" || echo "No claim/release logs found"
else
    echo ""
    echo "⚠️  UNEXPECTED RESPONSE: $RESPONSE"
fi

# Cleanup
echo ""
echo "Stopping daemon..."
kill $DAEMON_PID 2>/dev/null || true
pkill -9 zeroclaw 2>/dev/null || true

echo ""
echo "=== Test Complete ==="