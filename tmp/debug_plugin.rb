require "open-uri"
js = URI.open("https://cdn.jsdelivr.net/npm/bootstrap@3.4.1/dist/js/bootstrap.js").read
depth = 0
js.each_line.with_index(1) do |line, i|
  chars = line.chars
  j = 0
  while j < chars.length
    ch = chars[j]
    if ch == '"' || ch == "'" || ch == "`"
      delim = ch
      j += 1
      while j < chars.length
        if chars[j] == "\\" && j + 1 < chars.length
          j += 2
        elsif chars[j] == delim
          j += 1
          break
        else
          j += 1
        end
      end
      next
    end
    depth += 1 if ch == "{"
    depth -= 1 if ch == "}"
    j += 1
  end
  stripped = line.strip
  if stripped =~ /function Plugin\(/ && depth == 2
    puts "Line #{i}: function Plugin(option) (depth=#{depth})"
  end
end
