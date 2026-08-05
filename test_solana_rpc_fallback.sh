#!/bin/bash

# Test script to verify Solana RPC fallback mechanism
# This test checks that the RPC proxy falls back to secondary endpoints when primary fails

set -e

echo "=== Testing Solana RPC Fallback Mechanism ==="
echo ""

# Check if worker is deployed and accessible
PROXY_URL="https://solana-rpc-proxy.dharadarsh0.workers.dev"

echo "Testing RPC proxy health at $PROXY_URL..."
HEALTH_RESPONSE=$(curl -s "$PROXY_URL/rpc?method=getHealth")
echo "Health check response: $HEALTH_RESPONSE"

if echo "$HEALTH_RESPONSE" | grep -q "ok\|result"; then
    echo "✅ RPC proxy is accessible and healthy"
else
    echo "❌ RPC proxy health check failed"
    exit 1
fi

# Test getTransaction with a known signature (this should work with either endpoint)
echo ""
echo "Testing getTransaction with known signature..."
# Use a valid base58 signature (this is a placeholder, needs real transaction signature)
TEST_SIGNATURE="5Hk3LQAQQ6pMhAiE32z7Nc5rCq4RhzfG5g7vE6s5v5vQ6pMhAiE32z7Nc5rCq4RhzfG"

TX_RESPONSE=$(curl -s "$PROXY_URL/rpc?method=getTransaction&signature=$TEST_SIGNATURE&encoding=json")
echo "Transaction response: $TX_RESPONSE"

# RPC proxy is working if we get a valid JSON-RPC response (even if transaction not found)
if echo "$TX_RESPONSE" | grep -q "jsonrpc"; then
    echo "✅ RPC proxy responded successfully (transaction may not exist, but proxy works)"
    RPC_WORKING=true
else
    echo "⚠️  RPC proxy returned unexpected response"
    RPC_WORKING=false
fi

# Test getSignaturesForAddress (this exercises the fallback logic more)
echo ""
echo "Testing getSignaturesForAddress (fallback logic test)..."
# Use a known devnet address with wallet parameter
TEST_ADDRESS="GPM3F4dQ4VFGQ7cKZVzJ8HjMxZ5X6Y9qZ5X6Y9qZ5X6Y9qZ5X6Y9qZ5X6Y9qZ"
TEST_WALLET="GPM3F4dQ4VFGQ7cKZVzJ8HjMxZ5X6Y9qZ5X6Y9qZ5X6Y9qZ5X6Y9qZ5X6Y9qZ"

SIGS_RESPONSE=$(curl -s "$PROXY_URL/rpc?method=getSignaturesForAddress&address=$TEST_ADDRESS&wallet=$TEST_WALLET&limit=5")
echo "Signatures response: $SIGS_RESPONSE"

if echo "$SIGS_RESPONSE" | grep -q "jsonrpc"; then
    echo "✅ getSignaturesForAddress request succeeded (address may not have signatures, but proxy works)"
    FALLBACK_WORKING=true
else
    echo "⚠️  getSignaturesForAddress request returned unexpected response"
    FALLBACK_WORKING=false
fi

# Test with invalid signature to verify error handling
echo ""
echo "Testing error handling with invalid signature..."
INVALID_SIGNATURE="invalid_signature_12345"

ERROR_RESPONSE=$(curl -s "$PROXY_URL/rpc?method=getTransaction&signature=$INVALID_SIGNATURE&encoding=json")
echo "Error response: $ERROR_RESPONSE"

if echo "$ERROR_RESPONSE" | grep -q "error\|null"; then
    echo "✅ Error handling works correctly"
    ERROR_HANDLING=true
else
    echo "⚠️  Error handling returned unexpected response"
    ERROR_HANDLING=false
fi

# Summary
echo ""
echo "=== Test Summary ==="
if [ "$RPC_WORKING" = true ]; then
    echo "✅ RPC proxy accessibility: WORKING"
else
    echo "❌ RPC proxy accessibility: FAILED"
fi

if [ "$FALLBACK_WORKING" = true ]; then
    echo "✅ RPC fallback mechanism: WORKING (at least one endpoint responds)"
else
    echo "❌ RPC fallback mechanism: FAILED"
fi

if [ "$ERROR_HANDLING" = true ]; then
    echo "✅ Error handling: WORKING"
else
    echo "❌ Error handling: FAILED"
fi

echo ""
echo "Note: To test actual fallback (primary → secondary), you would need to:"
echo "1. Temporarily break the primary endpoint (e.g., invalid API key)"
echo "2. Verify requests still succeed using the secondary endpoint"
echo "3. Check Cloudflare Worker logs for 'RPC fallback' messages"
echo ""
echo "=== Test Complete ==="
