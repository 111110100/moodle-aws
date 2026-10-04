import requests
import re
import time
import threading
import sys
import urllib3

# Suppress insecure request warnings if testing without a valid SSL cert
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Configuration from command line args
if len(sys.argv) < 5:
    print("Usage: python3 moodle_load_tester.py <URL> <USERNAME> <PASSWORD> <THREADS>")
    sys.exit(1)

TARGET_URL = sys.argv[1].rstrip('/')
USERNAME = sys.argv[2]
PASSWORD = sys.argv[3]
THREADS = int(sys.argv[4])
STOP_EVENT = threading.Event()

def simulate_user_journey(thread_id):
    session = requests.Session()
    session.verify = False # Ignore SSL errors in testing

    while not STOP_EVENT.is_set():
        try:
            # 1. Access Login Page to grab CSRF 'logintoken'
            login_page = session.get(f"{TARGET_URL}/login/index.php", timeout=10)
            token_match = re.search(r'name="logintoken"\s+value="([^"]+)"', login_page.text)

            if token_match:
                logintoken = token_match.group(1)

                # 2. Perform Login
                payload = {
                    'username': USERNAME,
                    'password': PASSWORD,
                    'logintoken': logintoken
                }
                session.post(f"{TARGET_URL}/login/index.php", data=payload, timeout=10)

            # 3. Hammer CPU-intensive pages (Dashboard & DB Search)
            # We loop this to maintain sustained CPU pressure
            for _ in range(5):
                if STOP_EVENT.is_set():
                    break
                session.get(f"{TARGET_URL}/my/", timeout=10)
                session.get(f"{TARGET_URL}/course/search.php?search=simulation", timeout=10)

        except Exception as e:
            # Silently catch timeouts/errors to keep the load test running aggressively
            pass

def start_load_test():
    print(f"Starting Moodle Load Test against {TARGET_URL}")
    print(f"Simulating {THREADS} concurrent users. Press Ctrl+C to stop.")

    threads = []
    for i in range(THREADS):
        t = threading.Thread(target=simulate_user_journey, args=(i,))
        t.daemon = True
        t.start()
        threads.append(t)

    try:
        # Keep main thread alive to catch KeyboardInterrupt
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\nStopping load test... waiting for threads to close.")
        STOP_EVENT.set()
        for t in threads:
            t.join()
        print("Load test terminated.")

if __name__ == "__main__":
    start_load_test()
