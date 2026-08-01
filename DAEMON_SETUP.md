# ZeroClaw Daemon Setup - macOS launchd

This document describes the persistent daemon setup for ZeroClaw on macOS using launchd.

## Overview

The ZeroClaw daemon is configured to run as a persistent background service using macOS launchd. This ensures the daemon:
- Starts automatically on system boot
- Restarts automatically if it crashes
- Runs continuously in the background
- Logs output to dedicated log files

## launchd Configuration

**File:** `~/Library/LaunchAgents/com.zeroclaw.daemon.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.zeroclaw.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/adarsh/.cargo/bin/zeroclaw</string>
        <string>daemon</string>
        <string>--config-dir</string>
        <string>/Users/adarsh/.zeroclaw</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/Users/adarsh/.zeroclaw/logs/daemon.stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/adarsh/.zeroclaw/logs/daemon.stderr.log</string>
    <key>WorkingDirectory</key>
    <string>/Users/adarsh/.zeroclaw</string>
</dict>
</plist>
```

## Management Commands

### Check daemon status
```bash
launchctl list | grep zeroclaw
ps aux | grep zeroclaw
curl http://localhost:42617/health
```

### Start daemon
```bash
launchctl load -w ~/Library/LaunchAgents/com.zeroclaw.daemon.plist
```

### Stop daemon
```bash
launchctl unload ~/Library/LaunchAgents/com.zeroclaw.daemon.plist
```

### Restart daemon
```bash
launchctl unload ~/Library/LaunchAgents/com.zeroclaw.daemon.plist
launchctl load -w ~/Library/LaunchAgents/com.zeroclaw.daemon.plist
```

### View logs
```bash
cat /Users/adarsh/.zeroclaw/logs/daemon.stdout.log
cat /Users/adarsh/.zeroclaw/logs/daemon.stderr.log
```

## Cron Job Configuration

The subscription check SOP is configured to run every 5 minutes via the built-in cron scheduler:

```bash
zeroclaw cron add "*/5 * * * *" 'agent -m "Execute the subscription_check SOP to check payment status for all subscribers"' -a sop_agent
```

### Check cron jobs
```bash
zeroclaw cron list
```

### Remove cron job
```bash
zeroclaw cron remove <job_id>
```

## Troubleshooting

If the daemon is not running:
1. Check launchd status: `launchctl list | grep zeroclaw`
2. Check logs: `cat /Users/adarsh/.zeroclaw/logs/daemon.stderr.log`
3. Restart: `launchctl unload ~/Library/LaunchAgents/com.zeroclaw.daemon.plist && launchctl load -w ~/Library/LaunchAgents/com.zeroclaw.daemon.plist`

If cron jobs are not executing:
1. Check cron status: `zeroclaw cron list`
2. Verify daemon is running: `curl http://localhost:42617/health`
3. Re-add cron job if needed

## Setup Date

**Date:** August 1, 2026  
**Purpose:** Configure persistent daemon and cron job for automatic payment verification
