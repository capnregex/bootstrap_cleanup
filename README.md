# Bootstrap SCSS Modernization Toolkit

## `fleeble.scss` — SCSS Library

A Bootstrap-like variables + mixins library. Successfully migrated from `@import` to `@use`/`@forward` with all deprecated global functions (`lighten`, `darken`, `ceil`, `floor`, `fade_in`, `adjust-hue`, etc.) replaced by modern `color.*` and `math.*` equivalents.

```bash
yarn build:css   # compiles fleeble.scss → fleeble.css
```

---

## Bootstrap 3.4.1 Conversion Test

`convert-sass-functions.rb` was tested against the real [bootstrap-sass](https://github.com/twbs/bootstrap-sass) 3.4.1 SCSS source:

- **123 replacements** across **18 files**
- `color.adjust` for all color functions (lighten/darken/adjust-hue/fade_in)
- `math.*` for ceil/floor/percentage
- Zero remaining deprecated global calls after conversion
- Handles nested functions (e.g. `darken(adjust-hue($color, -10), 5%)` → both outer and inner converted)
- No false positives in comments or already-namespaced calls

---

# Scripts

## `find-unused-mixins.rb` and `find-unused-vars.rb`

Scan all `*.scss` files in the project for defined vs used Sass mixins/variables. Two-pass: first pass collects all definitions (with file/line), second pass collects all references. Unused = defined but never referenced.

**Output:**
- Console: prints each unused item with its definition location
- `tmp/used-mixins.yaml` — list of used mixin names
- `tmp/unused-mixins.yaml` — unused mixins with `defined_in` file
- `tmp/used-vars.yaml` — list of used variable names
- `tmp/unused_variables.yaml` — unused variables with `defined_in` file:line

```bash
ruby find-unused-mixins.rb
ruby find-unused-vars.rb
```

## `find-unused-bootstrap-classes.rb`

Scans a Rails project for usage of Bootstrap 3.4.1 CSS classes from `bootstrap-3.4.1-styles.yaml`. Extracts class/tag selectors from the YAML, searches templates and assets in the target project, and reports which selectors are used vs unused.

**Output:**
- `tmp/used-bootstrap-classes.yaml` — selectors found in the project
- `tmp/unused-bootstrap-classes.yaml` — selectors not found

```bash
ruby find-unused-bootstrap-classes.rb /path/to/rails/project
ruby find-unused-bootstrap-classes.rb /path/to/rails/project --used custom-used.yaml --unused custom-unused.yaml
```

## `fetch-bootstrap-css.rb` and `fetch-bootstrap-js.rb`

Download and parse Bootstrap 3.4.1 CSS/JS from CDN, extracting style rules and JavaScript methods into YAML. CSS parser handles `@media` blocks; JS parser handles brace-depth tracking, escaped quotes, and IIFE closures to avoid internal functions.

```bash
ruby fetch-bootstrap-css.rb   # → bootstrap-3.4.1-styles.yaml
ruby fetch-bootstrap-js.rb    # → bootstrap-3.4.1-js.yaml
```

## `convert-sass-functions.rb`

Replaces deprecated Sass global function calls (`lighten`, `darken`, `ceil`, `floor`, `percentage`, etc.) with modern `color.*` and `math.*` equivalents. Handles nested function calls, string escaping, and inline/block comments. Adds `@use "sass:color"` / `@use "sass:math"` where needed and skips already-namespaced calls.

**Functions converted:**

| Deprecated | Replacement |
|------------|-------------|
| `lighten($c, $a)` | `color.adjust($c, $lightness: $a)` |
| `darken($c, $a)` | `color.adjust($c, $lightness: -$a)` |
| `saturate` / `desaturate` | `color.adjust(…, $saturation: …)` |
| `adjust-hue($c, $d)` | `color.adjust($c, $hue: $d)` |
| `fade_in` / `fade-out` / `opacify` / `transparentize` | `color.adjust($c, $alpha: …)` |
| `grayscale` / `complement` / `invert` / `mix` | `color.grayscale(…)` etc. |
| `ceil` / `floor` / `round` / `abs` / `min` / `max` / `percentage` / `random` | `math.ceil(…)` etc. |
| `unit` / `unitless` / `comparable` | `math.unit` / `math.is-unitless` / `math.compatible` |

```bash
ruby convert-sass-functions.rb          # rewrite files in place
ruby convert-sass-functions.rb --dry-run  # preview changes only
```

## `convert-sass-units.rb`

Corrects function arguments affected by the [strict function units](https://sass-lang.com/documentation/breaking-changes/function-units/) breaking change. Fixes unitless/non-`%` saturation/lightness, `%` alpha values, unit-bearing `math.random()` limits and `list.nth()`/`list.set-nth()` indices, and missing `%` on `color.mix()`/`color.invert()` weights.

| Correction | Example |
|---|---|
| `$saturation: N` → `$saturation: N%` | `color.adjust($c, $saturation: 20)` → `20%` |
| `$lightness: N` → `$lightness: N%` | `color.adjust($c, $lightness: 10)` → `10%` |
| `$alpha: N%` → `$alpha: 0.N` | `color.adjust($c, $alpha: 50%)` → `0.5` |
| `$weight: N` → `$weight: N%` | `color.mix(a, b, 50)` → `50%` |
| `math.random(Npx)` → `math.random(N)` | strips units from `$limit` |
| `list.nth($l, Npx)` → `list.nth($l, N)` | strips units from `$n` |
| `hsl(h, s, l)` → `hsl(h, s%, l%)` | adds `%` to sat/light |

```bash
ruby convert-sass-units.rb          # rewrite files in place
ruby convert-sass-units.rb --dry-run  # preview changes only
```

## `convert-sass-imports.rb`

Migrates `@import` rules to `@use`/`@forward` per the [@import deprecation](https://sass-lang.com/documentation/breaking-changes/import/). Operates in three phases:

1. **Classify** each `.scss` file (aggregator, variable, mixin, or component)
2. **Convert** `@import` → `@forward` in aggregator files, `@use "... as *"` elsewhere
3. **Add** `@use` imports to leaf files based on `$variable`/`@include` references

Tested against bootstrap-sass 3.4.1 (74 files, 73 imports converted, `@use` added to 33 leaf files).

```bash
ruby convert-sass-imports.rb             # rewrite files in place
ruby convert-sass-imports.rb --dry-run   # preview changes only
ruby convert-sass-imports.rb --verbose   # show detailed progress
```
