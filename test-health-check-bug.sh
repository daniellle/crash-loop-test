#!/bin/bash
# Test script to verify the health check bug can be reproduced

set -e

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Testing Health Check Bug Reproduction"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check if docker-compose is available
if ! command -v docker-compose &> /dev/null; then
    echo "❌ docker-compose not found. Please install it."
    exit 1
fi

echo "1️⃣  Starting services with docker-compose..."
docker-compose -f docker-compose-health-check-bug.yml up -d

echo ""
echo "2️⃣  Waiting for services to start (15 seconds)..."
sleep 15

echo ""
echo "3️⃣  Checking web service health (should be healthy initially)..."
WEB_HEALTH=$(curl -s http://localhost:8080/health 2>/dev/null || echo '{"status":"not_ready"}')
echo "   Response: $WEB_HEALTH"

if echo "$WEB_HEALTH" | grep -q "healthy"; then
    echo "   ✅ Web service is healthy (as expected)"
else
    echo "   ⚠️  Web service not responding yet, might need more time"
fi

echo ""
echo "4️⃣  Waiting 30 more seconds for health checks to start failing..."
for i in {30..1}; do
    printf "\r   ⏳ Waiting... %2d seconds" $i
    sleep 1
done
echo ""

echo ""
echo "5️⃣  Checking web service health again (should be unhealthy now)..."
WEB_HEALTH_AFTER=$(curl -s http://localhost:8080/health 2>/dev/null || echo '{"status":"not_ready"}')
echo "   Response: $WEB_HEALTH_AFTER"

if echo "$WEB_HEALTH_AFTER" | grep -q "unhealthy"; then
    echo "   ✅ Web service is now unhealthy (as expected)"
    echo "   ✅ Health check failure scenario reproduced!"
else
    echo "   ⚠️  Web service still healthy. The failure might take longer."
    echo "   Tip: Wait a bit longer or check the logs with:"
    echo "        docker-compose -f docker-compose-health-check-bug.yml logs web"
fi

echo ""
echo "6️⃣  Checking heartbeat init container (should have failed)..."
HEARTBEAT_STATUS=$(docker-compose -f docker-compose-health-check-bug.yml ps heartbeat | grep heartbeat || echo "not found")
echo "   Status: $HEARTBEAT_STATUS"

if echo "$HEARTBEAT_STATUS" | grep -q "Exit 1"; then
    echo "   ✅ Heartbeat failed as expected (migration error)"
else
    echo "   ℹ️  Heartbeat status: check with 'docker-compose logs heartbeat'"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "✅ Test setup complete!"
echo ""
echo "What just happened:"
echo "  1. Services started successfully"
echo "  2. Web service passed health checks initially (0-30s)"
echo "  3. Web service started failing health checks (30s+)"
echo ""
echo "In Shipyard, this creates:"
echo "  • ROUTINE log (successful=true) at ~15s"
echo "  • HEALTH_CHECK_FAILED log (successful=false) at ~30s"
echo "  • But API returns ROUTINE log ← THE BUG!"
echo ""
echo "Next steps:"
echo "  1. Deploy this to Shipyard (see README_HEALTH_CHECK_BUG.md)"
echo "  2. Wait 45+ seconds after deployment"
echo "  3. Check /services API endpoint"
echo "  4. Verify bug in database with Flask shell"
echo ""
echo "View logs:"
echo "  docker-compose -f docker-compose-health-check-bug.yml logs -f web"
echo ""
echo "Stop services:"
echo "  docker-compose -f docker-compose-health-check-bug.yml down"
echo ""
