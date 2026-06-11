#!/usr/bin/env ruby
# Scans SCSS files and migrates `@import` to `@use`/`@forward` per
# https://sass-lang.com/documentation/breaking-changes/import/
#
# Usage: ruby convert-sass-imports.rb [--dry-run] [--verbose]

require "optparse"
require "set"
require "yaml"

dry_run = false
verbose = false
OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} [--dry-run] [--verbose]"
  opts.on("--dry-run", "Show changes without modifying files") { dry_run = true }
  opts.on("--verbose", "Show detailed progress") { verbose = true }
end.parse!

# ── file classification ────────────────────────────────────────────────

def file_kind(path, content)
  # Classify a scss file by what it contains
  lines = content.lines
  non_blank = lines.reject { |l| l.strip.empty? || l.strip.start_with?("//") || l.strip.start_with?("/*") || l.strip.start_with?("*") }

  has_css = false
  has_vars = false
  has_mixins = false
  has_functions = false
  has_imports = false

  non_blank.each do |l|
    stripped = l.strip
    next if stripped.start_with?("@use ") || stripped.start_with?("@forward ") || stripped.start_with?("@import ")
    next if stripped.start_with?("//") || stripped.start_with?("/*")
    next if stripped.start_with?("@if ") || stripped.start_with?("@else") || stripped.start_with?("@each ") || stripped.start_with?("@for ") || stripped.start_with?("@while ")
    next if stripped == "}" || stripped.start_with?("} ") || stripped.start_with?("}}")
    next if stripped.start_with?("@at-root ")

    if stripped.match?(/^\$[\w-]+\s*:/)
      has_vars = true
    elsif stripped.match?(/^@mixin\s+/)
      has_mixins = true
    elsif stripped.match?(/^@function\s+/)
      has_functions = true
    else
      has_css = true
    end
  end

  non_blank.each do |l|
    stripped = l.strip
    has_imports = true if stripped.start_with?("@import ")
  end

  {
    has_css: has_css,
    has_vars: has_vars,
    has_mixins: has_mixins,
    has_functions: has_functions,
    has_imports: has_imports,
    is_aggregator: has_imports && !has_css && !has_vars && !has_mixins && !has_functions,
    is_variable_file: has_vars && !has_css && !has_mixins && !has_functions,
    is_mixin_file: has_mixins && !has_css && !has_vars && !has_functions,
    is_function_file: has_functions && !has_css && !has_vars && !has_mixins,
  }
end

# ── member tracking ────────────────────────────────────────────────────

# Collect variable names from a file content
def extract_variables(content)
  content.scan(/^\s*\$([\w-]+)\s*:/).flatten.uniq
end

def extract_mixins(content)
  content.scan(/^\s*@mixin\s+([\w-]+)/).flatten.uniq
end

def extract_functions(content)
  content.scan(/^\s*@function\s+([\w-]+)/).flatten.uniq
end

# Check if a line uses variables (has $var references)
def references_variables?(line)
  line.match?(/\$[\w-]+/)
end

# Check if a line uses a mixin
def references_mixins?(line)
  line.match?(/@include\s+[\w-]+/)
end

# ── @import parsing ────────────────────────────────────────────────────

CSS_IMPORT_RE = /\A\s*@import\s+(?:url\s*\(|"https?:\/\/|'https?:\/\/|"[^"]+\.css"|'[^']+\.css')/
SASS_IMPORT_RE = /\A\s*@import\s+(.+?)\s*;\s*\z/

# Parse a single @import line, returning:
#   { type: :css, value: "..." } for CSS imports
#   { type: :sass, paths: ["a", "b"] } for Sass imports (may be multi)
def parse_import(line)
  stripped = line.strip
  return nil unless stripped.start_with?("@import")

  if stripped.match?(/url\(/) || stripped.match?(/"https?:\/\//) || stripped.match?(/'https?:\/\//) ||
     stripped.match?(/"[^"]+\.css"/) || stripped.match?(/'[^']+\.css'/)
    return { type: :css, value: stripped }
  end

  # Extract the path(s) between @import and ;
  m = stripped.match(/\A@import\s+(.+?);\z/)
  return nil unless m

  # Split by commas, respecting quotes and parens
  imports_part = m[1]
  paths = split_import_paths(imports_part)
  { type: :sass, paths: paths }
end

def split_import_paths(str)
  paths = []
  buf = ""
  depth = 0
  in_str = false
  str_delim = nil

  str.each_char do |ch|
    if in_str
      if ch == "\\" && buf[-1] != "\\"  # simplistic escape skip
        buf << ch; next
      elsif ch == str_delim
        in_str = false
      end
      buf << ch; next
    end
    if ch == '"' || ch == "'"
      in_str = true
      str_delim = ch
      buf << ch
      next
    end
    if ch == "("
      depth += 1
      buf << ch
      next
    end
    if ch == ")"
      depth -= 1
      buf << ch
      next
    end
    if ch == "," && depth == 0 && !in_str
      paths << buf.strip.gsub(/\A["']|["']\z/, "")
      buf = ""
      next
    end
    buf << ch
  end
  paths << buf.strip.gsub(/\A["']|["']\z/, "") unless buf.strip.empty?
  paths
end

# ── import path resolution ─────────────────────────────────────────────

def resolve_import_path(import_path, source_file)
  # Given an import like "bootstrap/variables" from "assets/stylesheets/bootstrap/_mixins.scss"
  # return the expected path to the file relative to the project root
  dir = File.dirname(source_file)
  segments = import_path.split("/")
  partial_name = segments.pop
  # Sass resolves imports by looking for _partial.scss or partial.scss
  # We can't know the exact resolution without full load path info, but we can guess
  candidate_path = File.join(dir, *segments, "_#{partial_name}.scss")
  if File.exist?(candidate_path)
    return candidate_path
  end
  candidate_path = File.join(dir, *segments, "#{partial_name}.scss")
  if File.exist?(candidate_path)
    return candidate_path
  end
  nil
end

# ── leaf file analysis ─────────────────────────────────────────────────

def scan_for_references(content, known_vars, known_mixins)
  # Check each line for variable/mixin references from other files
  needs_vars = false
  needs_mixins = false

  content.each_line do |line|
    stripped = line.strip
    next if stripped.start_with?("//") || stripped.start_with?("/*") || stripped.start_with?("*")
    next if stripped.start_with?("@import ") || stripped.start_with?("@use ") || stripped.start_with?("@forward ")

    if line.match?(/\$[\w-]+/)
      needs_vars = true
    end

    if line.match?(/@include\s+[\w-]+/)
      needs_mixins = true
    end
  end

  { needs_vars: needs_vars, needs_mixins: needs_mixins }
end

# ── main migration ─────────────────────────────────────────────────────

files = Dir.glob("**/*.scss").reject { |f| f.include?("/vendor/") || f.include?("/node_modules/") }

# Phase 1: Classify all files and index their exports
puts "Scanning #{files.size} files..." if verbose

file_kinds = {}
file_exports = {}  # file_path => { vars: [...], mixins: [...], funcs: [...] }
files.each do |f|
  content = File.read(f)
  file_kinds[f] = file_kind(f, content)
  file_exports[f] = {
    vars: extract_variables(content),
    mixins: extract_mixins(content),
    funcs: extract_functions(content),
  }
end

# Phase 2: Process each file that has @import
all_changes = []
reports = []  # human-readable report lines

files.each do |file|
  content = File.read(file)
  lines = content.lines
  kind = file_kinds[file]

  # Skip files with no @import
  next unless kind[:has_imports]

  # Collect all @import lines and their replacements
  new_lines = []
  import_conversions = []  # { orig_line:, new_lines: [], line_num: }
  css_imports = []  # preserved CSS imports
  nested_imports = []  # can't auto-fix

  lines.each_with_index do |line, idx|
    parsed = parse_import(line)
    next if parsed.nil?

    if parsed[:type] == :css
      css_imports << { line: line, line_num: idx + 1 }
      new_lines << line
      next
    end

    # Sass import
    entry = { orig_line: line, line_num: idx + 1, new_lines: [] }
    parsed[:paths].each do |path|
      # Aggregator files (only imports, no code): use @forward to re-export members.
      # All other files: use @use "... as *" to preserve global availability.
      if kind[:is_aggregator]
        entry[:new_lines] << "@forward \"#{path}\";"
      else
        entry[:new_lines] << "@use \"#{path}\" as *;"
      end
    end
    import_conversions << entry
    new_lines << nil  # placeholder, will be removed
  end

  next if import_conversions.empty? && css_imports.empty?

  # Build the new file content
  # Strategy: replace @import lines with @use/@forward, collect at top position
  # Insert before the first non-comment, non-@use, non-@import line (or at file start)

  if import_conversions.any?
    # Build replacement lines
    new_use_lines = import_conversions.flat_map { |e| e[:new_lines].map { |nl| "#{nl}\n" } }
    new_use_lines.uniq!

    # Remove all @import lines and build the new file
    updated_lines = lines.reject.with_index { |_l, i| import_conversions.any? { |e| e[:line_num] - 1 == i } }

    # Find insertion point: after the last existing @use/@forward line,
    # or after the leading comment block, or at line 0.
    insert_idx = 0
    updated_lines.each_with_index do |l, i|
      stripped = l.strip
      if stripped.start_with?("@use ") || stripped.start_with?("@forward ")
        insert_idx = i + 1
      elsif stripped.empty? || stripped.start_with?("//") || stripped.start_with?("/*") || stripped.start_with?("*")
        # skip comments/blanks — insertion_idx only advances if nothing else found yet
        insert_idx = i + 1 if insert_idx == i
      else
        # first content line — stop
        break
      end
    end

    # Insert new @use lines at insert_idx
    new_use_lines.each { |nl| updated_lines.insert(insert_idx, nl) }

    new_content = updated_lines.join("")

    unless dry_run
      File.write(file, new_content)
    end

    import_conversions.each do |entry|
      entry[:new_lines].each do |nl|
        reports << { file: file, line: entry[:line_num], old: entry[:orig_line].strip, new: nl }
      end
    end
  end
end

# Phase 3: Add @use to leaf files that reference variables/mixins from external files
# For bootstrap-sass: add @use "variables" as * and @use "mixins" as * to each leaf component
leaf_additions = []

files.each do |file|
  kind = file_kinds[file]
  # Skip files that already have @import (already processed) or aggregators
  next if kind[:has_imports]
  next if kind[:is_aggregator] || kind[:is_variable_file] || kind[:is_mixin_file] || kind[:is_function_file]

  content = File.read(file)
  refs = scan_for_references(content, nil, nil)

  needed = []
  if refs[:needs_vars]
    # Find the variables file relative to this file's directory
    dir = File.dirname(file)
    var_candidates = [
      File.join(dir, "_variables.scss"),
      File.join(dir, "variables.scss"),
    ]
    var_candidates.each do |c|
      if File.exist?(c)
        # Compute relative import path
        rel = Pathname.new(c).relative_path_from(Pathname.new(dir)).to_s.sub(/\A_/, "").sub(/\.scss\z/, "")
        # But the import path used by @use is relative to the source file's directory
        # Actually @use paths are relative to the file, so we need "./variables" or "variables"
        needed << "@use \"#{rel}\" as *;" unless content.include?("@use \"#{rel}\"")
        break
      end
    end
  end

  if refs[:needs_mixins]
    dir = File.dirname(file)
    mixin_candidates = [
      File.join(dir, "_mixins.scss"),
      File.join(dir, "mixins.scss"),
    ]
    mixin_candidates.each do |c|
      if File.exist?(c)
        rel = Pathname.new(c).relative_path_from(Pathname.new(dir)).to_s.sub(/\A_/, "").sub(/\.scss\z/, "")
        needed << "@use \"#{rel}\" as *;" unless content.include?("@use \"#{rel}\"")
        break
      end
    end
  end

  next if needed.empty?

  # Insert @use statements at top
  lines = content.lines
  insert_idx = 0
  # Skip comment block at top
  while insert_idx < lines.length && (lines[insert_idx].strip.empty? || lines[insert_idx].strip.start_with?("//") || lines[insert_idx].strip.start_with?("/*") || lines[insert_idx].strip.start_with?("*"))
    insert_idx += 1
  end

  lines.insert(insert_idx, needed.map { |n| "#{n}\n" }.join)

  unless dry_run
    File.write(file, lines.join)
  end

  needed.each do |n|
    leaf_additions << { file: file, line: insert_idx + 1, new: n.strip }
  end
end

# ── output ──────────────────────────────────────────────────────────────

if reports.empty? && leaf_additions.empty?
  puts "No @import statements found."
else
  if reports.any?
    puts "#{dry_run ? "[DRY RUN] " : ""}@import → @use/@forward conversions in #{reports.map { |r| r[:file] }.uniq.size} files:\n\n"
    reports.group_by { |r| r[:file] }.each do |file, changes|
      puts "  #{file}:"
      changes.each { |c| puts "    L#{c[:line]}  #{c[:old]} → #{c[:new]}" }
      puts
    end
  end

  if leaf_additions.any?
    puts "#{dry_run ? "[DRY RUN] " : ""}@use imports added to #{leaf_additions.map { |r| r[:file] }.uniq.size} leaf files:\n\n"
    leaf_additions.group_by { |r| r[:file] }.each do |file, additions|
      puts "  #{file}:"
      additions.each { |a| puts "    + #{a[:new]}" }
      puts
    end
  end

  total = reports.size + leaf_additions.size
  puts "(#{total} total changes)"
end
