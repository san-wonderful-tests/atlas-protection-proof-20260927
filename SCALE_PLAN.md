# Migration coordinator burst test

This is an isolated copy of `atlas-migration-coordinator-lab` under `san-wonderful-tests`. It tests whether the coordinator protocol survives a burst of ten migration PRs from the same `main` commit, representative of a busy monorepo. Each PR adds a distinct Atlas SQL data migration without changing the desired schema.

Acceptance criteria:

1. Ten PRs labeled `db-ready` nearly simultaneously all eventually finalize and merge without manual retries.
2. `main` contains each of the ten SQL files exactly once, all after the original baseline migrations and in valid Atlas order.
3. Every merge is preceded by checksum and SQL execution validation against the then-current `main` tip, with a success status on the exact finalized head.
4. No queued PR is lost when GitHub Actions coalesces or cancels pending workflow runs.
5. Report elapsed time, successful/failed/cancelled runs, and GitHub API or runner limits encountered.

The experiment is deliberately not a production deployment. GitHub's current private-repository plan cannot enforce this lab's branch ruleset; coordinator behavior is assessed from workflow logs, PR state, and final migration history.

## Live results

The first burst exposed two defects in the original one-PR-per-event implementation. Of ten simultaneous `db-ready` labels, GitHub [canceled eight pending coordinator runs](https://github.com/san-wonderful-tests/atlas-migration-scale-proof-20260927/actions/workflows/migration-coordinator.yml); one PR merged and another run failed after GitHub briefly reported the old PR head following a bot push. A first queue-draining revision then [failed](https://github.com/san-wonderful-tests/atlas-migration-scale-proof-20260927/actions/runs/36316278207) because its Issues API call lacked token permission, and process substitution hid the API error. The revision now scans the PR API with explicit error propagation, drains every ready PR in one worker, and waits for GitHub to observe the finalized head. [Recovery run 36316416715](https://github.com/san-wonderful-tests/atlas-migration-scale-proof-20260927/actions/runs/36316416715) merged the nine remaining PRs in 113 seconds. The final directory contained ten distinct first-burst SQL files and passed `atlas migrate validate`.

The **fresh burst against the repaired coordinator** passed: [run 36316607643](https://github.com/san-wonderful-tests/atlas-migration-scale-proof-20260927/actions/runs/36316607643) found ten ready PRs and merged [PRs #11–#20](https://github.com/san-wonderful-tests/atlas-migration-scale-proof-20260927/pulls?q=is%3Apr+is%3Amerged) without intervention, despite GitHub cancelling most individual label-event runs. The worker reported `Processed 10 PR(s), failed 0, elapsed 99s`; the full run took 129 seconds. `main` contains all twenty burst SQL files exactly once and its Atlas checksum validates. This is a throughput observation for tiny no-op data migrations, not a projection for real production DDL or the monorepo's full CI.

A [duplicate workflow dispatch](https://github.com/san-wonderful-tests/atlas-migration-scale-proof-20260927/actions/runs/36316749311) found zero ready PRs and made no changes. The history safety test, [PR #21](https://github.com/san-wonderful-tests/atlas-migration-scale-proof-20260927/pull/21), attempted to edit an existing migration. [The coordinator rejected it](https://github.com/san-wonderful-tests/atlas-migration-scale-proof-20260927/actions/runs/36316802479) before pushing or merging, posted failure, and removed `db-ready`.

## Release decision

**No-go for Wonderful deployment yet.** This coordinator handles one migration directory. The [separate two-directory test](https://github.com/san-wonderful-tests/atlas-autorebase-proof-20260927/pull/3) demonstrates why the official one-directory action cannot simply be repeated when two checksums conflict in one merge. The coordinator's `GITHUB_TOKEN` bot pushes also do not trigger ordinary PR CI: for the finalized head of [PR #20](https://github.com/san-wonderful-tests/atlas-migration-scale-proof-20260927/pull/20), GitHub returned zero check runs, although the coordinator's own migration validation and `Atlas Finalized` status succeeded. Production needs enforced checks on the exact finalized SHA, a trusted narrowly scoped credential, five-directory handling, and a durable recovery trigger for runner failures. This private org plan cannot enforce the intended branch ruleset, so the lab cannot prove merge-gate enforcement.
