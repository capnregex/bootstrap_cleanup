#!/usr/bin/env ruby

require "set"
require "yaml"
require "fileutils"

USED_YAML   = File.join(__dir__, "tmp", "used-vars.yaml")
UNUSED_YAML = File.join(__dir__, "tmp", "unused_variables.yaml")

files = Dir.glob("**/*.scss")

definitions = {}
files.each do |file|
  File.readlines(file).each_with_index do |line, idx|
    line.scan(/^\s*\$([\w-]+)\s*:/) do
      (definitions[$1] ||= []) << "#{file}:#{idx + 1}"
    end
  end
end

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

FileUtils.mkdir_p(File.dirname(USED_YAML))

used_data = used_vars.sort.map { |v| { name: v } }
File.write(USED_YAML, { count: used_data.size, vars: used_data }.to_yaml)

unused_data = unused.sort.map { |v| { name: v, defined_in: definitions[v] } }
File.write(UNUSED_YAML, { count: unused_data.size, total: definitions.size, vars: unused_data }.to_yaml)

if unused.empty?
  puts "All #{definitions.size} defined variables are in use."
else
  puts "Unused variables (#{unused.size} of #{definitions.size}):"
  unused.sort.each { |v| puts "  $#{v}  (#{definitions[v].join(', ')})" }
end

puts "\nWrote used vars (#{used_data.size}) to #{USED_YAML}"
puts "Wrote unused vars (#{unused_data.size}) to #{UNUSED_YAML}"
