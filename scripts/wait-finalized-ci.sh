#!/usr/bin/env bash
set -Eeuo pipefail

head_sha=${1:?"usage: wait-finalized-ci.sh <head-sha>"}
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

gh api --method POST "repos/${GITHUB_REPOSITORY}/statuses/${head_sha}" \
  -f state=pending -f context='Atlas CI' \
  -f description='Finalized commit CI has been requested.' >/dev/null

gh api --method POST "repos/${GITHUB_REPOSITORY}/actions/workflows/finalized-ci.yml/dispatches" \
  -f ref=main -f "inputs[expected_sha]=${head_sha}" >/dev/null

max_attempts=${FINALIZED_CI_MAX_ATTEMPTS:-120}
poll_seconds=${FINALIZED_CI_POLL_SECONDS:-10}
for ((attempt = 1; attempt <= max_attempts; attempt++)); do
  status=$(gh api "repos/${GITHUB_REPOSITORY}/commits/${head_sha}/statuses" \
    --jq '[.[] | select(.context == "Atlas CI")][0].state // "pending"')
  case ${status} in
    success)
      echo "Finalized commit ${head_sha} passed CI."
      exit 0
      ;;
    failure|error)
      echo "Finalized commit ${head_sha} failed CI." >&2
      exit 2
      ;;
    pending)
      echo "Waiting for finalized commit CI on ${head_sha} (${attempt}/${max_attempts})."
      ;;
    *)
      echo "Unexpected Atlas CI status ${status} on ${head_sha}." >&2
      exit 1
      ;;
  esac
  sleep "${poll_seconds}"
done

echo "Timed out waiting for finalized commit CI on ${head_sha}." >&2
exit 1
