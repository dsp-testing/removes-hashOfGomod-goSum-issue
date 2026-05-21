#!/usr/bin/env ruby
# frozen_string_literal: true

# reconcile_and_update.rb
#
# This script:
# 1. Reads the current go.mod to determine which dependencies were updated
# 2. Reads the original go.sum (from git) and the updated go.sum (from go tooling)
# 3. Applies reconcile_go_sum to preserve unrelated /go.mod checksum lines
# 4. Writes the corrected go.sum back to disk
#
# Usage: ruby reconcile_and_update.rb <go_project_dir> <updated_dep_1> [<updated_dep_2> ...]

require "set"

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
      # go.mod-only entry — restore if module+version still in graph
      next unless updated_modules.fetch(module_path, nil)&.include?(version)
    end

    line
  end

  return updated_go_sum if restored_lines.empty?

  (updated_lines + restored_lines).sort.join("\n") + "\n"
end

# =============================================================================
# MAIN
# =============================================================================
if __FILE__ == $PROGRAM_NAME
  if ARGV.length < 2
    puts "Usage: ruby reconcile_and_update.rb <go_project_dir> <dep1> [<dep2> ...]"
    puts "Example: ruby reconcile_and_update.rb ./go_project rsc.io/quote"
    exit 1
  end

  project_dir = ARGV[0]
  updated_deps = Set.new(ARGV[1..])

  go_sum_path = File.join(project_dir, "go.sum")

  unless File.exist?(go_sum_path)
    puts "ERROR: #{go_sum_path} not found"
    exit 1
  end

  # Get the original go.sum from git (before any changes)
  original_go_sum = `git show HEAD:#{go_sum_path} 2>/dev/null`
  if $?.exitstatus != 0
    puts "WARNING: Could not get original go.sum from git, using current file"
    original_go_sum = File.read(go_sum_path)
  end

  # The current file on disk is the "updated" version (after go tooling ran)
  updated_go_sum = File.read(go_sum_path)

  puts "Reconciling go.sum in #{project_dir}..."
  puts "  Updated dependencies: #{updated_deps.to_a.join(', ')}"

  result = reconcile_go_sum(original_go_sum, updated_go_sum, updated_deps)

  if result == updated_go_sum
    puts "  No changes needed — go.sum is already correct."
  else
    File.write(go_sum_path, result)
    original_count = original_go_sum.lines.reject { |l| l.strip.empty? }.count
    updated_count = updated_go_sum.lines.reject { |l| l.strip.empty? }.count
    final_count = result.lines.reject { |l| l.strip.empty? }.count
    puts "  Restored #{final_count - updated_count} pruned /go.mod checksum line(s)"
    puts "  Lines: original=#{original_count}, go_tooling=#{updated_count}, final=#{final_count}"
  end

  puts "Done."
end
