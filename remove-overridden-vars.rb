#!/usr/bin/env ruby
# Remove from a defaults SCSS file any variable definitions that are also
# defined in an overrides SCSS file.
#
# Usage: ruby remove-overridden-vars.rb <defaults> <overrides> [--dry-run]

require "optparse"
require "pathname"
require "set"

options = { dry_run: false }

OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} <defaults> <overrides> [--dry-run]"
  opts.on("--dry-run", "Show changes without modifying defaults") { options[:dry_run] = true }
end.parse!

defaults = ARGV[0]
overrides = ARGV[1]

unless defaults && overrides
  warn "Error: defaults and overrides filenames required"
  warn "Usage: ruby #{$0} <defaults> <overrides> [--dry-run]"
  exit 1
end

defaults_path = File.expand_path(defaults)
overrides_path = File.expand_path(overrides)

unless File.exist?(defaults_path)
  warn "Error: defaults file not found: #{defaults}"
  exit 1
end

unless File.exist?(overrides_path)
  warn "Error: overrides file not found: #{overrides}"
  exit 1
end

def display_path(path)
  Pathname.new(path).cleanpath
    .relative_path_from(Pathname.new(Dir.pwd).cleanpath).to_s
rescue ArgumentError
  path
end

VAR_DEF_RE = /\$([\w-]+)\s*:/

def extract_defined_variables(lines)
  defined = Set.new
  lines.each do |line|
    line.scan(/^\s*#{VAR_DEF_RE.source}/) { defined << $1 }
  end
  defined
end

def scan_depth_and_strings(text, depth:, in_str:, str_delim:)
  text.each_char do |ch|
    if in_str
      if ch == "\\"
        next
      elsif ch == str_delim
        in_str = false
        str_delim = nil
      end
      next
    end

    case ch
    when '"', "'"
      in_str = true
      str_delim = ch
    when "(", "[", "{"
      depth += 1
    when ")", "]", "}"
      depth -= 1 if depth > 0
    end
  end

  [depth, in_str, str_delim]
end

def statement_complete?(line, depth:, in_str:)
  return false unless depth.zero? && !in_str

  code = line.chomp.sub(/\s*\/\/.*\z/, "").rstrip
  code.end_with?(";")
end

def statement_range(lines, start_idx)
  depth = 0
  in_str = false
  str_delim = nil

  (start_idx...lines.length).each do |i|
    depth, in_str, str_delim = scan_depth_and_strings(lines[i], depth: depth, in_str: in_str, str_delim: str_delim)
    next unless statement_complete?(lines[i], depth: depth, in_str: in_str)

    return start_idx..i
  end

  start_idx..start_idx
end

def meaningful_line?(line)
  stripped = line.strip
  return false if stripped.empty?
  return false if stripped == "{"
  return false if stripped == "}"
  return false if stripped.match?(/\A\}\s*@else\b/)

  true
end

def if_block_range(lines, if_idx)
  depth = 0
  in_str = false
  str_delim = nil
  started = false

  (if_idx...lines.length).each do |i|
    lines[i].each_char do |ch|
      if in_str
        if ch == "\\"
          next
        elsif ch == str_delim
          in_str = false
          str_delim = nil
        end
        next
      end

      case ch
      when '"', "'"
        in_str = true
        str_delim = ch
      when "{"
        depth += 1
        started = true
      when "}"
        depth -= 1 if depth > 0
      end
    end

    return if_idx..i if started && depth.zero? && !in_str
  end

  if_idx..if_idx
end

def expand_preceding_comments(lines, to_delete)
  extra = Set.new

  to_delete.sort.each do |idx|
    i = idx - 1
    while i >= 0
      stripped = lines[i].strip
      break if stripped.empty?
      break unless stripped.start_with?("//")

      extra << i
      i -= 1
    end
  end

  to_delete.merge(extra)
end

def lines_to_delete(lines, vars_to_remove)
  to_delete = Set.new

  lines.each_with_index do |line, idx|
    match = line.match(/^\s*#{VAR_DEF_RE.source}/)
    next unless match
    next unless vars_to_remove.include?(match[1])

    statement_range(lines, idx).each { |i| to_delete << i }
  end

  changed = true
  while changed
    changed = false
    lines.each_with_index do |line, idx|
      next unless line.strip.start_with?("@if ")

      range = if_block_range(lines, idx)
      inner = (range.begin + 1...range.end).select { |i| meaningful_line?(lines[i]) }
      next if inner.empty?
      next unless inner.all? { |i| to_delete.include?(i) }

      before = to_delete.size
      range.each { |i| to_delete << i }
      changed = true if to_delete.size > before
    end
  end

  expand_preceding_comments(lines, to_delete)
  to_delete
end

overrides_lines = File.readlines(overrides_path)
overridden_vars = extract_defined_variables(overrides_lines)

if overridden_vars.empty?
  puts "No variable definitions found in #{display_path(overrides_path)}."
  exit 0
end

defaults_lines = File.readlines(defaults_path)
defaults_vars = extract_defined_variables(defaults_lines)
vars_to_remove = overridden_vars & defaults_vars

if vars_to_remove.empty?
  puts "No overridden variables to remove from #{display_path(defaults_path)}."
  exit 0
end

to_delete = lines_to_delete(defaults_lines, vars_to_remove)

removed_vars = []
defaults_lines.each_with_index do |line, idx|
  next unless to_delete.include?(idx)

  var = line.match(/^\s*#{VAR_DEF_RE.source}/)&.[](1)
  removed_vars << var if var
end
removed_vars.uniq!

only_in_overrides = overridden_vars - defaults_vars
if only_in_overrides.any?
  warn "Note: #{only_in_overrides.size} variable(s) defined in overrides but not in defaults (left unchanged):"
  only_in_overrides.sort.first(10).each { |v| warn "  $#{v}" }
  warn "  ..." if only_in_overrides.size > 10
end

defaults_display = display_path(defaults_path)
overrides_display = display_path(overrides_path)

if options[:dry_run]
  puts "[DRY RUN] Would remove #{removed_vars.size} overridden variables (#{to_delete.size} lines) from #{defaults_display}:"
  puts "  (defined in #{overrides_display})"
  removed_vars.first(20).each { |v| puts "  $#{v}" }
  puts "  ..." if removed_vars.size > 20
  exit 0
end

new_content = +""
defaults_lines.each_with_index do |line, idx|
  new_content << line unless to_delete.include?(idx)
end

File.write(defaults_path, new_content)
puts "Removed #{removed_vars.size} overridden variables (#{to_delete.size} lines) from #{defaults_display}:"
puts "  (defined in #{overrides_display})"
removed_vars.first(20).each { |v| puts "  $#{v}" }
puts "  ..." if removed_vars.size > 20