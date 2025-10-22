# 🎯 Quick Summary

## The Problem
Your frontend shows services as "Running" (green ●) even when they're in CrashLoopBackOff state.

## Root Cause
The Go code in `get_pods.go` only returns pod-level phase ("Running") but loses the container-level waiting reason ("CrashLoopBackOff").

## Test This Instantly

```bash
# Option 1: Kubernetes (most realistic)
./test-local-k8s.sh

# Option 2: Docker Compose (quickest)
docker-compose up

# Option 3: Deploy to Shipyard
# Push this repo and create an app
```

## Expected Results

You should see:
- Pods showing phase="Running" in API (current bug)
- But kubectl shows CrashLoopBackOff
- Restart count incrementing (0, 1, 2, 3...)
- Ready containers = 0

## The Fix

1. Add `waiting_reason` field to proto
2. Extract it in Go code
3. Use it in Python to determine real phase
4. Frontend shows correct status

See [VISUAL_COMPARISON.md](VISUAL_COMPARISON.md) for detailed flow diagrams.

## Files

- `docker-compose.yml` - Simple crash test
- `docker-compose-realistic.yml` - Mimics your exact setup
- `test-local-k8s.sh` - One-command k8s test
- `TESTING_GUIDE.md` - Full testing instructions
- `VISUAL_COMPARISON.md` - Before/after comparison

## Quick Links to Code

**The Bug:**
- [get_pods.go:44](https://github.com/shipyardbuild/shipyard/blob/main/nautilus/internal/coordinator/applicationbuild/get_pods.go#L44) - Only extracts pod.Phase
- [pods.py:48](https://github.com/shipyardbuild/shipyard/blob/main/shipyard/shipyard/services/pods.py#L48) - Uses pod.phase directly

**The Fix Needed:**
- [pods.proto:16](https://github.com/shipyardbuild/shipyard/blob/main/protos/definitions/daemon/coordinator/v1/pods.proto#L16) - Add waiting_reason field
- [get_pods.go:48](https://github.com/shipyardbuild/shipyard/blob/main/nautilus/internal/coordinator/applicationbuild/get_pods.go#L48) - Extract waiting reason
- [pods.py:60](https://github.com/shipyardbuild/shipyard/blob/main/shipyard/shipyard/services/pods.py#L60) - Check waiting reason

---

**TL;DR:** Run `./test-local-k8s.sh` to see the bug in action!
