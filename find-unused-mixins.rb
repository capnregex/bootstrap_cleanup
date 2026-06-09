#!/usr/bin/env ruby

files = Dir.glob("**/*.scss")

# Pass 1: collect all defined mixin names with their source file
definitions = {}
files.each do |file|
  File.read(file).scan(/@mixin\s+([\w-]+)/) do
    (definitions[$1] ||= []) << file
  end
end

# Pass 2: collect all mixin names that are used via @include
used_mixins = []
files.each do |file|
  File.read(file).scan(/@include\s+([\w-]+)/) { used_mixins << $1 }
end
used_mixins.uniq!

unused = definitions.keys - used_mixins

if unused.empty?
  puts "All #{definitions.size} defined mixins are in use."
else
  puts "Unused mixins (#{unused.size} of #{definitions.size}):"
  unused.sort.each { |m| puts "  #{m}  (#{definitions[m].join(', ')})" }
end
