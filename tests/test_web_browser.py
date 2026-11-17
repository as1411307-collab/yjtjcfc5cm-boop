import os
import shutil
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

import pytest

pytestmark = pytest.mark.skipif(
    os.getenv("RUN_BROWSER_TESTS") != "1",
    reason="Set RUN_BROWSER_TESTS=1 after installing Chromium to run the real browser test",
)


def wait_for_health(port: int):
    for _ in range(80):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=1) as response:
                if response.status == 200:
                    return
        except Exception:
            time.sleep(0.15)
    raise RuntimeError("Core did not start for the browser test")


def test_web_ui_executes_javascript_and_creates_session(tmp_path):
    sync_playwright = pytest.importorskip("playwright.sync_api").sync_playwright
    root = Path(__file__).resolve().parents[1]
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    key = "browser-test-key-with-more-than-24-characters"
    env = os.environ.copy()
    env.update({"AI_API_KEY": key, "DB_PATH": str(tmp_path / "browser.sqlite3")})
    process = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "core.app:app", "--host", "127.0.0.1", "--port", str(port)],
        cwd=root,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        wait_for_health(port)
        with sync_playwright() as playwright:
            options = {"headless": True, "args": ["--no-sandbox"]}
            chromium = os.getenv("CHROMIUM_PATH") or shutil.which("chromium")
            if chromium:
                options["executable_path"] = chromium
            browser = playwright.chromium.launch(**options)
            page = browser.new_page()
            errors = []
            page.on("console", lambda message: errors.append(message.text) if message.type == "error" else None)
            page.goto(f"http://127.0.0.1:{port}/", wait_until="networkidle")
            assert page.evaluate("typeof el") == "function"
            page.fill("#key", key)
            page.click("#start")
            deadline = time.time() + 10
            while True:
                session_text = page.locator("#session").inner_text()
                if "الجلسة:" in session_text:
                    break
                if time.time() >= deadline:
                    raise AssertionError("لم تُنشأ الجلسة من واجهة المتصفح")
                time.sleep(0.1)
            assert "لا توجد جلسة" not in page.locator("#session").inner_text()
            assert not any("Executing inline script violates" in error for error in errors)
            assert not any("Applying inline style violates" in error for error in errors)
            page.uncheck("#context")
            def reply(route):
                assert route.request.post_data_json["include_context"] is False
                route.fulfill(json={"answer": "رد تجريبي"})
            page.route("**/chat", reply)
            page.fill("#prompt", "اختبار")
            page.click("#send")
            page.get_by_text("المساعد: رد تجريبي").wait_for()
            page.fill("#key", "different-test-account")
            assert page.locator("#messages").inner_text() == ""
            assert page.locator("#session").inner_text() == "لا توجد جلسة"
            browser.close()
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
