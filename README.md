# Atlas migration coordinator lab

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
   `main` has not changed, publishes `Atlas Finalized`, and squash-merges the PR.

Other pull requests are not serialized. A push to `main` that changes the Atlas
inputs invalidates outstanding migration statuses.

## Live race test

Two demonstration pull requests can be created from the same `main` revision.
Both will contain a valid but mutually conflicting `atlas.sum`.

Add `db-ready` to both PRs in quick succession. The coordinator workflows share
the `atlas-migration-coordinator` concurrency group:

- The first PR is finalized and merged.
- The second workflow then fetches the new migration tip, rebases its migration
  to sort last, validates the combined history, and merges.
- No engineer resolves `atlas.sum` manually.

The `Actions` tab shows the lease and every safety check. The pull request's
commit list shows the bot-generated merge/rebase commit.

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

For Wonderful, the same protocol should be owned by a narrowly scoped GitHub
App. The App should be the only integration allowed to publish
`Atlas Finalized` and merge migration PRs.
