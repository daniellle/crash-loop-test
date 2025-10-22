# Visual Comparison: Current vs Expected Behavior

## Kubernetes Reality vs What Your App Shows

### What Kubernetes Actually Reports

```bash
$ kubectl get pods -n shipyard-app-build-xyz
NAME                   READY   STATUS             RESTARTS   AGE
web-7f9c8d5b6-abc123   0/1     CrashLoopBackOff   5          3m
```

### What Your Frontend Currently Shows (BUG)

```
Service Logs Tab:

┌─────────────────────────────────┐
│ Services                        │
├─────────────────────────────────┤
│ ● web                  ← Green! │
│   postgres             ← Green  │
│   redis                ← Green  │
└─────────────────────────────────┘

API Response:
{
  "name": "web",
  "phase": "Running",         ← WRONG!
  "phase_color": "success",   ← WRONG!
  "n_ready": 0,               ← Correct
  "restart_count": 5          ← Correct
}
```

**User thinks:** "Everything is running fine, why no logs?"

### What It Should Show (FIXED)

```
Service Logs Tab:

┌─────────────────────────────────┐
│ Services                        │
├─────────────────────────────────┤
│ ● web                  ← Red!   │
│   postgres             ← Green  │
│   redis                ← Green  │
└─────────────────────────────────┘

"Service is in CrashLoopBackOff state"
"Container has restarted 5 times"

Last crash log:
ERROR: column org.jfrog_api_key does not exist
psycopg2.errors.UndefinedColumn

API Response:
{
  "name": "web",
  "phase": "CrashLoopBackOff",  ← Correct!
  "phase_color": "danger",      ← Correct!
  "n_ready": 0,
  "restart_count": 5
}
```

**User knows:** "The service is crashing, I need to fix the database migration!"

---

## The Code Flow Comparison

### Current (Broken) Flow

```
┌─────────────────────────────────────────────────────────┐
│ Kubernetes Pod                                          │
│ - Phase: "Running"                                      │
│ - Container State: Waiting                              │
│ - Container Reason: "CrashLoopBackOff" ← LOST HERE!    │
└──────────────────────┬──────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────┐
│ Nautilus GetApplicationBuildPods (Go)                   │
│ pod.Phase = string(l.Items[i].Status.Phase)             │
│                                                         │
│ Only extracts pod-level phase ❌                        │
│ Ignores container waiting reason ❌                     │
└──────────────────────┬──────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────┐
│ Proto: coordinator.v1.Pod                               │
│ {                                                       │
│   phase: "Running"  ← Wrong!                           │
│   containers: [{                                        │
│     state: "Waiting" ← Generic, no reason!             │
│   }]                                                    │
│ }                                                       │
└──────────────────────┬──────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────┐
│ Python ApplicationBuildPods.get_pods()                  │
│ entry = {                                               │
│   'phase': pod.phase  ← "Running"                      │
│   'phase_color': 'success' ← Wrong!                    │
│ }                                                       │
└──────────────────────┬──────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────┐
│ Frontend: ApplicationBuildLogPane.tsx                   │
│ Shows green dot for "success" ● ← Wrong!                │
└─────────────────────────────────────────────────────────┘
```

### Fixed Flow

```
┌─────────────────────────────────────────────────────────┐
│ Kubernetes Pod                                          │
│ - Phase: "Running"                                      │
│ - Container State: Waiting                              │
│ - Container Reason: "CrashLoopBackOff" ← PRESERVED!    │
└──────────────────────┬──────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────┐
│ Nautilus GetApplicationBuildPods (Go) ✨ FIXED          │
│ pod.Phase = string(l.Items[i].Status.Phase)             │
│ container.WaitingReason = s.Waiting.Reason ✅           │
│                                                         │
│ Extracts waiting reason! ✅                             │
└──────────────────────┬──────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────┐
│ Proto: coordinator.v1.Container ✨ UPDATED               │
│ {                                                       │
│   phase: "Running"                                      │
│   containers: [{                                        │
│     state: "Waiting"                                    │
│     waiting_reason: "CrashLoopBackOff" ← NEW! ✅       │
│   }]                                                    │
│ }                                                       │
└──────────────────────┬──────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────┐
│ Python ApplicationBuildPods.get_pods() ✨ FIXED         │
│ if any(c.waiting_reason == "CrashLoopBackOff"):        │
│   phase = "CrashLoopBackOff"                           │
│   phase_color = "danger" ✅                             │
└──────────────────────┬──────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────┐
│ Frontend: ApplicationBuildLogPane.tsx                   │
│ Shows red dot for "danger" ● ← Correct! ✅              │
└─────────────────────────────────────────────────────────┘
```

---

## Side-by-Side API Response

### Current Response (Bug)
```json
{
  "pods": [
    {
      "name": "web",
      "n_ready": 0,
      "n_total": 1,
      "phase": "Running",          ❌
      "phase_color": "success",    ❌
      "restart_count": 5,
      "overall_restart_count": 5,
      "creation_timestamp": "2025-10-22 15:35:35.000000"
    }
  ]
}
```

### Expected Response (Fixed)
```json
{
  "pods": [
    {
      "name": "web",
      "n_ready": 0,
      "n_total": 1,
      "phase": "CrashLoopBackOff", ✅
      "phase_color": "danger",     ✅
      "restart_count": 5,
      "overall_restart_count": 5,
      "creation_timestamp": "2025-10-22 15:35:35.000000",
      "container_states": [        ✅ (bonus)
        {
          "name": "web",
          "state": "Waiting",
          "waiting_reason": "CrashLoopBackOff"
        }
      ]
    }
  ]
}
```

---

## How to See the Difference

Run the test script and you'll see:

```bash
$ ./test-local-k8s.sh

📊 Pod Phase (what GetApplicationBuildPods returns):
   Phase: Running
   ⚠️  This shows 'Running' even though container is crashing!

📊 Container State (the real status):
   {
     "waiting": {
       "message": "back-off 5m0s restarting failed container",
       "reason": "CrashLoopBackOff"    ← THIS IS THE TRUTH!
     }
   }

❌ PROBLEM: phase shows 'Running' with 'success' color!
```

---

## Impact on User Experience

### Before Fix:
1. ❌ User sees green indicator
2. ❌ Thinks service is healthy
3. ❌ Confused why logs are empty
4. ❌ Has to use kubectl manually
5. ❌ Wastes 15+ minutes debugging

### After Fix:
1. ✅ User sees red indicator immediately
2. ✅ Sees "CrashLoopBackOff" message
3. ✅ Sees last crash log
4. ✅ Sees restart count incrementing
5. ✅ Can fix the issue in < 2 minutes

---

## Try It Yourself

```bash
# 1. Run the test
./test-local-k8s.sh

# 2. Check what Shipyard API returns
curl http://localhost:8080/api/application-build/<id>/pods | jq

# 3. Compare with kubectl
kubectl get pods -n crash-loop-test

# You'll see the mismatch!
```
