#!/usr/bin/env ruby
# Usage: ruby find-unused-bootstrap-classes.rb /path/to/rails/project [options]
#
# Scans a Rails project for usage of Bootstrap 3.4.1 CSS classes and reports
# which styles are used vs unused.
#
# Options:
#   --used FILE    Output file for used styles (default: tmp/used-bootstrap-classes.yaml)
#   --unused FILE  Output file for unused styles (default: tmp/unused-bootstrap-classes.yaml)

require "yaml"
require "set"
require "find"
require "fileutils"
require "optparse"

BOOTSTRAP_YAML = File.join(__dir__, "bootstrap-3.4.1-styles.yaml")
DEFAULT_USED   = File.join(__dir__, "tmp", "used-bootstrap-classes.yaml")
DEFAULT_UNUSED = File.join(__dir__, "tmp", "unused-bootstrap-classes.yaml")

options = { used: DEFAULT_USED, unused: DEFAULT_UNUSED }
OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} /path/to/rails/project [options]"
  opts.on("--used FILE",  "Output for used styles (default: #{DEFAULT_USED})")
  opts.on("--unused FILE", "Output for unused styles (default: #{DEFAULT_UNUSED})")
end.parse!(into: options)

rails_path = ARGV.first
abort "Usage: #{$0} /path/to/rails/project" unless rails_path && Dir.exist?(rails_path)

# ── 1. Load Bootstrap styles ──────────────────────────────────────────

puts "Loading styles..."
data = YAML.safe_load_file(BOOTSTRAP_YAML, permitted_classes: [Symbol])

sel_to_rule  = {}
cls_to_sels  = Hash.new { |h, k| h[k] = Set.new }
tag_to_sels  = Hash.new { |h, k| h[k] = Set.new }
all_selectors = Set.new
all_classes   = Set.new

data[:rules].each do |rule|
  rule[:selector].split(/\s*,\s*/).each do |raw|
    sel = raw.strip
    next if sel.empty?
    all_selectors << sel
    sel_to_rule[sel] = rule
    sel.scan(/\.([\w-]+)/).flatten.each do |cls|
      cls_to_sels[cls] << sel
      all_classes << cls
    end
    sel.scan(/(?<=^|[>+~\s])([a-z]\w*)(?=[:.#\[>\s+~]|$)/).flatten.each do |tag|
      tag_to_sels[tag] << sel
    end
  end
end

puts "  #{data[:rules].size} rules, #{all_selectors.size} selectors"
puts "  #{all_classes.size} classes, #{tag_to_sels.size} tags"

# ── 2. Build regex patterns per class ─────────────────────────────────

# Precompile patterns for each class name.
# Order: longest class first so substring matches get caught by the longer class's pattern first.
sorted_classes = all_classes.sort_by { |c| -c.length }
cls_pattern = {}
sorted_classes.each do |cls|
  escaped = Regexp.escape(cls)

  # Patterns that signal a class is in use:
  #   .cls           — CSS / JSX / SCSS selector
  #   "cls"  'cls'   — exact JS/Ruby string literal
  #   :cls           — Ruby symbol
  #   class=" cls "  — HTML class attribute
  #   class: 'cls'   — Rails helper
  #   cls:           — Tailwind-like or JS object key with trailing colon
  patterns = [
    /(?<=^|[^-\w])\.#{escaped}(?=[^-\w]|$)/,            # CSS .cls
    /["']#{escaped}["']/,                                  # "cls" / 'cls'
    /["'][^"']*?\s#{escaped}(?:\s|["'])/,                  # "foo cls bar"
    /\bclass\s*[=:]\s*(?::|["'])#{escaped}(?:\s|["']|$)/,     # class="cls", class: :cls
  ]

  # For multi-word classes (e.g. "data-ride"), also match inside data attributes
  if cls.include?("-")
    patterns << /#{escaped}(?=["'\s\/>])/                   # data-ride="carousel"
  end

  cls_pattern[cls] = Regexp.union(patterns)
end

# ── 3. Scan project files ─────────────────────────────────────────────

used_selectors = Set.new
scan_dirs = %w[app config lib spec test].select { |d| Dir.exist?(File.join(rails_path, d)) }
extensions = %w[.erb .haml .slim .html .rb .rake .jbuilder .js .jsx .coffee .ts .tsx .scss .sass .less .css .json .yml .yaml .md]

puts "\nScanning #{scan_dirs.join(", ")}..."

Find.find(*scan_dirs.map { |d| File.join(rails_path, d) }) do |path|
  next unless File.file?(path)
  ext = File.extname(path).downcase
  next unless extensions.include?(ext)
  next if path.include?("/vendor/bundle") || path.include?("/node_modules/") || path.include?("/.git/")
  next if File.size(path) > 2_000_000

  content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)

  # Check classes — if any pattern matches, mark all its selectors as used
  cls_to_sels.each_key do |cls|
    next unless cls_pattern[cls].match?(content)
    cls_to_sels[cls].each { |sel| used_selectors << sel }
  end

  # Check tags
  tag_to_sels.each_key do |tag|
    next if %w[after before active visited hover focus].include?(tag)
    used_selectors.merge(tag_to_sels[tag]) if content.match?(/<#{tag}[\s>\/]/)
  end
end

# ── 4. Build output ───────────────────────────────────────────────────

used_rules   = []
unused_rules = []

all_selectors.sort.each do |sel|
  rule = sel_to_rule[sel]
  entry = { selector: sel, properties: rule[:properties] }
  (used_selectors.include?(sel) ? used_rules : unused_rules) << entry
end

FileUtils.mkdir_p(File.dirname(options[:used]))

File.write(options[:used],   { version: "3.4.1", project: rails_path, rules: used_rules }.to_yaml)
File.write(options[:unused], { version: "3.4.1", project: rails_path, rules: unused_rules }.to_yaml)

total = all_selectors.size
puts "\nDone. Used: #{used_rules.size}/#{total} (#{(used_rules.size * 100.0 / total).round(1)}%)"
puts "  Used:   #{options[:used]}"
puts "  Unused: #{options[:unused]}"
