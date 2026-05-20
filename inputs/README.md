# Input / Output Files

## inputs/

### `original_go.sum`
The go.sum file BEFORE Dependabot runs. Contains checksums for all modules including:
- `gonum.org/v1/gonum v0.16.0` — both zip hash (`h1:`) and `/go.mod` hash
- `rsc.io/quote v1.4.0` — the dependency being updated
- Other unrelated modules

### `go_tooling_output_go.sum`
What Go tooling (`go get rsc.io/quote@v1.5.2`) produces on disk.
Notice the **missing line**: `gonum.org/v1/gonum v0.16.0/go.mod h1:...`

The zip hash line (`gonum.org/v1/gonum v0.16.0 h1:...`) is still present,
proving the module is still in the dependency graph — only the `/go.mod`
checksum was incorrectly pruned.

## outputs/

### `without_fix_go.sum`
What Dependabot would commit WITHOUT the fix — identical to `go_tooling_output_go.sum`.
The unrelated `/go.mod` checksum is lost. This causes CI to fail when running `go mod tidy`.

### `with_fix_go.sum`
What Dependabot commits WITH the fix (`reconcile_go_sum`).
The `gonum.org/v1/gonum v0.16.0/go.mod` line is restored in sorted order.

## Diff showing the bug

```diff
  gonum.org/v1/gonum v0.16.0 h1:JKbmSgVMFkFMDpGCixMRJCMEMmNhrsJuJqVDPMGPnQY=
- gonum.org/v1/gonum v0.16.0/go.mod h1:fef3am4MQ93R2HHpKnLk4/Tbh/s0+wqD5nfa6Pnwy4E=  ← REMOVED BY BUG
+ gonum.org/v1/gonum v0.16.0/go.mod h1:fef3am4MQ93R2HHpKnLk4/Tbh/s0+wqD5nfa6Pnwy4E=  ← RESTORED BY FIX
```
