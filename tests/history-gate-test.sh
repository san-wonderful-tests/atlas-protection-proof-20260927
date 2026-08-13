#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
gate="${repo_root}/scripts/check-migration-history.sh"
test_root=$(mktemp -d)
trap 'rm -rf "${test_root}"' EXIT

new_repo() {
  local path=$1
  git init -q -b main "${path}"
  git -C "${path}" config user.email test@example.com
  git -C "${path}" config user.name Test
  mkdir -p "${path}/migrations"
  printf '%s\n' 'CREATE TABLE projects (id uuid PRIMARY KEY);' >"${path}/migrations/20260101000000_baseline.sql"
  git -C "${path}" add -- migrations/20260101000000_baseline.sql
  git -C "${path}" commit -qm baseline
}

ordered="${test_root}/ordered"
new_repo "${ordered}"
git -C "${ordered}" switch -qc feature
printf '%s\n' 'ALTER TABLE projects ADD COLUMN name text;' >"${ordered}/migrations/20260102000000_add_name.sql"
git -C "${ordered}" add -- migrations/20260102000000_add_name.sql
git -C "${ordered}" commit -qm ordered
git -C "${ordered}" branch base main
git -C "${ordered}" -c advice.detachedHead=false switch -q feature
(cd "${ordered}" && "${gate}" base migrations)

out_of_order="${test_root}/out-of-order"
new_repo "${out_of_order}"
git -C "${out_of_order}" switch -qc feature
printf '%s\n' 'ALTER TABLE projects ADD COLUMN name text;' >"${out_of_order}/migrations/20251231000000_add_name.sql"
git -C "${out_of_order}" add -- migrations/20251231000000_add_name.sql
git -C "${out_of_order}" commit -qm out-of-order
if (cd "${out_of_order}" && "${gate}" main migrations); then
  echo "Expected an out-of-order migration to fail." >&2
  exit 1
fi

modified="${test_root}/modified"
new_repo "${modified}"
git -C "${modified}" switch -qc feature
printf '%s\n' 'CREATE TABLE projects (id uuid PRIMARY KEY, name text);' >"${modified}/migrations/20260101000000_baseline.sql"
printf '%s\n' 'ALTER TABLE projects ADD COLUMN name text;' >"${modified}/migrations/20260102000000_add_name.sql"
git -C "${modified}" add -- migrations/20260101000000_baseline.sql migrations/20260102000000_add_name.sql
git -C "${modified}" commit -qm modified
if (cd "${modified}" && "${gate}" main migrations); then
  echo "Expected a modified historical migration to fail." >&2
  exit 1
fi

echo "History gate tests passed."
