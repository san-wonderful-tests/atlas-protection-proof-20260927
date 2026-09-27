# Migration coordinator burst test

This is an isolated copy of `atlas-migration-coordinator-lab` under `san-wonderful-tests`. It tests whether the coordinator protocol survives a burst of ten migration PRs from the same `main` commit, representative of a busy monorepo. Each PR adds a distinct Atlas SQL data migration without changing the desired schema.

Acceptance criteria:

1. Ten PRs labeled `db-ready` nearly simultaneously all eventually finalize and merge without manual retries.
2. `main` contains each of the ten SQL files exactly once, all after the original baseline migrations and in valid Atlas order.
3. Every merge is preceded by checksum and SQL execution validation against the then-current `main` tip, with a success status on the exact finalized head.
4. No queued PR is lost when GitHub Actions coalesces or cancels pending workflow runs.
5. Report elapsed time, successful/failed/cancelled runs, and GitHub API or runner limits encountered.

The experiment is deliberately not a production deployment. GitHub's current private-repository plan cannot enforce this lab's branch ruleset; coordinator behavior is assessed from workflow logs, PR state, and final migration history.
