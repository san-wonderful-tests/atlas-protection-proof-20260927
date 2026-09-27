# Atlas branch protection proof

This public synthetic repository tests GitHub's required-status enforcement for
the Atlas migration coordinator. It is separate from the private
[scale experiment](https://github.com/san-wonderful-tests/atlas-migration-scale-proof-20260927)
because this organization's plan does not enforce rulesets on private repos.

The active `main` ruleset is `24073500`. It requires pull requests, squash
merges, and two status contexts: `Atlas Finalized` and `Atlas CI`. Required
checks are **strict**, so a PR behind `main` must be updated and tested again.
The committed [ruleset definition](.github/main-ruleset.json) records that
configuration.

The coordinator uses a trusted workflow from `main` to resolve permitted
`atlas.sum` conflicts and validate migration history. It pushes a finalized
head, dispatches read-only CI on that exact SHA, and merges only after both
required statuses succeed. The [scale report](https://github.com/san-wonderful-tests/atlas-migration-scale-proof-20260927/blob/main/SCALE_PLAN.md)
describes the implementation, test matrix, and remaining production gaps.

## Enforcement evidence

- [PR #1](https://github.com/san-wonderful-tests/atlas-protection-proof-20260927/pull/1): GitHub rejected a merge with failed required checks (HTTP 405).
- [PR #4](https://github.com/san-wonderful-tests/atlas-protection-proof-20260927/pull/4): a rewritten coordinator head passed both required contexts and merged.
- [PR #6](https://github.com/san-wonderful-tests/atlas-protection-proof-20260927/pull/6): with strict checks disabled, an unrelated `main` change landed during CI and the old-base head still merged. This exposed a correctness gap.
- [PR #8](https://github.com/san-wonderful-tests/atlas-protection-proof-20260927/pull/8): with strict checks enabled, GitHub rejected that stale-base state despite green head statuses. [Re-finalization](https://github.com/san-wonderful-tests/atlas-protection-proof-20260927/actions/runs/36320770044) and [CI on the exact new SHA](https://github.com/san-wonderful-tests/atlas-protection-proof-20260927/actions/runs/36320801542) then passed and the PR merged.

This proves enforcement on small synthetic PRs. Wonderful's five Atlas
directories, full monorepo CI, and 300-PR/day scale have not been proven. The
[test plan](https://github.com/san-wonderful-tests/atlas-autorebase-proof-20260927/blob/main/TEST_PLAN.md)
records the remaining acceptance cases. The current release decision is
**no-go for Wonderful deployment**.
