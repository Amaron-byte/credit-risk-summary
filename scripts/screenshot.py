"""Снимает скриншот дашборда в docs/dashboard.png (headless Chromium через Playwright).

    python3 scripts/screenshot.py [--vega-dir DIR] [--dark]

--vega-dir: папка node_modules с vega/vega-lite/vega-embed — для окружений без доступа к CDN,
запросы к cdn.jsdelivr.net подменяются локальными файлами тех же версий.
"""
import argparse
import functools
import http.server
import re
import threading
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
ap = argparse.ArgumentParser()
ap.add_argument("--vega-dir")
ap.add_argument("--dark", action="store_true")
ap.add_argument("--out", default=str(ROOT / "docs/dashboard.png"))
args = ap.parse_args()

handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(ROOT / "dashboard"))
handler.log_message = lambda *a, **k: None
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{srv.server_port}/index.html"

with sync_playwright() as p:
    b = p.chromium.launch()
    page = b.new_page(viewport={"width": 1320, "height": 900}, device_scale_factor=2,
                      color_scheme="dark" if args.dark else "light")
    errors = []
    page.on("console", lambda m: m.type in ("error", "warning") and errors.append(m.text))
    page.on("pageerror", lambda e: errors.append(str(e)))
    if args.vega_dir:
        nm = Path(args.vega_dir)
        def serve(route):
            m = re.search(r"/npm/(vega(?:-lite|-embed)?)@[^/]+/(.+)$", route.request.url)
            route.fulfill(path=str(nm / m.group(1) / m.group(2)), content_type="application/javascript")
        page.route(re.compile(r"https://cdn\.jsdelivr\.net/npm/.*"), serve)
    page.goto(url)
    page.wait_for_selector("body[data-rendered='1']", timeout=30000)
    page.wait_for_timeout(500)
    print("charts rendered:", page.locator(".vega-embed svg").count())
    if page.locator(".err").count():
        errors.append(page.locator(".err").first.inner_text())
    page.screenshot(path=args.out, full_page=True)
    b.close()
print("saved", args.out)
for e in errors:
    print("PAGE:", e)
