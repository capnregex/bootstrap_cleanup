#!/usr/bin/env ruby
# Scans SCSS files and corrects function arguments affected by the strict units
# breaking change: https://sass-lang.com/documentation/breaking-changes/function-units/
#
# Corrections applied:
#   color.adjust/change($c, $saturation: N)   → $saturation: N%
#   color.adjust/change($c, $lightness: N)    → $lightness: N%
#   color.adjust/change($c, $alpha: N%)       → $alpha: (N / 100%)
#   color.mix($c1, $c2, $weight)             → $weight: N%
#   color.invert($c, $weight)                → $weight: N%
#   math.random($limit)                      → strip units from $limit
#   list.nth($list, $n)                     → strip units from $n
#   list.set-nth($list, $n, $value)         → strip units from $n
#   hsl/hsla($h, $s, $l)                    → add % to $s/$l if missing
#
# Usage: ruby convert-sass-units.rb [--dry-run]

require "fileutils"
require "optparse"
require "set"

dry_run = false
OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} [--dry-run]"
  opts.on("--dry-run", "Show changes without modifying files") { dry_run = true }
end.parse!

# ── helpers ────────────────────────────────────────────────────────────

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

# Extract top-level comma-separated arguments within parens at open_paren
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
  line_start = line.rindex("\n", pos) || 0
  return true if line[line_start...pos].include?("//")
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

# Parse a literal number: optional sign, digits, optional fraction, optional alpha unit
NUM_RE = /\A(-?\d+(?:\.\d+)?)([a-zA-Z%]*)\z/

def parse_number(value)
  m = value.strip.match(NUM_RE)
  return nil unless m
  [m[1], m[2]]  # [numeric_string, unit_string]
end

# ── correction logic ───────────────────────────────────────────────────

# Returns [new_value, description] or nil if no correction needed
def correct_value(value, rule)
  num = parse_number(value)
  return nil unless num

  raw, unit = num

  case rule
  when :ensure_percent
    return nil if unit == "%"      # already correct
    ["#{raw}%", "#{value} → #{raw}%"]

  when :ensure_unitless
    return nil if unit.empty?      # already correct
    if unit == "%"
      converted = raw.to_f / 100.0
      converted = converted.to_i if converted == converted.to_i
      result = converted.to_s
      [result, "#{value} → #{result}"]
    else
      [raw, "#{value} → #{raw}"]
    end

  when :strip_units
    return nil if unit.empty?
    [raw, "#{value} → #{raw}"]
  end
end

# ── function definitions ───────────────────────────────────────────────

FuncDef = Struct.new(:pattern, :named, :positional, keyword_init: true)

FUNCTIONS = [
  FuncDef.new(
    pattern: /(?<!\w)color\.adjust\(/,
    named: {
      "saturation" => :ensure_percent,
      "lightness"  => :ensure_percent,
      "alpha"      => :ensure_unitless,
    },
  ),
  FuncDef.new(
    pattern: /(?<!\w)color\.change\(/,
    named: {
      "saturation" => :ensure_percent,
      "lightness"  => :ensure_percent,
      "alpha"      => :ensure_unitless,
    },
  ),
  FuncDef.new(
    pattern: /(?<!\w)color\.mix\(/,
    named: { "weight" => :ensure_percent },
    positional: { 2 => :ensure_percent },
  ),
  FuncDef.new(
    pattern: /(?<!\w)color\.invert\(/,
    named: { "weight" => :ensure_percent },
    positional: { 1 => :ensure_percent },
  ),
  FuncDef.new(
    pattern: /(?<!\w)math\.random\(/,
    named: { "limit" => :strip_units },
    positional: { 0 => :strip_units },
  ),
  FuncDef.new(
    pattern: /(?<!\w)list\.nth\(/,
    named: { "n" => :strip_units },
    positional: { 1 => :strip_units },
  ),
  FuncDef.new(
    pattern: /(?<!\w)list\.set-nth\(/,
    named: { "n" => :strip_units },
    positional: { 1 => :strip_units },
  ),
  FuncDef.new(
    pattern: /(?<!\w)hsl\(/,
    positional: { 1 => :ensure_percent, 2 => :ensure_percent },
  ),
  FuncDef.new(
    pattern: /(?<!\w)hsla\(/,
    positional: {
      1 => :ensure_percent,
      2 => :ensure_percent,
      3 => :ensure_unitless,
    },
  ),
].freeze

# ── line processing ────────────────────────────────────────────────────

def process_line(line, changes)
  result = line.dup
  stripped = result.strip
  return result if stripped.start_with?("//") || stripped.start_with?("/*") || stripped.start_with?("*")

  FUNCTIONS.each do |fdef|
    pos = 0
    while (m = result.match(fdef.pattern, pos))
      idx = m.begin(0)

      if inside_comment?(result, idx) || result[0...idx].count('"').odd? || result[0...idx].count("'").odd?
        pos = idx + 1
        next
      end

      open_paren = idx + m[0].length - 1  # index of '('
      close_paren = find_matching_paren(result, open_paren)
      call_text = result[idx..close_paren]
      args = extract_args(result, open_paren)

      modified_args = args.dup
      any_correction = false
      notes = []

      # ── named arguments ──
      if fdef.named
        args.each_with_index do |arg, arg_idx|
          next unless arg.match?(/\A\$\w+:/)
          key, val = arg.split(":", 2).map(&:strip)
          key = key.sub(/\A\$/, "")
          next unless fdef.named[key]

          result_val = correct_value(val, fdef.named[key])
          next unless result_val

          new_val, note = result_val
          modified_args[arg_idx] = "$#{key}: #{new_val}"
          notes << note
          any_correction = true
        end
      end

      # ── positional arguments ──
      if fdef.positional
        positional_args = []
        args.each_with_index { |a, i| positional_args << i unless a.match?(/\A\$\w+:/) }

        fdef.positional.each do |pos_idx, rule|
          # Find the Nth positional argument
          actual_idx = positional_args[pos_idx]
          next unless actual_idx
          val = args[actual_idx]

          result_val = correct_value(val, rule)
          next unless result_val

          new_val, note = result_val
          modified_args[actual_idx] = new_val
          notes << note
          any_correction = true
        end
      end

      if any_correction
        new_call = "#{call_text.split("(").first}(#{modified_args.join(", ")})"
        result[idx..close_paren] = new_call
        close_paren = idx + new_call.length - 1
        changes << {
          func: call_text.split("(").first,
          old: call_text,
          new: new_call,
          notes: notes,
        }
        pos = idx + 1
      else
        pos = close_paren + 1
      end
    end
  end

  result
end

# ── @use tracking ──────────────────────────────────────────────────────

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

# ── main ────────────────────────────────────────────────────────────────

files = Dir.glob("**/*.scss").reject { |f| f.include?("/vendor/") || f.include?("/node_modules/") }

all_changes = []
needs_color = Set.new
needs_math  = Set.new
needs_list  = Set.new

files.each do |file|
  lines = File.readlines(file)
  changed_lines = []
  file_changed = false

  lines.each_with_index do |line, idx|
    these_changes = []
    new_line = process_line(line.chomp, these_changes)
    changed_lines << new_line

    unless these_changes.empty?
      file_changed = true
      these_changes.each do |c|
        c[:file] = file
        c[:line] = idx + 1
        func = c[:func]
        needs_color << file if func.start_with?("color.")
        needs_math  << file if func.start_with?("math.")
        needs_list  << file if func.start_with?("list.")
      end
      all_changes.concat(these_changes)
    end
  end

  if file_changed && !dry_run
    File.write(file, changed_lines.join("\n") + "\n")
  end
end

added_color = needs_color.count { |f| add_module_use(f, "color", dry_run) }
added_math  = needs_math.count  { |f| add_module_use(f, "math", dry_run) }
added_list  = needs_list.count  { |f| add_module_use(f, "list", dry_run) }

if all_changes.empty?
  puts "No function calls with strict-unit issues found."
else
  puts "#{dry_run ? "[DRY RUN] " : ""}#{all_changes.size} corrections in #{all_changes.map { |c| c[:file] }.uniq.size} files:\n\n"
  all_changes.group_by { |c| c[:file] }.each do |file, changes|
    puts "  #{file}:"
    changes.each do |c|
      puts "    L#{c[:line]}  #{c[:func]}(..):"
      c[:notes].each { |n| puts "      #{n}" }
    end
    puts
  end
  added = []
  added << "#{added_color} color" if added_color > 0
  added << "#{added_math} math" if added_math > 0
  added << "#{added_list} list" if added_list > 0
  puts "Added @use \"sass:x\" to #{added.join(", ")} file(s)" unless added.empty?
end
