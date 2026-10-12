require "compress/gzip"
require "./oracle"

# Writes spec/fixtures/reference.json.gz, what the differential spec holds
# the compiler to:
#
#   crystal run script/fixtures.cr
#
# { "version", "preflight": <css with no classes>, "cases": [[classes, css]],
#   "rejected": [class], "themes": [[name, theme css, [[classes, css]]]] }
#
# A case is one build of real Tailwind over its default theme, without the
# preflight, which is compared once. The cases are spec/cases.txt, written
# by hand; spec/fixtures/local.txt, when it is there; and the ones written
# here from Tailwind itself: every functional root with each kind of value,
# every variant, every static utility, and two builds of all of them
# together. A line that builds no rule is left out. `rejected` is the other
# side: each root and variant with values Tailwind builds no rule for.
#
# `themes` is the same over a project's theme: each spec/themes/<name>.css,
# with the builds of the lines of <name>.txt and of all of them together.
#
# `crystal spec` runs this when the reference is missing or older than its
# sources.
class Fixtures
  SPEC = "#{__DIR__}/../spec"

  # After each functional root: the root alone, arbitrary values of each
  # type, hints, and bare values.
  VALUES = ["", "-[13px]", "-[#123456]", "-[7]", "-[13%]", "-[var(--zz)]", "-(--zz)", "-[length:var(--zz)]", "-[color:var(--zz)]",
            "-[url(zz.png)]", "-[calc(1rem+2px)]", "-[#123456]/50", "-3", "-2.5", "-1/3", "-25%", "-[2_3]"]

  # What Tailwind may not take after a root, a static utility, or as a variant.
  ODD_VALUES = VALUES + ["-0.3", "-150", "-red-500", "-red-500/50", "-red-500/150", "-lg", "-lg/7", "-full", "-auto", "-none",
                         "-px", "-nope", "-[13px]/50", "-3/[0.5]", "-[]", "-()", "-3!", "--3", "-03", "-3.50", "-1e3", "-[13px]-x",
                         "-[1px;2px]", "-[1px}a{b]", "-[1px)]", "-(--zz;a)", "-(--zz}a{b)", "-[13px]/[1;2]", "-[13px]/[1}a{b]",
                         # A token of a longer namespace: `--inset-shadow-2xs` is not `--inset`'s.
                         "-shadow-2xs", "-weight-bold"]
  ODD_STATICS  = ["/50", "-3", "-[13px]", "-nope"]
  ODD_VARIANTS = ["hover", "md", "group-hover", "not-hover", "has", "data", "aria-nope", "nth-x", "supports", "min", "max-nope",
                  "@nope", "group", "peer-", "in", "[", "[]", "[>p]", "dark/x", "md/x", "hover/x", "nth-1.5", "data-[]", "aria-[]",
                  "group-nope", "not-nope", "@md/", "**/x", "2xl", "3xl", "max-3xl", "min-nope",
                  "[&;a]", "[&}a{b]", "[&{a]", "[&'a]", "[@media_a}b{c]", "data-[a{b]", "data-['a]", "data-[a}b]", "aria-[(a;b)]",
                  "has-[a}b]", "not-[a;b]", "in-[a{b]", "group-[a}b]", "peer-['a]", "nth-[2n}a]", "supports-[a;b]", "min-[1px;2px]",
                  "max-[1px}a]", "@[1px}a]", "@[1px]/a}b", "@md/a{b", "@md/a;b", "group-hover/a}b", "group-hover/a;b", "peer-focus/'a'",
                  "group-hover/a/b",
                  "group-md", "peer-print", "in-dark", "has-md", "group-supports-grid", "in-@md", "peer-min-[400px]", "group-starting",
                  "group-before", "in-after", "has-marker", "not-before", "not-starting", "in-*", "has-**", "not-*", "group-*",
                  "group-[@media(print)]", "in-[&::before]", "not-[&::before]", "group-not-md", "group-not-hover", "has-not-hover",
                  "in-not-hover", "not-not-hover",
                  "nth-03", "nth-last-1.5", "nth-of-type--1", "aria-foo.bar", "aria-50%", "aria-(--x)", "data-foo.bar", "data-(--x)",
                  "data-[x=y]/a", "aria-busy/a", "supports-grid/a", "min-(--x)", "min-[var(--x)]", "max-[var(--x)]", "min-md/a",
                  "@[var(--x)]", "@max-(--x)", "@min-[var(--x)]"]
  # Gradients that take no interpolation, and modifiers that are not one.
  ODD_GRADIENTS = ["bg-linear-[45deg]/oklch", "bg-linear-(--zz)/oklch", "-bg-linear-to-r/oklch", "bg-linear-to-x/oklch", "bg-linear/oklch",
                   "bg-conic-[from_45deg]/oklch", "bg-radial-[at_top]/oklch", "bg-radial-3/oklch", "bg-gradient-to-r/oklch", "bg-linear-to-r/[]",
                   "bg-linear-to-r/()", "bg-linear-to-r/(zz)", "bg-linear-to-r/[in_hsl;a]", "bg-linear-to-r/[a}b]", "bg-linear-to-r/a/b",
                   "bg-linear-to-r/", "bg-conic/a,b", "bg-radial/(color:--zz)", "from-red-500/(color:--zz)"]
  # Shadows with a modifier that is no alpha, or that take none.
  ODD_SHADOWS = ["drop-shadow-lg/nope", "drop-shadow-[0_1px_red]/nope", "shadow-none/50", "shadow-inherit/50", "inset-shadow-none/50",
                 "text-shadow-inherit/50", "shadow-lg/[]", "shadow-lg/()", "shadow-lg/(zz)", "shadow-lg/50/50", "shadow-lg/a,b",
                 "shadow-[0_1px_red]/[1;2]", "shadow-red-500/nope", "shadow-[#123456]/nope"]
  # Arbitrary properties whose value would end the declaration.
  ODD_PROPERTIES = ["[color:red;a]", "[color:red}a{b]", "[color:red)]", "[color:red]/[1;2]", "[--x:a}b]"]

  @design : Int32
  @roots : Array(String)
  @statics : Array(String)
  @variants : Array(String)

  def initialize(@oracle : Oracle)
    @design = @oracle.load(@oracle.read("theme.css"))
    @roots = @oracle.keys(@design, "functional").sort!
    @statics = @oracle.keys(@design, "static").sort!
    @variants = @oracle.variants(@design)
  end

  def run : Nil
    pending = lines("#{SPEC}/pending.txt").to_set
    cases = lines("#{SPEC}/cases.txt") + lines("#{SPEC}/fixtures/local.txt") + generated
    # Every class of the cases in one build, and those with a variant in
    # another: the order of classes and the at-rules they share.
    all = cases.reject { |line| pending.includes?(line) }.flat_map(&.split).uniq!
    cases << all.select { |name| variant?(name) }.join(" ") << all.join(" ")

    built = cases.uniq.compact_map do |line|
      css = @oracle.build(input(preflight: false), line.split)
      {line.split.join(" "), css} if css.includes?("@layer utilities {")
    end
    Dir.mkdir_p("#{SPEC}/fixtures")
    File.open("#{SPEC}/fixtures/reference.json.gz", "w") do |file|
      Compress::Gzip::Writer.open(file, level: Compress::Gzip::BEST_COMPRESSION) do |gzip|
        {version: Oracle::VERSION, preflight: @oracle.build(input(preflight: true), [] of String), cases: built, rejected: rejected, themes: themes}.to_json(gzip)
      end
    end
    puts "recorded #{built.size} cases from tailwindcss #{Oracle::VERSION}"
  end

  private def themes : Array({String, String, Array({String, String})})
    Dir.glob("#{SPEC}/themes/*.css").sort.map do |path|
      css = File.read(path)
      cases = lines(path.rchop(".css") + ".txt")
      cases << cases.flat_map(&.split).uniq.join(" ")
      built = cases.compact_map do |line|
        found = @oracle.build(input(preflight: false) + css, line.split)
        {line.split.join(" "), found} if found.includes?("@layer utilities {")
      end
      {File.basename(path, ".css"), css, built}
    end
  end

  # Whether a class has a `:` outside its brackets.
  private def variant?(name : String) : Bool
    depth = 0
    name.each_char do |c|
      case c
      when '[', '(' then depth += 1
      when ']', ')' then depth -= 1
      when ':'      then return true if depth == 0
      end
    end
    false
  end

  private def lines(path : String) : Array(String)
    return [] of String unless File.exists?(path)
    File.read_lines(path).reject { |line| line.blank? || line.starts_with?('#') }
  end

  private def input(preflight : Bool) : String
    <<-CSS
      @layer theme, base, components, utilities;
      @import "tailwindcss/theme.css" layer(theme);
      #{preflight ? %(@import "tailwindcss/preflight.css" layer(base);) : ""}
      @import "tailwindcss/utilities.css" layer(utilities);

      CSS
  end

  # The cases Tailwind itself can name.
  private def generated : Array(String)
    suggested = @oracle.classes(@design)
    by_root = @roots.to_h { |root| {root, [] of {String, Array(String)}} }
    suggested.zip(@oracle.parse(@design, suggested.map(&.[0]))) do |suggestion, candidate|
      next unless candidate["kind"]? == "functional"
      by_root[candidate["root"].as_s]?.try(&.<< suggestion)
    end

    cases = [] of String
    # Each root: named values spread over what Tailwind suggests, one with
    # each kind of modifier, and VALUES.
    @roots.each do |root|
      named = by_root[root]
      {0, 1, 2, named.size // 3, named.size // 2, 2 * named.size // 3, named.size - 2, named.size - 1}.each do |i|
        cases << named[i][0] if 0 <= i < named.size
      end
      if modified = named.find { |_, modifiers| !modifiers.empty? }
        name, modifiers = modified
        cases << "#{name}/#{modifiers[modifiers.size // 2]}" << "#{name}/[0.35]" << "#{name}/(--zz)"
      end
      VALUES.each { |value| cases << root + value }
    end
    # Each variant alone, then all of them on one utility, for their order.
    @variants.each { |variant| cases << "#{variant}:flex" }
    @variants.each_slice(18) { |slice| cases << slice.join(" ") { |variant| "#{variant}:p-1" } }
    # A class of each root, and every static utility, in groups, for the
    # order of utilities.
    sample = @roots.reject(&.starts_with?('-')).compact_map { |root| (by_root[root][1]? || by_root[root][0]?).try(&.[0]) }
    sample.each_slice(30) { |slice| cases << slice.join(" ") }
    @statics.each_slice(40) { |slice| cases << slice.join(" ") }
    cases
  end

  # Classes Tailwind builds no rule for.
  private def rejected : Array(String)
    tries = @roots.flat_map { |root| ODD_VALUES.map { |value| root + value } } +
            @statics.flat_map { |name| ODD_STATICS.map { |value| name + value } } +
            ODD_VARIANTS.map { |variant| "#{variant}:flex" } + ODD_GRADIENTS + ODD_SHADOWS + ODD_PROPERTIES
    tries.uniq!
    tries.zip(@oracle.compile(@design, tries)).compact_map { |name, found| name if found.empty? }
  end
end

Fixtures.new(Oracle.new).run
