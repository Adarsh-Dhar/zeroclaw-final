# Claim-Release Bug Fix Implementation

## Root Cause Analysis

### The Bug
The `finish_run` function in `src/crates/zeroclaw-runtime/src/sop/engine.rs` (lines 4822-4866) **never calls `release_claim_best_effort`** to explicitly release the concurrency claim when a run completes. 

While the store's `finish_run` method internally releases the claim, if there's any error or edge case in the store implementation, the claim remains held forever, creating a permanent lockout.

### Current Code (Buggy)
```rust
pub fn finish_run(
    &mut self,
    run_id: &str,
    status: SopRunStatus,
    reason: Option<String>,
) -> Result<SopRunAction> {
    let mut run = self.active_runs.get(run_id).cloned()
        .ok_or_else(|| anyhow::Error::msg(format!("Active run not found: {run_id}")))?;
    run.status = status;
    run.completed_at = Some(now_iso8601());
    let sop_name = run.sop_name.clone();
    let run_id_owned = run.run_id.clone();
    self.persist_terminal(&run)?;  // ← If this fails, claim never released
    self.claims_pending_persist.remove(run_id);
    self.claims_retained_after_terminal_rollback.remove(run_id);
    self.active_runs.remove(run_id);
    self.metrics.record_run_complete(&run);
    self.remove_deterministic_state_file(&run);
    self.finished_runs.push(run);
    // ❌ MISSING: release_claim_best_effort call
    // ...
}
```

### Why This Causes Permanent Lockout
1. Run starts and acquires claim via `claim_admission`
2. Run encounters error or gets stuck
3. `finish_run` is called but:
   - If `persist_terminal` fails, function returns early
   - Even if it succeeds, no explicit claim release
4. Claim remains in store's `sop_claims` table forever
5. All subsequent runs are rejected with "cooldown or concurrency limit reached"

## Fix Implementation

### Fix 1: Add Explicit Claim Release in finish_run

**File:** `src/crates/zeroclaw-runtime/src/sop/engine.rs`

**Location:** In `finish_run` function (around line 4822)

**Change:**
```rust
pub fn finish_run(
    &mut self,
    run_id: &str,
    status: SopRunStatus,
    reason: Option<String>,
) -> Result<SopRunAction> {
    let mut run = self.active_runs.get(run_id).cloned()
        .ok_or_else(|| anyhow::Error::msg(format!("Active run not found: {run_id}")))?;
    
    // Capture claim token BEFORE removing from active_runs
    let claim_token = Self::claim_handle_for_run(&run);
    
    run.status = status;
    run.completed_at = Some(now_iso8601());
    let sop_name = run.sop_name.clone();
    let run_id_owned = run.run_id.clone();
    
    // Use scope guard to ensure claim is always released
    let _claim_guard = scopeguard::guard(claim_token, |token| {
        Self::release_claim_best_effort_impl(&token);
    });
    
    self.persist_terminal(&run)?;
    self.claims_pending_persist.remove(run_id);
    self.claims_retained_after_terminal_rollback.remove(run_id);
    self.active_runs.remove(run_id);
    self.metrics.record_run_complete(&run);
    self.remove_deterministic_state_file(&run);
    self.finished_runs.push(run);
    
    // Evict oldest finished runs when over capacity
    let max = self.config.max_finished_runs;
    if max > 0 && self.finished_runs.len() > max {
        let excess = self.finished_runs.len() - max;
        self.finished_runs.drain(..excess);
    }

    Ok(match status {
        SopRunStatus::Failed => SopRunAction::Failed {
            run_id: run_id_owned,
            sop_name,
            reason: reason.unwrap_or_default(),
        },
        _ => SopRunAction::Completed {
            run_id: run_id_owned,
            sop_name,
        },
    })
}

// Helper function for scopeguard
fn release_claim_best_effort_impl(token: &ClaimToken) {
    // This would need access to store, so we might need a different approach
    // Alternative: use defer pattern or explicit finally block
}
```

**Alternative Implementation (Without scopeguard dependency):**
```rust
pub fn finish_run(
    &mut self,
    run_id: &str,
    status: SopRunStatus,
    reason: Option<String>,
) -> Result<SopRunAction> {
    let mut run = self.active_runs.get(run_id).cloned()
        .ok_or_else(|| anyhow::Error::msg(format!("Active run not found: {run_id}")))?;
    
    let claim_token = Self::claim_handle_for_run(&run);
    let sop_name = run.sop_name.clone();
    let run_id_owned = run.run_id.clone();
    
    run.status = status;
    run.completed_at = Some(now_iso8601());
    
    // Attempt persist, but always release claim regardless of outcome
    let persist_result = self.persist_terminal(&run);
    
    // Always release claim, even if persist failed
    self.release_claim_best_effort(&claim_token);
    
    // If persist failed, propagate error but claim is already released
    persist_result?;
    
    self.claims_pending_persist.remove(run_id);
    self.claims_retained_after_terminal_rollback.remove(run_id);
    self.active_runs.remove(run_id);
    self.metrics.record_run_complete(&run);
    self.remove_deterministic_state_file(&run);
    self.finished_runs.push(run);
    
    // Evict oldest finished runs when over capacity
    let max = self.config.max_finished_runs;
    if max > 0 && self.finished_runs.len() > max {
        let excess = self.finished_runs.len() - max;
        self.finished_runs.drain(..excess);
    }

    Ok(match status {
        SopRunStatus::Failed => SopRunAction::Failed {
            run_id: run_id_owned,
            sop_name,
            reason: reason.unwrap_or_default(),
        },
        _ => SopRunAction::Completed {
            run_id: run_id_owned,
            sop_name,
        },
    })
}
```

### Fix 2: Same Change for finish_run_with_gate_event

**File:** `src/crates/zeroclaw-runtime/src/sop/engine.rs`

**Location:** In `finish_run_with_gate_event` function (around line 4868)

**Change:** Apply the same pattern - release claim before error propagation

### Fix 3: Add Claim Timeout/Reaper Mechanism

**File:** `src/crates/zeroclaw-runtime/src/sop/engine.rs`

**Add to maintenance tick:**
```rust
fn maintenance_tick(&mut self) -> MaintenanceSummary {
    let mut summary = MaintenanceSummary::default();
    
    // ... existing maintenance code ...
    
    // NEW: Reap expired claims
    let now = now_iso8601();
    if let Ok(expired_claims) = self.store.expired_claims(&now) {
        for token in expired_claims {
            ::zeroclaw_log::record!(
                WARN,
                ::zeroclaw_log::Event::new(module_path!(), ::zeroclaw_log::Action::Note)
                    .with_outcome(::zeroclaw_log::EventOutcome::Unknown)
                    .with_attrs(::serde_json::json!({
                        "run_id": token.run_id,
                        "sop_name": token.sop_name,
                        "claimed_at": token.claimed_at,
                        "lease_expires": token.lease_expires,
                    })),
                "SOP engine: reaping expired claim for stuck run"
            );
            
            // Force-release the expired claim
            if let Err(e) = self.store.release_claim(&token) {
                ::zeroclaw_log::record!(
                    ERROR,
                    ::zeroclaw_log::Event::new(module_path!(), ::zeroclaw_log::Action::Note)
                        .with_outcome(::zeroclaw_log::EventOutcome::Unknown)
                        .with_attrs(::serde_json::json!({
                            "run_id": token.run_id,
                            "error": e.to_string(),
                        })),
                    "SOP engine: failed to release expired claim"
                );
            }
            
            summary.reaped_claims += 1;
            
            // Mark the corresponding run as failed if it's still in active_runs
            if let Some(run) = self.active_runs.get(&token.run_id) {
                ::zeroclaw_log::record!(
                    WARN,
                    ::zeroclaw_log::Event::new(module_path!(), ::zeroclaw_log::Action::Note)
                        .with_outcome(::zeroclaw_log::EventOutcome::Unknown)
                        .with_attrs(::serde_json::json!({
                            "run_id": token.run_id,
                            "sop_name": run.sop_name,
                            "status": run.status,
                        })),
                    "SOP engine: marking run as failed due to expired claim"
                );
                
                // Attempt to mark as failed
                let _ = self.finish_run(&token.run_id, SopRunStatus::Failed, 
                    Some("Claim expired - run likely stuck".to_string()));
            }
        }
    }
    
    summary
}
```

### Fix 4: Configure Claim Lease Expiration

**File:** `src/crates/zeroclaw-config/src/schema.rs` or config.example.toml

**Add to SOP config:**
```toml
[sop]
claim_lease_secs = 3600  # 1 hour default claim lease
```

**Update store implementation to use lease expiration:**
```rust
fn try_claim_run(
    &self,
    run_id: &str,
    sop_name: &str,
    per_sop_cap: usize,
    global_cap: usize,
) -> Result<Option<ClaimToken>, StoreError> {
    // ... existing code ...
    
    // Set lease expiration
    let lease_expires = chrono::Utc::now() + chrono::Duration::seconds(claim_lease_secs);
    
    Ok(Some(ClaimToken {
        run_id: run_id.to_string(),
        sop_name: sop_name.to_string(),
        claimed_at: chrono::Utc::now().to_rfc3339(),
        lease_expires: lease_expires.to_rfc3339(),
        holder: "engine".to_string(),
    }))
}
```

### Fix 5: Add Admin API for Manual Claim Cleanup

**File:** `src/crates/zeroclaw-gateway/src/api_sop.rs`

**Add new endpoint:**
```rust
pub async fn handle_force_release_claim(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(run_id): Path<String>,
) -> Response {
    // Authorize as admin
    let _principal = authorize(&state, &peer, &headers)?;
    
    // Get the engine
    let engine = state.sop_engine.read().await;
    let engine = engine.as_ref().ok_or_else(|| sop_disabled())?;
    
    // Find the run and release its claim
    if let Some(run) = engine.active_runs.get(&run_id) {
        let token = crate::claim_handle_for_run(run);
        engine.release_claim_best_effort(&token);
        
        // Mark as failed
        let _ = engine.finish_run(&run_id, SopRunStatus::Failed, 
            Some("Manually force-released by admin".to_string()));
        
        (StatusCode::OK, Json(serde_json::json!({
            "status": "released",
            "run_id": run_id
        }))).into_response()
    } else {
        (StatusCode::NOT_FOUND, Json(serde_json::json!({
            "error": "Run not found"
        }))).into_response()
    }
}
```

**Add route:**
```rust
.route("/api/admin/sops/{run_id}/force-release", 
    post(handle_force_release_claim))
```

## Implementation Priority

### Immediate (Critical)
1. **Fix 1 & 2:** Add explicit claim release in `finish_run` functions
2. **Fix 3:** Add claim timeout/reaper mechanism
3. **Fix 4:** Configure claim lease expiration

### Short-term (Important)
4. **Fix 5:** Add admin API for manual cleanup
5. Add health check for stuck runs (> threshold in "running")
6. Add metrics for claim reaper activity

### Long-term (Enhancement)
7. Add claim monitoring dashboard
8. Add automated alerts for claim exhaustion
9. Add claim leak detection in tests

## Testing Strategy

### Unit Tests
```rust
#[test]
fn finish_run_always_releases_claim_on_persist_failure() {
    let mut store = FailingPersistStore::new();
    let mut engine = engine_with_store(store.clone());
    
    // Start a run
    engine.start_run("test_sop", manual_event()).unwrap();
    
    // Attempt to finish with failing persist
    let result = engine.finish_run("run_id", SopRunStatus::Failed, None);
    
    // Should fail due to persist error
    assert!(result.is_err());
    
    // But claim should still be released
    assert!(store.try_claim_run("new_run", "test_sop", 1, 1).unwrap().is_some());
}

#[test]
fn claim_reaper_clears_expired_claims() {
    let store = SqliteRunStore::open_in_memory().unwrap();
    let mut engine = engine_with_store(store.clone());
    
    // Create a claim with expired lease
    let expired_token = ClaimToken {
        run_id: "stuck_run".to_string(),
        sop_name: "test_sop".to_string(),
        claimed_at: "2020-01-01T00:00:00Z".to_string(),
        lease_expires: "2020-01-01T01:00:00Z".to_string(),
        holder: "engine".to_string(),
    };
    
    // Manually insert expired claim
    store.insert_claim_direct(&expired_token);
    
    // Run maintenance tick
    engine.maintenance_tick();
    
    // Claim should be reaped
    assert!(store.try_claim_run("new_run", "test_sop", 1, 1).unwrap().is_some());
}
```

### Integration Tests
1. Run concurrency test with deliberately failing persist
2. Verify claim is released despite persist failure
3. Test claim reaper with artificially expired claims
4. Test admin API force-release endpoint

## Rollout Plan

### Phase 1: Emergency Patch
1. Implement Fix 1 & 2 (claim release in finish_run)
2. Add basic claim timeout (Fix 3 & 4)
3. Deploy to test environment
4. Run concurrency tests
5. Monitor for 24 hours

### Phase 2: Enhanced Recovery
1. Implement Fix 5 (admin API)
2. Add health checks and monitoring
3. Deploy to production
4. Update runbooks with claim cleanup procedures

### Phase 3: Prevention
1. Add comprehensive claim leak detection tests
2. Add claim exhaustion alerts
3. Implement claim monitoring dashboard

## Verification

After implementing fixes, re-run the concurrency test:

```bash
# Setup test subscribers
# ... (same as before)

# Test 1: Normal completion
./dev-tools/test_concurrency.sh

# Test 2: Simulated failure (kill process mid-run)
./dev-tools/test_concurrency_failure.sh

# Test 3: Claim timeout (set short lease, wait)
./dev-tools/test_claim_timeout.sh

# Expected: All tests should pass, no permanent lockouts
```

## Related Issues

- Original reliability test invalidated by this bug
- Need to re-run 3-hour reliability test after fix
- Consider adding claim health to standard health check endpoint