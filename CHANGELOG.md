# Changelog

All notable changes to the ZeroClaw subscription management system are documented in this file.

## [Unreleased]

### Fixed
- **Cron-triggered SOP execution** - Fixed critical bug where cron-triggered SOPs would hang indefinitely at step 1. The headless driver spawning logic was not integrated into the cron dispatch path, causing runs to never execute. Consolidated headless driver spawning into dispatch functions by adding a `full_config` parameter, ensuring consistent behavior across all trigger sources (gateway API, RPC, cron scheduler, and channel implementations).

### Root Cause
The original implementation used a two-step approach for headless driver spawning:
1. Dispatch phase: `dispatch_sop_event()` or `dispatch_sop_event_to()` would return results
2. Post-processing phase: Callers would invoke `process_headless_results()` to spawn headless drivers

This post-processing was only implemented in some paths:
- Working paths: Gateway API (`api_sop_author.rs`), RPC dispatch (`rpc/dispatch.rs`)
- Broken paths: Cron scheduler (`main.rs`), channel implementations (AMQP, filesystem, MQTT)

### Fix Details
- Added `full_config` parameter to dispatch functions to pass configuration through the dispatch chain
- Integrated headless driver spawning into `dispatch_sop_event_filtered()` to happen automatically for ExecuteStep actions
- Updated all call sites to pass the full config parameter
- Removed redundant `process_headless_results()` calls from gateway API, RPC dispatch, and channel orchestrator

### Files Modified
- `src/crates/zeroclaw-runtime/src/sop/dispatch.rs`
- `src/crates/zeroclaw-runtime/src/rpc/dispatch.rs`
- `src/crates/zeroclaw-gateway/src/api_sop_author.rs`
- `src/crates/zeroclaw-channels/src/orchestrator/mod.rs`
- `src/crates/zeroclaw-channels/src/amqp.rs`
- `src/crates/zeroclaw-channels/src/filesystem.rs`
- `src/crates/zeroclaw-channels/src/orchestrator/mqtt.rs`
- `src/src/main.rs`

### Verification
- Build succeeded without errors
- Daemon starts successfully
- Cron triggers fire correctly
- Headless drivers spawn automatically for cron-triggered SOPs
- Log output confirms: "SOP dispatch: spawning headless driver for ExecuteStep action"
- No more runs stuck at step 1
