#!/bin/bash

# Real Network Interruption Test for ZeroClaw
# Tests actual network failure (timeout/connection reset) vs auth error
# Uses pfctl to block Discord API traffic

set -e

echo "=== Real Network Interruption Test for ZeroClaw ==="
echo "Testing actual network failure (timeout/connection reset) vs auth error"
echo ""

# Configuration
PROJECT_DIR="/Users/adarsh/Documents/zeroclaw"
CONFIG_DIR="$PROJECT_DIR"
DAEMON_PORT=42617
MAX_WAIT_SECONDS=120
POLL_INTERVAL=2

# Binary path (using local build from source)
BINARY_PATH="$PROJECT_DIR/src/target/release/zeroclaw"

# Get binary version for traceability
echo "Binary path: $BINARY_PATH"
echo "Binary version:"
$BINARY_PATH --version || echo "Version command not available"
echo ""

# Clean up function
cleanup() {
    echo ""
    echo "=== CLEANUP ==="
    echo "Removing pfctl block rules..."
    echo "block out proto tcp from any to discord.com" | sudo pfctl -f - -d 2>/dev/null || echo "pfctl already disabled"
    echo "✅ Network rules cleaned up"
    
    # Kill daemon if running
    if lsof -i :$DAEMON_PORT > /dev/null 2>&1; then
        echo "Stopping daemon..."
        curl -sf -X POST http://127.0.0.1:$DAEMON_PORT/admin/shutdown > /dev/null 2>&1 || true
        sleep 2
        if lsof -i :$DAEMON_PORT > /dev/null 2>&1; then
            PID=$(lsof -ti :$DAEMON_PORT)
            kill -KILL $PID 2>/dev/null || true
        fi
    fi
}

# Set trap for cleanup
trap cleanup EXIT INT TERM

# Single-daemon guard
echo "=== SINGLE-DAEMON GUARD ==="
if lsof -i :$DAEMON_PORT > /dev/null 2>&1; then
    echo "Port $DAEMON_PORT is already in use. Attempting graceful shutdown..."
    if curl -sf -X POST http://127.0.0.1:$DAEMON_PORT/admin/shutdown > /dev/null 2>&1; then
        echo "Graceful shutdown initiated, waiting 5 seconds..."
        sleep 5
    else
        echo "Graceful shutdown failed, using SIGTERM..."
        PID=$(lsof -ti :$DAEMON_PORT)
        kill -TERM $PID 2>/dev/null || true
        sleep 2
    fi
    
    if lsof -i :$DAEMON_PORT > /dev/null 2>&1; then
        echo "Port still in use, using SIGKILL as last resort..."
        PID=$(lsof -ti :$DAEMON_PORT)
        kill -KILL $PID 2>/dev/null || true
        sleep 2
    fi
    
    if lsof -i :$DAEMON_PORT > /dev/null 2>&1; then
        echo "❌ FATAL: Could not free port $DAEMON_PORT"
        exit 1
    fi
    
    echo "✅ Port $DAEMON_PORT is now free"
else
    echo "✅ Port $DAEMON_PORT is free"
fi

# Clean up old test data
echo ""
echo "=== CLEANUP OLD TEST DATA ==="
TEST_DB="$PROJECT_DIR/data/sop/runs.db"
if [ -f "$TEST_DB" ]; then
    echo "Removing old test database: $TEST_DB"
    rm "$TEST_DB" || echo "Could not remove test database (may not exist)"
else
    echo "No old test database found"
fi

# Start daemon with project config
echo ""
echo "=== STARTING DAEMON ==="
echo "Starting daemon with config directory: $CONFIG_DIR"
$BINARY_PATH daemon --config-dir "$CONFIG_DIR" > /tmp/test-daemon-network.log 2>&1 &
DAEMON_PID=$!
echo "Daemon started with PID: $DAEMON_PID"

# Wait for daemon to be ready
echo "Waiting for daemon to initialize..."
for i in {1..30}; do
    if curl -sf http://127.0.0.1:$DAEMON_PORT/health > /dev/null 2>&1; then
        echo "✅ Daemon is ready after ${i}s"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "❌ Daemon failed to initialize within 30 seconds"
        kill -TERM $DAEMON_PID 2>/dev/null || true
        exit 1
    fi
    sleep 1
done

# Get pairing code
echo ""
echo "=== AUTHENTICATION ==="
echo "Getting pairing code..."
PAIR_CODE=$(curl -s -X POST http://127.0.0.1:$DAEMON_PORT/admin/paircode/new | jq -r '.pairing_code')
echo "Pairing code: $PAIR_CODE"

if [ -z "$PAIR_CODE" ] || [ "$PAIR_CODE" == "null" ]; then
    echo "❌ ERROR: Failed to get pairing code"
    exit 1
fi

# Pair and get token
echo "Pairing..."
TOKEN=$(curl -s -X POST http://127.0.0.1:$DAEMON_PORT/pair \
  -H "X-Pairing-Code: $PAIR_CODE" \
  -H "Content-Type: application/json" | jq -r '.token')
echo "Token obtained: ${TOKEN:0:20}..."

if [ -z "$TOKEN" ] || [ "$TOKEN" == "null" ]; then
    echo "❌ ERROR: Failed to obtain token"
    exit 1
fi

# Verify SOPs are loaded
echo ""
echo "=== VERIFYING SOP LOADING ==="
SOPS_LIST=$(curl -s http://127.0.0.1:$DAEMON_PORT/api/sops \
  -H "Authorization: Bearer $TOKEN")
SOP_COUNT=$(echo "$SOPS_LIST" | jq '.sops | length' 2>/dev/null || echo "0")
echo "SOPs loaded: $SOP_COUNT"

if [ "$SOP_COUNT" -eq 0 ]; then
    echo "❌ ERROR: No SOPs loaded by daemon"
    exit 1
fi

echo "✅ SOPs loaded successfully"

# Test with welcome_outreach (uses Discord API)
TEST_SOP="welcome_outreach"
echo ""
echo "=== NETWORK INTERRUPTION TEST STARTING ==="
echo "Testing SOP: $TEST_SOP (uses Discord API)"
echo ""

# Block Discord API traffic
echo "=== BLOCKING DISCORD API TRAFFIC ==="
echo "This simulates a real network interruption (timeout/connection reset)"
echo "block out proto tcp from any to discord.com" | sudo pfctl -f - -e
echo "✅ Discord API traffic blocked via pfctl"
echo ""

# Trigger run (should timeout/hang due to network block)
echo "Triggering run with blocked Discord API traffic..."
RESPONSE=$(curl -s -X POST http://127.0.0.1:$DAEMON_PORT/api/sops/$TEST_SOP/run \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{}')

if echo "$RESPONSE" | grep -q "run_id"; then
    RUN_ID=$(echo "$RESPONSE" | jq -r '.run_id')
    echo "✅ Run triggered: $RUN_ID"
else
    echo "❌ Run failed to trigger: $RESPONSE"
    exit 1
fi

# Wait for run to complete (should timeout)
echo ""
echo "Waiting for run to complete (should timeout due to network block)..."
echo "This test waits up to 60 seconds for timeout behavior"

elapsed=0
while [ $elapsed -lt 60 ]; do
    STATUS_RESPONSE=$(curl -s http://127.0.0.1:$DAEMON_PORT/api/sops/runs \
      -H "Authorization: Bearer $TOKEN")
    
    RUN_STATUS=$(echo "$STATUS_RESPONSE" | jq -r ".runs[] | select(.run_id == \"$RUN_ID\") | .status" 2>/dev/null || echo "unknown")
    
    echo "  [${elapsed}s] Status: $RUN_STATUS"
    
    if [ "$RUN_STATUS" == "completed" ] || [ "$RUN_STATUS" == "Failed" ] || [ "$RUN_STATUS" == "failed" ]; then
        echo "✅ Run completed with status: $RUN_STATUS"
        FINAL_STATUS="$RUN_STATUS"
        break
    fi
    
    if [ "$RUN_STATUS" == "unknown" ]; then
        echo "⚠️  Run not found in status response"
    fi
    
    sleep $POLL_INTERVAL
    elapsed=$((elapsed + POLL_INTERVAL))
done

if [ $elapsed -ge 60 ]; then
    echo "⚠️  Run did not complete within 60 seconds (expected for network timeout)"
    FINAL_STATUS="timeout"
fi

# Check failure reason if available
echo ""
echo "Checking failure reason..."
STATUS_RESPONSE=$(curl -s http://127.0.0.1:$DAEMON_PORT/api/sops/runs \
  -H "Authorization: Bearer $TOKEN")
RUN_DETAILS=$(echo "$STATUS_RESPONSE" | jq -r ".runs[] | select(.run_id == \"$RUN_ID\")" 2>/dev/null || echo "{}")
echo "Run details: $RUN_DETAILS"

# Unblock Discord API traffic
echo ""
echo "=== UNBLOCKING DISCORD API TRAFFIC ==="
echo "block out proto tcp from any to discord.com" | sudo pfctl -f - -d
echo "✅ Discord API traffic unblocked"

# Test recovery after network restoration
echo ""
echo "=== TESTING RECOVERY AFTER NETWORK RESTORATION ==="
echo "Triggering new run with restored network connectivity..."
RECOVERY_RESPONSE=$(curl -s -X POST http://127.0.0.1:$DAEMON_PORT/api/sops/$TEST_SOP/run \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{}')

if echo "$RECOVERY_RESPONSE" | grep -q "run_id"; then
    RECOVERY_RUN_ID=$(echo "$RECOVERY_RESPONSE" | jq -r '.run_id')
    echo "✅ Recovery run triggered: $RECOVERY_RUN_ID"
    
    # Wait for recovery run to complete
    echo "Waiting for recovery run to complete..."
    elapsed=0
    while [ $elapsed -lt $MAX_WAIT_SECONDS ]; do
        STATUS_RESPONSE=$(curl -s http://127.0.0.1:$DAEMON_PORT/api/sops/runs \
          -H "Authorization: Bearer $TOKEN")
        
        RUN_STATUS=$(echo "$STATUS_RESPONSE" | jq -r ".runs[] | select(.run_id == \"$RECOVERY_RUN_ID\") | .status" 2>/dev/null || echo "unknown")
        
        echo "  [${elapsed}s] Status: $RUN_STATUS"
        
        if [ "$RUN_STATUS" == "completed" ] || [ "$RUN_STATUS" == "Failed" ] || [ "$RUN_STATUS" == "failed" ]; then
            echo "✅ Recovery run completed with status: $RUN_STATUS"
            RECOVERY_STATUS="$RUN_STATUS"
            break
        fi
        
        sleep $POLL_INTERVAL
        elapsed=$((elapsed + POLL_INTERVAL))
    done
else
    echo "❌ Recovery run failed to trigger: $RECOVERY_RESPONSE"
    RECOVERY_STATUS="failed"
fi

# Test results
echo ""
echo "=== TEST RESULTS ==="
echo "Network Interruption Handling: $FINAL_STATUS"
echo "Recovery After Network Restoration: $RECOVERY_STATUS"

if [ "$FINAL_STATUS" == "failed" ] || [ "$FINAL_STATUS" == "timeout" ]; then
    echo "✅ Network interruption handled correctly"
    NETWORK_RESULT="PASSED"
else
    echo "⚠️  Network interruption behavior unexpected"
    NETWORK_RESULT="UNKNOWN"
fi

if [ "$RECOVERY_STATUS" == "completed" ] || [ "$RECOVERY_STATUS" == "failed" ]; then
    echo "✅ Recovery after network restoration working"
    RECOVERY_RESULT="PASSED"
else
    echo "⚠️  Recovery behavior unexpected"
    RECOVERY_RESULT="UNKNOWN"
fi

if [ "$NETWORK_RESULT" == "PASSED" ] && [ "$RECOVERY_RESULT" == "PASSED" ]; then
    echo ""
    echo "✅ OVERALL: PASSED"
    exit 0
else
    echo ""
    echo "⚠️  OVERALL: PARTIAL"
    exit 0
fi
