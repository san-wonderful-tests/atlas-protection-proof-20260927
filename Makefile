ATLAS_VERSION := v1.2.0

.PHONY: atlas-diff atlas-hash atlas-validate test

atlas-diff:
	@if [ -z "$(NAME)" ]; then echo "Usage: make atlas-diff NAME=description"; exit 1; fi
	atlas migrate diff --env local "$(NAME)"

atlas-hash:
	atlas migrate hash --env local

atlas-validate:
	atlas migrate validate --env local

test:
	bash -n scripts/check-migration-history.sh scripts/finalize-migration-pr.sh scripts/github-pr-merge.sh scripts/process-ready-migration-prs.sh scripts/wait-finalized-ci.sh tests/history-gate-test.sh tests/github-pr-merge-test.sh
	bash tests/history-gate-test.sh
	bash tests/github-pr-merge-test.sh
