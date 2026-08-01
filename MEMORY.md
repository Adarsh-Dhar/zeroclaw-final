# MEMORY.md — ZeroClaw Project Memory

## Subscription Deletion Handling

When users say "delete my subscription" in Discord:

1. **This must be handled immediately by the Discord agent** - do not wait for SOP cron
2. **Process:**
   - Use `memory_recall` to get subscriber record: `{"name": "memory_recall", "arguments": {"query": "subscriber:{discord_user_id}", "strategy": "bm25", "limit": 1}}`
   - Update status to "lapsed" using `memory_store` with proper JSON string format
   - **CRITICAL: Remove role immediately using http_request DELETE:**
     ```
     {"name": "http_request", "arguments": {"url": "https://solana-rpc-proxy.dharadarsh0.workers.dev/discord/guilds/1531347878906302484/members/{discord_user_id}/roles/1531669950819733575", "method": "DELETE"}}
     ```
   - Post confirmation message

3. **IMPORTANT:** Never invoke skills directly from Discord agent - only SOPs can invoke skills
4. **Use http_request tool directly** for all API calls

## Constants
- Proxy URL: `https://solana-rpc-proxy.dharadarsh0.workers.dev`
- Discord Guild ID: `1531347878906302484`  
- Subscriber Role ID: `1531669950819733575`
- Subscribe Channel ID: `1531347878906302487`
