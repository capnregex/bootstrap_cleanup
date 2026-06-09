#!/usr/bin/env ruby

require "set"

files = Dir.glob("**/*.scss")

# Pass 1: collect all defined variable names with their source file and line
definitions = {}
files.each do |file|
  File.readlines(file).each_with_index do |line, idx|
    line.scan(/^\s*\$([\w-]+)\s*:/) do
      (definitions[$1] ||= []) << "#{file}:#{idx + 1}"
    end
  end
end

# Pass 2: for each defined variable, find references on lines
# other than its own definition line
used_vars = Set.new
files.each do |file|
  lines = File.readlines(file)
  lines.each_with_index do |line, idx|
    line.scan(/\$[\w-]+/) do |match|
      var = match.sub(/^\$/, '')
      loc = "#{file}:#{idx + 1}"
      if definitions[var] && !definitions[var].include?(loc)
        used_vars << var
      end
    end
  end
end

unused = definitions.keys - used_vars.to_a

if unused.empty?
  puts "All #{definitions.size} defined variables are in use."
else
  puts "Unused variables (#{unused.size} of #{definitions.size}):"
  unused.sort.each { |v| puts "  $#{v}  (#{definitions[v].join(', ')})" }
end
