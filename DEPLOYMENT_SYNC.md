# Deployment Sync - Critical Information

**Date Resolved:** August 1, 2026

## Root Cause of QR Code Issue (RESOLVED)

The zeroclaw daemon reads skill files from a **separate deployed location** (`~/.zeroclaw/`) that is NOT automatically synchronized with the git repository. This means:

### Source vs Deployed Files

**Source (Git Repo):**
- `/Users/adarsh/Documents/zeroclaw/shared/skills/default/onboarding/SKILL.md`
- `/Users/adarsh/Documents/zeroclaw/sops/onboarding_check/SOP.md`

**Deployed (Actual Daemon Reads):**
- `/Users/adarsh/.zeroclaw/shared/skills/default/onboarding/SKILL.md`
- `/Users/adarsh/.zeroclaw/skills/default/onboarding/SKILL.md`
- SOP files: Verified no .md files exist under ~/.zeroclaw/sop/ (only runs.db found)

### The Problem

When we edited the git repo files to remove dial.to and QR code references, the daemon continued reading the **old deployed copies** under `~/.zeroclaw/` that still contained the old format. This caused:

1. Identical reference keys appearing across multiple attempts (daemon reading stale deployed files)
2. QR code format persisting despite git repo edits
3. Reloads and restarts having no effect (daemon reading different files than we were editing)

### The Fix

**Manual Sync Required:**
After editing source files in the git repo, you must manually copy them to the deployed location:

```bash
# Copy updated skill files to deployed location
cp /Users/adarsh/Documents/zeroclaw/shared/skills/default/onboarding/SKILL.md \
   /Users/adarsh/.zeroclaw/shared/skills/default/onboarding/SKILL.md

cp /Users/adarsh/Documents/zeroclaw/shared/skills/default/onboarding/SKILL.md \
   /Users/adarsh/.zeroclaw/skills/default/onboarding/SKILL.md

# Note: SOP files do not exist as .md files in deployed location
# SOPs appear to be managed internally by zeroclaw (only runs.db found in ~/.zeroclaw/sop/)
# SOP changes may be handled differently or automatically synced

# Restart daemon to pick up changes
pkill -f "zeroclaw daemon"
sleep 2
zeroclaw daemon --config-dir ~/.zeroclaw &
```

### Verification

After syncing, verify the deployed files contain the expected content:

```bash
# Check deployed skill files contain correct format
find ~/.zeroclaw -iname "SKILL.md" -path "*onboarding*" 2>/dev/null -exec grep -n "pay_url\|self-hosted" {} \;

# Ensure no old QR code references remain
find ~/.zeroclaw -iname "SKILL.md" -path "*onboarding*" 2>/dev/null -exec grep -n "QR:\|chart.googleapis\|api.qrserver" {} \;
```

### Long-term Solution

Consider:
1. Creating a deployment script that automatically syncs git repo files to `~/.zeroclaw/`
2. Setting up symlinks instead of copying files
3. Investigating if zeroclaw has a built-in mechanism to specify source directories

### Legacy Script Found

Also discovered and disabled:
- `dev-tools/onboarding_check.sh` - legacy shell script that was competing with the real SOP
- Renamed to `onboarding_check.sh.disabled` to prevent execution
- This was the same issue documented in REMEDIATION_COMPLETE.md for subscription_check

### Current Status

✅ Deployed skill files updated with self-hosted payment page format
✅ QR code references removed from deployed files  
✅ Legacy script disabled
✅ Daemon restarted with fresh skill bundles
✅ Both git repo and deployed locations now synchronized

**Always verify BOTH locations after making changes!**
