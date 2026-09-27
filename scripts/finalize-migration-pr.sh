#!/usr/bin/env bash
set -Eeuo pipefail

pr_number=${1:?"usage: finalize-migration-pr.sh <pr-number> <head-ref>"}
head_ref=${2:?"usage: finalize-migration-pr.sh <pr-number> <head-ref>"}

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${ATLAS_DEV_URL:?ATLAS_DEV_URL is required}"

migration_dirs=(migrations migrations_aux)
schema_files=(schema.hcl schema_aux.hcl)
base_ref=origin/main
atlas_config=file:///dev/null
finalized=false

# shellcheck source=scripts/github-pr-merge.sh
source "$(dirname "${BASH_SOURCE[0]}")/github-pr-merge.sh"

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
  if [[ -n ${archive_root:-} ]]; then
    rm -rf -- "${archive_root}"
  fi
  if [[ ${exit_code} -ne 0 && ${finalized} != true ]]; then
    local sha
    sha=$(current_pr_sha 2>/dev/null || true)
    if [[ -n "${sha}" ]]; then
      if [[ ${exit_code} -eq 2 ]]; then
        post_status "${sha}" failure 'Migration rejected; inspect the workflow log.' || true
      else
        post_status "${sha}" pending 'Coordinator interrupted; queued for retry.' || true
      fi
    fi
  fi
}
trap on_exit EXIT

reject() {
  echo "$*" >&2
  exit 2
}

fingerprint() {
  local ref=$1
  local paths=("${ref}:atlas.hcl")
  local index
  for index in "${!migration_dirs[@]}"; do
    paths+=("${ref}:${migration_dirs[index]}/atlas.sum" "${ref}:${schema_files[index]}")
  done
  git rev-parse "${paths[@]}" |
    shasum -a 256 |
    awk '{print $1}'
}

git fetch origin main --prune
original_head_sha=$(git rev-parse HEAD)
post_status "$(git rev-parse HEAD)" pending 'Waiting for the migration coordinator.'

pr_migrations=()
changed_existing=()
for migration_dir in "${migration_dirs[@]}"; do
  while IFS= read -r path; do
    [[ -n "${path}" ]] && pr_migrations+=("${path}")
  done < <(git diff --name-only --diff-filter=A "${base_ref}"...HEAD -- "${migration_dir}/*.sql")
  while IFS= read -r path; do
    [[ -n "${path}" ]] && changed_existing+=("${path}")
  done < <(git diff --name-only --diff-filter=MDR "${base_ref}"...HEAD -- "${migration_dir}/*.sql")
done
if ((${#pr_migrations[@]} == 0)); then
  reject 'The PR changes Atlas inputs but does not add a SQL migration.'
fi
if ((${#changed_existing[@]} > 0)); then
  printf 'The PR modifies existing migrations:\n' >&2
  printf '  %s\n' "${changed_existing[@]}" >&2
  exit 2
fi

base_fingerprint=$(fingerprint "${base_ref}")

if ! git merge --no-edit "${base_ref}"; then
  conflicts=()
  while IFS= read -r path; do
    [[ -n "${path}" ]] && conflicts+=("${path}")
  done < <(git diff --name-only --diff-filter=U)
  for conflict in "${conflicts[@]}"; do
    allowed=false
    for migration_dir in "${migration_dirs[@]}"; do
      [[ ${conflict} == "${migration_dir}/atlas.sum" ]] && allowed=true
    done
    if [[ ${allowed} != true ]]; then
      printf 'Coordinator only resolves atlas.sum; unresolved conflicts:\n' >&2
      printf '  %s\n' "${conflicts[@]}" >&2
      git merge --abort
      exit 2
    fi
  done
  for conflict in "${conflicts[@]}"; do
    git checkout --theirs -- "${conflict}"
    git add -- "${conflict}"
  done
  git commit --no-edit
fi

# Atlas refuses to hash a directory containing two files with the same version.
# Move PR-owned files aside, hash main's files, then let Atlas allocate a fresh
# version for each PR file. Copy the original SQL bytes into the new files.
archive_root=$(mktemp -d)
for index in "${!migration_dirs[@]}"; do
  migration_dir=${migration_dirs[index]}
  migration_url="file://${PWD}/${migration_dir}"
  mkdir -p "${archive_root}/${migration_dir}"
  directory_migrations=()
  for path in "${pr_migrations[@]}"; do
    if [[ ${path} == "${migration_dir}/"* ]]; then
      directory_migrations+=("${path}")
      mv -- "${path}" "${archive_root}/${path}"
    fi
  done
  atlas migrate hash --config "${atlas_config}" --dir "${migration_url}"
  for path in "${directory_migrations[@]}"; do
    original_name=${path##*/}
    if [[ ! ${original_name} =~ ^[0-9]{14}_(.+)\.sql$ ]]; then
      reject "Invalid Atlas migration filename: ${path}"
    fi
    migration_name=${BASH_REMATCH[1]}
    atlas migrate new --config "${atlas_config}" --dir "${migration_url}" "${migration_name}"
    allocated_name=$(tail -n 1 "${migration_dir}/atlas.sum" | cut -d ' ' -f 1)
    if [[ ! ${allocated_name} =~ ^[0-9]{14}_${migration_name}\.sql$ || ! -f ${migration_dir}/${allocated_name} ]]; then
      reject "Atlas did not allocate an expected filename for ${path}: ${allocated_name}"
    fi
    cp -- "${archive_root}/${path}" "${migration_dir}/${allocated_name}"
    atlas migrate hash --config "${atlas_config}" --dir "${migration_url}"
    echo "Atlas allocated ${migration_dir}/${allocated_name} for ${path}."
  done
  git add -- "${migration_dir}"
done
if ! git diff --cached --quiet; then
  git commit -m 'chore: finalize Atlas migrations against main'
fi

for index in "${!migration_dirs[@]}"; do
  migration_dir=${migration_dirs[index]}
  migration_url="file://${PWD}/${migration_dir}"
  schema_url="file://${PWD}/${schema_files[index]}"
  if [[ -n $(git diff --name-only --diff-filter=A "${base_ref}"...HEAD -- "${migration_dir}/*.sql") ]]; then
    "$(dirname "${BASH_SOURCE[0]}")/check-migration-history.sh" "${base_ref}" "${migration_dir}" || exit 2
  fi
  atlas migrate validate --config "${atlas_config}" --dir "${migration_url}" --dev-url "${ATLAS_DEV_URL}" || exit 2
  if [[ -n "${ATLAS_TOKEN:-}" ]]; then
    atlas migrate lint \
      --config "${atlas_config}" \
      --dir "${migration_url}" \
      --dev-url "${ATLAS_DEV_URL}" \
      --git-base "${base_ref}" \
      --git-dir . || exit 2
  fi
  atlas migrate diff coordinator_verify_no_drift \
    --config "${atlas_config}" \
    --dir "${migration_url}" \
    --to "${schema_url}" \
    --dev-url "${ATLAS_DEV_URL}" || exit 2
  drift=$(git status --porcelain -- "${migration_dir}")
  if [[ -n "${drift}" ]]; then
    reject "Desired schema and migration history are not synchronized in ${migration_dir}: ${drift}"
  fi
done

git push origin "HEAD:refs/heads/${head_ref}"
head_sha=$(git rev-parse HEAD)

git fetch origin main --prune
if [[ $(fingerprint origin/main) != "${base_fingerprint}" ]]; then
  post_status "${head_sha}" pending 'Main migration tip changed; finalize again.'
  echo "The migration tip changed while the PR was being finalized." >&2
  exit 1
fi

post_status "${head_sha}" pending 'Waiting for CI on the finalized commit.'
"$(dirname "${BASH_SOURCE[0]}")/wait-finalized-ci.sh" "${head_sha}" || exit $?
post_status "${head_sha}" success 'Rebased and validated; finalized commit passed CI.'

if ! merge_finalized_pr "${pr_number}" "${head_sha}" "${base_fingerprint}" "${original_head_sha}"; then
  post_status "${head_sha}" failure 'GitHub rejected the finalized merge.'
  exit 1
fi

finalized=true
echo "PR #${pr_number} was finalized and merged at ${head_sha}."
