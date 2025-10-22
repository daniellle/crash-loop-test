# 🎯 START HERE - Bug Reproduction

## What We Built

A complete test environment to reproduce the bug where `run_log` shows `successful: true` even when health checks are failing.

## Quick Start (Choose One)

### Option A: Full Test (Recommended)
**Reproduces the actual bug in Shipyard**

1. Push to GitHub:
   ```bash
   git remote add origin https://github.com/YOUR_USERNAME/crash-loop-test.git
   git push -u origin main
   ```

2. Deploy in Shipyard UI:
   - Create new application
   - Point to this repo
   - **Use: `docker-compose-health-check-bug.yml`**
   - Deploy and wait 60 seconds

3. Verify bug:
   ```bash
   # Read: COMPLETE_BUG_REPRODUCTION_GUIDE.md
   # Sections: Step 4 (API check) and Step 5 (database check)
   ```

### Option B: Local Test
**Tests timing only, not the actual bug**

```bash
./test-health-check-bug.sh
```

## The Bug

**What happens:**
1. Service starts → Creates ROUTINE log (successful=true) ✅
2. Health check fails → Creates HEALTH_CHECK_FAILED log (successful=false) ❌
3. API returns ROUTINE log instead of HEALTH_CHECK_FAILED ← **BUG!**

**What should happen:**
- API should return HEALTH_CHECK_FAILED log (successful=false)

## Files Guide

| File | Purpose |
|------|---------|
| **COMPLETE_BUG_REPRODUCTION_GUIDE.md** | 📖 Full step-by-step guide |
| docker-compose-health-check-bug.yml | 🐳 Test compose file |
| test-health-check-bug.sh | 🧪 Local test script |
| README_HEALTH_CHECK_BUG.md | 📚 Detailed explanation |

## The Fix (Already Applied)

**File:** `../shipyard/shipyard/models/build.py` lines 4646-4672

**Change:** Check for HEALTH_CHECK_FAILED logs BEFORE ROUTINE logs

```python
# OLD: Returns ROUTINE log first (buggy)
# NEW: Returns HEALTH_CHECK_FAILED log first (fixed)
```

## Next Steps

1. ✅ Read: [COMPLETE_BUG_REPRODUCTION_GUIDE.md](COMPLETE_BUG_REPRODUCTION_GUIDE.md)
2. ✅ Deploy to Shipyard
3. ✅ Verify bug in API and database
4. ✅ Restart Shipyard web service (fix is already applied)
5. ✅ Redeploy and verify fix works

## Need Help?

- Can't reproduce? → Check "Troubleshooting" in COMPLETE_BUG_REPRODUCTION_GUIDE.md
- Timing issues? → Decrease `FAIL_AFTER_SECONDS` in compose file
- Database questions? → Use Flask shell queries in the guide

## Summary

✅ Created: Complete reproduction environment
✅ Applied: Fix to build.py
✅ Ready: Deploy and verify!

**Estimated time to reproduce:** 5 minutes (deploy) + 1 minute (wait) + 2 minutes (verify) = ~8 minutes
