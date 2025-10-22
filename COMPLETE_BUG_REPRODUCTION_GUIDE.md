# Complete Bug Reproduction Guide

## 🎯 The Bug We're Reproducing

**Problem:** When a service starts successfully but health checks fail later, the `/services` API returns the old "successful" log instead of the "failed" log.

**Your Real Scenario:**
```
heartbeat → migration fails (jfrog_api_key column error)
   ↓
web → starts OK → health checks fail → queries fail
   ↓
API shows: successful=true, log_reason=ROUTINE ← WRONG!
Should show: successful=false, log_reason=HEALTH_CHECK_FAILED
```

---

## 📋 Prerequisites

- Docker and docker-compose installed
- Shipyard instance running
- Access to Shipyard UI and Flask shell

---

## 🚀 Method 1: Quick Local Test (Fastest)

This tests the timing/behavior locally with docker-compose:

```bash
cd /Users/daniellepinheiro/crash-loop-test

# Run the test script
./test-health-check-bug.sh

# Or manually:
docker-compose -f docker-compose-health-check-bug.yml up
```

**What you'll see:**
- Services start
- Health checks pass for 30 seconds
- Health checks fail after 30 seconds
- Service logs show errors

**This proves:** The timing works correctly (start → pass → fail)

**Limitation:** This doesn't test the Shipyard database/API behavior

---

## 🏗️ Method 2: Full Shipyard Deployment (Complete Test)

This is the **complete end-to-end test** that reproduces the actual bug.

### Step 1: Push to GitHub

```bash
cd /Users/daniellepinheiro/crash-loop-test

# Make sure you have a git remote
git remote add origin https://github.com/YOUR_USERNAME/crash-loop-test.git

# Push
git push -u origin main
```

### Step 2: Create Shipyard Application

1. Go to Shipyard UI
2. Click "New Application"
3. Connect to your GitHub repo: `crash-loop-test`
4. **Important:** Select `docker-compose-health-check-bug.yml` as the compose file
5. Click "Create Application"

### Step 3: Deploy and Wait

```
⏱️ Timeline:

0:00  Deploy starts
0:15  Services start (web creates ROUTINE log with successful=true)
0:30  Health checks start failing (creates HEALTH_CHECK_FAILED log with successful=false)
0:45+ Bug is visible (API still returns ROUTINE log)
```

**Wait at least 60 seconds** after deployment starts before checking.

### Step 4: Verify the Bug via API

```bash
# Get your application build ID from the URL
# Example: http://localhost:8080/application-build/c871af4a-5157-4812-ade6-877f5c9b1654
APP_BUILD_ID="c871af4a-5157-4812-ade6-877f5c9b1654"

# Get your session cookie from browser DevTools
SESSION_COOKIE="your-session-cookie"

# Call the services API
curl -s "http://localhost:8080/api/application-build/$APP_BUILD_ID/services" \
  -H "Cookie: session=$SESSION_COOKIE" \
  | jq '.[].[] | select(.name == "web") | {
      name,
      run_log: {
        successful: .run_log.successful,
        log_reason: .run_log.log_reason,
        gathered_at: .run_log.gathered_at
      }
    }'
```

**Expected Output (THE BUG):**
```json
{
  "name": "web",
  "run_log": {
    "successful": true,              ← WRONG!
    "log_reason": "ROUTINE",         ← WRONG!
    "gathered_at": "2025-10-22 16:00:15.123456"
  }
}
```

**Should be:**
```json
{
  "name": "web",
  "run_log": {
    "successful": false,                     ← Correct
    "log_reason": "HEALTH_CHECK_FAILED",     ← Correct
    "gathered_at": "2025-10-22 16:00:35.123456"
  }
}
```

### Step 5: Verify in Database

```bash
cd /Users/daniellepinheiro/shipyard-code/shipyard
poetry run flask shell
```

```python
from shipyard.models import BuildServiceLog, Build
from shipyard.models.build import LogReason

# Get the build by UUID (from URL)
build = Build.get(uuid="c871af4a-5157-4812-ade6-877f5c9b1654")

# Or by ID if you know it
# build = Build.get(id=12345)

if not build:
    print("Build not found! Check the UUID")
else:
    print(f"Build found: {build.id}\n")

    # Find web service
    web_service = next((s for s in build.deployable_services() if s.name == "web"), None)

    if web_service:
        print(f"=== Service: {web_service.name} (ID: {web_service.id}) ===\n")

        # Get ALL logs for this service
        all_logs = BuildServiceLog.list(
            build_id=build.id,
            compose_service_id=web_service.id
        )

        print(f"📊 Total logs in database: {len(all_logs)}\n")

        # Show each log
        for i, log in enumerate(all_logs, 1):
            emoji = "✅" if log.successful else "❌"
            print(f"Log {i}: {log.log_reason.code}")
            print(f"  {emoji} Successful: {log.successful}")
            print(f"  ⏰ Gathered: {log.gathered_at}")
            print(f"  🏥 Health Check Success: {log.health_check_success}")
            print()

        # Show what API returns
        run_log = build.service_run_log(web_service)

        print(f"🌐 What /services API returns:")
        print(f"  Log Reason: {run_log.log_reason.code}")
        print(f"  Successful: {run_log.successful}")
        print(f"  Gathered: {run_log.gathered_at}")
        print()

        # Check if bug is present
        has_health_check_fail = any(
            log.log_reason == LogReason.HEALTH_CHECK_FAILED
            for log in all_logs
        )

        has_routine = any(
            log.log_reason == LogReason.ROUTINE
            for log in all_logs
        )

        print("=" * 60)
        if has_health_check_fail and has_routine and run_log.log_reason == LogReason.ROUTINE:
            print("🐛 BUG REPRODUCED!")
            print()
            print("Database has:")
            print("  ✅ ROUTINE log (successful=true)")
            print("  ❌ HEALTH_CHECK_FAILED log (successful=false)")
            print()
            print("But API returns:")
            print(f"  ⚠️  ROUTINE log (the old one)")
            print()
            print("Expected:")
            print("  ✅ Should return HEALTH_CHECK_FAILED log")
        elif has_health_check_fail and run_log.log_reason == LogReason.HEALTH_CHECK_FAILED:
            print("✅ BUG FIXED!")
            print()
            print("API correctly returns HEALTH_CHECK_FAILED log")
        else:
            print("⚠️  Inconclusive - check timing or wait longer")
            print()
            print(f"Has ROUTINE: {has_routine}")
            print(f"Has HEALTH_CHECK_FAILED: {has_health_check_fail}")
            print(f"API returns: {run_log.log_reason.code}")
        print("=" * 60)
```

### Step 6: Expected Database Output

**Before Fix:**
```
=== Service: web (ID: 456) ===

📊 Total logs in database: 2

Log 1: ROUTINE
  ✅ Successful: True
  ⏰ Gathered: 2025-10-22 16:00:15.123456
  🏥 Health Check Success: None

Log 2: HEALTH_CHECK_FAILED
  ❌ Successful: False
  ⏰ Gathered: 2025-10-22 16:00:35.789012
  🏥 Health Check Success: False

🌐 What /services API returns:
  Log Reason: ROUTINE
  Successful: True
  Gathered: 2025-10-22 16:00:15.123456

============================================================
🐛 BUG REPRODUCED!

Database has:
  ✅ ROUTINE log (successful=true)
  ❌ HEALTH_CHECK_FAILED log (successful=false)

But API returns:
  ⚠️  ROUTINE log (the old one)

Expected:
  ✅ Should return HEALTH_CHECK_FAILED log
============================================================
```

**After Fix:**
```
🌐 What /services API returns:
  Log Reason: HEALTH_CHECK_FAILED
  Successful: False
  Gathered: 2025-10-22 16:00:35.789012

============================================================
✅ BUG FIXED!

API correctly returns HEALTH_CHECK_FAILED log
============================================================
```

---

## 🔍 Troubleshooting

### Issue: Only seeing ROUTINE log, no HEALTH_CHECK_FAILED

**Cause:** Health checks haven't failed yet or Nautilus isn't reporting them.

**Solution:**
1. Wait longer (at least 60 seconds)
2. Check Nautilus logs: `kubectl logs -n shipyard-system deploy/nautilus -f`
3. Verify health check labels are present in compose file
4. Decrease `FAIL_AFTER_SECONDS` in the compose file

### Issue: No logs at all

**Cause:** Service didn't start or logs aren't being collected.

**Solution:**
1. Check if deployment succeeded: `kubectl get pods -n shipyard-app-build-<id>`
2. Check application build status in UI
3. Look at build logs in Shipyard UI

### Issue: Can't reproduce in local docker-compose

**Cause:** Local docker-compose doesn't create Shipyard database records.

**Solution:** This is expected. Local testing only verifies the timing works. You MUST deploy to Shipyard to test the actual bug.

### Issue: Build UUID not found

```python
# List recent builds
from shipyard.models import Build
builds = Build.query.order_by(Build.id.desc()).limit(10).all()
for b in builds:
    print(f"ID: {b.id}, UUID: {b.uuid}, Project: {b.project.name if b.project else 'N/A'}")
```

---

## ✅ Verification Checklist

Before saying the bug is reproduced, verify:

- [ ] Deployment completed successfully
- [ ] Waited at least 60 seconds after deployment
- [ ] Web service health endpoint is accessible
- [ ] Health checks are failing (check service logs)
- [ ] Database shows 2+ logs for the service
- [ ] Database has both ROUTINE and HEALTH_CHECK_FAILED logs
- [ ] API returns ROUTINE log (not HEALTH_CHECK_FAILED)

---

## 🎬 Quick Commands Summary

```bash
# Deploy
cd /Users/daniellepinheiro/crash-loop-test
git push origin main
# Create app in Shipyard UI with docker-compose-health-check-bug.yml

# Wait 60 seconds

# Check API
curl -s "http://localhost:8080/api/application-build/<id>/services" \
  -H "Cookie: session=<cookie>" | jq '.[].[] | select(.name == "web") | .run_log'

# Check Database
cd /Users/daniellepinheiro/shipyard-code/shipyard
poetry run flask shell
# Then paste the verification script from Step 5 above

# Test Fix
# 1. Apply fix to shipyard/models/build.py (already done)
# 2. Restart: docker-compose restart web
# 3. Redeploy application
# 4. Verify API now returns HEALTH_CHECK_FAILED
```

---

## 📚 Related Files

- `docker-compose-health-check-bug.yml` - The reproduction compose file
- `README_HEALTH_CHECK_BUG.md` - Detailed explanation
- `test-health-check-bug.sh` - Local testing script
- `../shipyard/models/build.py:4646-4672` - The fix location

---

**Need help?** Re-read the timeline in Step 3 - timing is critical for reproduction!
