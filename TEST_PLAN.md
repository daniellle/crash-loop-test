# Test Plan: Reproducing the "bg-success" Bug

## The Bug

Services that initially pass health checks but later fail still show `successful: true` in the API response.

## Timeline of Events

| Time | Event | Database State | API Response |
|------|-------|----------------|--------------|
| T+0s | Deploy starts | No logs | N/A |
| T+5s | First health check | Waiting... | N/A |
| T+15s | Health checks pass | `ROUTINE` log created (`successful=true`) | ✅ `successful: true` |
| T+30s | Deployment succeeds | Still `ROUTINE` log only | ✅ `successful: true` |
| T+60s | Health checks timeout | `HEALTH_CHECK_FAILED` log created (`successful=false`) | ❌ BUG: Still returns `successful: true` |
| T+70s | Still timing out | Both logs exist | ❌ BUG: Returns old `ROUTINE` log |

## Test Services

### 1. `delayed-timeout` (Primary test case)
- **Initial**: Responds to `/health` in < 100ms for first 60 seconds
- **After 60s**: Takes 10 seconds to respond (triggers 2s timeout)
- **Expected behavior**:
  - T+15s: Creates `ROUTINE` log with `successful: true`
  - T+65s: Creates `HEALTH_CHECK_FAILED` log with `successful: false`
  - **BUG**: API returns `ROUTINE` log at T+70s instead of `HEALTH_CHECK_FAILED`

### 2. `port-closer` (Alternative test case)
- **Initial**: Responds normally for 60 seconds
- **After 60s**: Process exits → connection timeouts
- **Expected behavior**: Same as above

### 3. `always-healthy` (Control)
- Always responds quickly
- Should only have `ROUTINE` log with `successful: true`

## Steps to Reproduce

### 1. Deploy the Application

```bash
# Upload docker-compose-success-then-fail.yml to Shipyard UI
# Note the build ID from the URL
BUILD_ID="your-build-id-here"
```

### 2. Verify Initial Success (T+30s)

After deployment shows "success" (around 30 seconds), check the API:

```bash
SESSION="your-session-cookie"

curl -s -H "Cookie: session=$SESSION" \
  "http://localhost:8080/api/application-build/$BUILD_ID/services" \
  | jq '.[] | select(.name == "delayed-timeout") | {
      name: .name,
      run_log_successful: .run_log.successful,
      run_log_reason: .run_log.log_reason,
      failure_metadata: .failure_metadata
    }'
```

**Expected at T+30s** (Before timeout):
```json
{
  "name": "delayed-timeout",
  "run_log_successful": true,
  "run_log_reason": "ROUTINE",
  "failure_metadata": null
}
```

### 3. Wait for Health Check Timeout (T+70s)

Wait about 70 seconds total (30s to deploy + 40s for health checks to timeout), then check again:

```bash
# Same curl command as above
curl -s -H "Cookie: session=$SESSION" \
  "http://localhost:8080/api/application-build/$BUILD_ID/services" \
  | jq '.[] | select(.name == "delayed-timeout")'
```

**BEFORE FIX - Expected at T+70s** (Bug present):
```json
{
  "name": "delayed-timeout",
  "run_log": {
    "successful": true,              // ❌ BUG: Should be false!
    "log_reason": "ROUTINE",         // ❌ BUG: Should be "HEALTH_CHECK_FAILED"
    "health_check_success": true     // ❌ BUG: Should be false
  },
  "failure_metadata": {
    "build_failure_status": "HEALTH_CHECK_FAILED",
    "deploy_failure_status": "HEALTH_CHECK_FAILED",
    "failure_message": "health check timeout"
  }
}
```

Notice the contradiction:
- `run_log.successful: true` says it's healthy
- `failure_metadata` says health check failed
- This is the bug!

**AFTER FIX - Expected at T+70s** (Bug fixed):
```json
{
  "name": "delayed-timeout",
  "run_log": {
    "successful": false,                     // ✅ Fixed!
    "log_reason": "HEALTH_CHECK_FAILED",    // ✅ Fixed!
    "health_check_success": false           // ✅ Fixed!
  },
  "failure_metadata": {
    "build_failure_status": "HEALTH_CHECK_FAILED",
    "deploy_failure_status": "HEALTH_CHECK_FAILED",
    "failure_message": "health check timeout"
  }
}
```

### 4. Monitor Service Logs

You can watch the service logs to see the exact moment it switches from healthy to timeout:

```bash
NAMESPACE="shipyard-app-build-$BUILD_ID"
kubectl logs -n $NAMESPACE -l app=delayed-timeout -f
```

Expected output:
```
============================================================
Starting delayed-timeout service
Will be HEALTHY for 60 seconds
Then will TIMEOUT (sleep 10s, timeout is 2s)
============================================================
 * Running on http://0.0.0.0:5000
[5.2s] Health check: HEALTHY (responding quickly)
[15.3s] Health check: HEALTHY (responding quickly)
[25.4s] Health check: HEALTHY (responding quickly)
[35.5s] Health check: HEALTHY (responding quickly)
[45.6s] Health check: HEALTHY (responding quickly)
[55.7s] Health check: HEALTHY (responding quickly)
[65.8s] Health check: TIMEOUT - sleeping 10s (timeout is 2s)
[75.9s] Health check: TIMEOUT - sleeping 10s (timeout is 2s)
```

Notice: After 60 seconds, the logs show "TIMEOUT" messages.

### 5. Verify Database State

Check that both logs exist in the database:

```python
from shipyard.models.build import BuildServiceLog, ComposeService

# Get all logs for delayed-timeout service
service = ComposeService.get(name='delayed-timeout')
logs = BuildServiceLog.list(
    build_id='your-build-id',
    compose_service_id=service.id
)

for log in logs:
    print(f"Created: {log.created_at}")
    print(f"  log_reason: {log.log_reason}")
    print(f"  successful: {log.successful}")
    print(f"  health_check_success: {log.health_check_success}")
    print()
```

Expected output (both logs exist):
```
Created: 2025-10-22 22:05:15
  log_reason: LogReason.ROUTINE
  successful: True
  health_check_success: True

Created: 2025-10-22 22:06:05
  log_reason: LogReason.HEALTH_CHECK_FAILED
  successful: False
  health_check_success: False
```

## Why This Reproduces the Bug

The key is the **timing sequence**:

1. **Service must start successfully** to create the `ROUTINE` log
2. **Initial health checks must pass** (first 60 seconds)
3. **Deployment must complete successfully** so it creates the snapshot
4. **Then health checks must fail** (after 60 seconds)

If the service fails immediately (like `unresponsive-health`), it never creates a `ROUTINE` log, so there's nothing to incorrectly return.

## The Fix

In [build.py:4646-4672](../shipyard-code/shipyard/shipyard/models/build.py#L4646-L4672), the fix changes the priority:

```python
# OLD CODE (buggy):
# 1. Check for ROUTINE log
# 2. If found, return it immediately ← BUG!
# 3. Never checks for HEALTH_CHECK_FAILED

# NEW CODE (fixed):
# 1. Check for HEALTH_CHECK_FAILED log first
# 2. If found, return it ← Correct!
# 3. Otherwise fall back to ROUTINE log
```

## Success Criteria

After the fix and restart, when you check the API at T+70s, you should see:
- ✅ `run_log.successful: false`
- ✅ `run_log.log_reason: "HEALTH_CHECK_FAILED"`
- ✅ `run_log.health_check_success: false`
- ✅ `failure_metadata.failure_message: "health check timeout"`

All fields should agree that the service has failed.
