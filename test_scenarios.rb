#!/usr/bin/env ruby
# frozen_string_literal: true

# Test scenarios for reconcile_go_sum to find cases where it mistakenly
# removes or adds entries.
#
# Based on analysis of: https://github.com/dependabot/dependabot-core/issues/14872

require "set"

# The function under test (copied from reproduce_issue.rb)
def reconcile_go_sum(original_go_sum, updated_go_sum, updated_dependency_names)
  original_lines = original_go_sum.lines(chomp: true).reject(&:empty?)
  updated_lines = updated_go_sum.lines(chomp: true).reject(&:empty?)
  updated_set = updated_lines.to_set

  updated_modules = {}
  updated_lines.each do |line|
    parts = line.split(/\s+/, 3)
    next unless parts.length >= 2

    path = parts[0]
    version = parts[1].sub(%r{/go\.mod$}, "")
    (updated_modules[path] ||= Set.new).add(version)
  end

  original_zip_versions = {}
  original_lines.each do |line|
    next if line.include?("/go.mod h1:")

    parts = line.split(/\s+/, 3)
    next unless parts.length >= 2

    (original_zip_versions[parts[0]] ||= Set.new).add(parts[1])
  end

  restored_lines = original_lines.filter_map do |line|
    next unless line.include?("/go.mod h1:")
    next if updated_set.include?(line)

    module_path = line.split(/\s+/, 2).first
    next if updated_dependency_names.include?(module_path)

    match = line.match(%r{^(\S+)\s+(\S+)/go\.mod\s})
    next unless match

    version = match[2]
    has_zip = original_zip_versions.fetch(module_path, nil)&.include?(version)

    if has_zip
      versions = updated_modules.fetch(module_path, nil)
      next unless versions&.include?(version)
    else
      next unless updated_modules.fetch(module_path, nil)&.include?(version)
    end

    line
  end

  return updated_go_sum if restored_lines.empty?

  (updated_lines + restored_lines).sort.join("\n") + "\n"
end

# =============================================================================
# TEST HARNESS
# =============================================================================
$pass_count = 0
$fail_count = 0

def run_test(name:, original:, updated:, updated_deps:, expected_lines:, unexpected_lines: [])
  result = reconcile_go_sum(original, updated, Set.new(updated_deps))
  result_lines = result.lines(chomp: true).reject(&:empty?)

  passed = true

  expected_lines.each do |line|
    unless result_lines.include?(line)
      puts "  ❌ FAIL: #{name}"
      puts "     MISSING expected line: #{line}"
      passed = false
    end
  end

  unexpected_lines.each do |line|
    if result_lines.include?(line)
      puts "  ❌ FAIL: #{name}"
      puts "     UNEXPECTED line present: #{line}"
      passed = false
    end
  end

  if passed
    puts "  ✅ PASS: #{name}"
    $pass_count += 1
  else
    puts "     OUTPUT was:"
    result_lines.each { |l| puts "       #{l}" }
    $fail_count += 1
  end
end

puts "=" * 80
puts "SCENARIO TESTS FOR reconcile_go_sum"
puts "=" * 80
puts

# =============================================================================
# SCENARIO 1: FALSE RESTORATION — stale go.mod-only entry (version changed)
# =============================================================================
# BUG: Module had only a /go.mod entry at v1.0.0 (no zip hash).
# Updated graph has module at v2.0.0 (upgraded by something else).
# The function incorrectly restores the v1.0.0/go.mod line because it only
# checks updated_modules.key?(module_path), not the specific version.
# =============================================================================
puts "--- Scenario 1: False restoration of stale go.mod-only entry ---"

run_test(
  name: "Should NOT restore go.mod line for old version when module upgraded",
  original: <<~GOSUM,
    example.com/tools v1.0.0/go.mod h1:abc123=
    example.com/lib v1.0.0 h1:libhash1=
    example.com/lib v1.0.0/go.mod h1:libmod1=
    rsc.io/quote v1.4.0 h1:quotehash1=
    rsc.io/quote v1.4.0/go.mod h1:quotemod1=
  GOSUM
  updated: <<~GOSUM,
    example.com/tools v2.0.0 h1:newtoolshash=
    example.com/tools v2.0.0/go.mod h1:newtoolsmod=
    example.com/lib v1.0.0 h1:libhash1=
    example.com/lib v1.0.0/go.mod h1:libmod1=
    rsc.io/quote v1.5.2 h1:quotehash2=
    rsc.io/quote v1.5.2/go.mod h1:quotemod2=
  GOSUM
  updated_deps: ["rsc.io/quote"],
  expected_lines: [
    "example.com/tools v2.0.0 h1:newtoolshash=",
    "example.com/tools v2.0.0/go.mod h1:newtoolsmod="
  ],
  # This is the BUG: the old v1.0.0/go.mod should NOT be restored
  unexpected_lines: [
    "example.com/tools v1.0.0/go.mod h1:abc123="
  ]
)

puts

# =============================================================================
# SCENARIO 2: FALSE RESTORATION — module completely removed from graph
#             but shares path prefix with another module
# =============================================================================
# The module is gone from the dependency graph entirely. Its /go.mod line
# should NOT be restored. Tests that the function correctly skips it.
# =============================================================================
puts "--- Scenario 2: Module fully removed from dependency graph ---"

run_test(
  name: "Should NOT restore line for module no longer in graph",
  original: <<~GOSUM,
    github.com/removed/pkg v1.0.0 h1:removedhash=
    github.com/removed/pkg v1.0.0/go.mod h1:removedmod=
    github.com/kept/pkg v1.0.0 h1:kepthash=
    github.com/kept/pkg v1.0.0/go.mod h1:keptmod=
    rsc.io/quote v1.4.0 h1:quotehash=
    rsc.io/quote v1.4.0/go.mod h1:quotemod=
  GOSUM
  updated: <<~GOSUM,
    github.com/kept/pkg v1.0.0 h1:kepthash=
    github.com/kept/pkg v1.0.0/go.mod h1:keptmod=
    rsc.io/quote v1.5.2 h1:quotehash2=
    rsc.io/quote v1.5.2/go.mod h1:quotemod2=
  GOSUM
  updated_deps: ["rsc.io/quote"],
  expected_lines: [
    "github.com/kept/pkg v1.0.0 h1:kepthash=",
    "github.com/kept/pkg v1.0.0/go.mod h1:keptmod="
  ],
  unexpected_lines: [
    "github.com/removed/pkg v1.0.0 h1:removedhash=",
    "github.com/removed/pkg v1.0.0/go.mod h1:removedmod="
  ]
)

puts

# =============================================================================
# SCENARIO 3: CORRECT RESTORATION — the base case from issue #14872
# =============================================================================
# Module's zip hash is still in updated go.sum but /go.mod line was pruned.
# The function should restore the /go.mod line.
# =============================================================================
puts "--- Scenario 3: Correct restoration of pruned /go.mod line ---"

run_test(
  name: "Should restore /go.mod line when zip hash still present",
  original: <<~GOSUM,
    gonum.org/v1/gonum v0.16.0 h1:gonumhash=
    gonum.org/v1/gonum v0.16.0/go.mod h1:gonummod=
    rsc.io/quote v1.4.0 h1:quotehash=
    rsc.io/quote v1.4.0/go.mod h1:quotemod=
  GOSUM
  updated: <<~GOSUM,
    gonum.org/v1/gonum v0.16.0 h1:gonumhash=
    rsc.io/quote v1.5.2 h1:quotehash2=
    rsc.io/quote v1.5.2/go.mod h1:quotemod2=
  GOSUM
  updated_deps: ["rsc.io/quote"],
  expected_lines: [
    "gonum.org/v1/gonum v0.16.0 h1:gonumhash=",
    "gonum.org/v1/gonum v0.16.0/go.mod h1:gonummod=",
    "rsc.io/quote v1.5.2 h1:quotehash2=",
    "rsc.io/quote v1.5.2/go.mod h1:quotemod2="
  ],
  unexpected_lines: []
)

puts

# =============================================================================
# SCENARIO 4: Should NOT restore the UPDATED dependency's old checksum
# =============================================================================
# The dependency being updated (rsc.io/quote) had its version changed.
# Its old /go.mod line should NOT be restored even if the module path
# still exists in the graph (at the new version).
# =============================================================================
puts "--- Scenario 4: Should not restore updated dependency's old lines ---"

run_test(
  name: "Should NOT restore old /go.mod line for the dependency being updated",
  original: <<~GOSUM,
    rsc.io/quote v1.4.0 h1:oldhash=
    rsc.io/quote v1.4.0/go.mod h1:oldmod=
    golang.org/x/text v0.3.7 h1:texthash=
    golang.org/x/text v0.3.7/go.mod h1:textmod=
  GOSUM
  updated: <<~GOSUM,
    rsc.io/quote v1.5.2 h1:newhash=
    rsc.io/quote v1.5.2/go.mod h1:newmod=
    golang.org/x/text v0.3.7 h1:texthash=
    golang.org/x/text v0.3.7/go.mod h1:textmod=
  GOSUM
  updated_deps: ["rsc.io/quote"],
  expected_lines: [
    "rsc.io/quote v1.5.2 h1:newhash=",
    "rsc.io/quote v1.5.2/go.mod h1:newmod="
  ],
  unexpected_lines: [
    "rsc.io/quote v1.4.0 h1:oldhash=",
    "rsc.io/quote v1.4.0/go.mod h1:oldmod="
  ]
)

puts

# =============================================================================
# SCENARIO 5: NO-OP — nothing was pruned, output should match go tooling
# =============================================================================
# Go tooling didn't remove any /go.mod lines. The function should return
# the updated go.sum exactly as-is (no modifications).
# =============================================================================
puts "--- Scenario 5: No-op when nothing was pruned ---"

run_test(
  name: "Should return go tooling output unchanged when nothing pruned",
  original: <<~GOSUM,
    example.com/a v1.0.0 h1:ahash=
    example.com/a v1.0.0/go.mod h1:amod=
    rsc.io/quote v1.4.0 h1:quotehash=
    rsc.io/quote v1.4.0/go.mod h1:quotemod=
  GOSUM
  updated: <<~GOSUM,
    example.com/a v1.0.0 h1:ahash=
    example.com/a v1.0.0/go.mod h1:amod=
    rsc.io/quote v1.5.2 h1:quotehash2=
    rsc.io/quote v1.5.2/go.mod h1:quotemod2=
  GOSUM
  updated_deps: ["rsc.io/quote"],
  expected_lines: [
    "example.com/a v1.0.0 h1:ahash=",
    "example.com/a v1.0.0/go.mod h1:amod=",
    "rsc.io/quote v1.5.2 h1:quotehash2=",
    "rsc.io/quote v1.5.2/go.mod h1:quotemod2="
  ],
  unexpected_lines: []
)

puts

# =============================================================================
# SCENARIO 6: MULTIPLE DEPENDENCIES UPDATED
# =============================================================================
# Two dependencies are updated simultaneously. Neither's old /go.mod lines
# should be restored.
# =============================================================================
puts "--- Scenario 6: Multiple dependencies updated simultaneously ---"

run_test(
  name: "Should not restore old lines for any of the updated deps",
  original: <<~GOSUM,
    example.com/unrelated v1.0.0 h1:unrhash=
    example.com/unrelated v1.0.0/go.mod h1:unrmod=
    github.com/dep-a v1.0.0 h1:ahash=
    github.com/dep-a v1.0.0/go.mod h1:amod=
    github.com/dep-b v2.0.0 h1:bhash=
    github.com/dep-b v2.0.0/go.mod h1:bmod=
  GOSUM
  updated: <<~GOSUM,
    example.com/unrelated v1.0.0 h1:unrhash=
    github.com/dep-a v1.1.0 h1:ahash2=
    github.com/dep-a v1.1.0/go.mod h1:amod2=
    github.com/dep-b v2.1.0 h1:bhash2=
    github.com/dep-b v2.1.0/go.mod h1:bmod2=
  GOSUM
  updated_deps: ["github.com/dep-a", "github.com/dep-b"],
  expected_lines: [
    "example.com/unrelated v1.0.0 h1:unrhash=",
    "github.com/dep-a v1.1.0 h1:ahash2=",
    "github.com/dep-b v2.1.0 h1:bhash2="
  ],
  # Old versions should NOT be restored, and unrelated /go.mod SHOULD be restored
  unexpected_lines: [
    "github.com/dep-a v1.0.0/go.mod h1:amod=",
    "github.com/dep-b v2.0.0/go.mod h1:bmod="
  ]
)

puts

# =============================================================================
# SCENARIO 7: FALSE RESTORATION — multiple versions, old version no longer needed
# =============================================================================
# BUG: Original had module at v1.0.0 (go.mod-only, no zip hash) AND v1.1.0.
# Updated only has v1.1.0. The function checks updated_modules.key?(path)
# which is true (v1.1.0 exists), so it restores v1.0.0/go.mod — wrong!
# =============================================================================
puts "--- Scenario 7: False restoration of old version (go.mod-only, version upgraded) ---"

run_test(
  name: "Should NOT restore go.mod-only entry when only a newer version remains",
  original: <<~GOSUM,
    example.com/multi v1.0.0/go.mod h1:multimod1=
    example.com/multi v1.1.0 h1:multihash2=
    example.com/multi v1.1.0/go.mod h1:multimod2=
    rsc.io/quote v1.4.0 h1:quotehash=
    rsc.io/quote v1.4.0/go.mod h1:quotemod=
  GOSUM
  updated: <<~GOSUM,
    example.com/multi v1.1.0 h1:multihash2=
    example.com/multi v1.1.0/go.mod h1:multimod2=
    rsc.io/quote v1.5.2 h1:quotehash2=
    rsc.io/quote v1.5.2/go.mod h1:quotemod2=
  GOSUM
  updated_deps: ["rsc.io/quote"],
  expected_lines: [
    "example.com/multi v1.1.0 h1:multihash2=",
    "example.com/multi v1.1.0/go.mod h1:multimod2="
  ],
  # BUG: v1.0.0/go.mod should NOT be restored — that version is no longer needed
  unexpected_lines: [
    "example.com/multi v1.0.0/go.mod h1:multimod1="
  ]
)

puts

# =============================================================================
# SCENARIO 8: CORRECT — go.mod-only entry, module still at same version
# =============================================================================
# A module only had a /go.mod entry (no zip hash) and is still in the
# graph at the same version. Go tooling pruned it — should be restored.
# =============================================================================
puts "--- Scenario 8: Correct restoration of go.mod-only entry (same version) ---"

run_test(
  name: "Should restore go.mod-only line when module still at same version",
  original: <<~GOSUM,
    example.com/indirect v1.2.0/go.mod h1:indirectmod=
    example.com/main v1.0.0 h1:mainhash=
    example.com/main v1.0.0/go.mod h1:mainmod=
    rsc.io/quote v1.4.0 h1:quotehash=
    rsc.io/quote v1.4.0/go.mod h1:quotemod=
  GOSUM
  updated: <<~GOSUM,
    example.com/indirect v1.2.0 h1:indirecthash=
    example.com/main v1.0.0 h1:mainhash=
    example.com/main v1.0.0/go.mod h1:mainmod=
    rsc.io/quote v1.5.2 h1:quotehash2=
    rsc.io/quote v1.5.2/go.mod h1:quotemod2=
  GOSUM
  updated_deps: ["rsc.io/quote"],
  expected_lines: [
    # This is a valid restoration — module is at v1.2.0 in updated
    "example.com/indirect v1.2.0/go.mod h1:indirectmod="
  ],
  unexpected_lines: []
)

puts

# =============================================================================
# SCENARIO 9: FALSE ADDITION — restored line for replaced module
# =============================================================================
# A module was replaced via `replace` directive in go.mod. Go tooling
# correctly removed its checksum since it's replaced. But the replacement
# target might still have the module path in go.sum (at a different version
# or as an indirect dep). The function may incorrectly restore it.
# =============================================================================
puts "--- Scenario 9: Module was replaced, go tooling removed its checksum ---"

run_test(
  name: "Should NOT restore line if go tooling intentionally removed it (replaced module)",
  original: <<~GOSUM,
    github.com/original/mod v1.0.0 h1:orighash=
    github.com/original/mod v1.0.0/go.mod h1:origmod=
    github.com/fork/mod v1.0.1 h1:forkhash=
    github.com/fork/mod v1.0.1/go.mod h1:forkmod=
    rsc.io/quote v1.4.0 h1:quotehash=
    rsc.io/quote v1.4.0/go.mod h1:quotemod=
  GOSUM
  # After update: original/mod removed because it's now replaced by fork/mod
  # and its zip hash is also gone — module truly removed from graph
  updated: <<~GOSUM,
    github.com/fork/mod v1.0.1 h1:forkhash=
    github.com/fork/mod v1.0.1/go.mod h1:forkmod=
    rsc.io/quote v1.5.2 h1:quotehash2=
    rsc.io/quote v1.5.2/go.mod h1:quotemod2=
  GOSUM
  updated_deps: ["rsc.io/quote"],
  expected_lines: [
    "github.com/fork/mod v1.0.1 h1:forkhash=",
    "github.com/fork/mod v1.0.1/go.mod h1:forkmod="
  ],
  # Module is completely gone from graph — should NOT be restored
  unexpected_lines: [
    "github.com/original/mod v1.0.0 h1:orighash=",
    "github.com/original/mod v1.0.0/go.mod h1:origmod="
  ]
)

puts

# =============================================================================
# SCENARIO 10: Multiple /go.mod lines pruned for different unrelated modules
# =============================================================================
# Go tooling pruned /go.mod lines for multiple unrelated modules.
# All should be restored.
# =============================================================================
puts "--- Scenario 10: Multiple unrelated modules have /go.mod lines pruned ---"

run_test(
  name: "Should restore ALL pruned /go.mod lines for unrelated modules",
  original: <<~GOSUM,
    github.com/pkg-a v1.0.0 h1:pkgahash=
    github.com/pkg-a v1.0.0/go.mod h1:pkgamod=
    github.com/pkg-b v2.0.0 h1:pkgbhash=
    github.com/pkg-b v2.0.0/go.mod h1:pkgbmod=
    github.com/pkg-c v3.0.0 h1:pkgchash=
    github.com/pkg-c v3.0.0/go.mod h1:pkgcmod=
    rsc.io/quote v1.4.0 h1:quotehash=
    rsc.io/quote v1.4.0/go.mod h1:quotemod=
  GOSUM
  # Go tooling pruned /go.mod for pkg-a and pkg-c but kept pkg-b
  updated: <<~GOSUM,
    github.com/pkg-a v1.0.0 h1:pkgahash=
    github.com/pkg-b v2.0.0 h1:pkgbhash=
    github.com/pkg-b v2.0.0/go.mod h1:pkgbmod=
    github.com/pkg-c v3.0.0 h1:pkgchash=
    rsc.io/quote v1.5.2 h1:quotehash2=
    rsc.io/quote v1.5.2/go.mod h1:quotemod2=
  GOSUM
  updated_deps: ["rsc.io/quote"],
  expected_lines: [
    "github.com/pkg-a v1.0.0/go.mod h1:pkgamod=",
    "github.com/pkg-c v3.0.0/go.mod h1:pkgcmod="
  ],
  unexpected_lines: []
)

puts

# =============================================================================
# SCENARIO 11: Zip hash removed but /go.mod line also removed
# =============================================================================
# Both the zip hash AND the /go.mod line for a module were removed.
# This means the module is truly gone. Should NOT restore.
# =============================================================================
puts "--- Scenario 11: Both zip hash and /go.mod removed (module gone) ---"

run_test(
  name: "Should NOT restore /go.mod when zip hash is also gone from updated",
  original: <<~GOSUM,
    example.com/transient v1.0.0 h1:transhash=
    example.com/transient v1.0.0/go.mod h1:transmod=
    rsc.io/quote v1.4.0 h1:quotehash=
    rsc.io/quote v1.4.0/go.mod h1:quotemod=
  GOSUM
  updated: <<~GOSUM,
    rsc.io/quote v1.5.2 h1:quotehash2=
    rsc.io/quote v1.5.2/go.mod h1:quotemod2=
  GOSUM
  updated_deps: ["rsc.io/quote"],
  expected_lines: [
    "rsc.io/quote v1.5.2 h1:quotehash2="
  ],
  unexpected_lines: [
    "example.com/transient v1.0.0 h1:transhash=",
    "example.com/transient v1.0.0/go.mod h1:transmod="
  ]
)

puts

# =============================================================================
# SCENARIO 12: Version downgraded as side effect
# =============================================================================
# A module was at v1.2.0 in original. After update, it's downgraded to v1.1.0
# (perhaps a constraint change). The old v1.2.0/go.mod should NOT be restored.
# =============================================================================
puts "--- Scenario 12: Module version downgraded as side effect ---"

run_test(
  name: "Should NOT restore /go.mod for old version when module was downgraded",
  original: <<~GOSUM,
    example.com/dep v1.2.0 h1:dephash12=
    example.com/dep v1.2.0/go.mod h1:depmod12=
    rsc.io/quote v1.4.0 h1:quotehash=
    rsc.io/quote v1.4.0/go.mod h1:quotemod=
  GOSUM
  # Module downgraded to v1.1.0
  updated: <<~GOSUM,
    example.com/dep v1.1.0 h1:dephash11=
    example.com/dep v1.1.0/go.mod h1:depmod11=
    rsc.io/quote v1.5.2 h1:quotehash2=
    rsc.io/quote v1.5.2/go.mod h1:quotemod2=
  GOSUM
  updated_deps: ["rsc.io/quote"],
  expected_lines: [
    "example.com/dep v1.1.0 h1:dephash11=",
    "example.com/dep v1.1.0/go.mod h1:depmod11="
  ],
  # Old version should NOT be restored — it's been downgraded
  unexpected_lines: [
    "example.com/dep v1.2.0 h1:dephash12=",
    "example.com/dep v1.2.0/go.mod h1:depmod12="
  ]
)

puts

# =============================================================================
# RESULTS
# =============================================================================
puts "=" * 80
puts "RESULTS: #{$pass_count} passed, #{$fail_count} failed"
puts "=" * 80

if $fail_count > 0
  puts
  puts "ANALYSIS OF FAILURES:"
  puts "  Scenarios 1, 7: The go.mod-only branch (has_zip=false) only checks"
  puts "  if the module PATH exists in the updated graph, not if the specific"
  puts "  VERSION is still needed. This causes stale /go.mod lines to be"
  puts "  incorrectly restored when a module was upgraded to a new version."
  puts
  puts "  Scenario 12: When a module is downgraded, the old version's zip hash"
  puts "  is no longer in the updated graph, so has_zip check correctly prevents"
  puts "  restoration. This scenario may pass depending on whether the version"
  puts "  match logic catches it."
  puts
  puts "SUGGESTED FIX for the go.mod-only branch:"
  puts "  Change: next unless updated_modules.fetch(module_path, nil)&.include?(version)"
  puts "  To:     next unless updated_modules.fetch(module_path, nil)&.include?(version)"
  puts "  This ensures the specific version is still in the graph, not just any version."
end

exit($fail_count > 0 ? 1 : 0)
