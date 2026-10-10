# tailwind

Tailwind CSS classes compiled to a stylesheet in Crystal. No JavaScript at
build time or run time.

The output for a set of classes matches Tailwind CSS 4.3.3's own build of
them, byte for byte, for every recorded build but the ones listed in
`spec/pending.txt`.

This project is not affiliated with Tailwind Labs. It reads Tailwind's
published data, under Tailwind's MIT license, in `src/tailwind/vendor/`.

## Use

```yaml
dependencies:
  tailwind:
    github: softkittens/tailwind.cr
```

```crystal
require "tailwind"

css = Tailwind.compile(["flex", "md:hover:bg-red-500/50", "p-[13px]"])
```

`compile` takes any words. A word that is not a utility builds no rule, so the
caller can pass every class in its templates without sorting them first.

| Argument | Default | |
|---|---|---|
| `classes` | | the classes to build |
| `theme` | `Tailwind::Theme.default` | the design tokens |
| `preflight` | `true` | include Tailwind's base styles |

## Theme

`Tailwind::Theme.load(css)` reads `@theme` blocks, and one `@custom-variant
dark`, on top of Tailwind's default theme:

```crystal
theme = Tailwind::Theme.load(<<-CSS)
  @theme {
    --color-*: initial;
    --color-brand: #1d4ed8;
    --breakpoint-3xl: 120rem;
    --animate-wiggle: wiggle 1s ease-in-out infinite;
    @keyframes wiggle {
      0%, 100% { rotate: -3deg; }
      50% { rotate: 3deg; }
    }
  }
  CSS
Tailwind.compile(classes, theme)
```

- A token with a default's name replaces its value.
- `--color-*: initial` removes a namespace; `--*: initial` removes every token.
- `@theme inline` tokens are written by value instead of `var()`.
- A token is written to `:root` only when a compiled class reads it.
  `@theme static` tokens are always written, so the project's own CSS can
  read them.
- `@theme reference` tokens are never written: another sheet defines them,
  and a utility reads `var(--color-brand, #1d4ed8)`.
- Anything else in the CSS raises `Tailwind::Error`, with the line.

### Dark mode

`dark:` follows the system's `prefers-color-scheme`. To switch it from the
page instead, give the theme the line Tailwind takes:

```css
@custom-variant dark (&:where(.dark, .dark *));
```

`dark:bg-black` then applies under an element with the class `dark`. An
attribute works the same way: `(&:where([data-theme=dark], [data-theme=dark] *))`.
Setting the class or attribute is the page's own script.

## What it builds

- Every static utility and every functional root of Tailwind 4.3.3, with
  named, bare, fractional, negative and arbitrary values (`p-[13px]`,
  `bg-(--x)`, `text-[length:var(--y)]`), opacity modifiers, gradient
  interpolation (`bg-linear-to-r/oklch`), a shadow's alpha (`shadow-lg/20`)
  and `!important`.
- An arbitrary value goes to the property its type calls for, by Tailwind's
  tests: `border-[thin]` is a width and `border-[#123]` a colour,
  `font-[Inter]` a family and `font-[450]` a weight.
- Arbitrary properties: `[mask-type:luminance]`.
- Every variant, stacked in any order: breakpoints and `max-*`, `min-[…]`,
  container queries, `group-*`, `peer-*`, `not-*`, `has-*`, `in-*`, `aria-*`,
  `data-*`, `nth-*`, `supports-*` and arbitrary variants (`[&_svg]:size-4`).

## What it does not build

- `@utility`, `@custom-variant` for anything but `dark`, `@apply`, `@import`,
  plugins and prefixes. A project's own CSS is plain CSS beside the sheet,
  reading the theme's variables.
- `theme()` in an arbitrary value, which is Tailwind 3's way to read a
  token. Write the variable: `w-[calc(100%-var(--spacing)*4)]`, not
  `w-[calc(100%-theme(spacing.4))]`.
- The 3 builds in `spec/pending.txt`.
- A reason for a class it does not build. `Tailwind.parse` answers nil.

A static utility is written as Tailwind's default theme builds it. One that
reads a `--default-*` token keeps reading it under a theme that removed it.

## Class names are trusted

As in Tailwind, the classes are taken to come from the project's own
templates. The compiler refuses the values Tailwind refuses
(`p-[1px;color:red]`, `[&}body{x]:flex`), and has Tailwind's limits: it reads
no comment and no `url(` inside a value, so a crafted class can still write
CSS outside its own rule. A single class of a hundred kilobytes can take
seconds to read.

A class that stacks more than 16 variants, or nests more than 16 in one
(`group-has-not-…`), builds no rule. Tailwind has no such limit.

Do not compile classes taken from visitors' content. A sheet written into a
`<style>` element needs its `</` escaped by the caller.

## How it works

Tailwind's utilities are data here, not code. `script/vendor.cr` asks real
Tailwind what each class builds and writes `src/tailwind/vendor/`:

| File | Holds |
|---|---|
| `static.json` | every class that takes no value, as a rule |
| `functional.json` | every root that takes one, as templates with `§` where the value goes, and which template each kind of value fills |
| `properties.json` | the custom properties utilities register |
| `variants.json` | every variant in Tailwind's order, and what each one that takes no value wraps a rule in |
| `property_order.txt` | the order utilities are sorted by |
| `theme.css`, `preflight.css` | Tailwind's default theme and base styles |

The Crystal source, in `src/tailwind/`:

| File | Does |
|---|---|
| `utilities.cr` | splits a utility into a root and a value |
| `root.cr` | fills the root's template from the value: arbitrary, a theme token, a number |
| `roots.cr` | the roots whose rule is more than a template: `text-*`, the gradients, the shadows, `@container` |
| `value.cr` | decodes an arbitrary value and tells its type |
| `variants.cr` | the variants that take a value or wrap another (`group-`, `not-`, `data-`, `min-`), and each one's sort order |
| `fallback.cr` | writes a `color-mix()` declaration twice, for browsers without it |
| `print.cr` | lifts at-rules outside rules, merges neighbours, prints |
| `theme.cr` | parses `@theme` over the default theme |

`src/tailwind.cr` reads classes, sorts them as Tailwind does and writes the
sheet. The tables are parsed when the program starts, in about 2 ms.

## Tests

```
crystal spec
```

The differential spec compares this compiler with real Tailwind on:

- `spec/cases.txt`: classes written by hand, one build a line;
- `spec/fixtures/local.txt`, when it is there: more classes, kept out of the
  repository;
- every functional root with each kind of value, every variant and every
  static utility, which `script/fixtures.cr` writes from Tailwind itself;
- two builds of all of those together, for the order of classes;
- `spec/themes/`: for each theme `<name>.css`, the lines of `<name>.txt`,
  built over that theme;
- the classes Tailwind builds no rule for, which this compiler must not
  build either.

It fails when a case differs, and when a case in `spec/pending.txt` stops
differing.

What real Tailwind builds is recorded in `spec/fixtures/reference.json.gz`,
which is not in the repository. `crystal spec` records it when it is missing
or older than its sources, which takes about 15 seconds and needs `bun` or
`node` (Tailwind is JavaScript). Without either, the differential spec is
skipped and the rest runs.

`TAILWIND_CASE=<substring> crystal spec` runs the cases that contain it.

## Scripts

| Script | Writes |
|---|---|
| `script/vendor.cr` | `src/tailwind/vendor/`: the tables, default theme and preflight |
| `script/fixtures.cr` | `spec/fixtures/reference.json.gz` |
| `script/oracle.cr` | nothing; it is how the other two ask real Tailwind |

`oracle.cr` fetches Tailwind's npm package into `script/.tailwind/` and runs
it under `bun` or `node`. Its bridge, about 20 lines kept as a string, is
all the JavaScript there is. Using the shard needs none of this: the vendor
folder is in the repository.

## Upgrading Tailwind

Change `Oracle::VERSION` in `script/oracle.cr`, then:

```
crystal run script/vendor.cr
crystal spec
```

`vendor.cr` prints the roots it could not write as templates. The spec
records the new reference and shows every class whose output changed.
