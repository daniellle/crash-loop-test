#!/bin/bash
# Quick test script for reproducing CrashLoopBackOff in local k8s

set -e

NAMESPACE="crash-loop-test"
DEPLOYMENT_NAME="crash-web"

echo "🧪 Testing CrashLoopBackOff Detection"
echo "======================================"
echo ""

# Create namespace
echo "1️⃣  Creating namespace: $NAMESPACE"
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Create crashing deployment
echo "2️⃣  Creating crashing deployment..."
kubectl create deployment $DEPLOYMENT_NAME -n $NAMESPACE \
  --image=python:3.10-slim \
  --dry-run=client -o yaml | \
  kubectl apply -f -

# Patch the deployment to actually crash
kubectl patch deployment $DEPLOYMENT_NAME -n $NAMESPACE --type=json -p='[
  {
    "op": "replace",
    "path": "/spec/template/spec/containers/0/command",
    "value": ["sh", "-c", "echo ERROR: column org.jfrog_api_key does not exist && exit 1"]
  },
  {
    "op": "add",
    "path": "/spec/template/metadata/labels/app",
    "value": "generic-app"
  }
]'

echo ""
echo "3️⃣  Waiting for pod to crash (15 seconds)..."
sleep 15

# Get pod name
POD_NAME=$(kubectl get pods -n $NAMESPACE -l app=$DEPLOYMENT_NAME -o jsonpath='{.items[0].metadata.name}')

echo ""
echo "4️⃣  Pod Status Analysis:"
echo "   Pod Name: $POD_NAME"
echo ""

# Show the misleading pod phase
POD_PHASE=$(kubectl get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.status.phase}')
echo "   📊 Pod Phase (what GetApplicationBuildPods returns):"
echo "      Phase: $POD_PHASE"
echo "      ⚠️  This shows 'Running' even though container is crashing!"
echo ""

# Show the actual container state
echo "   📊 Container State (the real status):"
kubectl get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.status.containerStatuses[0].state}' | jq
echo ""

# Show restart count
RESTART_COUNT=$(kubectl get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.status.containerStatuses[0].restartCount}')
echo "   🔄 Restart Count: $RESTART_COUNT"
echo ""

# Show ready status
READY=$(kubectl get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.status.containerStatuses[0].ready}')
echo "   ✅ Ready Status: $READY"
echo ""

# Test the current behavior (simulating what Python code does)
echo "5️⃣  Simulating Current Python Code Behavior:"
echo "   This is what ApplicationBuildPods.get_pods() currently returns:"
echo ""
echo "   {"
echo "     \"name\": \"$DEPLOYMENT_NAME\","
echo "     \"phase\": \"$POD_PHASE\","
echo "     \"phase_color\": \"success\","
echo "     \"n_ready\": 0,"
echo "     \"n_total\": 1,"
echo "     \"restart_count\": $RESTART_COUNT"
echo "   }"
echo ""
echo "   ❌ PROBLEM: phase shows '$POD_PHASE' with 'success' color!"
echo ""

# Show what it should be
echo "6️⃣  Expected Behavior After Fix:"
echo "   {"
echo "     \"name\": \"$DEPLOYMENT_NAME\","
echo "     \"phase\": \"CrashLoopBackOff\","
echo "     \"phase_color\": \"danger\","
echo "     \"n_ready\": 0,"
echo "     \"n_total\": 1,"
echo "     \"restart_count\": $RESTART_COUNT"
echo "   }"
echo ""

# Show full pod description
echo "7️⃣  Full Pod Description (for debugging):"
echo "   Run this command for details:"
echo "   kubectl describe pod $POD_NAME -n $NAMESPACE"
echo ""

# Show how to watch it
echo "8️⃣  Watch the pod crash in real-time:"
echo "   kubectl get pods -n $NAMESPACE -w"
echo ""

echo "✅ Test environment created!"
echo ""
echo "Cleanup with:"
echo "   kubectl delete namespace $NAMESPACE"
