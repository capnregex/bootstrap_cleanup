require "set"

DEPRECATED = {
  "ceil"       => { mod: "math", replacement: ->(args) { "math.ceil(#{args[0]})" } },
  "floor"      => { mod: "math", replacement: ->(args) { "math.floor(#{args[0]})" } },
  "percentage" => { mod: "math", replacement: ->(args) { "math.percentage(#{args[0]})" } },
}

def inside_comment?(text, pos)
  line_start = text.rindex("\n", pos) || 0
  line = text[line_start...pos]
  return true if line.include?("//")
  i = 0
  while i < pos
    open_c = text.index("/*", i)
    break unless open_c && open_c < pos
    close_c = text.index("*/", open_c + 2)
    return true if close_c.nil? || close_c >= pos
    i = close_c + 2
  end
  false
end

def extract_args(text, start)
  i = start + 1
  depth = 1
  args = []
  buf = ""
  in_str = false
  str_delim = nil
  while i < text.length && depth > 0
    ch = text[i]
    if in_str
      if ch == "\\" && i + 1 < text.length
        buf << ch << text[i + 1]; i += 2; next
      elsif ch == str_delim
        in_str = false
      end
      buf << ch; i += 1; next
    end
    if ch == '"' || ch == "'"
      in_str = true; str_delim = ch; buf << ch; i += 1; next
    end
    case ch
    when "("
      depth += 1
      buf << ch
    when ")"
      depth -= 1
      if depth == 0
        args << buf.strip
        buf = ""
      else
        buf << ch
      end
    when ","
      if depth == 1
        args << buf.strip
        buf = ""
      else
        buf << ch
      end
    else
      buf << ch
    end
    i += 1
  end
  args
end

# Read the actual file
content = File.read("fleeble/mixins/_grid.scss")
lines = content.lines

line = lines[27]  # line 28 (0-indexed) which has the first percentage call
puts "Line 28: #{line.inspect}"

DEPRECATED.each do |func, info|
  pattern = /(?<=^|[^-\w])(?<!math\.|color\.)#{Regexp.escape(func)}\(/
  offset = 0
  while (m = line.match(pattern, offset))
    idx = m.begin(0)
    puts "\nMatch for #{func} at #{idx}: #{m[0]}"
    puts "  inside_comment?: #{inside_comment?(line, idx)}"

    before = line[0...idx]
    puts "  odd double quotes? #{before.count('"').odd?}"
    puts "  odd single quotes? #{before.count("'").odd?}"

    next if inside_comment?(line, idx)
    next if before.count('"').odd? || before.count("'").odd?

    func_end = idx + func.length
    args = extract_args(line, func_end)
    puts "  args: #{args.inspect}"
    puts "  args empty? #{args.empty?}"
    next if args.empty? || (args.size == 1 && args[0].empty?)

    new_text = info[:replacement].call(args)
    puts "  old: #{line[idx...-1]}"
    puts "  new: #{new_text}"
    break
  end
end
