# Issue #14872: Dependabot unexpectedly removes go.mod checksums from go.sum

## Problem

When Dependabot updates a Go dependency, the Go tooling (`go get`, `go mod tidy`) can
prune `/go.mod` checksum entries from `go.sum` for **unrelated** modules. This causes
Dependabot PRs to unexpectedly remove hash entries that `go mod tidy` would normally keep.

## Repository Structure

```
├── reproduce_issue.rb        # Demonstrates the bug and fix
├── test_scenarios.rb         # 12 scenario tests for reconcile_go_sum
├── reconcile_and_update.rb   # Standalone reconcile script (used in CI)
├── go_project/
│   ├── go.mod                # Sample Go module file
│   └── go.sum                # Sample checksums file
├── .github/
│   └── workflows/
│       ├── ci.yml            # Runs reproduction + test scenarios
│       └── reconcile-gosum.yml  # Auto-reconciles and opens PR on go.mod change
```

## How to reproduce the bug

```bash
ruby reproduce_issue.rb
```

## Run test scenarios

```bash
ruby test_scenarios.rb
```

This runs 12 scenarios verifying the reconcile logic handles:
- Correct restoration of pruned `/go.mod` lines
- No false restoration for removed/upgraded/downgraded modules
- Multiple dependencies updated simultaneously
- go.mod-only entries (no zip hash)

## Automated Workflow: Reconcile & PR

The workflow (`.github/workflows/reconcile-gosum.yml`) triggers when `go_project/go.mod`
is modified. It:

1. **Detects** which dependencies were updated in `go.mod`
2. **Runs** `go mod tidy` to update `go.sum` via Go tooling
3. **Reconciles** `go.sum` using `reconcile_and_update.rb` — restores `/go.mod` checksum
   lines that Go tooling incorrectly pruned for unrelated modules
4. **Opens a PR** with the corrected `go.sum` if changes were needed

### Manual trigger

You can also trigger the workflow manually via `workflow_dispatch`:

```bash
gh workflow run reconcile-gosum.yml \
  -f dependency="rsc.io/quote" \
  -f version="v1.5.2"
```

## How the fix works

The `reconcile_go_sum` function compares the original `go.sum` with what Go tooling
produced and restores `/go.mod` checksum lines that were pruned, but only when:

1. The line is a `/go.mod` checksum (not a zip hash)
2. The module is **not** the dependency being updated
3. The module+version is still present in the dependency graph

## References

- Issue: https://github.com/dependabot/dependabot-core/issues/14872
- Fix PR: https://github.com/dependabot/dependabot-core/pull/15056
