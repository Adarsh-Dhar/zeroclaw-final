# Step-by-Step Cloudflare Worker Deployment Guide

This guide will walk you through deploying the Solana RPC proxy to Cloudflare Workers and getting your public URL.

## Prerequisites

- A Cloudflare account (free tier is sufficient)
- Node.js installed on your machine
- npm package manager

## Step 1: Install Wrangler CLI

Wrangler is Cloudflare's command-line tool for deploying Workers.

```bash
npm install -g wrangler
```

Verify installation:
```bash
wrangler --version
```

## Step 2: Login to Cloudflare

Authenticate with your Cloudflare account:

```bash
wrangler login
```

This will open a browser window where you'll:
1. Log in to your Cloudflare account (or create one if you don't have one)
2. Authorize Wrangler to access your account
3. Return to the terminal once authorized

## Step 3: Navigate to the Proxy Directory

```bash
cd /Users/adarsh/.zeroclaw/solana-rpc-proxy
```

Verify the files are present:
```bash
ls -la
```

You should see:
- `worker.js` - The Worker code
- `wrangler.toml` - Worker configuration
- `README.md` - Documentation

## Step 4: Configure Worker Name (Optional)

Open `wrangler.toml` and customize the worker name if desired:

```toml
name = "solana-rpc-proxy"  # You can change this
main = "worker.js"
compatibility_date = "2024-01-01"
```

The worker name will become part of your URL: `https://solana-rpc-proxy.YOUR-ACCOUNT.workers.dev`

## Step 5: Deploy the Worker

Deploy the worker to Cloudflare:

```bash
wrangler deploy
```

You'll see output like:
```
✨ Built successfully
✨ Deployed solana-rpc-proxy (X sec)
  https://solana-rpc-proxy.YOUR-ACCOUNT.workers.dev
```

**Copy the URL shown** - this is your deployed worker URL.

## Step 6: Test the Deployed Worker

Test your deployed worker with a simple health check:

```bash
curl "https://YOUR-WORKER-URL.workers.dev/?method=getHealth"
```

Expected response:
```json
{"jsonrpc":"2.0","result":"ok","id":123456}
```

Test with a real wallet address:
```bash
curl "https://YOUR-WORKER-URL.workers.dev/?method=getSignaturesForAddress&wallet=11111111111111111111111111111111&limit=5"
```

## Step 7: Update SKILL.md with Your URL

Edit the SKILL.md file with your actual deployed URL:

```bash
nano /Users/adarsh/.zeroclaw/shared/skills/default/check-payment/SKILL.md
```

Or use your preferred editor.

Replace:
```
**Proxy URL:** https://solana-rpc-proxy.YOUR-ACCOUNT.workers.dev
```

With your actual URL:
```
**Proxy URL:** https://YOUR-ACTUAL-URL.workers.dev
```

Also update the GET request URLs in the same file:
```
- http_request tool with: GET https://YOUR-ACTUAL-URL.workers.dev/?method=getSignaturesForAddress&wallet=<MERCHANT_WALLET>&limit=50
```

## Step 8: Restart ZeroClaw Daemon

```bash
# Find the daemon process
ps aux | grep zeroclaw

# Kill the daemon (replace PID with actual process ID)
kill <PID>

# Start the daemon again
zeroclaw daemon --config-dir /Users/adarsh/.zeroclaw
```

## Step 9: Test the Integration

Test the subscription check with the real proxy:

```bash
zeroclaw agent -a test_agent -m "Use the check-payment skill to check payment status for wallet EYSHit3n1e6qQWKG6L4g34SNoG6P7R9U7y6MGREBLebB against merchant wallet pt6Ws1FMbdrLbUZqKooediS8mu6SNvDJodzXUx6ypak"
```

Expected output:
```
EYSHit3n1e6qQWKG6L4g34SNoG6P7R9U7y6MGREBLebB: ❌ lapsed (last paid: none found) | role_action: no_change | current_role: no_role
```

Or if there are recent payments:
```
EYSHit3n1e6qQWKG6L4g34SNoG6P7R9U7y6MGREBLebB: ✅ active (last paid: 2026-07-15) | role_action: grant_role/no_change | current_role: has_role/no_role
```

## Troubleshooting

### Wrangler login fails
- Ensure you have a Cloudflare account
- Try logging out and back in: `wrangler logout` then `wrangler login`

### Deployment fails
- Check your internet connection
- Verify `wrangler.toml` syntax is correct
- Ensure you have sufficient permissions on your Cloudflare account

### Worker returns errors
- Check the worker logs: `wrangler tail`
- Verify the worker code in `worker.js` is correct
- Test the Solana RPC endpoint directly: `curl -X POST https://api.mainnet-beta.solana.com -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}'`

### ZeroClaw still reports RPC errors
- Verify the URL in SKILL.md matches your deployed worker URL exactly
- Check the daemon is using the updated config: restart the daemon
- Test the worker URL directly with curl to ensure it's working

## Security Notes

- The worker is public and accessible to anyone
- It only forwards requests to the official Solana mainnet-beta RPC endpoint
- Consider adding rate limiting for production use (Cloudflare Workers has built-in rate limiting)
- Monitor usage in your Cloudflare dashboard

## Cost

Cloudflare Workers free tier includes:
- 100,000 requests per day
- 10ms CPU time per request
- This should be sufficient for the subscription check use case

If you exceed free tier limits, pricing starts at $5/month for 10 million requests.
