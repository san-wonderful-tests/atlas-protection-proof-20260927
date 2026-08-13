#!/usr/bin/env bash
set -Eeuo pipefail

pr_number=${1:?"usage: finalize-migration-pr.sh <pr-number> <head-ref>"}
head_ref=${2:?"usage: finalize-migration-pr.sh <pr-number> <head-ref>"}

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${ATLAS_DEV_URL:?ATLAS_DEV_URL is required}"

migration_dir=migrations
base_ref=origin/main
migration_url="file://${PWD}/${migration_dir}"
schema_url="file://${PWD}/schema.hcl"
finalized=false

post_status() {
  local sha=$1
  local state=$2
  local description=$3
  gh api --method POST "repos/${GITHUB_REPOSITORY}/statuses/${sha}" \
    -f state="${state}" \
    -f context='Atlas Finalized' \
    -f description="${description}" >/dev/null
}

current_pr_sha() {
  gh api "repos/${GITHUB_REPOSITORY}/pulls/${pr_number}" --jq '.head.sha'
}

on_exit() {
  local exit_code=$?
  if [[ ${exit_code} -ne 0 && ${finalized} != true ]]; then
    local sha
    sha=$(current_pr_sha 2>/dev/null || true)
    if [[ -n "${sha}" ]]; then
      post_status "${sha}" failure 'Coordinator failed; inspect the workflow log.' || true
    fi
  fi
}
trap on_exit EXIT

fingerprint() {
  local ref=$1
  git rev-parse \
    "${ref}:migrations/atlas.sum" \
    "${ref}:schema.hcl" \
    "${ref}:atlas.hcl" |
    shasum -a 256 |
    awk '{print $1}'
}

git fetch origin main --prune
post_status "$(git rev-parse HEAD)" pending 'Waiting for the migration coordinator.'

pr_migrations=()
while IFS= read -r path; do
  [[ -n "${path}" ]] && pr_migrations+=("${path}")
done < <(git diff --name-only --diff-filter=A "${base_ref}"...HEAD -- "${migration_dir}/*.sql")
if ((${#pr_migrations[@]} == 0)); then
  echo "The PR changes Atlas inputs but does not add a SQL migration." >&2
  exit 1
fi

changed_existing=()
while IFS= read -r path; do
  [[ -n "${path}" ]] && changed_existing+=("${path}")
done < <(git diff --name-only --diff-filter=MDR "${base_ref}"...HEAD -- "${migration_dir}/*.sql")
if ((${#changed_existing[@]} > 0)); then
  printf 'The PR modifies existing migrations:\n' >&2
  printf '  %s\n' "${changed_existing[@]}" >&2
  exit 1
fi

base_fingerprint=$(fingerprint "${base_ref}")

if ! git merge --no-edit "${base_ref}"; then
  conflicts=()
  while IFS= read -r path; do
    [[ -n "${path}" ]] && conflicts+=("${path}")
  done < <(git diff --name-only --diff-filter=U)
  if ((${#conflicts[@]} != 1)) || [[ ${conflicts[0]} != "${migration_dir}/atlas.sum" ]]; then
    printf 'Coordinator only resolves atlas.sum; unresolved conflicts:\n' >&2
    printf '  %s\n' "${conflicts[@]}" >&2
    git merge --abort
    exit 1
  fi

  git checkout --theirs -- "${migration_dir}/atlas.sum"
  git add -- "${migration_dir}/atlas.sum"
  git commit --no-edit
fi

rebase_names=()
for path in "${pr_migrations[@]}"; do
  rebase_names+=("${path##*/}")
done

atlas migrate rebase --dir "${migration_url}" "${rebase_names[@]}"
git add -- "${migration_dir}"
git commit -m 'chore: finalize Atlas migrations against main'

scripts/check-migration-history.sh "${base_ref}" "${migration_dir}"
atlas migrate validate --dir "${migration_url}" --dev-url "${ATLAS_DEV_URL}"
if [[ -n "${ATLAS_TOKEN:-}" ]]; then
  atlas migrate lint \
    --dir "${migration_url}" \
    --dev-url "${ATLAS_DEV_URL}" \
    --git-base "${base_ref}" \
    --git-dir .
else
  echo "ATLAS_TOKEN is not configured; skipping optional Atlas Pro migration lint."
fi

atlas migrate diff coordinator_verify_no_drift \
  --dir "${migration_url}" \
  --to "${schema_url}" \
  --dev-url "${ATLAS_DEV_URL}"

drift=$(git status --porcelain -- "${migration_dir}")
if [[ -n "${drift}" ]]; then
  echo "Desired schema and migration history are not synchronized:" >&2
  echo "${drift}" >&2
  exit 1
fi

git push origin "HEAD:refs/heads/${head_ref}"
head_sha=$(git rev-parse HEAD)

git fetch origin main --prune
if [[ $(fingerprint origin/main) != "${base_fingerprint}" ]]; then
  post_status "${head_sha}" pending 'Main migration tip changed; finalize again.'
  echo "The migration tip changed while the PR was being finalized." >&2
  exit 1
fi

post_status "${head_sha}" success 'Rebased and validated against the current migration tip.'

merge_result=$(
  gh api --method PUT "repos/${GITHUB_REPOSITORY}/pulls/${pr_number}/merge" \
    -f merge_method=squash \
    -f sha="${head_sha}"
)
if [[ $(jq -r '.merged' <<<"${merge_result}") != true ]]; then
  post_status "${head_sha}" failure 'GitHub rejected the finalized merge.'
  jq . <<<"${merge_result}" >&2
  exit 1
fi

finalized=true
echo "PR #${pr_number} was finalized and merged at ${head_sha}."
