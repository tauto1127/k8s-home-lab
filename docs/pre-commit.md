# Pre-commit secret scanning

This repository runs Gitleaks 8.30.1 as a pre-commit hook. The hook invokes the
Aqua-managed binary and scans the staged Git diff, not unstaged working-tree
content. Gitleaks redacts findings at 100%; the hook does not enable verbose
source output.

Setup:

    aqua install
    aqua exec -- pre-commit install

Run the staged hook manually (the normal commit-time check):

    aqua exec -- pre-commit run

This hook intentionally scans only the staged Git index. `--all-files` only
asks pre-commit to invoke the hook for every configured file; this repository's
hook ignores those filenames and still runs Gitleaks with `--staged`, so it is
not a full-tree scan.

Run a separate full working-tree scan when you need repository-wide coverage:

    aqua exec -- gitleaks dir --redact=100 --no-banner --no-color .

The Aqua registry and both tool versions are pinned in `aqua.yaml` and
`.pre-commit-config.yaml`. The regression test first proves a clean staged
fixture passes, then proves a staged synthetic canary is rejected without
disclosing its value:

    ruby scripts/test-pre-commit.rb

If the hook is intentionally bypassed, the equivalent CI check still runs on
pull requests.
