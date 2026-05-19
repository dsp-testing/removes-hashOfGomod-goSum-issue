#!/usr/bin/env ruby
# frozen_string_literal: true

# Reproduction of https://github.com/dependabot/dependabot-core/issues/14872
#
# Demonstrates that the old code path in GoModUpdater simply returned whatever
# go tooling produced, losing unrelated /go.mod checksum lines from go.sum.

puts "=" * 80
puts "REPRODUCING ISSUE #14872: Dependabot removes unrelated go.mod checksums"
puts "=" * 80
puts

# =============================================================================
# SCENARIO
# =============================================================================
# We are updating: rsc.io/quote from v1.4.0 to v1.5.2
# Unrelated module: gonum.org/v1/gonum v0.16.0 (has both zip hash and /go.mod hash)
#
# Go tooling (go get / go mod tidy) sometimes prunes the /go.mod checksum line
# for gonum.org/v1/gonum even though it's still in the dependency graph.
# Running `go mod tidy` afterward would re-add it.

# =============================================================================
# INPUT: Original go.sum before Dependabot runs
# =============================================================================
original_go_sum = <<~GOSUM
  gonum.org/v1/gonum v0.16.0 h1:JKbmSgVMFkFMDpGCixMRJCMEMmNhrsJuJqVDPMGPnQY=
  gonum.org/v1/gonum v0.16.0/go.mod h1:fef3am4MQ93R2HHpKnLk4/Tbh/s0+wqD5nfa6Pnwy4E=
  golang.org/x/text v0.3.0/go.mod h1:NqM8EUOU14njkJ3fqMW+pc6Ldnwhi/IjpwHt7yyuwOQ=
  golang.org/x/text v0.3.7 h1:olpwvP2KacW1ZWvsR7uQhoyTYvKAupfQrRGBFM352Gk=
  golang.org/x/text v0.3.7/go.mod h1:u+2+/6zg+i71rQMx5EYifcz6MCKuco9NR6JIITiCfzQ=
  rsc.io/quote v1.4.0 h1:tYuJspOzwTRMUOX6qmSDRTEKFVV80GM0/l89OLZuVNg=
  rsc.io/quote v1.4.0/go.mod h1:S2vMDfxMfk+OGQ7xf1uNqJCSuSPCW5QC127LHYfOJmQ=
  rsc.io/sampler v1.0.0 h1:CZX0Ury6np11Lwls9Jja2rFf3YrNPeUPAWiEVrJ0u/4=
  rsc.io/sampler v1.0.0/go.mod h1:cqxpM3ZVz9VtirqxZPmrWzkQ+UkiNiGtkrN+B+i8kx8=
GOSUM

puts "INPUT: Original go.sum (before Dependabot update)"
puts "-" * 80
puts original_go_sum
puts

# =============================================================================
# PROCESS: Go tooling updates rsc.io/quote and PRUNES gonum /go.mod line
# =============================================================================
# This is what `go get rsc.io/quote@v1.5.2` + `go mod tidy` produces on disk.
# Notice: gonum.org/v1/gonum v0.16.0/go.mod line is MISSING even though the
# zip hash (h1:) line is still present — the module is still needed!
updated_go_sum_from_go_tooling = <<~GOSUM
  gonum.org/v1/gonum v0.16.0 h1:JKbmSgVMFkFMDpGCixMRJCMEMmNhrsJuJqVDPMGPnQY=
  golang.org/x/text v0.3.0/go.mod h1:NqM8EUOU14njkJ3fqMW+pc6Ldnwhi/IjpwHt7yyuwOQ=
  golang.org/x/text v0.3.7 h1:olpwvP2KacW1ZWvsR7uQhoyTYvKAupfQrRGBFM352Gk=
  golang.org/x/text v0.3.7/go.mod h1:u+2+/6zg+i71rQMx5EYifcz6MCKuco9NR6JIITiCfzQ=
  rsc.io/quote v1.5.2 h1:w5fcysjrx7yqtD/aO+QwRjYZOKnaM9Uh2b40tElTs3Y=
  rsc.io/quote v1.5.2/go.mod h1:LzX7hefJvL54yjefDEDHNONMoOzP4AKkY4Xfn703+fY=
  rsc.io/sampler v1.0.0 h1:CZX0Ury6np11Lwls9Jja2rFf3YrNPeUPAWiEVrJ0u/4=
  rsc.io/sampler v1.0.0/go.mod h1:cqxpM3ZVz9VtirqxZPmrWzkQ+UkiNiGtkrN+B+i8kx8=
GOSUM

puts "PROCESS: Go tooling output (after `go get rsc.io/quote@v1.5.2`)"
puts "-" * 80
puts updated_go_sum_from_go_tooling
puts

# =============================================================================
# OUTPUT WITHOUT FIX (old behavior)
# =============================================================================
# The old code simply did: updated_go_sum = File.read("go.sum")
# No reconciliation — whatever Go tooling produced is what Dependabot committed.

def old_behavior(updated_go_sum)
  # This is all the old code did — return go tooling's output directly
  updated_go_sum
end

result_without_fix = old_behavior(updated_go_sum_from_go_tooling)

removed_line = "gonum.org/v1/gonum v0.16.0/go.mod h1:fef3am4MQ93R2HHpKnLk4/Tbh/s0+wqD5nfa6Pnwy4E="

puts "OUTPUT WITHOUT FIX (old behavior — the bug):"
puts "-" * 80
puts result_without_fix
puts
if result_without_fix.include?(removed_line)
  puts "  Result: Line preserved ✅"
else
  puts "  ❌ BUG REPRODUCED!"
  puts "  Missing line: #{removed_line}"
  puts
  puts "  The gonum.org/v1/gonum /go.mod checksum was removed even though:"
  puts "    - gonum is NOT the dependency being updated"
  puts "    - gonum's zip hash (h1:) is still in go.sum (module still needed)"
  puts "    - Running `go mod tidy` would re-add this line"
  puts
  puts "  This is exactly what issue #14872 reports."
end

puts
puts "=" * 80

# =============================================================================
# OUTPUT WITH FIX (reconcile_go_sum)
# =============================================================================
# The fix compares original vs updated go.sum and restores /go.mod checksum
# lines that were removed for modules NOT being updated but still in the graph.

def reconcile_go_sum(original_go_sum, updated_go_sum, updated_dependency_names)
  original_lines = original_go_sum.lines(chomp: true).reject(&:empty?)
  updated_lines = updated_go_sum.lines(chomp: true).reject(&:empty?)
  updated_set = updated_lines.to_set

  # Build map of module_path -> Set[versions] from updated go.sum
  updated_modules = {}
  updated_lines.each do |line|
    parts = line.split(/\s+/, 3)
    next unless parts.length >= 2

    path = parts[0]
    version = parts[1].sub(%r{/go\.mod$}, "")
    (updated_modules[path] ||= Set.new).add(version)
  end

  # Build map of module_path -> Set[versions] for zip hash lines in original
  original_zip_versions = {}
  original_lines.each do |line|
    next if line.include?("/go.mod h1:")

    parts = line.split(/\s+/, 3)
    next unless parts.length >= 2

    (original_zip_versions[parts[0]] ||= Set.new).add(parts[1])
  end

  # Find /go.mod checksum lines that should be restored
  restored_lines = original_lines.filter_map do |line|
    next unless line.include?("/go.mod h1:")  # only consider /go.mod lines
    next if updated_set.include?(line)        # already in updated go.sum

    module_path = line.split(/\s+/, 2).first
    next if updated_dependency_names.include?(module_path)  # skip updated deps

    # Extract version from /go.mod line
    match = line.match(%r{^(\S+)\s+(\S+)/go\.mod\s})
    next unless match

    version = match[2]
    has_zip = original_zip_versions.fetch(module_path, nil)&.include?(version)

    if has_zip
      # Module had a zip hash — only restore if module+version still in graph
      versions = updated_modules.fetch(module_path, nil)
      next unless versions&.include?(version)
    else
      # go.mod-only entry — restore if module is still referenced at all
      next unless updated_modules.key?(module_path)
    end

    line
  end

  return updated_go_sum if restored_lines.empty?

  (updated_lines + restored_lines).sort.join("\n") + "\n"
end

result_with_fix = reconcile_go_sum(
  original_go_sum,
  updated_go_sum_from_go_tooling,
  Set["rsc.io/quote"]  # the dependency being updated
)

puts
puts "OUTPUT WITH FIX (reconcile_go_sum):"
puts "-" * 80
puts result_with_fix
puts
if result_with_fix.include?(removed_line)
  puts "  ✅ FIX WORKS! The unrelated checksum line is preserved."
  puts "  Restored: #{removed_line}"
else
  puts "  ❌ Line still missing"
end

puts
puts "=" * 80
puts
puts "SUMMARY:"
puts "  Without fix: go.sum loses unrelated /go.mod checksums → CI fails on `go mod tidy`"
puts "  With fix:    reconcile_go_sum detects and restores improperly pruned lines"
puts
puts "  The fix only restores lines where:"
puts "    1. The line is a /go.mod checksum (not a zip hash)"
puts "    2. The module is NOT the dependency being updated"
puts "    3. The module is still present in the dependency graph"
