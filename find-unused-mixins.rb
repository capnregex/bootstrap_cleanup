#!/usr/bin/env ruby

require "yaml"
require "fileutils"

USED_YAML   = File.join(__dir__, "tmp", "used-mixins.yaml")
UNUSED_YAML = File.join(__dir__, "tmp", "unused-mixins.yaml")

files = Dir.glob("**/*.scss")

definitions = {}
files.each do |file|
  File.read(file).scan(/@mixin\s+([\w-]+)/) do
    (definitions[$1] ||= []) << file
  end
end

used_mixins = []
files.each do |file|
  File.read(file).scan(/@include\s+([\w-]+)/) { used_mixins << $1 }
end
used_mixins.uniq!

unused = definitions.keys - used_mixins

FileUtils.mkdir_p(File.dirname(USED_YAML))

used_data = used_mixins.sort.map { |m| { name: m } }
File.write(USED_YAML, { count: used_data.size, mixins: used_data }.to_yaml)

unused_data = unused.sort.map { |m| { name: m, defined_in: definitions[m] } }
File.write(UNUSED_YAML, { count: unused_data.size, total: definitions.size, mixins: unused_data }.to_yaml)

if unused.empty?
  puts "All #{definitions.size} defined mixins are in use."
else
  puts "Unused mixins (#{unused.size} of #{definitions.size}):"
  unused.sort.each { |m| puts "  #{m}  (#{definitions[m].join(', ')})" }
end

puts "\nWrote used mixins (#{used_data.size}) to #{USED_YAML}"
puts "Wrote unused mixins (#{unused_data.size}) to #{UNUSED_YAML}"
