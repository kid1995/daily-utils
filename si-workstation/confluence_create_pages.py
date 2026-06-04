#!/usr/bin/env python3
"""
confluence_create_pages.py
--------------------------
Creates a Confluence page hierarchy via the REST API.

This script shows the core pattern for:
  1. Authenticating with a Bearer token (no username/password needed)
  2. Creating a parent page, then child pages using 'ancestors'
  3. Writing Confluence Storage Format (HTML-like) as page body
  4. Skipping SSL verification for internal SI hosts (-k equivalent)

Prerequisites on the workstation:
  source ~/.bashrc.d/atlassian.sh   # provides CONFLUENCE_URL
  source ~/.credentials             # provides CONFLUENCE_PERSONAL_TOKEN

Usage:
  python3 confluence_create_pages.py
"""

import json
import os
import ssl
import urllib.request
import urllib.error

# ─── Config ──────────────────────────────────────────────────────────────────

BASE  = os.environ["CONFLUENCE_URL"].rstrip("/")
TOKEN = os.environ["CONFLUENCE_PERSONAL_TOKEN"]
SPACE = "~u167653"   # Personal space key — change to e.g. "CDC" for a team space

# ─── HTTP helper ─────────────────────────────────────────────────────────────

# SSL context that skips certificate verification.
# Required because the SI internal CA is not in Ubuntu's default trust store.
# Safe to use here because traffic never leaves the corporate network.
_SSL_CTX = ssl.create_default_context()
_SSL_CTX.check_hostname = False
_SSL_CTX.verify_mode = ssl.CERT_NONE


def _request(method: str, path: str, body: dict | None = None) -> dict | None:
    """Make an authenticated JSON request to the Confluence REST API."""
    url = f"{BASE}{path}"
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, context=_SSL_CTX) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        print(f"  ✗ HTTP {e.code}: {e.read().decode()[:300]}")
        return None


# ─── Page helpers ────────────────────────────────────────────────────────────

def create_page(title: str, body_html: str, parent_id: str | None = None) -> str | None:
    """
    Create a Confluence page and return its ID.

    Parameters
    ----------
    title      : Page title (must be unique within the space)
    body_html  : Confluence Storage Format — basically HTML with special macros
    parent_id  : ID of the parent page. None = top-level page in the space.
    """
    payload = {
        "type": "page",
        "title": title,
        "space": {"key": SPACE},
        "body": {
            "storage": {
                "value": body_html,
                "representation": "storage",   # 'storage' = raw Confluence XML
            }
        },
    }
    if parent_id:
        # 'ancestors' list makes this page a child of parent_id
        payload["ancestors"] = [{"id": parent_id}]

    result = _request("POST", "/rest/api/content", payload)
    if result:
        page_id = result["id"]
        print(f"  ✅ [{page_id}] {title}")
        return page_id
    return None


def get_page_id(title: str) -> str | None:
    """Look up an existing page by title in the configured space."""
    from urllib.parse import quote
    result = _request(
        "GET",
        f"/rest/api/content?spaceKey={SPACE}&title={quote(title)}&type=page",
    )
    items = result.get("results", []) if result else []
    return items[0]["id"] if items else None


def update_page(page_id: str, title: str, body_html: str, new_version: int) -> bool:
    """
    Update an existing page.
    Confluence requires the version number to be incremented on each update.
    """
    payload = {
        "version": {"number": new_version},
        "title": title,
        "type": "page",
        "body": {
            "storage": {
                "value": body_html,
                "representation": "storage",
            }
        },
    }
    result = _request("PUT", f"/rest/api/content/{page_id}", payload)
    return result is not None


# ─── Confluence Storage Format (CSF) tips ────────────────────────────────────
#
# CSF is mostly HTML but has special Confluence macros:
#
#   Code block:
#   <ac:structured-macro ac:name="code">
#     <ac:parameter ac:name="language">python</ac:parameter>
#     <ac:plain-text-body><![CDATA[your code here]]></ac:plain-text-body>
#   </ac:structured-macro>
#
#   Note / Warning / Info panels:
#   <ac:structured-macro ac:name="note">   <!-- or "warning" / "info" / "tip" -->
#     <ac:rich-text-body><p>Text here</p></ac:rich-text-body>
#   </ac:structured-macro>
#
#   Table of contents:
#   <ac:structured-macro ac:name="toc"/>
#
#   Standard HTML (h1-h6, p, ul, ol, table, strong, em, code) works normally.
#   HTML entities like &auml; &ouml; &uuml; work too.
#
# ─────────────────────────────────────────────────────────────────────────────


# ─── Example page content ────────────────────────────────────────────────────

PARENT_BODY = """
<p>This is the <strong>parent page</strong> — replace this content with your own.</p>
<ac:structured-macro ac:name="toc"/>
<h2>About</h2>
<p>Created programmatically via the Confluence REST API.</p>
"""

CHILD_BODY = """
<h1>Child Page</h1>
<p>This page was created as a child of the parent via the <code>ancestors</code> field in the API payload.</p>
<ac:structured-macro ac:name="code">
  <ac:parameter ac:name="language">python</ac:parameter>
  <ac:plain-text-body><![CDATA[print("Hello from Confluence!")]]></ac:plain-text-body>
</ac:structured-macro>
<ac:structured-macro ac:name="note">
  <ac:rich-text-body><p>Use <code>CONFLUENCE_PERSONAL_TOKEN</code> — never hardcode credentials.</p></ac:rich-text-body>
</ac:structured-macro>
"""


# ─── Main ────────────────────────────────────────────────────────────────────

def main() -> None:
    print(f"Creating pages in space '{SPACE}'...")
    print()

    parent_id = create_page("Example Parent Page", PARENT_BODY)
    if not parent_id:
        raise SystemExit("Failed to create parent page — check credentials and space key.")

    child_id = create_page("Example Child Page", CHILD_BODY, parent_id)

    print()
    print("Done!")
    print(f"  Parent: {BASE}/pages/viewpage.action?pageId={parent_id}")
    if child_id:
        print(f"  Child:  {BASE}/pages/viewpage.action?pageId={child_id}")


if __name__ == "__main__":
    main()
