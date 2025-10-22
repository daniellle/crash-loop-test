# How to Reproduce the /pods Endpoint Bug

## The Issue You're Seeing

You checked `/services` endpoint which shows:
- ✅ `crash_log` - Correctly shows crashes
- ✅ `run_log` - Shows the error logs
- ✅ `pod_timeline` - Shows crash history

BUT, these are **historical logs** stored in the database. They don't show **real-time pod status**.

## The REAL Bug: `/pods` Endpoint

The bug is in the **`/pods` endpoint** which returns **real-time Kubernetes pod status**.

### Step-by-Step to See the Bug

#### 1. Deploy the App

Make sure your crash-loop-test app is deployed and the pods are actively crashing.

#### 2. Call the CORRECT Endpoint

```bash
# NOT this one (you already tested this)
curl http://localhost:8080/api/application-build/<id>/services

# Call THIS one instead:
curl http://localhost:8080/api/application-build/c871af4a-5157-4812-ade6-877f5c9b1654/pods
```

#### 3. Expected vs Actual

**What You SHOULD See (but won't with the bug):**
```json
{
  "pods": [
    {
      "name": "web-crash",
      "phase": "CrashLoopBackOff",  ← Should show this
      "phase_color": "danger",       ← Should be danger/red
      "n_ready": 0,
      "n_total": 1,
      "restart_count": 5
    }
  ]
}
```

**What You ACTUALLY See (the bug):**
```json
{
  "pods": [
    {
      "name": "web-crash",
      "phase": "Running",       ← WRONG! Shows "Running"
      "phase_color": "success", ← WRONG! Shows green
      "n_ready": 0,             ← This is correct
      "n_total": 1,
      "restart_count": 5        ← This is correct
    }
  ]
}
```

## Why This Happens

### The Data Flow

```
Kubernetes API
  ↓ (Pod.Status.Phase = "Running")
  ↓ (Container.State.Waiting.Reason = "CrashLoopBackOff")
  ↓
Nautilus GetApplicationBuildPods
  ↓ (Only extracts Pod.Status.Phase, ignores Container.State.Waiting.Reason)
  ↓
Proto: Pod.phase = "Running"
  ↓
Python ApplicationBuildPods.get_pods()
  ↓ (Uses pod.phase directly)
  ↓
/pods endpoint returns: phase="Running", phase_color="success"
  ↓
Frontend shows GREEN dot ● even though service is crashing
```

## How to Verify the Bug with kubectl

While your app is running and crashing:

```bash
# 1. Find the namespace
NS=$(kubectl get namespaces | grep "c871af4a" | awk '{print $1}')
echo "Namespace: $NS"

# 2. Get pod name
POD=$(kubectl get pods -n $NS -l app=generic-app -o jsonpath='{.items[0].metadata.name}')
echo "Pod: $POD"

# 3. Check pod phase (this is what /pods endpoint returns)
kubectl get pod $POD -n $NS -o jsonpath='{.status.phase}'
# Output: Running  ← This is what the bug shows!

# 4. Check ACTUAL container state (this is what it SHOULD show)
kubectl get pod $POD -n $NS -o jsonpath='{.status.containerStatuses[0].state}' | jq
# Output: {"waiting":{"reason":"CrashLoopBackOff",...}}  ← This is the TRUTH!

# 5. Check restart count
kubectl get pod $POD -n $NS -o jsonpath='{.status.containerStatuses[0].restartCount}'
# Output: 5 (or higher)

# 6. See it visually
kubectl get pods -n $NS
# Output:
# NAME                 READY   STATUS             RESTARTS   AGE
# web-crash-xxx        0/1     CrashLoopBackOff   5          5m
```

## The Proof

Compare these three sources:

### A. kubectl (Truth)
```bash
$ kubectl get pods -n $NS
NAME            READY   STATUS             RESTARTS
web-crash-xxx   0/1     CrashLoopBackOff   5
```

### B. /pods API (Bug - shows "Running")
```bash
$ curl http://localhost:8080/api/application-build/<id>/pods
{
  "phase": "Running",        ← MISMATCH!
  "phase_color": "success"   ← WRONG COLOR!
}
```

### C. Kubernetes Pod Object
```bash
$ kubectl get pod web-crash-xxx -n $NS -o json | jq '.status'
{
  "phase": "Running",  ← Pod-level (misleading)
  "containerStatuses": [{
    "state": {
      "waiting": {
        "reason": "CrashLoopBackOff"  ← Container-level (truth!)
      }
    },
    "restartCount": 5,
    "ready": false
  }]
}
```

## Why `/services` Shows Crashes But `/pods` Doesn't

### `/services` Endpoint
- Returns: Historical crash logs from database
- Source: `BuildServiceLog` model (stored when crashes are detected)
- Shows: `crash_log.log_reason = "CRASHED"`
- This WORKS because it's based on historical detection

### `/pods` Endpoint
- Returns: Real-time pod status from Kubernetes
- Source: Live data from `GetApplicationBuildPods` gRPC call
- Shows: `phase = pod.Status.Phase` (pod-level)
- This is BROKEN because it doesn't check container-level waiting reason

## The Frontend Impact

When you look at the "Run Logs" tab in the UI:

1. **Sidebar Service List** - Uses `/services` data
   - Shows crash logs correctly
   - Has crash_log with contents

2. **Pod Status Widget** (if it exists) - Uses `/pods` data
   - Would show green "Running" status
   - Shows 0/1 ready but with success color
   - This is the bug!

## Quick Test Script

```bash
#!/bin/bash
# Save as check-bug.sh

APP_BUILD_ID="c871af4a-5157-4812-ade6-877f5c9b1654"
NS="shipyard-app-build-$APP_BUILD_ID"

echo "=== Checking Pod Status ==="
POD=$(kubectl get pods -n $NS -o name | head -1)

echo "\n1. kubectl shows:"
kubectl get pods -n $NS | grep -E "NAME|web-crash|delayed-crash|api-with-db"

echo "\n2. Container state (truth):"
kubectl get $POD -n $NS -o jsonpath='{.status.containerStatuses[0].state}' | jq

echo "\n3. API returns (bug):"
curl -s "http://localhost:8080/api/application-build/$APP_BUILD_ID/pods" | jq '.[] | {name, phase, phase_color, n_ready, restart_count}'

echo "\n=== BUG: phase should be 'CrashLoopBackOff', not 'Running' ==="
```

## Summary

- ✅ `/services` endpoint shows crash logs (working)
- ❌ `/pods` endpoint shows phase="Running" (broken)
- The bug is specifically in how **real-time pod status** is reported
- kubectl shows "CrashLoopBackOff"
- API shows "Running" with "success" color
- Frontend would display green indicator instead of red

To fix: Add `waiting_reason` to proto and check it in Python code.
