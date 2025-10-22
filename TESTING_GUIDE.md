# Testing Guide: CrashLoopBackOff Detection

This guide shows you how to reproduce and test the CrashLoopBackOff issue in various environments.

## Quick Start - 3 Ways to Test

### Method 1: Local Docker Compose (Quickest)

```bash
cd /Users/daniellepinheiro/crash-loop-test

# Simple version - multiple failing services
docker-compose up

# Realistic version - mimics your exact setup
docker-compose -f docker-compose-realistic.yml up --build
```

**What to observe:**
```bash
# Watch containers crash and restart
docker-compose ps

# You'll see:
# web    Exit 1 (restarting)
# web    Exit 1 (restarting)
# web    Exit 1 (restarting)
```

### Method 2: Deploy to Your Local Kubernetes (org-cluster)

This is the MOST REALISTIC test since it uses the same k3s setup as your docker-compose.yml.

```bash
cd /Users/daniellepinheiro/crash-loop-test

# Create namespace
kubectl create namespace crash-loop-test

# Create deployment
kubectl create deployment crash-web -n crash-loop-test \
  --image=python:3.10-slim \
  -- sh -c "echo 'ERROR: column org.jfrog_api_key does not exist' && exit 1"

# Watch it crash loop
kubectl get pods -n crash-loop-test -w

# You'll see:
# crash-web-xxxx-xxxx   0/1   CrashLoopBackOff   0   10s
# crash-web-xxxx-xxxx   0/1   CrashLoopBackOff   1   20s
# crash-web-xxxx-xxxx   0/1   CrashLoopBackOff   2   40s
```

**Verify the bug:**
```bash
# Get pod details
POD=$(kubectl get pods -n crash-loop-test -o name | head -1)

# Check pod phase (will show "Running" even though it's crashing!)
kubectl get $POD -n crash-loop-test -o jsonpath='{.status.phase}'
# Output: Running

# Check container state (this shows the real status)
kubectl get $POD -n crash-loop-test -o jsonpath='{.status.containerStatuses[0].state}'
# Output: {"waiting":{"message":"back-off 5m0s restarting failed container...","reason":"CrashLoopBackOff"}}
```

### Method 3: Deploy as Shipyard Application (Full Integration Test)

```bash
# 1. Push this repo to GitHub
cd /Users/daniellepinheiro/crash-loop-test
git add .
git commit -m "Add crash loop test"
git remote add origin <your-github-url>
git push -u origin main

# 2. In Shipyard UI:
#    - Create new application
#    - Point to this repo
#    - Use docker-compose-realistic.yml
#    - Deploy

# 3. Navigate to build details page
#    - Go to "Run Logs" tab
#    - Click on "web" service
#    - You should see the error logs

# 4. Check the API response (this is what FE receives)
curl http://localhost:8080/api/application-build/<app-build-id>/pods
```

## Testing the API Directly

If you want to test the exact API endpoint:

```bash
# 1. Start your Shipyard web service
cd /Users/daniellepinheiro/shipyard-code/shipyard
make start

# 2. Create an application with the crash-loop-test repo

# 3. Get the application build ID from the UI or database

# 4. Call the pods API
APP_BUILD_ID="<your-app-build-id>"
curl -X GET \
  "http://localhost:8080/api/application-build/${APP_BUILD_ID}/pods" \
  -H "Authorization: Bearer <your-token>" \
  | jq

# Current (broken) response:
# {
#   "pods": [
#     {
#       "name": "web",
#       "phase": "Running",          ← WRONG
#       "phase_color": "success",    ← WRONG
#       "n_ready": 0,                ← Correct
#       "restart_count": 5           ← Correct
#     }
#   ]
# }

# Expected (fixed) response:
# {
#   "pods": [
#     {
#       "name": "web",
#       "phase": "CrashLoopBackOff", ← Correct
#       "phase_color": "danger",     ← Correct
#       "n_ready": 0,
#       "restart_count": 5
#     }
#   ]
# }
```

## Debugging Tips

### Check Kubernetes Pod Details

```bash
# Get all info about a pod
kubectl describe pod <pod-name> -n <namespace>

# Look for these sections:
# - Status: Running (misleading!)
# - Containers > State > Waiting > Reason: CrashLoopBackOff (actual state!)
# - Restart Count: (increments each crash)
```

### Check Nautilus Logs

```bash
# If testing with Shipyard deployment
kubectl logs -n shipyard-system deploy/nautilus -f

# Look for GetApplicationBuildPods calls
```

### Check Web Service Logs

```bash
# See what the web service receives
docker-compose -f /Users/daniellepinheiro/shipyard-code/shipyard/docker-compose.yml logs -f web

# Or if deployed to k8s
kubectl logs -n shipyard deploy/web -f
```

### Simulate the Exact Error Scenario

```bash
# Create a pod that mimics your database migration issue
kubectl run test-crash -n crash-loop-test \
  --image=python:3.10-slim \
  --restart=Always \
  --labels="app=generic-app" \
  -- python -c "
import sys
print('[INFO] Starting gunicorn 20.1.0')
print('[INFO] Listening at: http://0.0.0.0:8080')
print('ERROR: column org.jfrog_api_key does not exist at character 2670', file=sys.stderr)
sys.exit(1)
"

# Watch it crash
kubectl get pods -n crash-loop-test -w
```

## What Success Looks Like

After implementing the fix, you should see:

1. **Frontend Display:**
   - Service shows red/danger indicator
   - Phase shows "CrashLoopBackOff"
   - Restart count increments visibly
   - Clear error messaging

2. **API Response:**
   - `phase: "CrashLoopBackOff"`
   - `phase_color: "danger"`
   - `n_ready: 0`
   - `restart_count: > 0`

3. **User Experience:**
   - User immediately knows service is failing
   - Can see crash logs
   - Gets notification/alert about the failure

## Cleanup

```bash
# Remove local docker resources
docker-compose down -v
docker-compose -f docker-compose-realistic.yml down -v

# Remove k8s resources
kubectl delete namespace crash-loop-test

# Remove Shipyard application
# (via UI or API)
```

## Pro Tips

1. **Set low restart backoff** to speed up testing:
   ```yaml
   # Add to docker-compose.yml
   restart_policy:
     condition: on-failure
     delay: 5s
     max_attempts: 10
   ```

2. **Use kubectl events** to see crash details:
   ```bash
   kubectl get events -n crash-loop-test --sort-by='.lastTimestamp'
   ```

3. **Monitor restart counts**:
   ```bash
   watch -n 2 'kubectl get pods -n crash-loop-test'
   ```

4. **Test with real database** to be extra realistic:
   - Start postgres with old schema
   - Try to query new column
   - Watch it crash naturally
