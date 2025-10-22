#!/bin/bash
# Compare /services vs /pods endpoints to see the difference

APP_BUILD_ID="${1:-c871af4a-5157-4812-ade6-877f5c9b1654}"
BASE_URL="${2:-http://localhost:8080}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Comparing /services vs /pods Endpoints"
echo "  App Build ID: $APP_BUILD_ID"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "1️⃣  /services Endpoint (Historical Data)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
curl -s "$BASE_URL/api/application-build/$APP_BUILD_ID/services" 2>/dev/null | \
  python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for project_id, services in data.items():
        print(f'\nProject: {project_id[:8]}...')
        for svc in services:
            name = svc.get('name', 'unknown')
            has_crash = 'crash_log' in svc and svc['crash_log']
            has_run = 'run_log' in svc and svc['run_log']
            print(f'  {name}:')
            if has_crash:
                print(f'    ✓ Has crash_log (log_reason: {svc[\"crash_log\"].get(\"log_reason\")})')
            if has_run:
                print(f'    ✓ Has run_log')
            if not has_crash and not has_run:
                print(f'    - No crash/run logs')
except Exception as e:
    print(f'Error parsing: {e}')
" || echo "Failed to fetch /services"

echo ""
echo ""
echo "2️⃣  /pods Endpoint (Real-time Kubernetes Status)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
PODS_DATA=$(curl -s "$BASE_URL/api/application-build/$APP_BUILD_ID/pods" 2>/dev/null)

if [ -z "$PODS_DATA" ] || [ "$PODS_DATA" == "[]" ]; then
    echo "⚠️  No pod data returned (might need authentication or pods not running)"
    echo ""
    echo "Try with authentication:"
    echo "  curl -H 'Cookie: session=<your-session>' $BASE_URL/api/application-build/$APP_BUILD_ID/pods"
else
    echo "$PODS_DATA" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if not data:
        print('  No pods found')
    else:
        for pod in data:
            name = pod.get('name', 'unknown')
            phase = pod.get('phase', 'unknown')
            phase_color = pod.get('phase_color', 'unknown')
            n_ready = pod.get('n_ready', '?')
            n_total = pod.get('n_total', '?')
            restart_count = pod.get('restart_count', '?')

            color_emoji = {
                'success': '🟢',
                'danger': '🔴',
                'warning': '🟡',
                'info': '🔵'
            }.get(phase_color, '⚪')

            print(f'  {name}:')
            print(f'    Phase: {phase} {color_emoji}')
            print(f'    Phase Color: {phase_color}')
            print(f'    Ready: {n_ready}/{n_total}')
            print(f'    Restarts: {restart_count}')
            print('')
except Exception as e:
    print(f'Error parsing: {e}')
"
fi

echo ""
echo "3️⃣  Kubernetes Truth (via kubectl)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

NS="shipyard-app-build-$APP_BUILD_ID"

if kubectl get namespace "$NS" >/dev/null 2>&1; then
    echo "Namespace: $NS"
    echo ""
    kubectl get pods -n "$NS" 2>/dev/null | head -10 || echo "No pods found"

    echo ""
    echo "Detailed status of crashing pods:"
    echo ""

    kubectl get pods -n "$NS" -o json 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for pod in data.get('items', []):
        name = pod['metadata']['name']
        phase = pod['status']['phase']

        for container in pod['status'].get('containerStatuses', []):
            state = container.get('state', {})
            restart_count = container.get('restartCount', 0)
            ready = container.get('ready', False)

            # Check for crash loop
            if 'waiting' in state and state['waiting'].get('reason') == 'CrashLoopBackOff':
                print(f'  🔴 {name}')
                print(f'     Pod Phase: {phase} ← What /pods API uses')
                print(f'     Container State: CrashLoopBackOff ← THE TRUTH!')
                print(f'     Restart Count: {restart_count}')
                print(f'     Ready: {ready}')
                print('')
                print(f'     ❌ BUG: API shows phase=\"{phase}\" with color=\"success\"')
                print(f'     ✅ FIX: Should show phase=\"CrashLoopBackOff\" with color=\"danger\"')
                print('')
except Exception as e:
    print(f'Error: {e}')
"
else
    echo "⚠️  Namespace not found: $NS"
    echo ""
    echo "Available app-build namespaces:"
    kubectl get namespaces 2>/dev/null | grep "shipyard-app-build" | head -5
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "• /services endpoint shows historical crash logs ✅"
echo "• /pods endpoint shows phase='Running' with 'success' color ❌"
echo "• kubectl shows actual CrashLoopBackOff status ✅"
echo ""
echo "The bug: /pods doesn't check container waiting reason!"
echo ""
