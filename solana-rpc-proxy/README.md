# Solana RPC Proxy

This Cloudflare Worker provides a public GET endpoint that forwards requests to Solana RPC as POST requests. This works around the ZeroClaw `http_request` tool's POST body bug.

## Deployment

1. Install Wrangler CLI:
```bash
npm install -g wrangler
```

2. Login to Cloudflare:
```bash
wrangler login
```

3. Deploy the worker:
```bash
cd /Users/adarsh/.zeroclaw/solana-rpc-proxy
wrangler deploy
```

4. Note the deployed URL (e.g., `https://solana-rpc-proxy.YOUR-ACCOUNT.workers.dev`)

## Usage

The proxy accepts GET requests with query parameters:

### getSignaturesForAddress
```
GET https://your-worker.workers.dev/?method=getSignaturesForAddress&wallet=WALLET_ADDRESS&limit=50
```

### getTransaction
```
GET https://your-worker.workers.dev/?method=getTransaction&signature=SIGNATURE&encoding=jsonParsed
```

### getHealth
```
GET https://your-worker.workers.dev/?method=getHealth
```

## Integration with ZeroClaw

Update the SKILL.md to use the proxy URL instead of direct Solana RPC calls. The proxy converts GET requests to POST requests with proper JSON-RPC formatting, bypassing the http_request POST body bug.

## Security Notes

- This is a public proxy with no authentication
- It only forwards to the official Solana mainnet-beta RPC endpoint
- No sensitive data is stored or logged
- Consider adding rate limiting for production use
