## Context

```toml
[constants]
proxy_base_url = "https://solana-rpc-proxy.dharadarsh0.workers.dev"
discord_guild = "1531347878906302484"
```

## Steps

1. **Fetch current members** — GET {proxy_base_url}/discord/guilds/{discord_guild}/members/list?limit=1000
   - tools: http_request

2. **Filter and greet new/non-subscribed members** — For each member, `memory_recall` for `subscriber:{member.id}`. If no record exists, or record has `status` other than `active`/`pending_payment`, and no record of a prior welcome DM (`memory_recall` for `welcomed:{member.id}`), send a welcome DM via `GET {proxy_base_url}/discord/dm?user_id={member.id}&content=<message>` and `memory_store` a `welcomed:{member.id}` marker so they're never double-welcomed. Do NOT message anyone already `pending_payment` or `active` — they're mid-flow or done, a cold pitch there is just noise.
   - tools: http_request, memory_recall, memory_store
