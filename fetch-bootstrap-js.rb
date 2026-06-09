#!/usr/bin/env ruby

require "open-uri"
require "yaml"

url = "https://cdn.jsdelivr.net/npm/bootstrap@3.4.1/dist/js/bootstrap.js"
js = URI.open(url).read

plugins = {}
depth = 0

js.each_line do |line|
  chars = line.chars
  i = 0
  while i < chars.length
    ch = chars[i]

    if ch == '"' || ch == "'" || ch == "`"
      delim = ch
      i += 1
      while i < chars.length
        if chars[i] == "\\" && i + 1 < chars.length
          i += 2
        elsif chars[i] == delim
          i += 1
          break
        else
          i += 1
        end
      end
      next
    end

    depth += 1 if ch == "{"
    depth -= 1 if ch == "}"
    i += 1
  end

  stripped = line.strip

  if depth == 2 && stripped =~ /^var\s+([A-Z]\w+)\s*=\s*function\s*\(([^)]*)\)\s*\{/
    name = $1
    params = $2.strip.split(/\s*,\s*/).reject(&:empty?)
    plugins[name] = { name: name, type: "constructor", params: params, methods: [] }
    next
  end

  if depth == 2 && stripped =~ /^function\s+([A-Z]\w+)\s*\(([^)]*)\)/
    name = $1
    next if name == "Plugin"
    params = $2.strip.split(/\s*,\s*/).reject(&:empty?)
    plugins[name] = { name: name, type: "constructor", params: params, methods: [] }
    next
  end

  if stripped =~ /(\w+)\.prototype\.(\w+)\s*=\s*function\s*\(([^)]*)\)/
    plugin_name = $1
    method_name = $2
    params = $3.strip.split(/\s*,\s*/).reject(&:empty?)
    plugins[plugin_name] ||= { name: plugin_name, type: "constructor", params: [], methods: [] }
    plugins[plugin_name][:methods] << { name: method_name, params: params }
    next
  end

  if depth == 2 && stripped =~ /\$\.fn\.(\w+)\s*=\s*function\s*\(([^)]*)\)/
    name = $1
    params = $2.strip.split(/\s*,\s*/).reject(&:empty?)
    plugins[name] = { name: name, type: "jquery_plugin", params: params, methods: [] }
    next
  end

  if stripped =~ /\.on\s*\(\s*['\"](\w+)\.bs\.(\w+)/
    event = $1
    plugin_short = $2
    plugins["data_api_#{plugin_short}_#{event}"] = {
      type: "data_api_event", event: event, plugin: plugin_short
    }
  end
end

data_api = plugins.select { |k, v| v[:type] == "data_api_event" }.values.sort_by { |e| [e[:plugin], e[:event]] }.uniq { |e| [e[:plugin], e[:event]] }

plugin_list = plugins.reject { |k, v| v[:type] == "data_api_event" }
                     .values
                     .sort_by { |p| p[:name] || "" }

data = {
  version: "3.4.1",
  source: url,
  plugins: plugin_list,
  data_api_events: data_api
}

File.write("bootstrap-3.4.1-js.yaml", data.to_yaml)
puts "Wrote #{plugin_list.size} plugins/functions and #{data_api.size} data API events to bootstrap-3.4.1-js.yaml"