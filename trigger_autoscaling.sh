#!/bin/bash
# Exit on error
set -e

# --- CONFIGURATION ---
# Change these variables to match your environment
MOODLE_URL="https://your-moodle-domain.com"
TEST_USER="moodleadmin"     # Or create a dedicated test student account
TEST_PASS="TempPassword123!"
CONCURRENT_USERS=50         # 50 concurrent active threads (generates heavy load)
DURATION_MINUTES=5          # EB Autoscaling usually requires 5 mins of sustained >70% CPU

echo "=========================================================="
echo " Preparing CloudShell for Moodle Load Testing"
echo "=========================================================="

# 1. Install required Python package
echo "Installing 'requests' module..."
pip3 install requests --user -q

# 2. Launch the Python Load Tester in the background
echo "Launching Python Load Tester with $CONCURRENT_USERS concurrent threads..."
python3 moodle_load_tester.py "$MOODLE_URL" "$TEST_USER" "$TEST_PASS" "$CONCURRENT_USERS" &
LOAD_PID=$!

echo "Load test is running (PID: $LOAD_PID)."
echo "AWS Auto Scaling requires sustained CPU usage to trigger an alarm."
echo "Waiting for $DURATION_MINUTES minutes to trigger the scale-out event..."

# 3. Wait for the duration to maintain sustained load
sleep $((DURATION_MINUTES * 60))

# 4. Cleanup
echo "Time limit reached. Terminating load test..."
kill $LOAD_PID
echo "Load test complete."
