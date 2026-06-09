# Scripts

## `find-unused-mixins.rb` and `find-unused-vars.rb`

Scan all `*.scss` files in the project for defined vs used Sass mixins/variables. Two-pass: first pass collects all definitions (with file/line), second pass collects all references. Unused = defined but never referenced.

**Output:**
- Console: prints each unused item with its definition location
- `tmp/used-mixins.yaml` — list of used mixin names
- `tmp/unused-mixins.yaml` — unused mixins with `defined_in` file
- `tmp/used-vars.yaml` — list of used variable names
- `tmp/unused-vars.yaml` — unused variables with `defined_in` file:line

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
