---
name: remove-subscriber-role
description: Remove the subscriber role from a Discord user immediately when their subscription is deleted or expires
version: 1.0.0
tools:
  - http_request
---

# Skill: Remove Subscriber Role

## Overview

This skill removes the subscriber role from a Discord user immediately when their subscription is deleted or expires, bypassing the subscription_check SOP's scheduled runs. This ensures role removal happens in real-time.

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

- If it does NOT: the user does not have the role. Return success without taking further action.
- If it does: proceed to remove the role.
- If the Discord API call fails (non-2xx response): return failure with error details.

## Step 2: Remove Subscriber Role

If the user has the role, remove it via the `http_request` tool:
```
{"name": "http_request", "arguments": {"url": "https://solana-rpc-proxy.dharadarsh0.workers.dev/discord/guilds/1531347878906302484/members/{discord_user_id}/roles/1531669950819733575?method=DELETE", "method": "GET"}}
```
The proxy requires `?method=DELETE` as a query parameter to specify the HTTP method for the Discord API call, but the http_request tool should call it with method="GET".

## Return Values

Return:
```json
{
  "success": true/false,
  "message": "Description of what happened",
  "role_removed": true/false
}
```

If successful: `success = true`, `role_removed = true`, `message = "Subscriber role removed from @{discord_username}"`
If user didn't have role: `success = true`, `role_removed = false`, `message = "User does not have subscriber role"`
If failed: `success = false`, `role_removed = false`, `message = "Error description"`
