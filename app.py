"""
Flask app that simulates the jfrog_api_key column error
This mimics the exact error you're seeing in production
"""
from flask import Flask, jsonify
import sys
import time

app = Flask(__name__)

@app.route('/health')
def health():
    return jsonify({"status": "unhealthy"}), 500

@app.route('/')
def index():
    # Simulate the database query that fails
    print("ERROR:  column org.jfrog_api_key does not exist at character 2670", file=sys.stderr)
    print("STATEMENT:  SELECT count(*) AS count_1 FROM org", file=sys.stderr)
    print("psycopg2.errors.UndefinedColumn: column org.jfrog_api_key does not exist", file=sys.stderr)

    # Exit with error code to trigger crash loop
    sys.exit(1)

if __name__ == '__main__':
    # Wait a tiny bit to simulate startup
    time.sleep(2)

    # Print startup messages like gunicorn
    print("[INFO] Starting gunicorn 20.1.0")
    print("[INFO] Listening at: http://0.0.0.0:8080")
    print("[INFO] Using worker: gevent")
    print("[INFO] Booting worker with pid: 1")

    # Simulate the crash
    print("\nAttempting to query database...", file=sys.stderr)
    print("ERROR:  column org.jfrog_api_key does not exist at character 2670", file=sys.stderr)
    print("LINE 2: ...buildkit_cache_clear_latest_status, org.jfrog_...", file=sys.stderr)
    print("                                                             ^", file=sys.stderr)
    sys.exit(1)
