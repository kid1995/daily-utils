#!/usr/bin/env bash
# si_query.sh
# -----------
# Bash helper functions for querying SI-internal systems:
#   Jira, Confluence, Bitbucket
#
# WHY -k ON ALL CURL CALLS?
# All SI-internal hosts use a corporate CA not in Ubuntu's trust store.
# -k skips SSL verification. Safe here — traffic never leaves the corporate network.
#
# PREREQUISITES:
#   source ~/.bashrc.d/atlassian.sh   # JIRA_URL, CONFLUENCE_URL, BITBUCKET_URL
#   source ~/.credentials             # *_PERSONAL_TOKEN variables
#
# USAGE:
#   source si_query.sh
#   jira_get "ELPA4-226"
#   jira_search "project=ELPA4 AND assignee=currentUser() AND status!=Done"
#   confluence_search "cosi2" "datastore"
#   bitbucket_repos "ELPA"

# ─── Jira ────────────────────────────────────────────────────────────────────

# Fetch a single Jira issue by key.
# Only request specific fields — fields=*all returns hundreds of fields and is slow.
jira_get() {
  local key="${1:?Usage: jira_get <ISSUE_KEY>}"
  curl -sk \
    -H "Authorization: Bearer ${JIRA_PERSONAL_TOKEN}" \
    -H "Accept: application/json" \
    "${JIRA_URL%/}/rest/api/2/issue/${key}?fields=summary,status,description,assignee,priority,labels" \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
f = d['fields']
print(f'{d[\"key\"]}  [{f[\"status\"][\"name\"]}]  ({f.get(\"priority\",{}).get(\"name\",\"-\")})')
print(f'Summary: {f[\"summary\"]}')
print(f'Assignee: {(f.get(\"assignee\") or {}).get(\"displayName\", \"unassigned\")}')
"
}

# Search Jira with JQL.
# JQL reference: = != ~ !~ AND OR NOT ORDER BY
# Functions: currentUser() openSprints() now('-7d')
jira_search() {
  local jql="${1:?Usage: jira_search '<JQL>'}"
  local encoded
  encoded=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "${jql}")
  curl -sk \
    -H "Authorization: Bearer ${JIRA_PERSONAL_TOKEN}" \
    -H "Accept: application/json" \
    "${JIRA_URL%/}/rest/api/2/search?jql=${encoded}&fields=summary,status,priority,assignee&maxResults=20" \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(f'Total: {data.get(\"total\",0)} tickets')
for i in data['issues']:
    f = i['fields']
    print(f'  {i[\"key\"]:15} [{f[\"status\"][\"name\"]:20}] {f[\"summary\"]}')
"
}

# Add a comment to a Jira ticket.
jira_comment() {
  local key="${1:?Usage: jira_comment <KEY> <COMMENT>}"
  local comment="${2:?Missing comment text}"
  curl -sk -X POST \
    -H "Authorization: Bearer ${JIRA_PERSONAL_TOKEN}" \
    -H "Content-Type: application/json" \
    "${JIRA_URL%/}/rest/api/2/issue/${key}/comment" \
    -d "{\"body\": \"${comment}\"}" \
  | python3 -c "import json,sys; print('Comment ID:', json.load(sys.stdin).get('id','?'))"
}

# ─── Confluence ───────────────────────────────────────────────────────────────

# Search Confluence pages by space and keyword.
# CQL reference: space="KEY" AND text~"term" AND type=page AND lastModified>="-7d"
confluence_search() {
  local space="${1:?Usage: confluence_search <SPACE_KEY> <TERM>}"
  local term="${2:?Missing search term}"
  local encoded_cql
  encoded_cql=$(python3 -c "
import urllib.parse, sys
cql = 'space=\"' + sys.argv[1] + '\" AND text~\"' + sys.argv[2] + '\"'
print(urllib.parse.quote(cql))
" "${space}" "${term}")
  curl -sk \
    -H "Authorization: Bearer ${CONFLUENCE_PERSONAL_TOKEN}" \
    -H "Accept: application/json" \
    "${CONFLUENCE_URL%/}/rest/api/content/search?cql=${encoded_cql}&limit=10" \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(f'Total: {data.get(\"totalSize\",0)} matches')
for p in data.get('results', []):
    print(f'  [{p[\"id\"]}]  {p[\"title\"]}')
"
}

# Fetch a Confluence page by ID including its body.
# KEY: ?expand=body.storage is MANDATORY to get content — without it you get only metadata.
confluence_get_page() {
  local page_id="${1:?Usage: confluence_get_page <PAGE_ID>}"
  curl -sk \
    -H "Authorization: Bearer ${CONFLUENCE_PERSONAL_TOKEN}" \
    -H "Accept: application/json" \
    "${CONFLUENCE_URL%/}/rest/api/content/${page_id}?expand=body.storage,version" \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('Title:  ', d['title'])
print('Version:', d['version']['number'])
print('Body (first 500 chars):')
print(d['body']['storage']['value'][:500])
"
}

# ─── Bitbucket ───────────────────────────────────────────────────────────────

# List all repos in a Bitbucket project with clone URLs.
bitbucket_repos() {
  local project="${1:?Usage: bitbucket_repos <PROJECT_KEY>}"
  curl -sk \
    -H "Authorization: Bearer ${BITBUCKET_PERSONAL_TOKEN}" \
    -H "Accept: application/json" \
    "${BITBUCKET_URL%/}/rest/api/latest/projects/${project}/repos?limit=50" \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
repos = data.get('values', [])
print(len(repos), 'repos in', sys.argv[1])
for r in sorted(repos, key=lambda x: x['slug']):
    clone = next((c['href'] for c in r['links']['clone'] if c['name']=='http'), '')
    print(f'  {r[\"slug\"]:45} {clone}')
" "${project}"
}

# List branches sorted by most recently modified.
bitbucket_branches() {
  local project="${1:?Usage: bitbucket_branches <PROJECT_KEY> <REPO_SLUG>}"
  local repo="${2:?Missing repo slug}"
  curl -sk \
    -H "Authorization: Bearer ${BITBUCKET_PERSONAL_TOKEN}" \
    -H "Accept: application/json" \
    "${BITBUCKET_URL%/}/rest/api/latest/projects/${project}/repos/${repo}/branches?limit=15&orderBy=MODIFICATION" \
  | python3 -c "
import json, sys
for b in json.load(sys.stdin).get('values', []):
    default = ' <- default' if b.get('isDefault') else ''
    print(f'  {b[\"displayId\"]}{default}')
"
}

# List my open PRs across all repos.
bitbucket_my_prs() {
  curl -sk \
    -H "Authorization: Bearer ${BITBUCKET_PERSONAL_TOKEN}" \
    -H "Accept: application/json" \
    "${BITBUCKET_URL%/}/rest/api/latest/dashboard/pull-requests?role=AUTHOR&state=OPEN&limit=20" \
  | python3 -c "
import json, sys
prs = json.load(sys.stdin).get('values', [])
print(len(prs), 'open PRs')
for pr in prs:
    repo = pr['toRef']['repository']['slug']
    branch = pr['fromRef']['displayId']
    print(f'  [#{pr[\"id\"]:4}]  {repo:35} {branch:30} -> {pr[\"title\"][:60]}')
"
}

# Clone a repo with token embedded in URL (not saved to shell history if sourced).
bitbucket_clone() {
  local project="${1:?Usage: bitbucket_clone <PROJECT_KEY> <REPO_SLUG>}"
  local repo="${2:?Missing repo slug}"
  git clone "https://${BITBUCKET_USERNAME}:${BITBUCKET_PERSONAL_TOKEN}@git.system.local/scm/${project,,}/${repo}.git"
}

echo "si_query.sh loaded:"
echo "  jira_get <KEY>  |  jira_search '<JQL>'  |  jira_comment <KEY> <TEXT>"
echo "  confluence_search <SPACE> <TERM>  |  confluence_get_page <ID>"
echo "  bitbucket_repos <PROJECT>  |  bitbucket_branches <P> <REPO>  |  bitbucket_my_prs  |  bitbucket_clone <P> <REPO>"
