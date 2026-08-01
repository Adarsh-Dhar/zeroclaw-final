---
name: grant-subscriber-role
description: Grant the subscriber role to a Discord user immediately when they become a subscriber
version: 1.0.0
tools:
  - http_request
---

# Skill: Grant Subscriber Role

## Overview

This skill grants the subscriber role to a Discord user immediately when they become a subscriber, bypassing the subscription_check SOP's scheduled runs. This ensures role assignment happens in real-time.

## Constants

- **Proxy URL:** `https://solana-rpc-proxy.dharadarsh0.workers.dev`
- **Discord Guild ID:** `1531347878906302484`
- **Subscriber Role ID:** `1531669950819733575`

## Input

A `Subscriber_Record` object with the following fields:

| Field | Type | Description |
|---|---|---|
| `discord_user_id` | string | Discord snowflake ID of the subscriber |
| `discord_username` | string | Discord username |

## Tool Call Format (critical — follow exactly)

When calling `http_request`, you MUST nest all parameters inside an `"arguments"` object. Never place `url`, `method`, or `headers` as siblings of `"name"`.

CORRECT:
```json
{"name": "http_request", "arguments": {"url": "https://example.com", "method": "GET"}}
```

INCORRECT (will fail):
```json
{"name": "http_request", "url": "https://example.com", "method": "GET"}
```

## Step 1: Check Current Role Status

Call:
```
GET https://solana-rpc-proxy.dharadarsh0.workers.dev/discord/guilds/1531347878906302484/members/{discord_user_id}
```

Check if the role `"1531669950819733575"` appears in the `roles` array of the response JSON.

- If it does: the user already has the role. Return success without taking further action.
- If it does not: proceed to grant the role.
- If the Discord API call fails (non-2xx response): return failure with error details.

## Step 2: Grant Subscriber Role

If the user does not have the role, grant it via the `http_request` tool:
```
{"name": "http_request", "arguments": {"url": "https://solana-rpc-proxy.dharadarsh0.workers.dev/discord/guilds/1531347878906302484/members/{discord_user_id}/roles/1531669950819733575?method=PUT", "method": "GET"}}
```
The proxy requires `?method=PUT` as a query parameter to specify the HTTP method for the Discord API call, but the http_request tool should call it with method="GET".

## Return Values

Return:
```json
{
  "success": true/false,
  "message": "Description of what happened",
  "role_granted": true/false
}
```

If successful: `success = true`, `role_granted = true`, `message = "Subscriber role granted to @{discord_username}"`
If user already had role: `success = true`, `role_granted = false`, `message = "User already has subscriber role"`
If failed: `success = false`, `role_granted = false`, `message = "Error description"`
