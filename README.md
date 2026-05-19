# Issue #14872: Dependabot unexpectedly removes go.mod checksums from go.sum

## Problem

When Dependabot updates a Go dependency, the Go tooling (`go get`, `go mod tidy`) can
prune `/go.mod` checksum entries from `go.sum` for **unrelated** modules. This causes
Dependabot PRs to unexpectedly remove hash entries that `go mod tidy` would normally keep.

## How to reproduce

Run the demonstration script:

```bash
ruby reproduce_issue.rb
```

## What the script shows

1. **INPUT**: The original `go.sum` with checksums for all modules
2. **PROCESS**: Go tooling updates the target dependency and prunes an unrelated `/go.mod` line
3. **OUTPUT (without fix)**: The unrelated checksum is lost — this is the bug
4. **OUTPUT (with fix)**: The `reconcile_go_sum` method restores the improperly removed line

## References

- Issue: https://github.com/dependabot/dependabot-core/issues/14872
- Fix PR: https://github.com/dependabot/dependabot-core/pull/15056
