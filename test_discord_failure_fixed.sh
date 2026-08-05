#!/bin/bash

# Fixed Discord API Failure Test for ZeroClaw - Test #2
# Tests Discord API failure handling with corrected methodology:
# - Uses single-daemon guard to prevent port conflicts
# - Polls run status instead of fixed sleep
# - Graceful shutdown instead of SIGKILL
# - Status polling to verify actual failure state
# - Binary version tracking

set -e

echo "=== Fixed Discord API Failure Test for ZeroClaw ==="
echo "Testing Discord API failure handling with corrected methodology"
echo ""

# Configuration
PROJECT_DIR="/Users/adarsh/Documents/zeroclaw"
CONFIG_DIR="$PROJECT_DIR"
DAEMON_PORT=42617
MAX_WAIT_SECONDS=60  # Maximum time to wait for run completion
POLL_INTERVAL=2       # Status poll interval in seconds

# Binary path (using local build from source)
BINARY_PATH="$PROJECT_DIR/src/target/release/zeroclaw"
# BINARY_PATH="/opt/homebrew/bin/zeroclaw"

# Helper functions
restore_config() {
    if [ -f "$BACKUP_FILE" ]; then
        echo "Restoring original config from $BACKUP_FILE"
        mv "$BACKUP_FILE" "$CONFIG_FILE"
    else
        echo "❌ Backup file not found: $BACKUP_FILE"
    fi
}

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

# Backup original config
echo ""
echo "=== BACKUP CONFIGURATION ==="
CONFIG_FILE="$CONFIG_DIR/config.toml"
BACKUP_FILE="$CONFIG_DIR/config.toml.discord_test_backup"
if [ -f "$CONFIG_FILE" ]; then
    cp "$CONFIG_FILE" "$BACKUP_FILE"
    echo "✅ Config backed up to $BACKUP_FILE"
else
    echo "❌ Config file not found: $CONFIG_FILE"
    exit 1
fi

# Extract current Discord token
ORIGINAL_TOKEN=$(grep -A 5 '\[channels.discord\]' "$CONFIG_FILE" | grep 'bot_token' | head -1 | sed 's/.*bot_token = "\(.*\)".*/\1/' || echo "")
echo "Original token: ${ORIGINAL_TOKEN:0:20}..."

# Set invalid Discord token
echo ""
echo "=== SETTING INVALID DISCORD TOKEN ==="
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' 's/bot_token = .*/bot_token = "invalid_token_for_testing_purposes_only"/' "$CONFIG_FILE"
else
    sed -i 's/bot_token = .*/bot_token = "invalid_token_for_testing_purposes_only"/' "$CONFIG_FILE"
fi
echo "✅ Invalid token set in config"

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

# Start daemon with invalid token
echo ""
echo "=== STARTING DAEMON WITH INVALID TOKEN ==="
echo "Starting daemon with config directory: $CONFIG_DIR"
$BINARY_PATH daemon --config-dir "$CONFIG_DIR" > /tmp/test-daemon-discord-failure.log 2>&1 &
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
        restore_config
        graceful_shutdown
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
    restore_config
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
    restore_config
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
    restore_config
    graceful_shutdown
    exit 1
fi

echo "✅ SOPs loaded successfully"

# Use welcome_outreach as test SOP (uses Discord API)
TEST_SOP="welcome_outreach"
echo ""
echo "=== DISCORD API FAILURE TEST STARTING ==="
echo "Testing SOP: $TEST_SOP (uses Discord API)"
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

# Trigger run with invalid Discord token
echo "Triggering run with invalid Discord token..."
RESPONSE=$(curl -s -X POST http://127.0.0.1:$DAEMON_PORT/api/sops/$TEST_SOP/run \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{}')

if echo "$RESPONSE" | grep -q "run_id"; then
    RUN_ID=$(echo "$RESPONSE" | jq -r '.run_id')
    echo "✅ Run triggered: $RUN_ID"
else
    echo "❌ Run failed to trigger: $RESPONSE"
    restore_config
    graceful_shutdown
    exit 1
fi

# Wait for run to complete using status polling
echo ""
echo "Waiting for run to complete (should fail due to invalid token)..."
if wait_for_run_completion "$RUN_ID" $MAX_WAIT_SECONDS; then
    echo "✅ Run completed"
else
    echo "⚠️  Run did not complete within timeout"
fi

# Check final status
STATUS_RESPONSE=$(curl -s http://127.0.0.1:$DAEMON_PORT/api/sops/runs \
  -H "Authorization: Bearer $TOKEN")
FINAL_STATUS=$(echo "$STATUS_RESPONSE" | jq -r ".runs[] | select(.run_id == \"$RUN_ID\") | .status" 2>/dev/null || echo "unknown")
echo "Final status: $FINAL_STATUS"

# Check for proper failure handling
if [ "$FINAL_STATUS" == "Failed" ] || [ "$FINAL_STATUS" == "failed" ]; then
    echo "✅ Discord API failure handled correctly - run marked as Failed"
    FAILURE_HANDLING_RESULT="PASSED"
elif [ "$FINAL_STATUS" == "running" ]; then
    echo "❌ Discord API failure NOT handled correctly - run stuck in running"
    FAILURE_HANDLING_RESULT="FAILED"
else
    echo "⚠️  Unexpected status: $FINAL_STATUS"
    FAILURE_HANDLING_RESULT="INCONCLUSIVE"
fi

# Check daemon logs for error handling
echo ""
echo "=== CHECKING DAEMON LOGS ==="
echo "Recent daemon logs:"
tail -50 /tmp/test-daemon-discord-failure.log | grep -i "discord\|error\|failed" || echo "No Discord/error logs found"

# Graceful shutdown
graceful_shutdown

# Restore original config
echo ""
echo "=== RESTORING ORIGINAL CONFIGURATION ==="
restore_config

# Restart daemon with valid token to verify recovery
echo ""
echo "=== VERIFYING RECOVERY WITH VALID TOKEN ==="
echo "Restarting daemon with valid Discord token..."
$BINARY_PATH daemon --config-dir "$CONFIG_DIR" > /tmp/test-daemon-recovery.log 2>&1 &
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

# Get new pairing code
echo "Getting new pairing code..."
PAIR_CODE=$(curl -s -X POST http://127.0.0.1:$DAEMON_PORT/admin/paircode/new | jq -r '.pairing_code')
TOKEN=$(curl -s -X POST http://127.0.0.1:$DAEMON_PORT/pair \
  -H "X-Pairing-Code: $PAIR_CODE" \
  -H "Content-Type: application/json" | jq -r '.token')

# Attempt trigger with valid token
echo "Attempting trigger with valid token..."
RECOVERY_RESPONSE=$(curl -s -X POST http://127.0.0.1:$DAEMON_PORT/api/sops/$TEST_SOP/run \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{}')

if echo "$RECOVERY_RESPONSE" | grep -q "run_id"; then
    echo "✅ Recovery successful - trigger succeeded with valid token"
    RECOVERY_RESULT="PASSED"
else
    echo "❌ Recovery failed - trigger blocked: $RECOVERY_RESPONSE"
    RECOVERY_RESULT="FAILED"
fi

# Graceful shutdown
graceful_shutdown

# Final results
echo ""
echo "=== TEST RESULTS ==="
echo "Discord API Failure Handling: $FAILURE_HANDLING_RESULT"
echo "Recovery After Failure: $RECOVERY_RESULT"
echo ""

if [ "$FAILURE_HANDLING_RESULT" == "PASSED" ] && [ "$RECOVERY_RESULT" == "PASSED" ]; then
    echo "✅ OVERALL: PASSED"
    exit 0
else
    echo "❌ OVERALL: FAILED"
    exit 1
fi
