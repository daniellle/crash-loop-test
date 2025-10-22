# Reproducing the Health Check Bug

## The Bug

Services that:
1. **Start successfully** → Shipyard creates `BuildServiceLog` with `log_reason=ROUTINE, successful=true`
2. **Pass initial health checks** → Logs show service is working
3. **Fail health checks later** → Shipyard creates `BuildServiceLog` with `log_reason=HEALTH_CHECK_FAILED, successful=false`

**Problem:** The `/services` API returns the **old ROUTINE log** instead of the **new HEALTH_CHECK_FAILED log**.

## The Scenario

This reproduces your exact issue:

```
heartbeat service (runs migrations)
  ↓ migration FAILS (jfrog_api_key column error)
  ↓
web service (depends on heartbeat)
  ↓ starts successfully (creates ROUTINE log)
  ↓ health checks PASS initially
  ↓ tries to query database
  ↓ ERROR: column org.jfrog_api_key does not exist
  ↓ health checks FAIL (creates HEALTH_CHECK_FAILED log)
  ↓
API returns: successful: true, log_reason: ROUTINE ← BUG!
Should return: successful: false, log_reason: HEALTH_CHECK_FAILED
```

## How to Reproduce

### Step 1: Deploy to Shipyard

```bash
cd /Users/daniellepinheiro/crash-loop-test

# Make sure this is a git repo and pushed to GitHub
git add -A
git commit -m "Add health check bug reproduction"
git remote add origin <your-github-url>
git push -u origin main

# Then create a Shipyard application:
# 1. Go to Shipyard UI
# 2. Create new application
# 3. Point to this repo
# 4. Use docker-compose-health-check-bug.yml
# 5. Deploy and wait
```

### Step 2: Watch the Timeline

**0-10 seconds:**
- All services starting
- Postgres becomes ready
- Heartbeat starts

**10-15 seconds:**
- Heartbeat runs migration (via `shipyard.init` label)
- Migration FAILS with jfrog_api_key error
- Heartbeat init container exits with code 1

**15-30 seconds:**
- Web service starts successfully
- Shipyard creates `BuildServiceLog` with `log_reason=ROUTINE, successful=true`
- Health checks START (initial_delay=15s)
- Health checks PASS (service returns 200)

**30-45 seconds:**
- Web service starts returning 500 on `/health`
- Health checks FAIL
- Shipyard receives health check failure from Nautilus
- `deploy_update.py` creates `BuildServiceLog` with `log_reason=HEALTH_CHECK_FAILED, successful=false`

**Result:**
- Database has TWO logs:
  - `ROUTINE` log with `successful=true` (created at 15s)
  - `HEALTH_CHECK_FAILED` log with `successful=false` (created at 30s)
- API returns the `ROUTINE` log ← **BUG!**

### Step 3: Check the API

```bash
# Get your application build ID from the URL
APP_BUILD_ID="<your-app-build-id>"

# Wait 45+ seconds after deployment starts

# Call the services API
curl "http://localhost:8080/api/application-build/$APP_BUILD_ID/services" \
  -H "Cookie: session=<your-session>" \
  | jq '.[].[] | select(.name == "web") | {name, run_log: {successful: .run_log.successful, log_reason: .run_log.log_reason}}'

# You'll see:
# {
#   "name": "web",
#   "run_log": {
#     "successful": true,        ← WRONG! Should be false
#     "log_reason": "ROUTINE"    ← WRONG! Should be HEALTH_CHECK_FAILED
#   }
# }
```

### Step 4: Verify in Database

```bash
# Start Flask shell
cd /Users/daniellepinheiro/shipyard-code/shipyard
poetry run flask shell
```

```python
from shipyard.models import BuildServiceLog, Build
from shipyard.models.build import LogReason

# Get your build (find the ID from the database or logs)
build = Build.get(uuid="<your-build-uuid>")

# Find the web service
web_service = next((s for s in build.deployable_services() if s.name == "web"), None)

if web_service:
    # Get all logs for web service
    all_logs = BuildServiceLog.list(build_id=build.id, compose_service_id=web_service.id)

    print(f"Total logs for web service: {len(all_logs)}\n")

    for log in all_logs:
        print(f"Log Reason: {log.log_reason.code}")
        print(f"  Successful: {log.successful}")
        print(f"  Gathered at: {log.gathered_at}")
        print()

    # Check what API returns
    run_log = build.service_run_log(web_service)
    print(f"API returns:")
    print(f"  Log Reason: {run_log.log_reason.code}")
    print(f"  Successful: {run_log.successful}")
    print()

    # The bug:
    has_health_check_fail = any(
        log.log_reason == LogReason.HEALTH_CHECK_FAILED
        for log in all_logs
    )

    if has_health_check_fail and run_log.log_reason != LogReason.HEALTH_CHECK_FAILED:
        print("🐛 BUG REPRODUCED!")
        print("   Health check failure exists in database")
        print(f"   But API returns: {run_log.log_reason.code}")
```

## Expected Output (Before Fix)

```
Total logs for web service: 2

Log Reason: ROUTINE
  Successful: True
  Gathered at: 2025-10-22 16:00:15

Log Reason: HEALTH_CHECK_FAILED
  Successful: False
  Gathered at: 2025-10-22 16:00:30

API returns:
  Log Reason: ROUTINE          ← BUG!
  Successful: True             ← BUG!

🐛 BUG REPRODUCED!
   Health check failure exists in database
   But API returns: ROUTINE
```

## Expected Output (After Fix)

```
Total logs for web service: 2

Log Reason: ROUTINE
  Successful: True
  Gathered at: 2025-10-22 16:00:15

Log Reason: HEALTH_CHECK_FAILED
  Successful: False
  Gathered at: 2025-10-22 16:00:30

API returns:
  Log Reason: HEALTH_CHECK_FAILED    ← FIXED!
  Successful: False                   ← FIXED!
```

## Visual Timeline

```
Time    Event                                   Database State                      API Returns
────────────────────────────────────────────────────────────────────────────────────────────────────
0s      Deploy starts                           (no logs)                           N/A

15s     Web starts successfully                 ROUTINE: successful=true            successful=true
        Initial health checks pass                                                  log_reason=ROUTINE

30s     Health checks start failing             ROUTINE: successful=true            successful=true ← BUG!
        Migration error detected                HEALTH_CHECK_FAILED: successful=false   log_reason=ROUTINE

45s+    Health checks continue failing          (same as above)                     (same as above)

After   Fix applied                             (same as above)                     successful=false ✓
Fix                                                                                  log_reason=HEALTH_CHECK_FAILED ✓
```

## Testing the Fix

After applying the fix to `build.py`, restart Shipyard and redeploy:

```bash
# Restart Shipyard web service
docker-compose restart web

# Redeploy the test application (or trigger a new build)

# Wait 45+ seconds

# Check API again - should now return HEALTH_CHECK_FAILED
curl "http://localhost:8080/api/application-build/$APP_BUILD_ID/services" \
  -H "Cookie: session=<your-session>" \
  | jq '.[].[] | select(.name == "web") | .run_log | {successful, log_reason}'

# Should see:
# {
#   "successful": false,
#   "log_reason": "HEALTH_CHECK_FAILED"
# }
```

## Troubleshooting

### Health checks are passing when they should fail

Increase the failure time in the docker-compose file:
```yaml
FAIL_AFTER_SECONDS = 20  # Change to lower value like 15 or 10
```

### Services aren't being health checked

Check Nautilus logs:
```bash
kubectl logs -n shipyard-system deploy/nautilus -f | grep health
```

### Can't see the logs in database

The logs might be getting garbage collected. Check:
```python
from shipyard.models import BuildServiceLog
# Check if logs exist with ANY log_reason
all_build_logs = BuildServiceLog.list(build_id=build.id)
print(f"Total logs for build: {len(all_build_logs)}")
```

## Summary

This reproduction shows:
1. ✅ Services start successfully (ROUTINE log created)
2. ✅ Health checks fail later (HEALTH_CHECK_FAILED log created)
3. ❌ API returns old ROUTINE log (the bug!)
4. ✅ After fix, API returns HEALTH_CHECK_FAILED log

The timing is critical - there needs to be enough time for:
- Service to start and create ROUTINE log
- Health checks to pass initially
- Health checks to fail later and create HEALTH_CHECK_FAILED log
