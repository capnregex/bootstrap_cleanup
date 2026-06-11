#!/usr/bin/env ruby
# Remove @forward entries from _index.scss that reference missing files.
#
# Usage: ruby prune-index-forwards.rb <directory> [--dry-run]

require "optparse"
require "pathname"

options = { dry_run: false }

OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} <directory> [--dry-run]"
  opts.on("--dry-run", "Show changes without modifying _index.scss") { options[:dry_run] = true }
end.parse!

directory = ARGV[0]
unless directory
  warn "Error: directory argument required"
  warn "Usage: ruby #{$0} <directory> [--dry-run]"
  exit 1
end

dir_path = File.expand_path(directory)

unless File.directory?(dir_path)
  warn "Error: directory not found: #{directory}"
  exit 1
end

index_path = File.join(dir_path, "_index.scss")

unless File.exist?(index_path)
  warn "Error: #{index_path} not found"
  exit 1
end

def display_path(path)
  Pathname.new(path).cleanpath
    .relative_path_from(Pathname.new(Dir.pwd).cleanpath).to_s
rescue ArgumentError
  path
end

FORWARD_RE = /\A(\s*)@forward\s+["']([^"']+)["'](.*);\s*(?:\/\/.*)?\z/

def resolve_forward_path(forward_path, index_dir)
  path = forward_path.sub(/\.scss\z/, "")
  segments = path.split("/")
  base_name = segments.pop
  parent_dir = File.join(index_dir, *segments)

  [
    File.join(parent_dir, "_#{base_name}.scss"),
    File.join(parent_dir, "#{base_name}.scss"),
    File.join(parent_dir, base_name, "_index.scss"),
    File.join(parent_dir, base_name, "index.scss"),
    File.join(parent_dir, "#{path}.scss"),
    File.join(parent_dir, "_#{path.tr('/', '_')}.scss"),
  ].find { |candidate| File.exist?(candidate) }
end

lines = File.readlines(index_path)
kept_lines = []
removed = []

lines.each_with_index do |line, idx|
  match = line.match(FORWARD_RE)
  unless match
    kept_lines << line
    next
  end

  forward_path = match[2]
  resolved = resolve_forward_path(forward_path, dir_path)

  if resolved
    kept_lines << line
  else
    removed << { line: idx + 1, path: forward_path, text: line.chomp }
  end
end

if removed.empty?
  puts "All @forward entries in #{display_path(index_path)} resolve to existing files."
  exit 0
end

index_display = display_path(index_path)

if options[:dry_run]
  puts "[DRY RUN] Would remove #{removed.size} @forward entr#{removed.size == 1 ? 'y' : 'ies'} from #{index_display}:"
  removed.each { |entry| puts "  L#{entry[:line]}  #{entry[:text].strip}  (#{entry[:path]})" }
  exit 0
end

File.write(index_path, kept_lines.join)
puts "Removed #{removed.size} @forward entr#{removed.size == 1 ? 'y' : 'ies'} from #{index_display}:"
removed.each { |entry| puts "  L#{entry[:line]}  #{entry[:text].strip}  (#{entry[:path]})" }