#!/bin/bash

# Test script to verify SOP loading configuration
# Tests that SOPs load correctly with the configured sops_dir

set -e

echo "=== Testing SOP Loading Configuration ==="
echo ""

# Pre-cleanup to ensure clean environment
echo "Pre-cleanup: removing any existing zeroclaw processes..."
pkill -9 zeroclaw 2>/dev/null || true
sleep 2

# Don't start daemon - just test SOP loading directly via CLI
echo "Testing SOP loading via CLI (no daemon needed)..."
echo ""

# List available SOPs via CLI with correct config-dir
echo ""
echo "Listing available SOPs (with config-dir)..."
/opt/homebrew/bin/zeroclaw sop list --config-dir /Users/adarsh/Documents/zeroclaw > /tmp/sop_list_output.txt 2>&1
cat /tmp/sop_list_output.txt
echo ""

# Verify that SOPs are loaded
if grep -q "role_audit" /tmp/sop_list_output.txt; then
    echo "✅ SOPs loaded successfully with correct sops_dir configuration"
    echo ""
    echo "The sops_dir configuration is working correctly."
else
    echo "❌ SOPs failed to load"
    echo ""
    echo "The sops_dir configuration may still have issues."
fi

echo ""
echo "=== Test Complete ==="