#!/usr/bin/env bash
set -Eeuo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

mapfile -t ready_prs < <(
  gh api --paginate "repos/${GITHUB_REPOSITORY}/issues?labels=db-ready&state=open&per_page=100" \
    --jq '.[] | select(.pull_request != null) | .number'
)

echo "Found ${#ready_prs[@]} ready migration PR(s)."
started_at=$(date +%s)
processed=0
failed=0

for pr_number in "${ready_prs[@]}"; do
  metadata=$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${pr_number}")
  state=$(jq -r '.state' <<<"${metadata}")
  draft=$(jq -r '.draft' <<<"${metadata}")
  head_repo=$(jq -r '.head.repo.full_name' <<<"${metadata}")
  head_ref=$(jq -r '.head.ref' <<<"${metadata}")

  if [[ ${state} != open || ${draft} == true ]]; then
    echo "Skipping PR #${pr_number}: state=${state}, draft=${draft}."
    continue
  fi
  if [[ ${head_repo} != "${GITHUB_REPOSITORY}" ]]; then
    echo "Skipping PR #${pr_number}: fork PRs are unsupported." >&2
    gh api --method DELETE "repos/${GITHUB_REPOSITORY}/issues/${pr_number}/labels/db-ready" >/dev/null
    failed=$((failed + 1))
    continue
  fi

  echo "Finalizing PR #${pr_number} from ${head_ref}."
  git merge --abort >/dev/null 2>&1 || true
  git reset --hard HEAD >/dev/null
  git clean -fd >/dev/null
  git fetch origin main "refs/heads/${head_ref}:refs/remotes/origin/${head_ref}"
  git checkout -B coordinator-candidate "origin/${head_ref}"

  if ../trusted/scripts/finalize-migration-pr.sh "${pr_number}" "${head_ref}"; then
    processed=$((processed + 1))
  else
    echo "PR #${pr_number} failed finalization; removing db-ready until it is fixed." >&2
    gh api --method DELETE "repos/${GITHUB_REPOSITORY}/issues/${pr_number}/labels/db-ready" >/dev/null
    failed=$((failed + 1))
  fi
done

elapsed=$(( $(date +%s) - started_at ))
echo "Processed ${processed} PR(s), failed ${failed}, elapsed ${elapsed}s."
if ((failed > 0)); then
  exit 1
fi
