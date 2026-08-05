#!/bin/bash

# Fixed Concurrency Test for ZeroClaw - Test #1 (Highest Priority)
# Tests the claim-release mechanism with corrected methodology:
# - Uses single-daemon guard to prevent port conflicts
# - Polls run status instead of fixed sleep
# - Graceful shutdown instead of SIGKILL
# - Status polling to verify actual completion
# - Binary version tracking

set -e

echo "=== Fixed Concurrency Test for ZeroClaw ==="
echo "Testing claim-release mechanism with corrected methodology"
echo ""

# Configuration
PROJECT_DIR="/Users/adarsh/Documents/zeroclaw"
CONFIG_DIR="$PROJECT_DIR"
DAEMON_PORT=42617
MAX_WAIT_SECONDS=120  # Maximum time to wait for run completion
POLL_INTERVAL=2       # Status poll interval in seconds

# Binary path (can be switched to local build when disk space allows)
# BINARY_PATH="$PROJECT_DIR/src/target/release/zeroclaw"
BINARY_PATH="/opt/homebrew/bin/zeroclaw"

# Get binary version for traceability
echo "Binary path: $BINARY_PATH"
echo "Binary version:"
$BINARY_PATH --version || echo "Version command not available"
echo ""

# Single-daemon guard: ensure port 42617 is free
echo "=== SINGLE-DAEMON GUARD ==="
if lsof -i :$DAEMON_PORT > /dev/null 2>&1; then
    echo "Port $DAEMON_PORT is already in use. Attempting graceful shutdown..."
    
    # Try graceful shutdown first
    if curl -sf -X POST http://127.0.0.1:$DAEMON_PORT/admin/shutdown > /dev/null 2>&1; then
        echo "Graceful shutdown initiated, waiting 5 seconds..."
        sleep 5
    else
        echo "Graceful shutdown failed, using SIGTERM..."
        PID=$(lsof -ti :$DAEMON_PORT)
        kill -TERM $PID 2>/dev/null || true
        sleep 2
    fi
    
    # Final check and force kill if needed
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

# Clean up any old test data to prevent claim bleeding
echo ""
echo "=== CLEANUP OLD TEST DATA ==="
TEST_DB="$PROJECT_DIR/data/sop_store.db"
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
$BINARY_PATH daemon --config-dir "$CONFIG_DIR" > /tmp/test-daemon-fixed.log 2>&1 &
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
    graceful_shutdown
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
    graceful_shutdown
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
    echo "This indicates a configuration issue with sops_dir"
    graceful_shutdown
    exit 1
fi

echo "✅ SOPs loaded successfully"

# Use role_audit as test SOP (max_concurrent=1, has manual trigger)
TEST_SOP="role_audit"
echo ""
echo "=== CONCURRENCY TEST STARTING ==="
echo "Testing SOP: $TEST_SOP (max_concurrent=1)"
echo ""

# Function to poll run status until completion
wait_for_run_completion() {
    local run_id=$1
    local max_wait=$2
    local elapsed=0
    
    echo "Waiting for run $run_id to complete (max ${max_wait}s)..."
    
    while [ $elapsed -lt $max_wait ]; do
        STATUS_RESPONSE=$(curl -s http://127.0.0.1:$DAEMON_PORT/api/sops/runs \
          -H "Authorization: Bearer $TOKEN")
        
        RUN_STATUS=$(echo "$STATUS_RESPONSE" | jq -r ".runs[] | select(.run_id == \"$run_id\") | .status" 2>/dev/null || echo "unknown")
        
        echo "  [${elapsed}s] Status: $RUN_STATUS"
        
        if [ "$RUN_STATUS" == "completed" ] || [ "$RUN_STATUS" == "Failed" ] || [ "$RUN_STATUS" == "failed" ]; then
            echo "✅ Run completed with status: $RUN_STATUS"
            return 0
        fi
        
        if [ "$RUN_STATUS" == "unknown" ]; then
            echo "⚠️  Run not found in status response"
        fi
        
        sleep $POLL_INTERVAL
        elapsed=$((elapsed + POLL_INTERVAL))
    done
    
    echo "❌ Run did not complete within ${max_wait}s"
    return 1
}

# Trigger first run
echo "Triggering first run..."
RESPONSE1=$(curl -s -X POST http://127.0.0.1:$DAEMON_PORT/api/sops/$TEST_SOP/run \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{}')

if echo "$RESPONSE1" | grep -q "run_id"; then
    RUN_ID1=$(echo "$RESPONSE1" | jq -r '.run_id')
    echo "✅ First run triggered: $RUN_ID1"
else
    echo "❌ First run failed to trigger: $RESPONSE1"
    graceful_shutdown
    exit 1
fi

# Immediately attempt second trigger (should be rejected by concurrency guard)
echo ""
echo "Immediately attempting second trigger (should be rejected)..."
RESPONSE2=$(curl -s -X POST http://127.0.0.1:$DAEMON_PORT/api/sops/$TEST_SOP/run \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{}')

if echo "$RESPONSE2" | grep -q "cooldown\|concurrency\|limit\|already running"; then
    echo "✅ Concurrency guard correctly rejected second trigger"
    CONCURRENCY_GUARD_RESULT="PASSED"
else
    echo "❌ Concurrency guard did not reject second trigger: $RESPONSE2"
    CONCURRENCY_GUARD_RESULT="FAILED"
fi

# Wait for first run to complete using status polling
echo ""
echo "Waiting for first run to complete..."
if wait_for_run_completion "$RUN_ID1" $MAX_WAIT_SECONDS; then
    echo "✅ First run completed successfully"
else
    echo "⚠️  First run did not complete within timeout, proceeding with claim release test"
fi

# Check final status of first run
STATUS_RESPONSE=$(curl -s http://127.0.0.1:$DAEMON_PORT/api/sops/runs \
  -H "Authorization: Bearer $TOKEN")
FINAL_STATUS=$(echo "$STATUS_RESPONSE" | jq -r ".runs[] | select(.run_id == \"$RUN_ID1\") | .status" 2>/dev/null || echo "unknown")
echo "Final status of first run: $FINAL_STATUS"

# Attempt third trigger to test claim release
echo ""
echo "Attempting third trigger (should succeed if claim was released)..."
RESPONSE3=$(curl -s -X POST http://127.0.0.1:$DAEMON_PORT/api/sops/$TEST_SOP/run \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{}')

if echo "$RESPONSE3" | grep -q "run_id"; then
    RUN_ID3=$(echo "$RESPONSE3" | jq -r '.run_id')
    echo "✅ Claim release working: Third trigger succeeded with run_id: $RUN_ID3"
    CLAIM_RELEASE_RESULT="PASSED"
else
    echo "❌ Claim release failed: Third trigger blocked: $RESPONSE3"
    CLAIM_RELEASE_RESULT="FAILED"
fi

# Check for stuck claims in database
echo ""
echo "=== CHECKING FOR STUCK CLAIMS ==="
if [ -f "$TEST_DB" ]; then
    echo "Checking sop_claims table for stuck claims..."
    if command -v sqlite3 &> /dev/null; then
        STUCK_CLAIMS=$(sqlite3 "$TEST_DB" "SELECT run_id, lease_expires FROM sop_claims WHERE lease_expires > datetime('now')" 2>/dev/null || echo "")
        if [ -n "$STUCK_CLAIMS" ]; then
            echo "❌ STUCK CLAIMS FOUND:"
            echo "$STUCK_CLAIMS"
        else
            echo "✅ No stuck claims found"
        fi
    else
        echo "sqlite3 not available, skipping claim check"
    fi
else
    echo "Test database not found at $TEST_DB"
fi

# Graceful shutdown function
graceful_shutdown() {
    echo ""
    echo "=== GRACEFUL SHUTDOWN ==="
    echo "Attempting graceful shutdown via API..."
    if curl -sf -X POST http://127.0.0.1:$DAEMON_PORT/admin/shutdown > /dev/null 2>&1; then
        echo "✅ Graceful shutdown initiated"
        sleep 5
    else
        echo "⚠️  Graceful shutdown failed, using SIGTERM..."
        kill -TERM $DAEMON_PID 2>/dev/null || true
        sleep 2
    fi
    
    # Final cleanup if still running
    if ps -p $DAEMON_PID > /dev/null 2>&1; then
        echo "Process still running, using SIGKILL..."
        kill -KILL $DAEMON_PID 2>/dev/null || true
    fi
}

# Cleanup
graceful_shutdown

# Final results
echo ""
echo "=== TEST RESULTS ==="
echo "Concurrency Guard: $CONCURRENCY_GUARD_RESULT"
echo "Claim Release: $CLAIM_RELEASE_RESULT"
echo ""

if [ "$CONCURRENCY_GUARD_RESULT" == "PASSED" ] && [ "$CLAIM_RELEASE_RESULT" == "PASSED" ]; then
    echo "✅ OVERALL: PASSED"
    exit 0
else
    echo "❌ OVERALL: FAILED"
    exit 1
fi
