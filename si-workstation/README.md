# si-workstation

Scripts for querying and automating SI-internal systems from the GCloud Workstation.

All scripts run **on the GCloud Workstation** (`si-kiet-dang-2-ini-393`), not on the local Mac. Access is via SSH tunnel on port 2222.

## Prerequisites

```bash
# On the workstation — credentials must be set
source ~/.bashrc.d/atlassian.sh   # JIRA_URL, CONFLUENCE_URL, BITBUCKET_URL
source ~/.credentials             # all *_PERSONAL_TOKEN variables
```

## Scripts

### `confluence_create_pages.py` — Create a page hierarchy in Confluence

Demonstrates how to use the Confluence REST API to create parent/child pages programmatically.

**Key patterns:**
- Bearer token auth (no username needed)
- `ancestors` field to create child pages
- Confluence Storage Format (CSF) for page body — HTML + special macros
- SSL verification skipped with a custom `ssl.SSLContext` (equivalent to curl's `-k`)

```bash
source ~/.credentials
python3 confluence_create_pages.py
```

**Useful for:** Generating wiki documentation, creating page templates, bulk page creation.

---

### `jenkins_api.js` — Query Jenkins via Node.js

Demonstrates why **curl fails for Jenkins** (LDAP hang) and how Node.js solves it.

**Key patterns:**
- `NODE_TLS_REJECT_UNAUTHORIZED=0` must be set as a shell env var **before** node starts
- Basic auth with `Buffer.from(user:token).toString('base64')`
- CSRF crumb required for all POST requests (build triggers)
- Timeout handling with `req.on('timeout', ...)`

```bash
source ~/.credentials
NODE_TLS_REJECT_UNAUTHORIZED=0 node jenkins_api.js
```

**Useful for:** Listing build status, fetching build logs, triggering builds programmatically.

---

### `si_query.sh` — Bash helper functions for Jira, Confluence, Bitbucket

Shell functions that wrap the curl-based REST API patterns with Python parsing.

**Key patterns:**
- All curl calls use `-sk` (skip SSL verify — same reason as above)
- JQL URL-encoding via Python `urllib.parse.quote`
- `python3 -c` for inline JSON parsing (no `jq` dependency)
- Confluence: `?expand=body.storage` is **mandatory** to get page content

```bash
source ~/.bashrc.d/atlassian.sh && source ~/.credentials
source si_query.sh

# Examples
jira_get "ELPA4-226"
jira_search "project=ELPA4 AND assignee=currentUser() AND status!=Done"
confluence_search "cosi2" "datastore"
bitbucket_repos "ELPA"
bitbucket_my_prs
```

## Why `-k` everywhere?

The SI corporate CA certificate is not in Ubuntu's default trust store (`/etc/ssl/certs/ca-certificates.crt`). All `.system.local` hosts use TLS signed by that CA, so curl/Node.js rejects them unless you skip verification. This is safe on the internal network.

For curl: use `-k`  
For Node.js: set `NODE_TLS_REJECT_UNAUTHORIZED=0` before starting the process  
For Python `urllib`: create an `ssl.SSLContext` with `check_hostname=False, verify_mode=CERT_NONE`

## Why Node.js for Jenkins?

Jenkins triggers an LDAP lookup to verify credentials. The LDAP server is on a subnet not routed from the workstation. This causes curl to hang indefinitely on any authenticated request. Node.js uses a different TLS path and does not trigger this hang — same runtime as the Jenkins Workbench VS Code extension.
