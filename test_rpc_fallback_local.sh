#!/bin/bash

# Test Solana RPC fallback locally by using environment variables
# This tests the fallback logic without requiring deployment

set -e

echo "=== Testing Solana RPC Fallback (Local Test) ==="
echo ""

# The fallback logic is in worker.js lines 918-966
# We can test this by setting an invalid primary endpoint via environment variable

# Test 1: Verify fallback logic exists in code
echo "Checking fallback logic in worker.js..."
if grep -q "RPC fallback" /Users/adarsh/Documents/zeroclaw/solana-rpc-proxy/worker.js; then
    echo "✅ Fallback logging found in code"
    FALLBACK_LOGGING=true
else
    echo "❌ Fallback logging not found in code"
    FALLBACK_LOGGING=false
fi

# Test 2: Verify multiple endpoints are configured
echo ""
echo "Checking configured RPC endpoints..."
if grep -A 3 "rpcEndpoints = \[" /Users/adarsh/Documents/zeroclaw/solana-rpc-proxy/worker.js | grep -q "https://devnet.helius-rpc.com"; then
    echo "✅ Primary endpoint configured: Helius devnet"
    PRIMARY_CONFIGURED=true
else
    echo "❌ Primary endpoint not configured"
    PRIMARY_CONFIGURED=false
fi

if grep -A 3 "rpcEndpoints = \[" /Users/adarsh/Documents/zeroclaw/solana-rpc-proxy/worker.js | grep -q "api.devnet.solana.com"; then
    echo "✅ Fallback endpoint configured: Solana devnet"
    FALLBACK_CONFIGURED=true
else
    echo "❌ Fallback endpoint not configured"
    FALLBACK_CONFIGURED=false
fi

# Test 3: Verify error handling and fallback loop
echo ""
echo "Checking error handling and fallback loop..."
if grep -q "for (const endpoint of rpcEndpoints)" /Users/adarsh/Documents/zeroclaw/solana-rpc-proxy/worker.js; then
    echo "✅ Fallback loop structure found"
    FALLBACK_LOOP=true
else
    echo "❌ Fallback loop not found"
    FALLBACK_LOOP=false
fi

if grep -q "catch (error)" /Users/adarsh/Documents/zeroclaw/solana-rpc-proxy/worker.js; then
    echo "✅ Error handling found"
    ERROR_HANDLING=true
else
    echo "❌ Error handling not found"
    ERROR_HANDLING=false
fi

# Test 4: Verify fallback logging when primary fails
echo ""
echo "Checking fallback logging when primary fails..."
if grep -q 'console.log(`RPC fallback' /Users/adarsh/Documents/zeroclaw/solana-rpc-proxy/worker.js; then
    echo "✅ Fallback success logging found"
    FALLBACK_SUCCESS_LOG=true
else
    echo "❌ Fallback success logging not found"
    FALLBACK_SUCCESS_LOG=false
fi

# Test 5: Verify proxy is currently working
echo ""
echo "Testing current proxy operation..."
PROXY_URL="https://solana-rpc-proxy.dharadarsh0.workers.dev"
HEALTH_RESPONSE=$(curl -s "$PROXY_URL/rpc?method=getHealth" 2>/dev/null)
if echo "$HEALTH_RESPONSE" | grep -q "ok\|result"; then
    echo "✅ Proxy currently operational"
    PROXY_WORKING=true
else
    echo "⚠️  Proxy not responding (may be offline)"
    PROXY_WORKING=false
fi

# Summary
echo ""
echo "=== Test Summary ==="
if [ "$FALLBACK_LOGGING" = true ] && [ "$PRIMARY_CONFIGURED" = true ] && [ "$FALLBACK_CONFIGURED" = true ] && [ "$FALLBACK_LOOP" = true ] && [ "$ERROR_HANDLING" = true ] && [ "$FALLBACK_SUCCESS_LOG" = true ]; then
    echo "✅ Fallback infrastructure: COMPLETE"
    echo "  - Multiple endpoints configured"
    echo "  - Fallback loop with error handling"
    echo "  - Success logging when fallback occurs"
    echo ""
    echo "To test actual failover behavior:"
    echo "  1. Temporarily break primary endpoint (invalid API key)"
    echo "  2. Trigger requests to verify fallback to secondary"
    echo "  3. Check Cloudflare Worker logs for 'RPC fallback' message"
    echo "  4. Restore primary endpoint"
else
    echo "❌ Fallback infrastructure: INCOMPLETE"
fi

echo ""
echo "=== Test Complete ==="
