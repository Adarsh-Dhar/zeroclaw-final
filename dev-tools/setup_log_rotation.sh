#!/bin/bash

# Log Rotation Setup for ZeroClaw
# Configures automatic log rotation to prevent disk space issues

LOG_DIR="/Users/adarsh/.zeroclaw/logs"
LOGROTATE_CONF="$HOME/.logrotate_zeroclaw"
LOGROTATE_STATE="$HOME/.logrotate_zeroclaw_state"

echo "Setting up log rotation for ZeroClaw..."

# Create logrotate configuration
cat > "$LOGROTATE_CONF" << 'EOF'
# ZeroClaw Log Rotation Configuration
# Rotates logs to prevent disk space issues

/Users/adarsh/.zeroclaw/logs/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 adarsh staff
    size 10M
    maxage 30
}

/Users/adarsh/.zeroclaw/logs/*.stderr {
    daily
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    create 0640 adarsh staff
    size 5M
    maxage 14
}

/Users/adarsh/.zeroclaw/logs/*.stdout {
    daily
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    create 0640 adarsh staff
    size 5M
    maxage 14
}
EOF

echo "Logrotate configuration created: $LOGROTATE_CONF"

# Test logrotate configuration
if command -v logrotate &> /dev/null; then
    echo "Testing logrotate configuration..."
    logrotate --dry-run --state "$LOGROTATE_STATE" "$LOGROTATE_CONF"
    echo "Logrotate test successful"
else
    echo "logrotate not found, installing via homebrew..."
    brew install logrotate
fi

# Set up daily cron job for logrotate
CRON_JOB="0 0 * * * /usr/local/bin/logrotate --state $LOGROTATE_STATE $LOGROTATE_CONF"

# Check if cron job already exists
if crontab -l 2>/dev/null | grep -q "logrotate_zeroclaw"; then
    echo "Cron job already exists for logrotate"
else
    echo "Adding daily cron job for logrotate..."
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    echo "Cron job added successfully"
fi

echo ""
echo "=== Log Rotation Setup Complete ==="
echo "Configuration: $LOGROTATE_CONF"
echo "State file: $LOGROTATE_STATE"
echo "Cron job: Daily at midnight"
echo ""
echo "Log rotation will:"
echo "- Rotate .log files daily, keep 7 days, compress old logs"
echo "- Rotate .stderr/.stdout files daily, keep 3 days, compress"
echo "- Trigger rotation when files exceed 10M (.log) or 5M (.stderr/.stdout)"
echo "- Delete logs older than 30 days (.log) or 14 days (.stderr/.stdout)"