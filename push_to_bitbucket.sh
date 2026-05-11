#!/usr/bin/env bash
#
# push_to_bitbucket.sh — one-shot bootstrap helper
#
# Creates a brand-new Bitbucket Cloud repository in an existing workspace and
# pushes the current local git repo to it. Designed to be run once when you
# need a fresh Bitbucket target (e.g. to end-to-end test the eval kit's
# --platform bitbucket path).
#
# Prerequisites
# -------------
#   • git installed and you're inside a git working tree with at least one commit
#   • curl installed
#   • The target *workspace* must already exist — workspaces cannot be created
#     via the Bitbucket API. Create one in the browser:
#       https://bitbucket.org → avatar (top-right) → All workspaces → Create workspace
#   • A Bitbucket access token. Pick one of:
#       (a) Workspace/Repository/Project Access Token (Bearer auth — preferred)
#             export BITBUCKET_TOKEN="ATBB..."
#             scopes: repository, repository:admin, pullrequest
#       (b) Atlassian account API token (Bearer auth)
#             export BITBUCKET_TOKEN="..."
#       (c) Legacy App Password (HTTP Basic auth — also needs username)
#             export BITBUCKET_TOKEN="your_app_password"
#             export BITBUCKET_USERNAME="your_bitbucket_username"
#             scopes: Repositories: Admin, Pull requests: Read
#
# Usage
# -----
#   ./push_to_bitbucket.sh -w WORKSPACE -r REPO_SLUG [options]
#
# Behaviour
# ---------
#   Any uncommitted changes in the working tree (respecting .gitignore) are
#   auto-staged into a single snapshot commit BEFORE the push, so the new
#   Bitbucket repo always reflects the full current state of your working tree.
#   Override the snapshot message with -m / --message.
#
# Options:
#   -w, --workspace WORKSPACE   Bitbucket workspace slug (required)
#   -r, --repo      REPO_SLUG   New repository slug to create (required)
#   -p, --project   PROJECT_KEY Existing project key in the workspace
#                                 (optional; Bitbucket auto-creates one otherwise)
#   -b, --branch    BRANCH      Branch to push (default: current branch)
#   -m, --message   MSG         Commit message for the auto-snapshot
#                                 (default: "Snapshot for Bitbucket bootstrap")
#       --public                Create as a public repo (default: private)
#       --remote    NAME        Local git remote name to add (default: bitbucket)
#   -h, --help                  Show this help and exit
#
# Example
# -------
#   export BITBUCKET_TOKEN="ATBB..."
#   ./push_to_bitbucket.sh -w eval-test -r lh2-datalabs-eval-kit

set -euo pipefail

# ── arg parsing ──────────────────────────────────────────────────────────────
WORKSPACE=""
REPO_SLUG=""
PROJECT_KEY=""
BRANCH=""
IS_PRIVATE="true"
REMOTE_NAME="bitbucket"
SNAPSHOT_MSG="Snapshot for Bitbucket bootstrap"

usage() {
  sed -n '2,/^# Example$/p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--workspace)  WORKSPACE="${2:?missing value for $1}"; shift 2 ;;
    -r|--repo)       REPO_SLUG="${2:?missing value for $1}"; shift 2 ;;
    -p|--project)    PROJECT_KEY="${2:?missing value for $1}"; shift 2 ;;
    -b|--branch)     BRANCH="${2:?missing value for $1}"; shift 2 ;;
    -m|--message)    SNAPSHOT_MSG="${2:?missing value for $1}"; shift 2 ;;
    --remote)        REMOTE_NAME="${2:?missing value for $1}"; shift 2 ;;
    --public)        IS_PRIVATE="false"; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "❌ Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ── validation ───────────────────────────────────────────────────────────────
[[ -z "$WORKSPACE" ]] && { echo "❌ -w/--workspace is required" >&2; exit 2; }
[[ -z "$REPO_SLUG" ]] && { echo "❌ -r/--repo is required" >&2; exit 2; }

if [[ -z "${BITBUCKET_TOKEN:-}" ]]; then
  echo "❌ BITBUCKET_TOKEN is not set." >&2
  echo "   export BITBUCKET_TOKEN=ATBB..." >&2
  echo "   (and BITBUCKET_USERNAME=your_user if it's an App Password)" >&2
  exit 2
fi

command -v git >/dev/null  || { echo "❌ git not found in PATH"   >&2; exit 2; }
command -v curl >/dev/null || { echo "❌ curl not found in PATH"  >&2; exit 2; }

git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "❌ Not inside a git repository (cwd: $(pwd))" >&2
  exit 2
}

if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
  echo "❌ This git repo has no commits yet — make at least one commit first." >&2
  exit 2
fi

if [[ -z "$BRANCH" ]]; then
  BRANCH="$(git branch --show-current)"
  if [[ -z "$BRANCH" ]]; then
    echo "❌ Detached HEAD and no -b/--branch given. Pass --branch to choose one." >&2
    exit 2
  fi
fi

# ── auto-snapshot any pending changes so the WHOLE working tree gets pushed ──
# `git push` can only ship commits — there's no way to push a dirty working
# tree directly. To make the new Bitbucket repo mirror what you see on disk,
# we stage everything (respecting .gitignore, so .env / .venv stay out) and
# create one snapshot commit on the current branch before pushing.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "→ Working tree has changes — snapshotting them into one commit:"
  git status --short
  git add -A
  git commit -m "$SNAPSHOT_MSG" --allow-empty
  echo "✅ Snapshot commit:  $(git rev-parse --short HEAD)  ${SNAPSHOT_MSG}"
else
  echo "→ Working tree clean — nothing to snapshot."
fi

# ── auth selection: Bearer vs HTTP Basic ─────────────────────────────────────
if [[ -n "${BITBUCKET_USERNAME:-}" ]]; then
  CURL_AUTH=(-u "${BITBUCKET_USERNAME}:${BITBUCKET_TOKEN}")
  AUTH_KIND="HTTP Basic (App Password as ${BITBUCKET_USERNAME})"
else
  CURL_AUTH=(-H "Authorization: Bearer ${BITBUCKET_TOKEN}")
  AUTH_KIND="Bearer token"
fi

echo "→ Auth: ${AUTH_KIND}"
echo "→ Creating repo:  ${WORKSPACE}/${REPO_SLUG}  (private=${IS_PRIVATE})"
echo "→ Branch to push: ${BRANCH}"

# ── 1) create the repo ───────────────────────────────────────────────────────
BODY="{\"scm\":\"git\",\"is_private\":${IS_PRIVATE}"
if [[ -n "$PROJECT_KEY" ]]; then
  BODY+=",\"project\":{\"key\":\"${PROJECT_KEY}\"}"
fi
BODY+=",\"mainbranch\":{\"type\":\"branch\",\"name\":\"${BRANCH}\"}}"

API_URL="https://api.bitbucket.org/2.0/repositories/${WORKSPACE}/${REPO_SLUG}"

HTTP_RESP_FILE="$(mktemp -t bb_resp.XXXXXX)"
trap 'rm -f "$HTTP_RESP_FILE"' EXIT

HTTP_CODE="$(
  curl -sS -o "$HTTP_RESP_FILE" -w '%{http_code}' \
    -X POST "${CURL_AUTH[@]}" \
    -H 'Content-Type: application/json' \
    -d "$BODY" \
    "$API_URL"
)"

if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "201" ]]; then
  echo "❌ Failed to create repo (HTTP $HTTP_CODE):" >&2
  echo "── response ──" >&2
  cat "$HTTP_RESP_FILE" >&2
  echo "" >&2
  echo "── hints ──" >&2
  case "$HTTP_CODE" in
    400) echo "  • 400 often means the repo slug is invalid or the workspace doesn't exist." >&2;;
    401) echo "  • 401: token rejected. If it's an App Password, set BITBUCKET_USERNAME too." >&2;;
    403) echo "  • 403: token lacks scope. Need 'repository:admin' to create repos." >&2;;
    404) echo "  • 404: workspace '${WORKSPACE}' not found, or token can't see it." >&2;;
    409) echo "  • 409: a repo at '${WORKSPACE}/${REPO_SLUG}' already exists." >&2;;
  esac
  exit 1
fi

echo "✅ Created: https://bitbucket.org/${WORKSPACE}/${REPO_SLUG}"

# ── 2) push current branch ───────────────────────────────────────────────────
if [[ -n "${BITBUCKET_USERNAME:-}" ]]; then
  USR_ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$BITBUCKET_USERNAME")
  TOK_ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$BITBUCKET_TOKEN")
  PUSH_URL="https://${USR_ENC}:${TOK_ENC}@bitbucket.org/${WORKSPACE}/${REPO_SLUG}.git"
else
  PUSH_URL="https://x-token-auth:${BITBUCKET_TOKEN}@bitbucket.org/${WORKSPACE}/${REPO_SLUG}.git"
fi

echo "→ Pushing '${BRANCH}' to Bitbucket …"
git push "$PUSH_URL" "${BRANCH}:${BRANCH}"

# ── 3) add a clean (credential-less) remote for future pushes ────────────────
REMOTE_URL_CLEAN="https://bitbucket.org/${WORKSPACE}/${REPO_SLUG}.git"
if git remote get-url "$REMOTE_NAME" >/dev/null 2>&1; then
  git remote set-url "$REMOTE_NAME" "$REMOTE_URL_CLEAN"
  echo "↺ Updated remote '${REMOTE_NAME}' → ${REMOTE_URL_CLEAN}"
else
  git remote add "$REMOTE_NAME" "$REMOTE_URL_CLEAN"
  echo "＋ Added remote '${REMOTE_NAME}' → ${REMOTE_URL_CLEAN}"
fi

cat <<EOF

✅ Done.
   Repository:  https://bitbucket.org/${WORKSPACE}/${REPO_SLUG}
   Remote:      ${REMOTE_NAME}  →  ${REMOTE_URL_CLEAN}

Future pushes (auth picked up from git credential helper / re-export the token):
   git push ${REMOTE_NAME} ${BRANCH}

Test the eval kit against it:
   python repo_evaluator.py bitbucket:${WORKSPACE}/${REPO_SLUG} \\
     --platform bitbucket --json --output results.json
EOF
