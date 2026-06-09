#!/usr/bin/env ruby

require "open-uri"
require "yaml"

url = "https://cdn.jsdelivr.net/npm/bootstrap@3.4.1/dist/css/bootstrap.css"
css = URI.open(url).read.gsub(/\/\*.*?\*\//m, "")

rules = []

# Match standard rules: .foo, .bar { prop: val; prop: val; }
# A rule starts with a selector (no @), has {, then properties, then }
css.scan(/(?:^|\n)\s*([^{}@]+)\s*\{([^}]+)\}\s*\n/m) do |sel, body|
  sel = sel.strip.gsub(/\s*\n\s*/, " ").gsub(/\s+/, " ").gsub(/\s*,\s*/, ", ")
  props = body.split(";").map(&:strip).reject(&:empty?).map do |p|
    k, v = p.split(":", 2).map(&:strip)
    [k, v] if k && v
  end.compact
  rules << [sel, props.to_h] unless props.empty?
end

# Match rules inside @media blocks: @media query { .foo { prop: val; } }
# Collect media context and pass to inner rule
media_idx = 0
while (m = css.match(/@media\s+([^{]+)\{/m, media_idx))
  mq = m[1].strip
  open_brace = 1
  pos = m.end(0)
  block_start = pos
  while pos < css.length && open_brace > 0
    case css[pos]
    when "{" then open_brace += 1
    when "}" then open_brace -= 1
    when '"', "'"
      delim = css[pos]
      pos += 1
      while pos < css.length && css[pos] != delim
        pos += 1 if css[pos] == "\\"
        pos += 1
      end
    end
    pos += 1
  end
  block = css[block_start...pos - 1]

  # Now extract rules from inside the media block
  block.scan(/([^{}]+)\{([^}]+)\}/m) do |sel, body|
    sel = sel.strip.gsub(/\s*\n\s*/, " ").gsub(/\s+/, " ").gsub(/\s*,\s*/, ", ")
    props = body.split(";").map(&:strip).reject(&:empty?).map do |p|
      k, v = p.split(":", 2).map(&:strip)
      [k, v] if k && v
    end.compact
    rules << ["@media #{mq} { #{sel} }", props.to_h] unless props.empty?
  end

  media_idx = m.end(0)
end

rules.uniq! { |r| r[0] }

data = { version: "3.4.1", source: url, rules: rules.map { |s, p| { selector: s, properties: p } } }

File.write("bootstrap-3.4.1-styles.yaml", data.to_yaml)
puts "Wrote #{rules.size} style rules to bootstrap-3.4.1-styles.yaml"