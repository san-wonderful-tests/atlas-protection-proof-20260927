# Atlas migration coordinator lab

> This repository is an isolated copy used for the 2026-09-27 concurrency experiment. See [SCALE_PLAN.md](SCALE_PLAN.md) for the current live results and deployment gaps. The historical PR links below refer to the original coordinator lab.

This private repository demonstrates how to serialize Atlas migration pull
requests without enabling GitHub Merge Queue.

The repository deliberately keeps Atlas's committed `atlas.sum` integrity file.
Migration pull requests cannot merge until a trusted workflow has rebased their
new migration files onto the current migration tip, validated the resulting
history, and published the `Atlas Finalized` commit status.

## The flow

1. A developer changes `schema.hcl` and runs `make atlas-diff NAME=...`.
2. The pull request receives a pending `Atlas Finalized` status.
3. A maintainer adds the `db-ready` label.
4. The migration coordinator takes a repository-wide Actions concurrency lease.
5. It merges the latest `main` into the branch, automatically resolves an
   `atlas.sum`-only conflict, and runs `atlas migrate rebase` for only the SQL
   files added by that pull request.
6. It validates immutable history, ordering, checksums, SQL execution, and
   desired-schema drift against PostgreSQL 17. Atlas Pro migration lint also
   runs when an `ATLAS_TOKEN` repository secret is configured.
7. It pushes the finalized migration commit, verifies that the migration tip on
   `main` has not changed, publishes `Atlas Finalized`, waits for GitHub to
   recompute mergeability for the exact pushed SHA, and squash-merges the PR.

Other pull requests are not serialized. A push to `main` that changes the Atlas
inputs invalidates outstanding migration statuses.

## Live race test

Two draft exercise pull requests are ready from the same `main` revision. Both
contain a valid but mutually conflicting `atlas.sum`:

- [PR #5: add task due timestamp](https://github.com/san-wonderful-tests/atlas-migration-coordinator-lab/pull/5)
- [PR #6: add project archive timestamp](https://github.com/san-wonderful-tests/atlas-migration-coordinator-lab/pull/6)

Mark both ready for review, then add `db-ready` to both PRs in quick succession.
The coordinator workflows share the `atlas-migration-coordinator` concurrency
group:

- The first PR is finalized and merged.
- The second workflow then fetches the new migration tip, rebases its migration
  to sort last, validates the combined history, and merges.
- No engineer resolves `atlas.sum` manually.

The `Actions` tab shows the lease and every safety check. The pull request's
commit list shows the bot-generated merge/rebase commit.

The setup has already completed one clean race: [PR #3](https://github.com/san-wonderful-tests/atlas-migration-coordinator-lab/pull/3)
merged first, then [PR #4](https://github.com/san-wonderful-tests/atlas-migration-coordinator-lab/pull/4)
rebased its migration onto the new tip, replayed the combined history, and
merged. [PR #1](https://github.com/san-wonderful-tests/atlas-migration-coordinator-lab/pull/1)
also demonstrates the negative path: the coordinator rejected a real
`schema.hcl` conflict instead of silently resolving anything beyond
`atlas.sum`.

## GitHub plan limitation

GitHub does not allow rulesets on private repositories in this organization's
current plan. The workflows still publish and consume `Atlas Finalized`, but
GitHub cannot yet require that status before every merge. The intended ruleset
is committed at `.github/main-ruleset.json` and can be enabled after making the
repository public or upgrading the organization plan.

Do not treat the lab's currently unprotected `main` as the production security
model. The coordinator protocol is live; enforcement of the exclusive merge
path is the one unavailable piece.

## Local commands

Atlas is pinned to `v1.2.0` in GitHub Actions.

```bash
make atlas-diff NAME=add_example_column
make atlas-hash
make atlas-validate
make test
```

`make atlas-diff` uses a disposable PostgreSQL 17 dev database through Docker.
`atlas migrate lint` became an Atlas Pro feature in current CLI releases, so it
is deliberately optional rather than making the lab depend on an Atlas Cloud
account.

## Safety boundary

This is a lab implementation, not a production credential model. It uses the
repository `GITHUB_TOKEN` and executes only the finalizer script from protected
`main`; it never executes shell code from the pull request. Candidate SQL is
applied only to an isolated PostgreSQL service container.

A branch update made by the repository `GITHUB_TOKEN` produces an
approval-required `pull_request` CI run by GitHub design. The lab coordinator
therefore performs the same migration validation in its trusted job before
publishing `Atlas Finalized`. A production GitHub App token should trigger the
ordinary post-update CI run instead.

For Wonderful, the same protocol should be owned by a narrowly scoped GitHub
App. The App should be the only integration allowed to publish
`Atlas Finalized` and merge migration PRs.

Synthetic code-only main advance for A17.
