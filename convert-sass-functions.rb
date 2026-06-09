#!/usr/bin/env ruby
# Scans SCSS files and replaces deprecated Sass function calls with modern equivalents.
# Usage: ruby convert-sass-functions.rb [--dry-run]

require "fileutils"
require "optparse"

dry_run = false
OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} [--dry-run]"
  opts.on("--dry-run", "Show changes without modifying files") { dry_run = true }
end.parse!

DEPRECATED = {
  "lighten"       => { mod: "color", replacement: ->(args) { "color.adjust(#{args[0]}, $lightness: #{args[1]})" } },
  "darken"        => { mod: "color", replacement: ->(args) { "color.adjust(#{args[0]}, $lightness: -#{args[1]})" } },
  "saturate"      => { mod: "color", replacement: ->(args) { "color.adjust(#{args[0]}, $saturation: #{args[1]})" } },
  "desaturate"    => { mod: "color", replacement: ->(args) { "color.adjust(#{args[0]}, $saturation: -#{args[1]})" } },
  "adjust-hue"    => { mod: "color", replacement: ->(args) { "color.adjust(#{args[0]}, $hue: #{args[1]})" } },
  "fade_in"       => { mod: "color", replacement: ->(args) { "color.adjust(#{args[0]}, $alpha: #{args[1]})" } },
  "fade-out"      => { mod: "color", replacement: ->(args) { "color.adjust(#{args[0]}, $alpha: -#{args[1]})" } },
  "opacify"       => { mod: "color", replacement: ->(args) { "color.adjust(#{args[0]}, $alpha: #{args[1]})" } },
  "transparentize" => { mod: "color", replacement: ->(args) { "color.adjust(#{args[0]}, $alpha: -#{args[1]})" } },
  "grayscale"     => { mod: "color", replacement: ->(args) { "color.grayscale(#{args[0]})" } },
  "complement"    => { mod: "color", replacement: ->(args) { "color.complement(#{args[0]})" } },
  "invert"        => { mod: "color", replacement: ->(args) { "color.invert(#{args[0]}#{args[1] ? ", #{args[1]}" : ""})" } },
  "mix"           => { mod: "color", replacement: ->(args) { "color.mix(#{args.join(", ")})" } },
  "ceil"          => { mod: "math", replacement: ->(args) { "math.ceil(#{args[0]})" } },
  "floor"         => { mod: "math", replacement: ->(args) { "math.floor(#{args[0]})" } },
  "round"         => { mod: "math", replacement: ->(args) { "math.round(#{args[0]})" } },
  "abs"           => { mod: "math", replacement: ->(args) { "math.abs(#{args[0]})" } },
  "percentage"    => { mod: "math", replacement: ->(args) { "math.percentage(#{args[0]})" } },
  "random"        => { mod: "math", replacement: ->(args) { "math.random(#{args[0]})" } },
  "min"           => { mod: "math", replacement: ->(args) { "math.min(#{args.join(", ")})" } },
  "max"           => { mod: "math", replacement: ->(args) { "math.max(#{args.join(", ")})" } },
  "unit"          => { mod: "math", replacement: ->(args) { "math.unit(#{args[0]})" } },
  "unitless"      => { mod: "math", replacement: ->(args) { "math.is-unitless(#{args[0]})" } },
  "comparable"    => { mod: "math", replacement: ->(args) { "math.compatible(#{args[0]}, #{args[1]})" } },
}.freeze

def extract_args(line, open_paren)
  i = open_paren + 1
  depth = 1
  args = []
  buf = ""
  in_str = false
  str_delim = nil

  while i < line.length && depth > 0
    ch = line[i]
    if in_str
      if ch == "\\" && i + 1 < line.length
        buf << ch << line[i + 1]; i += 2; next
      elsif ch == str_delim
        in_str = false
      end
      buf << ch; i += 1; next
    end
    if ch == '"' || ch == "'"
      in_str = true; str_delim = ch; buf << ch; i += 1; next
    end
    case ch
    when "(" then depth += 1; buf << ch
    when ")"
      depth -= 1
      if depth == 0 then args << buf.strip; buf = ""
      else buf << ch; end
    when ","
      if depth == 1 then args << buf.strip; buf = ""
      else buf << ch; end
    else buf << ch
    end
    i += 1
  end
  args
end

def inside_comment?(line, pos)
  # single-line comment
  line_start = line.rindex("\n", pos) || 0
  return true if line[line_start...pos].include?("//")
  # block comment
  i = 0
  while i < pos
    op = line.index("/*", i)
    break unless op && op < pos
    cl = line.index("*/", op + 2)
    return true if cl.nil? || cl >= pos
    i = cl + 2
  end
  false
end

def find_matching_paren(line, open_paren)
  d = 1
  i = open_paren
  while i < line.length && d > 0
    i += 1
    case line[i]
    when "(" then d += 1
    when ")" then d -= 1
    end
  end
  i
end

def replace_deprecated(line, changes, dry_run)
  result = line

  DEPRECATED.each do |func, info|
    pattern = /(?<=^|[^-\w])(?<!math\.|color\.)#{Regexp.escape(func)}\(/
    pos = 0

    while (m = result.match(pattern, pos))
      idx = m.begin(0)

      if inside_comment?(result, idx)
        pos = idx + 1
        next
      end

      before = result[0...idx]
      if before.count('"').odd? || before.count("'").odd?
        pos = idx + 1
        next
      end

      open_paren = idx + func.length
      args = extract_args(result, open_paren)

      if args.empty? || (args.size == 1 && args[0].empty?)
        pos = find_matching_paren(result, open_paren) + 1
        next
      end

      close_paren = find_matching_paren(result, open_paren)
      old_call = result[idx..close_paren]
      new_text = info[:replacement].call(args)

      if old_call != new_text
        unless dry_run
          result[idx..close_paren] = new_text
        end
        changes << { func: func, old: old_call, new: new_text }
        pos = idx + new_text.length
      else
        pos = close_paren + 1
      end
    end
  end

  result
end

def add_module_use(file, mod, dry_run)
  content = File.read(file)
  use = "@use \"sass:#{mod}\";"
  return false if content.include?(use)

  unless dry_run
    lines = content.lines
    idx = lines.rindex { |l| l.start_with?("@use ") }
    if idx
      lines.insert(idx + 1, "#{use}\n")
    else
      idx = 0
      idx += 1 while idx < lines.length && lines[idx].match?(/\A\s*(?:\/\/|\/\*|\*|\s*\z)/)
      lines.insert(idx, "#{use}\n")
    end
    File.write(file, lines.join)
  end
  true
end

# ── main ──────────────────────────────────────────────────────────────

files = Dir.glob("**/*.scss").reject { |f| f.include?("/vendor/") || f.include?("/node_modules/") }

all_changes = []
needs_color = Set.new
needs_math  = Set.new

files.each do |file|
  lines = File.readlines(file)
  changed_lines = []
  file_changed = false

  lines.each_with_index do |line, idx|
    these_changes = []
    new_line = replace_deprecated(line.chomp, these_changes, dry_run)
    changed_lines << new_line

    unless these_changes.empty?
      file_changed = true
      all_changes << these_changes.map { |c| c.merge(file: file, line: idx + 1) }
      all_changes.flatten!
      these_changes.each do |c|
        needs_color << file if DEPRECATED[c[:func]][:mod] == "color"
        needs_math  << file if DEPRECATED[c[:func]][:mod] == "math"
      end
    end
  end

  if file_changed && !dry_run
    File.write(file, changed_lines.join("\n") + "\n")
  end
end

added_color = needs_color.count { |f| add_module_use(f, "color", dry_run) }
added_math  = needs_math.count  { |f| add_module_use(f, "math", dry_run) }

if all_changes.empty?
  puts "No deprecated function calls found."
else
  puts "#{dry_run ? "[DRY RUN] " : ""}#{all_changes.size} replacements in #{all_changes.map { |c| c[:file] }.uniq.size} files:\n\n"
  all_changes.group_by { |c| c[:file] }.each do |file, changes|
    puts "  #{file}:"
    changes.each { |c| puts "    L#{c[:line]}  #{c[:func]}(...)\n      old: #{c[:old]}\n      new: #{c[:new]}\n" }
    puts
  end
    puts "Added @use \"sass:color\" to #{added_color} files" if added_color > 0
    puts "Added @use \"sass:math\" to #{added_math} files" if added_math > 0
end
