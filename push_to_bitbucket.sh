#!/usr/bin/env bash
#
# push_to_bitbucket.sh — Bitbucket Cloud bootstrap / sync helper
#
# Creates a Bitbucket Cloud repository in an existing workspace and pushes the
# current local git repo to it. Designed for end-to-end testing the eval kit's
# --platform bitbucket path, but also handy any time you want to mirror a local
# tree to Bitbucket without clicking through the UI.
#
# Default behaviour: create a *brand-new* PUBLIC repo and fail loudly if one
# already exists at <workspace>/<slug>. Pass --reuse-existing to instead push
# into the repo that's already there (no create attempt is treated as fatal).
# Pass --private if you'd rather create a private repo.
#
# When reusing an existing repo with --reuse-existing, the script also aligns
# the remote repo's visibility (public/private) with the requested setting via
# a follow-up PATCH — so `--reuse-existing` (default public) will flip an
# existing private repo to public, and `--reuse-existing --private` will do
# the reverse.
#
# Prerequisites
# -------------
#   • git installed and you're inside a git working tree with at least one commit
#   • curl installed
#   • The target *workspace* must already exist — workspaces cannot be created
#     via the Bitbucket API. Create one in the browser:
#       https://bitbucket.org → avatar (top-right) → All workspaces → Create workspace
#   • A Bitbucket access token. Pick one of:
#       (a) Workspace / Repository / Project Access Token  — Bearer auth (preferred)
#             export BITBUCKET_TOKEN="ATBB..."           # leave BITBUCKET_USERNAME unset
#             scopes: repository, repository:admin, pullrequest
#       (b) Atlassian account API token (ATATT…)         — HTTP Basic auth (email:token)
#             export BITBUCKET_TOKEN="ATATT…"
#             export BITBUCKET_USERNAME="you@example.com"   # your Atlassian email
#             note: REST API only by default; for git over HTTPS the token must
#                   have been created with Bitbucket repository scopes.
#       (c) Legacy App Password                          — HTTP Basic auth
#             export BITBUCKET_TOKEN="your_app_password"
#             export BITBUCKET_USERNAME="your_bitbucket_username"
#             scopes: Repositories: Admin, Pull requests: Read
#
#   The script picks Basic vs Bearer automatically based on whether
#   BITBUCKET_USERNAME is set.
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
#   -r, --repo      REPO_SLUG   Target repository slug (required)
#   -p, --project   PROJECT_KEY Existing project key in the workspace
#                                 (optional; Bitbucket auto-creates one otherwise)
#   -b, --branch    BRANCH      Branch to push (default: current branch)
#   -m, --message   MSG         Commit message for the auto-snapshot
#                                 (default: "Snapshot for Bitbucket bootstrap")
#       --public                Create as a public repo (the default).
#       --private               Create as a private repo.
#       --remote    NAME        Local git remote name to add (default: bitbucket)
#       --reuse-existing        If <workspace>/<slug> already exists, skip the
#                                 create step and push to it instead of failing.
#       --force-push            Use `git push --force-with-lease` (use with
#                                 --reuse-existing to overwrite a divergent
#                                 remote branch). Off by default.
#   -h, --help                  Show this help and exit
#
# Examples
# --------
#   # (a) brand-new repo
#   export BITBUCKET_TOKEN="ATBB..."
#   ./push_to_bitbucket.sh -w eval-test -r lh2-datalabs-eval-kit
#
#   # (b) push into a repo that already exists in the workspace
#   ./push_to_bitbucket.sh -w eval-test -r lh2-datalabs-eval-kit --reuse-existing
#
#   # (c) same, but overwrite the remote branch
#   ./push_to_bitbucket.sh -w eval-test -r lh2-datalabs-eval-kit \
#     --reuse-existing --force-push

set -euo pipefail

# ── arg parsing ──────────────────────────────────────────────────────────────
WORKSPACE=""
REPO_SLUG=""
PROJECT_KEY=""
BRANCH=""
IS_PRIVATE="false"
REMOTE_NAME="bitbucket"
SNAPSHOT_MSG="Snapshot for Bitbucket bootstrap"
REUSE_EXISTING="false"
FORCE_PUSH="false"

usage() {
  sed -n '2,/^# Examples$/p' "$0" | sed 's/^# \{0,1\}//'
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
    --private)       IS_PRIVATE="true";  shift ;;
    --reuse-existing) REUSE_EXISTING="true"; shift ;;
    --force-push)    FORCE_PUSH="true"; shift ;;
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

if [[ "$IS_PRIVATE" == "true" ]]; then VISIBILITY_LABEL="private"; else VISIBILITY_LABEL="public"; fi

echo "→ Auth: ${AUTH_KIND}"
echo "→ Creating repo:  ${WORKSPACE}/${REPO_SLUG}  (${VISIBILITY_LABEL})"
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

RESP_BODY="$(cat "$HTTP_RESP_FILE")"

# Detect Bitbucket's "this repo already exists" response. Bitbucket returns 400
# for this case (not 409, despite what you'd expect); the discriminator is the
# message body. We match on a stable substring so we don't get tripped up by
# punctuation changes in the API response.
already_exists() {
  [[ "$HTTP_CODE" == "400" ]] && \
    grep -qiE 'Repository with this (Slug|Name) and Owner already exists|already has a repository with this name' <<<"$RESP_BODY"
}

if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
  echo "✅ Created: https://bitbucket.org/${WORKSPACE}/${REPO_SLUG}"
elif already_exists; then
  if [[ "$REUSE_EXISTING" == "true" ]]; then
    echo "✓ Repo already exists at ${WORKSPACE}/${REPO_SLUG} — skipping create, will push to it."

    # ── align the existing repo's visibility with --public/--private ─────────
    # Bitbucket's PUT /2.0/repositories/{ws}/{slug} is idempotent: if the repo
    # already has the requested is_private value, this is a no-op from the
    # user's perspective. We don't fail the whole script on a non-2xx here —
    # the push step is still the important part.
    VIS_RESP_FILE="$(mktemp -t bb_vis.XXXXXX)"
    VIS_CODE="$(
      curl -sS -o "$VIS_RESP_FILE" -w '%{http_code}' \
        -X PUT "${CURL_AUTH[@]}" \
        -H 'Content-Type: application/json' \
        -d "{\"is_private\":${IS_PRIVATE}}" \
        "$API_URL"
    )"
    if [[ "$VIS_CODE" == "200" ]]; then
      ACTUAL_PRIVATE="$(python3 -c 'import json,sys; print(str(json.load(open(sys.argv[1])).get("is_private","?")).lower())' "$VIS_RESP_FILE" 2>/dev/null || echo "?")"
      if [[ "$ACTUAL_PRIVATE" == "$IS_PRIVATE" ]]; then
        echo "✓ Visibility aligned: repo is now ${VISIBILITY_LABEL}."
      else
        echo "⚠ Visibility PATCH returned 200 but is_private=${ACTUAL_PRIVATE} (expected ${IS_PRIVATE}). Continuing."
      fi
    else
      echo "⚠ Could not update visibility (HTTP ${VIS_CODE}). The repo will be pushed to as-is."
      echo "── response ──"
      cat "$VIS_RESP_FILE"
      echo
      case "$VIS_CODE" in
        403) echo "  • 403: token lacks 'repository:admin' scope, which is needed to change visibility.";;
        404) echo "  • 404: repo disappeared between create and update — unusual.";;
      esac
    fi
    rm -f "$VIS_RESP_FILE"
  else
    echo "❌ Repo already exists at ${WORKSPACE}/${REPO_SLUG} (HTTP 400):" >&2
    echo "── response ──" >&2
    echo "$RESP_BODY" >&2
    echo "" >&2
    echo "── hints ──" >&2
    echo "  • Re-run with --reuse-existing to push to the existing repo instead." >&2
    echo "  • Or pick a different -r/--repo slug to create a fresh one." >&2
    echo "  • Add --force-push (with --reuse-existing) to overwrite a divergent remote branch." >&2
    exit 1
  fi
else
  echo "❌ Failed to create repo (HTTP $HTTP_CODE):" >&2
  echo "── response ──" >&2
  echo "$RESP_BODY" >&2
  echo "" >&2
  echo "── hints ──" >&2
  case "$HTTP_CODE" in
    400) echo "  • 400: bad request. Check the repo slug (lowercase a-z, 0-9, hyphens) and workspace slug." >&2;;
    401) echo "  • 401: token rejected." >&2
         echo "    - If it's an Atlassian-account API token (ATATT…), set BITBUCKET_USERNAME=your_email." >&2
         echo "    - If it's a Workspace/Repo Access Token, leave BITBUCKET_USERNAME unset (Bearer auth)." >&2;;
    403) echo "  • 403: token lacks scope. Need 'repository:admin' to create repos." >&2;;
    404) echo "  • 404: workspace '${WORKSPACE}' not found, or token can't see it." >&2
         echo "    - List visible workspaces:  curl -sS \"\${CURL_AUTH[@]}\" \\" >&2
         echo "        https://api.bitbucket.org/2.0/workspaces | jq -r '.values[].slug'" >&2;;
    409) echo "  • 409: a repo at '${WORKSPACE}/${REPO_SLUG}' already exists. Re-run with --reuse-existing." >&2;;
  esac
  exit 1
fi

# ── 2) push current branch ───────────────────────────────────────────────────
if [[ -n "${BITBUCKET_USERNAME:-}" ]]; then
  USR_ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$BITBUCKET_USERNAME")
  TOK_ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$BITBUCKET_TOKEN")
  PUSH_URL="https://${USR_ENC}:${TOK_ENC}@bitbucket.org/${WORKSPACE}/${REPO_SLUG}.git"
else
  PUSH_URL="https://x-token-auth:${BITBUCKET_TOKEN}@bitbucket.org/${WORKSPACE}/${REPO_SLUG}.git"
fi

if [[ "$FORCE_PUSH" == "true" ]]; then
  echo "→ Pushing '${BRANCH}' to Bitbucket (--force-with-lease) …"
  git push --force-with-lease "$PUSH_URL" "${BRANCH}:${BRANCH}"
else
  echo "→ Pushing '${BRANCH}' to Bitbucket …"
  git push "$PUSH_URL" "${BRANCH}:${BRANCH}"
fi

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
