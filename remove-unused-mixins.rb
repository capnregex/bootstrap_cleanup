#!/usr/bin/env ruby
# Remove unused Sass mixin definitions using tmp/unused-mixins.yaml.
# Only edits mixin definitions in files under the specified directory.
#
# Usage: ruby remove-unused-mixins.rb <directory> [--dry-run] [--yaml PATH]

require "optparse"
require "pathname"
require "set"
require "yaml"

options = { dry_run: false, yaml: File.join(__dir__, "tmp", "unused-mixins.yaml") }

OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} <directory> [--dry-run] [--yaml PATH]"
  opts.on("--dry-run", "Show changes without modifying files") { options[:dry_run] = true }
  opts.on("--yaml PATH", "Unused-mixins YAML (default: tmp/unused-mixins.yaml)") { |p| options[:yaml] = p }
end.parse!

directory = ARGV[0]
unless directory
  warn "Error: directory argument required"
  warn "Usage: ruby #{$0} <directory> [--dry-run] [--yaml PATH]"
  exit 1
end

unless File.exist?(options[:yaml])
  warn "Error: #{options[:yaml]} not found"
  exit 1
end

dir_path = File.expand_path(directory)

unless File.directory?(dir_path)
  warn "Error: directory not found: #{directory}"
  exit 1
end

begin
  dir_rel = Pathname.new(dir_path).cleanpath
    .relative_path_from(Pathname.new(Dir.pwd).cleanpath).to_s
rescue ArgumentError
  dir_rel = dir_path
end

def display_path(path)
  Pathname.new(path).cleanpath
    .relative_path_from(Pathname.new(Dir.pwd).cleanpath).to_s
rescue ArgumentError
  path
end

def file_in_directory?(file, dir_rel)
  normalized_file = file.tr("\\", "/")
  normalized_dir = dir_rel.tr("\\", "/").sub(%r{/\z}, "")
  normalized_file == normalized_dir || normalized_file.start_with?("#{normalized_dir}/")
end

data = YAML.load_file(options[:yaml])
mixins_by_file = Hash.new { |h, k| h[k] = Set.new }

(Array(data[:mixins]) + Array(data["mixins"])).each do |entry|
  name = entry[:name] || entry["name"]
  defined_in = entry[:defined_in] || entry["defined_in"] || []
  defined_in.each do |file|
    mixins_by_file[file] << name if file_in_directory?(file, dir_rel)
  end
end

if mixins_by_file.empty?
  puts "No unused mixins to remove under #{dir_rel}."
  exit 0
end

MIXIN_DEF_RE = /@mixin\s+([\w-]+)/

def mixin_block_range(lines, start_idx)
  depth = 0
  in_str = false
  str_delim = nil
  started = false

  (start_idx...lines.length).each do |i|
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

    return start_idx..i if started && depth.zero? && !in_str
  end

  start_idx..start_idx
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

def lines_to_delete(lines, mixins_to_remove)
  to_delete = Set.new

  lines.each_with_index do |line, idx|
    match = line.match(/^\s*#{MIXIN_DEF_RE.source}/)
    next unless match
    next unless mixins_to_remove.include?(match[1])

    mixin_block_range(lines, idx).each { |i| to_delete << i }
  end

  expand_preceding_comments(lines, to_delete)
  to_delete
end

total_removed = 0
total_lines = 0
changed_files = []

mixins_by_file.sort.each do |file, mixins_to_remove|
  file_path = File.expand_path(file)
  unless File.exist?(file_path)
    warn "Warning: skipping missing file #{file}"
    next
  end

  lines = File.readlines(file_path)
  to_delete = lines_to_delete(lines, mixins_to_remove)

  removed_mixins = []
  lines.each_with_index do |line, idx|
    next unless to_delete.include?(idx)

    mixin = line.match(/^\s*#{MIXIN_DEF_RE.source}/)&.[](1)
    removed_mixins << mixin if mixin
  end
  removed_mixins.uniq!

  next if removed_mixins.empty?

  file_display = display_path(file_path)
  changed_files << file_display

  if options[:dry_run]
    puts "  #{file_display}:"
    removed_mixins.each { |m| puts "    @mixin #{m}" }
    total_removed += removed_mixins.size
    total_lines += to_delete.size
    next
  end

  new_content = +""
  lines.each_with_index do |line, idx|
    new_content << line unless to_delete.include?(idx)
  end

  File.write(file_path, new_content)
  puts "  #{file_display}:"
  removed_mixins.each { |m| puts "    @mixin #{m}" }
  total_removed += removed_mixins.size
  total_lines += to_delete.size
end

if changed_files.empty?
  puts "No matching mixin definitions found under #{dir_rel}."
  exit 0
end

prefix = options[:dry_run] ? "[DRY RUN] Would remove" : "Removed"
puts "\n#{prefix} #{total_removed} unused mixins (#{total_lines} lines) from #{changed_files.size} file(s) under #{dir_rel}:"
changed_files.each { |f| puts "  #{f}" }