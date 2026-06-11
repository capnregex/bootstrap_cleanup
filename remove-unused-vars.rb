#!/usr/bin/env ruby
# Remove unused Sass variable definitions from a file using tmp/unused_variables.yaml.
#
# Usage: ruby remove-unused-vars.rb <file> [--dry-run] [--yaml PATH]

require "optparse"
require "pathname"
require "set"
require "yaml"

options = { dry_run: false, yaml: File.join(__dir__, "tmp", "unused_variables.yaml") }

OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} <file> [--dry-run] [--yaml PATH]"
  opts.on("--dry-run", "Show changes without modifying the file") { options[:dry_run] = true }
  opts.on("--yaml PATH", "Unused-variables YAML (default: tmp/unused_variables.yaml)") { |p| options[:yaml] = p }
end.parse!

target = ARGV[0]
unless target
  warn "Error: filename argument required"
  warn "Usage: ruby #{$0} <file> [--dry-run] [--yaml PATH]"
  exit 1
end

unless File.exist?(options[:yaml])
  warn "Error: #{options[:yaml]} not found"
  exit 1
end

unless File.exist?(target)
  warn "Error: #{target} not found"
  exit 1
end

project_root = __dir__
target_rel = Pathname.new(File.expand_path(target, project_root)).relative_path_from(Pathname.new(project_root)).to_s

def locations_match?(defined_in, target_rel)
  defined_in == target_rel || defined_in.end_with?("/#{target_rel}")
end

data = YAML.load_file(options[:yaml])
vars_to_remove = {}

(Array(data[:vars]) + Array(data["vars"])).each do |entry|
  name = entry[:name] || entry["name"]
  defined_in = entry[:defined_in] || entry["defined_in"] || []
  defined_in.each do |loc|
    file, _line = loc.to_s.split(":", 2)
    vars_to_remove[name] = true if locations_match?(file, target_rel)
  end
end

if vars_to_remove.empty?
  puts "No unused variables to remove from #{target_rel}."
  exit 0
end

VAR_DEF_RE = /\$([\w-]+)\s*:/

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
    next unless vars_to_remove[match[1]]

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

lines = File.readlines(target)
to_delete = lines_to_delete(lines, vars_to_remove)

removed_vars = []
lines.each_with_index do |line, idx|
  next unless to_delete.include?(idx)

  var = line.match(/^\s*#{VAR_DEF_RE.source}/)&.[](1)
  removed_vars << var if var
end
removed_vars.uniq!

if removed_vars.empty?
  puts "No matching variable definitions found in #{target_rel}."
  exit 0
end

if options[:dry_run]
  puts "[DRY RUN] Would remove #{removed_vars.size} unused variables (#{to_delete.size} lines) from #{target_rel}:"
  removed_vars.first(20).each { |v| puts "  $#{v}" }
  puts "  ..." if removed_vars.size > 20
  exit 0
end

new_content = +""
lines.each_with_index do |line, idx|
  new_content << line unless to_delete.include?(idx)
end

File.write(target, new_content)
puts "Removed #{removed_vars.size} unused variables (#{to_delete.size} lines) from #{target_rel}:"
removed_vars.first(20).each { |v| puts "  $#{v}" }
puts "  ..." if removed_vars.size > 20