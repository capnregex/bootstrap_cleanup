#!/usr/bin/env ruby
require "open-uri"

js = URI.open("https://cdn.jsdelivr.net/npm/bootstrap@3.4.1/dist/js/bootstrap.js").read
depth = 0
in_string = false
string_char = nil
js.each_line.with_index(1) do |line, i|
  line.each_char do |ch|
    if in_string
      if ch == string_char
        in_string = false
      end
      next
    end
    if ch == '"' || ch == "'"
      in_string = true
      string_char = ch
      next
    end
    depth += 1 if ch == "{"
    depth -= 1 if ch == "}"
  end
  stripped = line.strip
  
  if i >= 20 && i <= 35
    puts "Line #{i}: depth=#{depth} #{stripped[0..80]}"
  end
end
