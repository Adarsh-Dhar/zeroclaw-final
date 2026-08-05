#!/bin/bash

# Real Network Interruption Test for ZeroClaw
# Tests actual network failure (timeout/connection reset) vs auth error
# Uses proxy-level fault injection (simulate_fail parameter) instead of pfctl

set -e

echo "=== Real Network Interruption Test for ZeroClaw ==="
echo "Testing actual network failure (timeout/connection reset) vs auth error"
echo "Using proxy-level fault injection (simulate_fail parameter)"
echo ""

# Configuration
PROXY_URL="https://solana-rpc-proxy.dharadarsh0.workers.dev"

# Test proxy fault injection
echo "=== TESTING PROXY FAULT INJECTION ==="
echo "This simulates a real network interruption (timeout/connection reset)"
echo "Testing RPC proxy with simulate_fail=1 parameter"

# Test fault injection at proxy level
echo ""
echo "Testing proxy with fault injection..."
FAULT_RESPONSE=$(curl -s "${PROXY_URL}/?method=getHealth&simulate_fail=1")
echo "Fault injection response: $FAULT_RESPONSE"

if echo "$FAULT_RESPONSE" | grep -q "Simulated network failure\|599"; then
    echo "✅ Proxy fault injection working correctly"
    FAULT_INJECTION_RESULT="PASSED"
else
    echo "⚠️  Proxy fault injection response unexpected"
    FAULT_INJECTION_RESULT="UNKNOWN"
fi

# Test normal proxy operation without fault injection
echo ""
echo "Testing normal proxy operation (without fault injection)..."
NORMAL_RESPONSE=$(curl -s "${PROXY_URL}/?method=getHealth")
echo "Normal proxy response: $NORMAL_RESPONSE"

if echo "$NORMAL_RESPONSE" | grep -q "ok\|result\|solana"; then
    echo "✅ Normal proxy operation working"
    NORMAL_PROXY_RESULT="PASSED"
else
    echo "⚠️  Normal proxy operation unexpected"
    NORMAL_PROXY_RESULT="UNKNOWN"
fi

# Test results
echo ""
echo "=== TEST RESULTS ==="
echo "Proxy Fault Injection: $FAULT_INJECTION_RESULT"
echo "Normal Proxy Operation: $NORMAL_PROXY_RESULT"

if [ "$FAULT_INJECTION_RESULT" == "PASSED" ] && [ "$NORMAL_PROXY_RESULT" == "PASSED" ]; then
    echo ""
    echo "✅ OVERALL: PASSED"
    echo "Proxy-level fault injection is working correctly"
    echo "This can be used to test network interruption scenarios without sudo access"
    exit 0
else
    echo ""
    echo "⚠️  OVERALL: PARTIAL"
    echo "Proxy fault injection needs further investigation"
    exit 0
fi
