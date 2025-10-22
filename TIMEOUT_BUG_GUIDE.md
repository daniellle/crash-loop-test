# Health Check Timeout Bug Reproduction Guide

This guide shows how to reproduce the bug where services that timeout during health checks still show `successful: true` in the API response.

## The Bug Flow

1. **Service starts successfully** → Creates `BuildServiceLog` with `log_reason=ROUTINE, successful=true`
2. **Health check times out** → Nautilus detects timeout after 2 seconds
3. **Nautilus sends gRPC message** → `failureMessage: "health check timeout"`
4. **Python creates failure log** → Creates/updates `BuildServiceLog` with `log_reason=HEALTH_CHECK_FAILED, successful=false`
5. **API returns wrong log** ❌ → `service_run_log()` returns ROUTINE log instead of HEALTH_CHECK_FAILED

## Understanding Health Check Timeout

From `nautilus/internal/coordinator/healthchecker/sleep_cancel.go:36-40`:

```go
case context.DeadlineExceeded:
    return &CheckBuildHealthResponse{
        Failure: buildstatusdefv1.BuildFailure_NEVER_STARTED,
        Message: "health check timeout",
    }
```

This timeout happens when:
- HTTP health check takes longer than `shipyard.liveness.timeout` (default 2s)
- Service port is not accessible (connection timeout)
- Health check endpoint doesn't exist

## Test Services

### 1. `slow-health-check`
- **Scenario**: Health check response becomes slow after 30 seconds
- **Initial behavior**: Responds quickly to `/health` → Creates ROUTINE log ✅
- **After 30s**: Takes 5 seconds to respond → Health check times out (timeout is 2s) ❌
- **Expected failureMessage**: `"health check timeout"`

### 2. `unresponsive-health`
- **Scenario**: Service listens on wrong port (9999 instead of 5000)
- **Initial behavior**: Pod starts → Creates ROUTINE log ✅
- **Health check**: Nautilus tries port 5000 → Connection refused/timeout ❌
- **Expected failureMessage**: `"health check timeout"` or connection error

### 3. `healthy-service` (control)
- **Scenario**: Always responds quickly to health checks
- **Expected**: Only ROUTINE log, no failures

## Reproduction Steps

### Step 1: Deploy the Test Application

1. Go to Shipyard UI: http://localhost:8080
2. Create new project or use existing
3. Upload `docker-compose-timeout.yml`
4. Click "Build & Deploy"
5. Note the `application_build_id` from the URL

### Step 2: Monitor the Failure

Wait for about 40-50 seconds after deployment starts:

```bash
# Watch the build events
NAMESPACE="shipyard-app-build-YOUR_BUILD_ID"
kubectl logs -n $NAMESPACE -l app=slow-health-check --tail=50 -f
```

You should see:
```
Starting Flask app...
 * Running on http://0.0.0.0:5000
[... healthy responses for 30 seconds ...]
Health check will timeout - sleeping 5s (timeout is 2s)
```

### Step 3: Check the API Response

```bash
# Get your session cookie from browser DevTools
BUILD_ID="YOUR_BUILD_ID"
SESSION_COOKIE="YOUR_SESSION_COOKIE"

# Check /services endpoint
curl -H "Cookie: session=$SESSION_COOKIE" \
  "http://localhost:8080/api/application-build/$BUILD_ID/services" \
  | python3 -m json.tool > services_response.json

# Look for slow-health-check service
cat services_response.json | jq '.[] | select(.name == "slow-health-check")'
```

### Step 4: Verify the Bug

**BEFORE FIX** - You'll see this bug:

```json
{
  "name": "slow-health-check",
  "run_log": {
    "successful": true,              // ❌ BUG: Should be false!
    "log_reason": "ROUTINE",         // ❌ BUG: Should be "HEALTH_CHECK_FAILED"
    "health_check_success": true     // ❌ BUG: Should be false
  },
  "crash_log": null,
  "failure_metadata": {
    "build_failure_status": "HEALTH_CHECK_FAILED",
    "deploy_failure_status": "HEALTH_CHECK_FAILED",
    "failure_message": "health check timeout"  // ✅ This is correct!
  }
}
```

**AFTER FIX** - You should see:

```json
{
  "name": "slow-health-check",
  "run_log": {
    "successful": false,                      // ✅ Fixed!
    "log_reason": "HEALTH_CHECK_FAILED",     // ✅ Fixed!
    "health_check_success": false            // ✅ Fixed!
  },
  "crash_log": null,
  "failure_metadata": {
    "build_failure_status": "HEALTH_CHECK_FAILED",
    "deploy_failure_status": "HEALTH_CHECK_FAILED",
    "failure_message": "health check timeout"
  }
}
```

## Verifying the Database

You can also check the database directly to see both logs:

```python
from shipyard.models.build import BuildServiceLog, Build, ComposeService

# Get the build
build = Build.get(id='YOUR_BUILD_ID')

# Get the service
service = ComposeService.get(name='slow-health-check', project_id=build.project_id)

# List all logs for this service
logs = BuildServiceLog.list(build_id=build.id, compose_service_id=service.id)

for log in logs:
    print(f"Log ID: {log.id}")
    print(f"  log_reason: {log.log_reason}")
    print(f"  successful: {log.successful}")
    print(f"  health_check_success: {log.health_check_success}")
    print(f"  created_at: {log.created_at}")
    print()
```

Expected output (you should see BOTH logs):

```
Log ID: 12345
  log_reason: LogReason.ROUTINE
  successful: True
  health_check_success: True
  created_at: 2025-10-22 15:30:00

Log ID: 12346
  log_reason: LogReason.HEALTH_CHECK_FAILED
  successful: False
  health_check_success: False
  created_at: 2025-10-22 15:30:45
```

## The Fix

The fix in [build.py:4646-4672](../shipyard-code/shipyard/shipyard/models/build.py#L4646-L4672) changes the priority:

**Before**: Check ROUTINE first → Return it even if HEALTH_CHECK_FAILED exists
**After**: Check HEALTH_CHECK_FAILED first → Return it if it exists, otherwise fall back to ROUTINE

## Timeline

| Time | Event | Database State |
|------|-------|----------------|
| T+0s | Pod starts | No logs yet |
| T+10s | Initial health check succeeds | `ROUTINE` log created (successful=true) |
| T+30s | Health check starts taking 5s | Still using `ROUTINE` log |
| T+35s | Nautilus times out (2s limit) | `HEALTH_CHECK_FAILED` log created (successful=false) |
| T+35s | API call | ❌ BUG: Returns `ROUTINE` log instead of `HEALTH_CHECK_FAILED` |

## Key Insight

The bug happens because:
1. Both logs exist in the database at the same time
2. The old code checked for `ROUTINE` first
3. If `ROUTINE` exists, it returns immediately without checking for `HEALTH_CHECK_FAILED`

The fix prioritizes failure states over success states, which is the correct behavior.
