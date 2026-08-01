#!/usr/bin/env python3
"""
ZeroClaw Subscription Check — direct payment verification + role grant
                               + user command handling.

Runs as a cron job every 5 minutes.

What it does each cycle:
  1. Poll Subscribe_Channel for user commands:
       - "delete my subscription" / "delete the subscription" → cancel + remove role
       - "subscribe [tier]" → post pay link (if no active sub)
  2. Verify on-chain SOL payments for every subscriber in the index.
  3. Grant/retain/propose-removal of the Discord subscriber role.

No AI agent layer — pure deterministic logic.

NOTE: All writes to the Cloudflare proxy use curl subprocesses.
      Cloudflare blocks Python urllib PUT/POST with 403; curl passes fine.
      All reads and Discord API calls use urllib (no issue there).
"""

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import logging
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PROXY_BASE             = "https://solana-rpc-proxy.dharadarsh0.workers.dev"
MERCHANT_WALLET        = "pt6Ws1FMbdrLbUZqKooediS8mu6SNvDJodzXUx6ypak"
DISCORD_GUILD_ID       = "1531347878906302484"
SUBSCRIBER_ROLE_ID     = "1531669950819733575"
SUBSCRIPTION_CHANNEL_ID = "1531347878906302487"
GRACE_PERIOD_DAYS      = 3
RENEWAL_REMINDER_DAYS  = 5

TIERS = {
    "standard": (0.001,  30),
    "premium":  (0.0025, 30),
}
DEFAULT_TIER = "standard"

SCRIPT_DIR = Path(__file__).parent

# ---------------------------------------------------------------------------
# Bot token — env var takes priority, then .env file
# ---------------------------------------------------------------------------
def _load_bot_token() -> str:
    token = os.environ.get("DISCORD_BOT_TOKEN", "")
    if token:
        return token
    env_path = SCRIPT_DIR / ".env"
    if env_path.exists():
        for line in env_path.read_text().splitlines():
            if line.startswith("DISCORD_BOT_TOKEN="):
                return line.split("=", 1)[1].strip()
    return ""

BOT_TOKEN = _load_bot_token()

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
LOG_DIR = SCRIPT_DIR / "logs"
LOG_DIR.mkdir(exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_DIR / "subscription_check.log"),
        logging.StreamHandler(sys.stdout),
    ],
)
log = logging.getLogger("sub_check")

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------
TIMEOUT = 15


def _urllib_get(url: str):
    """GET via urllib — works fine for reads (Cloudflare allows GETs)."""
    try:
        req = urllib.request.Request(
            url,
            headers={"User-Agent": "curl/8.0"},   # pretend to be curl
        )
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            raw = resp.read().decode()
            try:
                return json.loads(raw)
            except json.JSONDecodeError:
                return raw
    except Exception as exc:
        log.warning("GET %s failed: %s", url, exc)
        return None


def _curl_put(url: str, body: dict) -> bool:
    """PUT via curl subprocess — avoids Cloudflare 403 on Python urllib writes."""
    try:
        result = subprocess.run(
            [
                "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                "-X", "PUT",
                "-H", "Content-Type: application/json",
                "-d", json.dumps(body),
                url,
            ],
            capture_output=True,
            text=True,
            timeout=TIMEOUT,
        )
        status = int(result.stdout.strip() or "0")
        if status not in (200, 201, 204):
            log.warning("curl PUT %s → HTTP %d stderr: %s", url, status, result.stderr[:200])
            return False
        return True
    except Exception as exc:
        log.warning("curl PUT %s failed: %s", url, exc)
        return False


def _discord_api(method: str, path: str, body: dict | None = None) -> tuple[int, dict]:
    """Direct Discord API call using urllib."""
    url  = f"https://discord.com/api/v10{path}"
    data = json.dumps(body).encode() if body else None
    headers = {
        "Authorization": f"Bot {BOT_TOKEN}",
        "Content-Type":  "application/json",
        "User-Agent":    "ZeroClaw-SubCheck/1.0",
    }
    try:
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            raw = resp.read().decode()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as exc:
        body_txt = exc.read().decode()
        log.warning("Discord %s %s → %d  %s", method, path, exc.code, body_txt[:200])
        return exc.code, {}
    except Exception as exc:
        log.warning("Discord %s %s failed: %s", method, path, exc)
        return 0, {}


# ---------------------------------------------------------------------------
# Proxy / KV helpers
# ---------------------------------------------------------------------------

def proxy_get(path: str):
    return _urllib_get(f"{PROXY_BASE}{path}")


def post_channel_message(content: str):
    encoded = urllib.parse.quote(content)
    proxy_get(f"/discord/message?channel_id={SUBSCRIPTION_CHANNEL_ID}&content={encoded}")


def kv_get(key: str):
    """Read a KV entry (GET is fine through urllib)."""
    return proxy_get(f"/storage/{key}")


def kv_put(key: str, value) -> bool:
    """Write a KV entry via curl to bypass Cloudflare's urllib block."""
    return _curl_put(f"{PROXY_BASE}/storage/{key}", value)


# ---------------------------------------------------------------------------
# Solana helpers
# ---------------------------------------------------------------------------

def get_signatures_for_address(wallet: str, limit: int = 100) -> list:
    data = proxy_get(f"/?method=getSignaturesForAddress&wallet={wallet}&limit={limit}")
    if isinstance(data, dict):
        return data.get("result") or []
    return []


def get_transaction(signature: str) -> dict | None:
    data = proxy_get(f"/?method=getTransaction&signature={signature}&encoding=jsonParsed")
    if isinstance(data, dict):
        return data.get("result")
    return None


def verify_payment(record: dict, now_ts: int) -> tuple[str, int | None, str | None]:
    """
    Scan the merchant wallet for a qualifying SOL payment for this subscriber.

    Returns (status, block_time, sender_wallet):
      status       ∈ {"active", "lapsed", "check_failed"}
      block_time   = Unix timestamp of the winning tx, or None
      sender_wallet = sender pubkey, or None
    """
    expected_sol = record.get("expected_amount_sol")
    period_days  = record.get("period_days", 30)
    subscribed_at = record.get("subscribed_at")

    if not expected_sol or not isinstance(expected_sol, (int, float)) or expected_sol <= 0:
        log.error("Bad expected_amount_sol for %s: %r",
                  record.get("discord_user_id"), expected_sol)
        return "check_failed", None, None

    min_lamports = int(expected_sol * 1_000_000_000)

    # Window: [sub_ts, sub_ts + period_days*86400].
    # If subscribed_at is null, accept any past blockTime (first payment).
    if subscribed_at:
        try:
            sub_ts = int(
                datetime.fromisoformat(subscribed_at.replace("Z", "+00:00")).timestamp()
            )
        except Exception:
            sub_ts = 0
    else:
        sub_ts = 0

    window_end = (sub_ts + period_days * 86400) if sub_ts > 0 else (now_ts + period_days * 86400)

    signatures = get_signatures_for_address(MERCHANT_WALLET, limit=100)
    if signatures is None:
        return "check_failed", None, None

    best_block_time  = None
    best_sender      = None
    any_sol_transfer = False

    for sig_info in signatures:
        sig = sig_info.get("signature")
        if not sig:
            continue

        tx = get_transaction(sig)
        if not tx:
            continue

        block_time = tx.get("blockTime")
        if block_time is None:
            continue

        # Window check — only enforce if we have a prior subscribed_at
        if sub_ts > 0 and (block_time < sub_ts or block_time > window_end):
            continue

        instructions = (
            tx.get("transaction", {})
              .get("message", {})
              .get("instructions", [])
        )

        for ix in instructions:
            if ix.get("program") != "system":
                continue
            parsed = ix.get("parsed", {})
            if not isinstance(parsed, dict) or parsed.get("type") != "transfer":
                continue

            info = parsed.get("info", {})
            if info.get("destination") != MERCHANT_WALLET:
                continue

            lamports = info.get("lamports", 0)
            any_sol_transfer = True

            if lamports < min_lamports:
                continue

            # Condition E: if record has a known wallet, verify sender matches
            wallet_addr = record.get("wallet_address")
            sender      = info.get("source", "")
            if wallet_addr and sender and sender != wallet_addr:
                continue

            # Qualifying tx — keep the most recent
            if best_block_time is None or block_time > best_block_time:
                best_block_time = block_time
                best_sender     = sender

    if best_block_time is not None:
        return "active", best_block_time, best_sender

    return "lapsed", None, None


# ---------------------------------------------------------------------------
# Discord helpers
# ---------------------------------------------------------------------------

def member_has_role(user_id: str) -> bool | None:
    """True if user has SUBSCRIBER_ROLE_ID, False if not, None on API error."""
    status, data = _discord_api("GET", f"/guilds/{DISCORD_GUILD_ID}/members/{user_id}")
    if status == 200:
        return SUBSCRIBER_ROLE_ID in data.get("roles", [])
    if status == 404:
        return False   # not in guild
    return None        # API error


def grant_role(user_id: str) -> bool:
    status, _ = _discord_api(
        "PUT",
        f"/guilds/{DISCORD_GUILD_ID}/members/{user_id}/roles/{SUBSCRIBER_ROLE_ID}",
    )
    return status in (200, 201, 204)


def remove_role(user_id: str) -> bool:
    status, _ = _discord_api(
        "DELETE",
        f"/guilds/{DISCORD_GUILD_ID}/members/{user_id}/roles/{SUBSCRIBER_ROLE_ID}",
    )
    return status in (200, 201, 204, 404)


# ---------------------------------------------------------------------------
# Subscriber record helpers
# ---------------------------------------------------------------------------

def load_record(user_id: str) -> dict | None:
    raw = kv_get(f"subscriber/{user_id}")
    if raw is None or raw == "null":
        return None
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str):
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return None
    return None


def save_record(record: dict) -> bool:
    uid = record.get("discord_user_id")
    if not uid:
        return False
    return kv_put(f"subscriber/{uid}", record)


def ensure_in_index(user_id: str):
    raw = kv_get("subscriber_index")
    if isinstance(raw, list):
        index = raw
    elif isinstance(raw, str):
        try:
            index = json.loads(raw)
        except Exception:
            index = []
    else:
        index = []
    if user_id not in index:
        index.append(user_id)
        kv_put("subscriber_index", index)
        log.info("Added %s to subscriber_index", user_id)


# ---------------------------------------------------------------------------
# Per-subscriber processing
# ---------------------------------------------------------------------------

def _iso(ts: int) -> str:
    return (
        datetime.fromtimestamp(ts, timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def process_subscriber(user_id: str, now_ts: int, now_iso: str, summary: list):
    log.info("--- Processing %s ---", user_id)

    record = load_record(user_id)
    if record is None:
        log.warning("No KV record for %s — bootstrapping minimal record", user_id)
        record = {
            "discord_user_id":            user_id,
            "discord_username":           user_id,
            "wallet_address":             None,
            "tier":                       DEFAULT_TIER,
            "expected_amount_sol":        TIERS[DEFAULT_TIER][0],
            "period_days":                TIERS[DEFAULT_TIER][1],
            "subscribed_at":              None,
            "expires_at":                 None,
            "grace_started_at":           None,
            "reference_key":              None,
            "status":                     "pending_payment",
            "last_known_status":          None,
            "renewal_dm_sent_for_expiry": None,
        }

    username = record.get("discord_username") or user_id

    # ── Renewal window check ──────────────────────────────────────────────
    expires_at = record.get("expires_at")
    if expires_at and record.get("status") == "active":
        try:
            expiry_ts = int(
                datetime.fromisoformat(expires_at.replace("Z", "+00:00")).timestamp()
            )
            secs_left = expiry_ts - now_ts
            if 0 < secs_left <= RENEWAL_REMINDER_DAYS * 86400:
                if record.get("renewal_dm_sent_for_expiry") != expires_at:
                    keygen = proxy_get("/keygen")
                    if isinstance(keygen, dict) and keygen.get("reference_key"):
                        new_ref = keygen["reference_key"]
                        tier    = record.get("tier", DEFAULT_TIER)
                        pay_url = (
                            f"{PROXY_BASE}/pay?tier={tier}"
                            f"&discord_user_id={user_id}&reference={new_ref}"
                        )
                        record["reference_key"]              = new_ref
                        record["status"]                     = "pending_payment"
                        record["renewal_dm_sent_for_expiry"] = expires_at
                        save_record(record)
                        days_left = secs_left // 86400
                        dm = (
                            f"🔔 ZeroClaw renewal — your {tier} subscription "
                            f"expires in {days_left} day(s).\nRenew: {pay_url}"
                        )
                        proxy_get(
                            f"/discord/dm?user_id={user_id}"
                            f"&content={urllib.parse.quote(dm)}"
                        )
                        log.info("Sent renewal DM to %s (%d days left)", username, days_left)
        except Exception as exc:
            log.warning("Renewal check failed for %s: %s", user_id, exc)

    # ── Payment verification ──────────────────────────────────────────────
    pay_status, block_time, sender_wallet = verify_payment(record, now_ts)
    log.info("Payment result: status=%s block_time=%s sender=%s",
             pay_status, block_time, sender_wallet)

    old_status = record.get("status", "unknown")

    if pay_status == "active":
        record["status"]           = "active"
        record["subscribed_at"]    = _iso(block_time)
        record["expires_at"]       = _iso(block_time + record.get("period_days", 30) * 86400)
        record["grace_started_at"] = None
        if sender_wallet and not record.get("wallet_address"):
            record["wallet_address"] = sender_wallet

    elif pay_status == "lapsed":
        record["last_known_status"] = old_status
        record["status"]            = "lapsed"

    else:  # check_failed
        record["last_known_status"] = old_status
        record["status"]            = "check_failed"

    # ── Grace period logic ────────────────────────────────────────────────
    effective_status = record["status"]

    if effective_status == "lapsed":
        grace_started = record.get("grace_started_at")
        if grace_started is None:
            # First cycle after lapsing — start grace clock
            record["grace_started_at"] = now_iso
            save_record(record)
            effective_status = "grace"
            log.info("%s entered grace period", username)
            tier    = record.get("tier", DEFAULT_TIER)
            ref_key = record.get("reference_key", "")
            pay_url = (
                f"{PROXY_BASE}/pay?tier={tier}"
                f"&discord_user_id={user_id}&reference={ref_key}"
            )
            grace_expiry = _iso(now_ts + GRACE_PERIOD_DAYS * 86400)
            post_channel_message(
                f"⚠️ <@{user_id}>'s payment has lapsed. "
                f"Grace period ends {grace_expiry}.\nRenew: {pay_url}"
            )
        else:
            try:
                grace_ts  = int(
                    datetime.fromisoformat(grace_started.replace("Z", "+00:00")).timestamp()
                )
                grace_end = grace_ts + GRACE_PERIOD_DAYS * 86400
                if now_ts < grace_end:
                    effective_status = "grace"
                else:
                    effective_status = "expired"
            except Exception:
                effective_status = "grace"

    # ── Role action ───────────────────────────────────────────────────────
    role_action = "no_change"

    if effective_status == "active":
        has_role = member_has_role(user_id)
        if has_role is None:
            log.warning("Discord member check failed for %s", user_id)
            effective_status = "check_failed"
            role_action      = "check_failed"
        elif not has_role:
            if grant_role(user_id):
                role_action               = "granted"
                record["role_granted_at"] = now_iso
                log.info("✅ Granted subscriber role to %s", username)
                post_channel_message(
                    f"✅ Subscriber role granted to <@{user_id}> "
                    f"(payment confirmed, expires {record.get('expires_at', 'N/A')})"
                )
            else:
                log.error("Failed to grant role to %s via Discord API", user_id)
                effective_status = "check_failed"
                role_action      = "check_failed"
                post_channel_message(
                    f"⚠️ Failed to grant role to <@{user_id}> at {now_iso}. "
                    "Manual review required."
                )
        else:
            role_action = "unchanged"
            log.info("%s already has subscriber role", username)

    elif effective_status == "grace":
        role_action = "unchanged"   # retain role during grace period

    elif effective_status == "expired":
        role_action = "removal_proposed"
        tier    = record.get("tier", DEFAULT_TIER)
        ref_key = record.get("reference_key", "")
        pay_url = (
            f"{PROXY_BASE}/pay?tier={tier}"
            f"&discord_user_id={user_id}&reference={ref_key}"
        )
        grace_end_iso = ""
        if record.get("grace_started_at"):
            try:
                grace_ts    = int(
                    datetime.fromisoformat(
                        record["grace_started_at"].replace("Z", "+00:00")
                    ).timestamp()
                )
                grace_end_iso = _iso(grace_ts + GRACE_PERIOD_DAYS * 86400)
            except Exception:
                pass
        post_channel_message(
            f"⚠️ ROLE REMOVAL PROPOSAL: <@{user_id}>'s grace period ended "
            f"({grace_end_iso}). Admin: react ✅ to remove or ❌ to extend.\n"
            f"Renew: {pay_url}"
        )

    elif effective_status == "check_failed":
        role_action = "check_failed"
        post_channel_message(
            f"⚠️ Payment check failed for <@{user_id}> at {now_iso}. "
            "Manual review required."
        )

    # ── Persist final record ──────────────────────────────────────────────
    # Keep the stored status as the underlying DB status (lapsed/active/etc),
    # not the derived effective_status (grace/expired are runtime states).
    save_record(record)

    row = (
        f"<@{user_id}> | {record.get('tier','?')} | {effective_status} | "
        f"expires: {record.get('expires_at') or 'N/A'} | role: {role_action}"
    )
    summary.append(row)
    log.info("Result: %s", row)


# ---------------------------------------------------------------------------
# Command handling — poll Subscribe_Channel for user commands
# ---------------------------------------------------------------------------

# Persist the last-seen message ID to avoid re-processing on each cycle.
LAST_MSG_ID_FILE = SCRIPT_DIR / "data" / "state" / "cmd_last_msg_id.txt"

# Patterns that all mean "cancel my subscription"
DELETE_PATTERNS = re.compile(
    r"\b(delete|cancel|remove)\b.{0,20}\b(subscription|sub)\b"
    r"|\bdelete the subscription\b"
    r"|\bcancel subscription\b",
    re.IGNORECASE,
)

def _load_last_msg_id() -> str | None:
    try:
        return LAST_MSG_ID_FILE.read_text().strip() or None
    except Exception:
        return None


def _save_last_msg_id(msg_id: str):
    try:
        LAST_MSG_ID_FILE.parent.mkdir(parents=True, exist_ok=True)
        LAST_MSG_ID_FILE.write_text(msg_id)
    except Exception as exc:
        log.warning("Could not save last_msg_id: %s", exc)


def handle_commands():
    """Poll Subscribe_Channel for user commands and act on them immediately."""
    last_id = _load_last_msg_id()

    url = (
        f"{PROXY_BASE}/discord/channels/{SUBSCRIPTION_CHANNEL_ID}/messages?limit=50"
    )
    if last_id:
        url += f"&after={last_id}"

    raw = proxy_get(
        f"/discord/channels/{SUBSCRIPTION_CHANNEL_ID}/messages?limit=50"
        + (f"&after={last_id}" if last_id else "")
    )

    if not isinstance(raw, list):
        log.warning("Could not fetch channel messages: %r", raw)
        return

    if not raw:
        log.info("No new channel messages since last check.")
        return

    # Messages come newest-first; reverse to process oldest-first so last_id
    # advances monotonically.
    messages = list(reversed(raw))
    newest_id = raw[0].get("id")  # raw[0] is newest

    for msg in messages:
        author  = msg.get("author") or {}
        if author.get("bot"):
            continue

        user_id  = author.get("id") or ""
        username = author.get("global_name") or author.get("username") or user_id
        content  = (msg.get("content") or "").strip()
        msg_id   = msg.get("id") or ""

        if not user_id or not content:
            continue

        log.info("Command message from %s (%s): %r", username, user_id, content[:80])

        # ── DELETE / CANCEL subscription ────────────────────────────────
        if DELETE_PATTERNS.search(content):
            log.info("Delete subscription command from %s", user_id)
            _handle_delete(user_id, username)
            continue

        # ── SUBSCRIBE [tier] ─────────────────────────────────────────────
        if re.search(r"\bsubscribe\b", content, re.IGNORECASE):
            log.info("Subscribe command from %s", user_id)
            _handle_subscribe(user_id, username, content)
            continue

    if newest_id:
        _save_last_msg_id(newest_id)


def _handle_delete(user_id: str, username: str):
    """Cancel subscription: remove role + delete KV record + confirm."""
    record = load_record(user_id)

    cancellable = {"active", "pending_payment", "grace", "lapsed"}
    if record is None or record.get("status") not in cancellable:
        post_channel_message(
            f"<@{user_id}> — You don't have an active subscription to cancel."
        )
        log.info("No active subscription to delete for %s", user_id)
        return

    # Remove Discord role
    role_removed = remove_role(user_id)
    log.info("Role removal for %s: %s", user_id, "ok" if role_removed else "failed/no-role")

    # Delete KV record
    try:
        result = subprocess.run(
            [
                "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                "-X", "DELETE",
                f"{PROXY_BASE}/storage/subscriber/{user_id}",
            ],
            capture_output=True, text=True, timeout=TIMEOUT,
        )
        http_code = int(result.stdout.strip() or "0")
        log.info("KV DELETE for %s → HTTP %d", user_id, http_code)
    except Exception as exc:
        log.warning("KV DELETE failed for %s: %s", user_id, exc)

    # Remove from subscriber_index
    raw_index = kv_get("subscriber_index")
    if isinstance(raw_index, list):
        index = raw_index
    elif isinstance(raw_index, str):
        try:
            index = json.loads(raw_index)
        except Exception:
            index = []
    else:
        index = []
    if user_id in index:
        index.remove(user_id)
        kv_put("subscriber_index", index)
        log.info("Removed %s from subscriber_index", user_id)

    post_channel_message(
        f"<@{user_id}> — Your subscription has been cancelled and your "
        "subscriber role has been removed. "
        "You can re-subscribe at any time with `subscribe`."
    )


def _handle_subscribe(user_id: str, username: str, content: str):
    """Reply with a pay link if the user doesn't already have a pending invoice."""
    record = load_record(user_id)

    # Parse tier from message
    words = content.lower().split()
    tier  = DEFAULT_TIER
    try:
        idx = next(i for i, w in enumerate(words) if "subscribe" in w)
        if idx + 1 < len(words) and words[idx + 1] in TIERS:
            tier = words[idx + 1]
    except StopIteration:
        pass

    # If already pending, re-send existing link
    if record and record.get("status") == "pending_payment" and record.get("pay_url"):
        post_channel_message(
            f"<@{user_id}> — You already have a pending payment. Pay here:\n"
            f"{record['pay_url']}"
        )
        return

    # If already active, remind them
    if record and record.get("status") == "active":
        post_channel_message(
            f"<@{user_id}> — You already have an active subscription "
            f"(expires {record.get('expires_at', 'N/A')}). "
            "Use `delete my subscription` to cancel first, or wait for renewal."
        )
        return

    # Generate a new reference key and post the pay link
    keygen = proxy_get("/keygen")
    if not isinstance(keygen, dict) or not keygen.get("reference_key"):
        post_channel_message(
            f"<@{user_id}> — Service error generating payment link. "
            "Please try again in a moment."
        )
        log.warning("keygen failed for subscribe command from %s", user_id)
        return

    ref_key = keygen["reference_key"]
    amount, period_days = TIERS.get(tier, TIERS[DEFAULT_TIER])
    pay_url = (
        f"{PROXY_BASE}/pay?tier={tier}"
        f"&discord_user_id={user_id}&reference={ref_key}"
    )

    # Upsert record
    new_record = {
        "discord_user_id":            user_id,
        "discord_username":           username,
        "wallet_address":             (record or {}).get("wallet_address"),
        "tier":                       tier,
        "expected_amount_sol":        amount,
        "period_days":                period_days,
        "subscribed_at":              None,
        "expires_at":                 None,
        "grace_started_at":           None,
        "reference_key":              ref_key,
        "status":                     "pending_payment",
        "last_known_status":          (record or {}).get("status"),
        "renewal_dm_sent_for_expiry": None,
        "pay_url":                    pay_url,
    }
    save_record(new_record)
    ensure_in_index(user_id)

    post_channel_message(
        f"<@{user_id}> — ZeroClaw {tier} subscription "
        f"({amount} SOL / {period_days} days)\n"
        f"⚡ Pay here: {pay_url}"
    )
    log.info("Posted pay link to %s for tier=%s ref=%s", user_id, tier, ref_key)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def _chunks(text: str, size: int = 2000) -> list[str]:
    parts = []
    while len(text) > size:
        cut = text.rfind("\n", 0, size)
        if cut == -1:
            cut = size
        parts.append(text[:cut])
        text = text[cut:].lstrip("\n")
    if text:
        parts.append(text)
    return parts


def run():
    now_ts  = int(datetime.now(timezone.utc).timestamp())
    now_iso = _iso(now_ts)
    log.info("========== Subscription check start %s ==========", now_iso)

    if not BOT_TOKEN:
        log.error("DISCORD_BOT_TOKEN not set — cannot manage roles. Aborting.")
        sys.exit(1)

    # Step 1: Handle user commands (delete, subscribe) from the channel
    try:
        handle_commands()
    except Exception as exc:
        log.exception("handle_commands failed: %s", exc)

    # Step 2: Load subscriber index
    raw_index = kv_get("subscriber_index")
    if isinstance(raw_index, list):
        subscriber_ids = raw_index
    elif isinstance(raw_index, str):
        try:
            subscriber_ids = json.loads(raw_index)
        except Exception:
            subscriber_ids = []
    else:
        subscriber_ids = []

    if not subscriber_ids:
        log.info("subscriber_index is empty — nothing to do.")
        return

    log.info("Subscribers to check: %s", subscriber_ids)

    summary: list[str] = []
    for user_id in subscriber_ids:
        try:
            process_subscriber(user_id, now_ts, now_iso, summary)
        except Exception as exc:
            log.exception("Unhandled error for %s: %s", user_id, exc)
            summary.append(f"<@{user_id}> | ERROR | {exc}")

    # Post summary to subscription channel
    if summary:
        header = f"📊 Subscription Check — {now_iso}\n{'─' * 44}"
        full   = header + "\n" + "\n".join(summary)
        for chunk in _chunks(full):
            post_channel_message(chunk)

    log.info("========== Subscription check complete ==========")


if __name__ == "__main__":
    run()
