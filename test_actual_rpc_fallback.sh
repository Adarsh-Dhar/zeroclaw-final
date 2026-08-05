#!/bin/bash

# Test actual Solana RPC fallback by breaking the primary endpoint
# This tests the real failover behavior, not just that the proxy is responsive

set -e

echo "=== Testing Actual Solana RPC Fallback ==="
echo ""

# Current working directory should have the worker.js
WORKER_DIR="/Users/adarsh/Documents/zeroclaw/solana-rpc-proxy"
cd "$WORKER_DIR"

# Backup the original worker.js
echo "Backing up original worker.js..."
cp worker.js worker.js.backup

# Break the primary endpoint by invalidating the API key
echo ""
echo "Breaking primary endpoint (invalidating HELIUS_API_KEY)..."
# Replace the first endpoint with an invalid one
sed -i.bak 's|https://devnet.helius-rpc.com/?api-key=${env.HELIUS_API_KEY}|https://invalid-endpoint-that-does-not-exist.com|g' worker.js

# Deploy the modified worker
echo ""
echo "Deploying modified worker to test fallback..."
# Note: This assumes you have wrangler configured
# If you don't have wrangler CLI access, this test would need to be done manually
echo "Manual deployment required: wrangler deploy"
echo "Would you like to proceed with manual deployment? (y/n)"
read -r response

if [ "$response" != "y" ]; then
    echo "Aborting test. Restoring original worker.js..."
    mv worker.js.backup worker.js
    rm worker.js.bak
    exit 0
fi

# Wait for deployment
echo ""
echo "Waiting 10 seconds for deployment to take effect..."
sleep 10

# Test with broken primary endpoint
echo ""
echo "Testing RPC with broken primary endpoint..."
PROXY_URL="https://solana-rpc-proxy.dharadarsh0.workers.dev"

# Test getHealth
HEALTH_RESPONSE=$(curl -s "$PROXY_URL/rpc?method=getHealth")
echo "Health check: $HEALTH_RESPONSE"

if echo "$HEALTH_RESPONSE" | grep -q "ok\|result"; then
    echo "✅ Fallback working - proxy still responds despite broken primary"
    FALLBACK_WORKING=true
else
    echo "❌ Fallback failed - proxy not responding"
    FALLBACK_WORKING=false
fi

# Restore original worker.js
echo ""
echo "Restoring original worker.js..."
mv worker.js.backup worker.js
rm worker.js.bak

# Re-deploy original worker
echo ""
echo "Re-deploying original worker..."
echo "Manual deployment required: wrangler deploy"
echo "Press Enter when deployment is complete..."
read -r

# Verify normal operation
echo ""
echo "Verifying normal operation after restore..."
HEALTH_RESPONSE=$(curl -s "$PROXY_URL/rpc?method=getHealth")
echo "Health check: $HEALTH_RESPONSE"

if echo "$HEALTH_RESPONSE" | grep -q "ok\|result"; then
    echo "✅ Normal operation restored"
else
    echo "⚠️  Normal operation not restored"
fi

# Check Cloudflare Worker logs for fallback message
echo ""
echo "To verify fallback occurred, check Cloudflare Worker logs:"
echo "  wrangler tail"
echo "Look for: 'RPC fallback: primary failed, using ...'"

# Summary
echo ""
echo "=== Test Summary ==="
if [ "$FALLBACK_WORKING" = true ]; then
    echo "✅ Actual RPC fallback: WORKING"
else
    echo "❌ Actual RPC fallback: FAILED"
fi

echo ""
echo "=== Test Complete ==="
