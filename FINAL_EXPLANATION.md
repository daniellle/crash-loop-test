# FINAL EXPLANATION: Why You're Not Seeing the Bug

## TL;DR

You checked `/services` endpoint which **does work correctly** for showing crash logs.

The bug is in the `/pods` endpoint which you **haven't tested yet**.

## What You Tested

You called:
```bash
GET /api/application-build/c871af4a-5157-4812-ade6-877f5c9b1654/services
```

This endpoint returns:
- ✅ `crash_log` - Historical crash logs from database
- ✅ `run_log` - Historical run logs from database
- ✅ `pod_timeline` - Historical timeline data
- ✅ Shows `log_reason: "CRASHED"` correctly

**This works fine!** The crash detection system (from `deploy_update.py`) correctly identifies crashes and stores them in the database.

## What You NEED to Test

You need to call:
```bash
GET /api/application-build/c871af4a-5157-4812-ade6-877f5c9b1654/pods
```

This endpoint returns **real-time Kubernetes pod status**:
- ❌ `phase` - Currently shows "Running" (wrong!)
- ❌ `phase_color` - Currently shows "success" (wrong!)
- ✅ `n_ready` - Shows 0 (correct)
- ✅ `restart_count` - Shows actual count (correct)

## The Two Different Systems

### System 1: Crash Detection (Works ✅)

**Flow:**
```
Kubernetes detects crash
  ↓
Nautilus sends DeployUpdate gRPC
  ↓
Python deploy_update.py checks for "CrashLoopBackOff" in message
  ↓
Creates BuildServiceLog with log_reason="CRASHED"
  ↓
Stores in database
  ↓
/services endpoint returns this data
```

**File:** [deploy_update.py:53-74](../shipyard/shipyard/grpc/buildstatus_svc/deploy_update.py#L53-L74)
```python
log_reason: LogReason = (
    LogReason.CRASHED
    if 'CrashLoopBackOff' in svc_info.failure_message  ← Works!
    else LogReason.HEALTH_CHECK_FAILED
)
```

### System 2: Live Pod Status (Broken ❌)

**Flow:**
```
Frontend requests /pods
  ↓
Python calls ApplicationBuildPods.get_pods()
  ↓
Python calls Nautilus GetApplicationBuildPods gRPC
  ↓
Go code extracts Pod.Status.Phase = "Running"
  ↓
Go code IGNORES Container.State.Waiting.Reason = "CrashLoopBackOff"
  ↓
Returns phase="Running"
  ↓
Python uses it directly without checking containers
  ↓
/pods endpoint returns phase="Running", phase_color="success"
```

**File:** [get_pods.go:44](../nautilus/internal/coordinator/applicationbuild/get_pods.go#L44)
```go
pod := coordinatorv1.Pod{
    Phase: string(l.Items[i].Status.Phase),  ← Only uses pod-level phase!
    // Missing: Container waiting reason!
}
```

## Why This Matters

### For `/services` Endpoint (What You Tested)
- Used by: Build history, logs display
- Shows: Past crashes that were detected
- Problem: None! It works fine.

### For `/pods` Endpoint (What You Need to Test)
- Used by: Real-time pod status widgets, monitoring
- Shows: Current pod state from Kubernetes
- Problem: Shows "Running" with green color even when crashing!

## How to Actually See the Bug

### Option 1: Check Frontend Pod Status Widget

If your frontend has a widget/component that shows live pod status (not logs), it will show:
- 🟢 Green indicator
- "Running" status
- But 0/1 ready

This is the bug! It should show:
- 🔴 Red indicator
- "CrashLoopBackOff" status
- 0/1 ready

### Option 2: Call /pods Endpoint Directly

```bash
# Get your session cookie from browser DevTools
SESSION_COOKIE="your-session-cookie"

# Call the pods endpoint
curl -H "Cookie: session=$SESSION_COOKIE" \
  "http://localhost:8080/api/application-build/c871af4a-5157-4812-ade6-877f5c9b1654/pods"

# You'll see:
# {
#   "pods": [
#     {
#       "name": "web-crash",
#       "phase": "Running",       ← BUG!
#       "phase_color": "success", ← BUG!
#       "n_ready": 0,
#       "restart_count": 5
#     }
#   ]
# }
```

### Option 3: Check Kubernetes Directly

```bash
# Find your namespace
kubectl get namespaces | grep c871af4a

# Check pod status
kubectl get pods -n shipyard-app-build-c871af4a-5157-4812-ade6-877f5c9b1654

# You'll see:
# NAME            READY   STATUS             RESTARTS
# web-crash-xxx   0/1     CrashLoopBackOff   5

# ↑ This is the TRUTH
# But /pods endpoint returns phase="Running" ← This is the BUG
```

## The Smoking Gun

Run these three commands while pods are crashing:

```bash
NS="shipyard-app-build-c871af4a-5157-4812-ade6-877f5c9b1654"
POD=$(kubectl get pods -n $NS -o name | head -1)

# 1. What kubectl shows (TRUTH)
kubectl get pods -n $NS
# Output: STATUS = CrashLoopBackOff

# 2. What Kubernetes reports at pod level
kubectl get $POD -n $NS -o jsonpath='{.status.phase}'
# Output: Running  ← This is what /pods uses!

# 3. What Kubernetes reports at container level
kubectl get $POD -n $NS -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}'
# Output: CrashLoopBackOff  ← This is what /pods SHOULD use!
```

**The bug:** `/pods` endpoint uses #2 (pod phase) instead of #3 (container state).

## Summary Table

| Data Source | Endpoint | Shows Crashes? | Status |
|-------------|----------|----------------|---------|
| BuildServiceLog | `/services` | ✅ Yes | Works |
| Kubernetes Pod Phase | `/pods` | ❌ No | Bug! |
| Kubernetes Container State | (not exposed) | ✅ Yes | Should use this |

## What to Do Next

1. **Test `/pods` endpoint** with authentication to see phase="Running"
2. **Compare with `kubectl get pods`** to see CrashLoopBackOff
3. **Implement the fix** I described earlier:
   - Add `waiting_reason` to proto
   - Extract it in Go code
   - Use it in Python code
   - Return correct phase

## The Fix (Recap)

Update [pods.proto](../protos/definitions/daemon/coordinator/v1/pods.proto):
```protobuf
message Container {
    string name = 1;
    string state = 3;
    int32 restart_count = 4;
    bool ready = 5;
    string terminated_reason = 6;
    int32 exit_code = 7;
    string image = 8;
    string waiting_reason = 9;  // NEW!
}
```

Update [get_pods.go](../nautilus/internal/coordinator/applicationbuild/get_pods.go):
```go
cnt := coordinatorv1.Container{
    // ... existing fields ...
    WaitingReason: getWaitingReason(containerStatus.State),  // NEW!
}

func getWaitingReason(state v1.ContainerState) string {
    if state.Waiting != nil {
        return state.Waiting.Reason
    }
    return ""
}
```

Update [pods.py](../shipyard/shipyard/services/pods.py):
```python
# Check for crash loop
crash_looping = any(
    c.waiting_reason == "CrashLoopBackOff"
    for c in pod.containers
)

entry = {
    'phase': 'CrashLoopBackOff' if crash_looping else pod.phase,  // NEW!
    'phase_color': phase_color('CrashLoopBackOff' if crash_looping else pod.phase),  // NEW!
    # ... rest ...
}
```

---

**Bottom Line:** You tested the right app, but the wrong endpoint. Test `/pods` to see the bug!
