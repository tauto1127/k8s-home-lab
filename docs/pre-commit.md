# Pre-commit secret scanning

This repository runs Gitleaks 8.30.1 as a pre-commit hook. The hook invokes the
Aqua-managed binary and scans the staged Git diff, not unstaged working-tree
content. Gitleaks redacts findings at 100%; the hook does not enable verbose
source output.

Setup:

    aqua install
    aqua exec -- pre-commit install

Run the same check manually against all repository files:

    aqua exec -- pre-commit run --all-files

The Aqua registry and both tool versions are pinned in `aqua.yaml` and
`.pre-commit-config.yaml`. The regression test also proves that a staged
synthetic canary is rejected without disclosing its value:

    aqua exec -- ruby scripts/test-pre-commit.rb

If the hook is intentionally bypassed, the equivalent CI check still runs on
pull requests.
