#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
# shellcheck source=scripts/github-pr-merge.sh
source "${repo_root}/scripts/github-pr-merge.sh"

test_root=$(mktemp -d)
trap 'rm -rf "${test_root}"' EXIT

export GITHUB_REPOSITORY=example/atlas-lab
export MERGEABILITY_MAX_ATTEMPTS=5
export MERGEABILITY_POLL_SECONDS=0

mode=retry_405
fingerprint_value=expected-tip

increment() {
  local name=$1
  local path="${test_root}/${name}"
  local value=0
  if [[ -f ${path} ]]; then
    value=$(<"${path}")
  fi
  value=$((value + 1))
  printf '%s\n' "${value}" >"${path}"
  printf '%s\n' "${value}"
}

count() {
  local path="${test_root}/$1"
  if [[ -f ${path} ]]; then
    printf '%s\n' "$(<"${path}")"
  else
    printf '0\n'
  fi
}

git() {
  if [[ $1 == fetch ]]; then
    increment fetch >/dev/null
    return 0
  fi
  command git "$@"
}

fingerprint() {
  printf '%s\n' "${fingerprint_value}"
}

post_status() {
  printf '%s %s %s\n' "$1" "$2" "$3" >>"${test_root}/statuses"
}

sleep() {
  increment sleep >/dev/null
}

gh() {
  local is_merge=false
  local argument
  for argument in "$@"; do
    if [[ ${argument} == PUT ]]; then
      is_merge=true
    fi
  done

  if [[ ${is_merge} == true ]]; then
    local merge_attempt
    merge_attempt=$(increment merge)
    if [[ ${mode} == retry_405 && ${merge_attempt} -eq 1 ]]; then
      echo 'gh: Pull Request has merge conflicts (HTTP 405)' >&2
      return 1
    fi
    printf '%s\n' '{"merged":true}'
    return 0
  fi

  local poll
  poll=$(increment poll)
  if [[ ${mode} == head_changed ]]; then
    printf '%s\n' '{"head":{"sha":"different-head"},"mergeable":true,"mergeable_state":"clean"}'
  elif [[ ${poll} -eq 1 ]]; then
    printf '%s\n' '{"head":{"sha":"expected-head"},"mergeable":null,"mergeable_state":"unknown"}'
  else
    printf '%s\n' '{"head":{"sha":"expected-head"},"mergeable":true,"mergeable_state":"clean"}'
  fi
}

merge_finalized_pr 6 expected-head expected-tip
[[ $(count poll) == 3 ]]
[[ $(count merge) == 2 ]]
[[ $(count fetch) == 3 ]]
[[ $(count sleep) == 2 ]]

rm -f "${test_root}"/{poll,merge,fetch,sleep,statuses}
mode=head_changed
if merge_finalized_pr 6 expected-head expected-tip; then
  echo "Expected a changed PR head to stop the merge." >&2
  exit 1
fi
[[ $(count merge) == 0 ]]

rm -f "${test_root}"/{poll,merge,fetch,sleep,statuses}
mode=retry_405
fingerprint_value=changed-tip
if merge_finalized_pr 6 expected-head expected-tip; then
  echo "Expected a changed main migration tip to stop the merge." >&2
  exit 1
fi
[[ $(count poll) == 0 ]]
[[ $(count merge) == 0 ]]

echo "GitHub mergeability retry tests passed."
