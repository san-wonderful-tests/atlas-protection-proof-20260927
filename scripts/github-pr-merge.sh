#!/usr/bin/env bash

# Merge a coordinator-validated PR only after GitHub has observed the pushed
# head and recomputed mergeability. GitHub's mergeability result is asynchronous
# and can briefly return a stale HTTP 405 immediately after a branch update.
merge_finalized_pr() {
  local pr_number=$1
  local expected_head_sha=$2
  local expected_base_fingerprint=$3
  local max_attempts=${MERGEABILITY_MAX_ATTEMPTS:-30}
  local poll_seconds=${MERGEABILITY_POLL_SECONDS:-2}
  local attempt metadata current_head mergeable mergeable_state
  local current_base_fingerprint merge_output merge_exit merged

  if ! [[ ${max_attempts} =~ ^[1-9][0-9]*$ ]]; then
    echo "MERGEABILITY_MAX_ATTEMPTS must be a positive integer." >&2
    return 1
  fi
  if ! [[ ${poll_seconds} =~ ^[0-9]+$ ]]; then
    echo "MERGEABILITY_POLL_SECONDS must be a non-negative integer." >&2
    return 1
  fi

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if ! git fetch origin main --prune; then
      echo "Could not refresh main while waiting for GitHub mergeability." >&2
      return 1
    fi
    if ! current_base_fingerprint=$(fingerprint origin/main); then
      echo "Could not fingerprint main while waiting for GitHub mergeability." >&2
      return 1
    fi
    if [[ ${current_base_fingerprint} != "${expected_base_fingerprint}" ]]; then
      echo "The migration tip changed while GitHub was computing mergeability." >&2
      return 1
    fi

    if ! metadata=$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${pr_number}"); then
      echo "Could not read PR #${pr_number} while waiting for GitHub mergeability." >&2
      return 1
    fi
    if ! current_head=$(jq -er '.head.sha' <<<"${metadata}"); then
      echo "GitHub returned PR metadata without a head SHA." >&2
      return 1
    fi
    if [[ ${current_head} != "${expected_head_sha}" ]]; then
      echo "PR head changed from ${expected_head_sha} to ${current_head}; refusing to merge." >&2
      return 1
    fi

    if ! mergeable=$(jq -er 'if .mergeable == null then "unknown" else (.mergeable | tostring) end' <<<"${metadata}"); then
      echo "GitHub returned invalid PR mergeability metadata." >&2
      return 1
    fi
    if ! mergeable_state=$(jq -er '.mergeable_state // "unknown"' <<<"${metadata}"); then
      echo "GitHub returned invalid PR mergeability state." >&2
      return 1
    fi
    if [[ ${mergeable} == true ]]; then
      merge_exit=0
      merge_output=$(
        gh api --method PUT "repos/${GITHUB_REPOSITORY}/pulls/${pr_number}/merge" \
          -f merge_method=squash \
          -f sha="${expected_head_sha}" 2>&1
      ) || merge_exit=$?

      if [[ ${merge_exit} -eq 0 ]]; then
        if ! merged=$(jq -er '.merged | tostring' <<<"${merge_output}"); then
          echo "GitHub returned an invalid merge response:" >&2
          echo "${merge_output}" >&2
          return 1
        fi
        if [[ ${merged} == true ]]; then
          return 0
        fi
        echo "GitHub returned a successful response without merging the PR:" >&2
        jq . <<<"${merge_output}" >&2
        return 1
      fi

      if ! grep -Eq 'HTTP 405|status.?405' <<<"${merge_output}"; then
        echo "GitHub rejected the finalized merge:" >&2
        echo "${merge_output}" >&2
        return 1
      fi

      echo "GitHub still has stale mergeability for ${expected_head_sha}; retrying after HTTP 405 (${attempt}/${max_attempts})."
    else
      echo "Waiting for GitHub mergeability for ${expected_head_sha}: ${mergeable}/${mergeable_state} (${attempt}/${max_attempts})."
    fi

    if ((attempt < max_attempts)); then
      sleep "${poll_seconds}"
    fi
  done

  echo "GitHub did not accept the finalized merge after ${max_attempts} attempts." >&2
  return 1
}
