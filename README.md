# Crash Loop Test Project

This project is designed to test how Shipyard handles various container failure scenarios, specifically CrashLoopBackOff states.

## Services

1. **web-crash** - Crashes immediately with database error message
2. **delayed-crash** - Crashes after 3 seconds (simulates startup then crash)
3. **postgres-migration-fail** - Healthy postgres, but dependent services fail
4. **api-with-db-error** - Simulates the exact error you're seeing (missing jfrog_api_key column)
5. **init-fail-service** - Has a failing init container
6. **healthy-service** - Actually works (for comparison)

## How to Use

### Option A: Deploy to Shipyard
1. Push this to a git repository
2. Create a new Shipyard application pointing to this repo
3. Watch the build - you should see services in various failure states

### Option B: Test Locally with Docker Compose
```bash
cd /Users/daniellepinheiro/shipyard-code/crash-loop-test
docker-compose up
```

Then check pod status:
```bash
docker-compose ps
```

### Option C: Test with Kubernetes (Most Realistic)

If you have access to the local k3s cluster:

```bash
# Deploy to namespace
kubectl create namespace crash-loop-test
kubectl apply -f k8s-test.yaml -n crash-loop-test

# Watch pods crash
kubectl get pods -n crash-loop-test -w

# Check specific pod
kubectl describe pod <pod-name> -n crash-loop-test

# See the CrashLoopBackOff status
kubectl get pods -n crash-loop-test -o wide
```

## Expected Behaviors

### In Kubernetes:
- Pods will show Phase: "Running"
- But containers will be in State: "Waiting" with Reason: "CrashLoopBackOff"
- restart_count will increment each crash
- Ready status will be 0/1

### What You Should See in Shipyard UI:
**Current Behavior (Bug):**
```json
{
  "phase": "Running",
  "phase_color": "success",
  "n_ready": 0,
  "restart_count": 0-5
}
```

**Expected Behavior (After Fix):**
```json
{
  "phase": "CrashLoopBackOff",
  "phase_color": "danger",
  "n_ready": 0,
  "restart_count": 0-5
}
```

## Testing the Fix

After implementing the proto changes:

1. Deploy this project
2. Navigate to the build details page
3. Check the "Run Logs" tab
4. Verify that services show as "CrashLoopBackOff" with danger color
5. Verify restart_count increments
6. Check that healthy-service shows as "Running" with success color
