#!/bin/bash
# Test script for SOPs - captures before/after memory state for diffing

set -e

SOP_NAME="${1:-}"
if [ -z "$SOP_NAME" ]; then
    echo "Usage: $0 <sop_name>"
    echo "Available SOPs: subscription_check, role_audit, welcome_outreach"
    exit 1
fi

echo "Testing SOP: $SOP_NAME"
echo "========================================"
echo "Capturing before state..."

# Get current memory state
GATEWAY_PORT=${GATEWAY_PORT:-42617}
AUTH_TOKEN=${AUTH_TOKEN:-zc_0470c268e2453188581af5314845342c7fd53b6faef50a0d33475ffdfbd64b2d}

curl -s -X GET "http://127.0.0.1:${GATEWAY_PORT}/api/memory?query=subscriber:" -H "Authorization: Bearer ${AUTH_TOKEN}" > /tmp/before_subscribers.json 2>/dev/null || echo "No subscriber records found"
curl -s -X GET "http://127.0.0.1:${GATEWAY_PORT}/api/memory?query=welcomed:" -H "Authorization: Bearer ${AUTH_TOKEN}" > /tmp/before_welcomed.json 2>/dev/null || echo "No welcomed records found"
curl -s -X GET "http://127.0.0.1:${GATEWAY_PORT}/api/memory?query=error:" -H "Authorization: Bearer ${AUTH_TOKEN}" > /tmp/before_errors.json 2>/dev/null || echo "No error records found"

echo "Running SOP: $SOP_NAME"
curl -s -X POST http://127.0.0.1:${GATEWAY_PORT}/api/sop/trigger -H "Authorization: Bearer ${AUTH_TOKEN}" -H "Content-Type: application/json" -d "{\"sop_name\": \"$SOP_NAME\"}"

echo ""
echo "Waiting for SOP to complete..."
sleep 5

echo "Capturing after state..."
curl -s -X GET "http://127.0.0.1:${GATEWAY_PORT}/api/memory?query=subscriber:" -H "Authorization: Bearer ${AUTH_TOKEN}" > /tmp/after_subscribers.json 2>/dev/null || echo "No subscriber records found"
curl -s -X GET "http://127.0.0.1:${GATEWAY_PORT}/api/memory?query=welcomed:" -H "Authorization: Bearer ${AUTH_TOKEN}" > /tmp/after_welcomed.json 2>/dev/null || echo "No welcomed records found"
curl -s -X GET "http://127.0.0.1:${GATEWAY_PORT}/api/memory?query=error:" -H "Authorization: Bearer ${AUTH_TOKEN}" > /tmp/after_errors.json 2>/dev/null || echo "No error records found"

echo ""
echo "========================================"
echo "DIFFS:"
echo "========================================"

echo "Subscriber records diff:"
diff /tmp/before_subscribers.json /tmp/after_subscribers.json || echo "Changes detected in subscriber records"

echo ""
echo "Welcomed records diff:"
diff /tmp/before_welcomed.json /tmp/after_welcomed.json || echo "Changes detected in welcomed records"

echo ""
echo "Error records diff:"
diff /tmp/before_errors.json /tmp/after_errors.json || echo "Changes detected in error records"

echo ""
echo "========================================"
echo "Test complete for $SOP_NAME"
