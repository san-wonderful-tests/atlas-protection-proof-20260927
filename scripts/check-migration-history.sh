#!/usr/bin/env bash
set -euo pipefail

base_ref=${1:?"usage: check-migration-history.sh <base-ref> [migration-dir]"}
migration_dir=${2:-migrations}

changed_existing=()
while IFS= read -r path; do
  [[ -n "${path}" ]] && changed_existing+=("${path}")
done < <(git diff --name-only --diff-filter=MDR "${base_ref}"...HEAD -- "${migration_dir}/*.sql")
if ((${#changed_existing[@]} > 0)); then
  printf 'Existing migrations are immutable:\n' >&2
  printf '  %s\n' "${changed_existing[@]}" >&2
  exit 1
fi

added=()
while IFS= read -r path; do
  [[ -n "${path}" ]] && added+=("${path}")
done < <(git diff --name-only --diff-filter=A "${base_ref}"...HEAD -- "${migration_dir}/*.sql")
if ((${#added[@]} == 0)); then
  echo "No new SQL migration was found." >&2
  exit 1
fi

base_latest=$(
  git ls-tree -r --name-only "${base_ref}" -- "${migration_dir}" |
    sed -n 's#^.*/\([^/]*\.sql\)$#\1#p' |
    LC_ALL=C sort |
    tail -n 1
)

for path in "${added[@]}"; do
  name=${path##*/}
  if [[ -n "${base_latest}" && "${name}" < "${base_latest}" ]]; then
    printf 'Out-of-order migration: %s must sort after %s\n' "${name}" "${base_latest}" >&2
    exit 1
  fi
done

printf 'Migration history is append-only and ordered (%d new file(s)).\n' "${#added[@]}"
