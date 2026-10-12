require "spec"
require "json"
require "compress/gzip"
require "../src/tailwind"

# The differential spec: this compiler against real Tailwind's output,
# recorded in spec/fixtures/reference.json.gz by script/fixtures.cr. Each
# case is one build of Tailwind over its default theme; `rejected` is the
# classes Tailwind builds no rule for. spec/pending.txt lists the cases known
# to differ. `themes` is the same over each theme in spec/themes.
#
# The reference is not in the repository. It is recorded here when it is
# missing or older than what it is written from, which needs bun or node;
# without it the differential spec is skipped.
#
# TAILWIND_CASE=<substring> runs only the cases whose classes contain it.

private REFERENCE = "#{__DIR__}/fixtures/reference.json.gz"
private SOURCES   = ["#{__DIR__}/cases.txt", "#{__DIR__}/fixtures/local.txt", "#{__DIR__}/../script/fixtures.cr", "#{__DIR__}/../script/oracle.cr"] +
                    Dir.glob("#{__DIR__}/themes/*")

private def stale? : Bool
  return true unless File.exists?(REFERENCE)
  recorded = File.info(REFERENCE).modification_time
  SOURCES.any? { |path| File.exists?(path) && File.info(path).modification_time > recorded }
end

if stale? && (Process.find_executable("bun") || Process.find_executable("node"))
  Process.run("crystal", ["run", "#{__DIR__}/../script/fixtures.cr"], output: :inherit, error: :inherit)
end

unless File.exists?(REFERENCE)
  describe "Tailwind against Tailwind CSS" do
    pending "needs spec/fixtures/reference.json.gz, which script/fixtures.cr records with bun or node"
  end
else
  reference = File.open(REFERENCE) { |file| Compress::Gzip::Reader.open(file) { |gzip| JSON.parse(gzip) } }
  pending = File.read_lines("#{__DIR__}/pending.txt").reject { |line| line.empty? || line.starts_with?('#') }.to_set
  build = ->(classes : String) { Tailwind.compile(classes.split(' '), preflight: false) }

  describe "Tailwind against Tailwind CSS #{reference["version"]}" do
    it "was recorded from the Tailwind the vendored files came from" do
      reference["version"].should eq(Tailwind::TAILWIND_VERSION)
    end

    it "prints the preflight and the theme it reads" do
      Tailwind.compile([] of String).should eq(reference["preflight"].as_s)
    end

    it "builds every recorded case as Tailwind does, but the pending ones" do
      filter = ENV["TAILWIND_CASE"]?
      cases = reference["cases"].as_a
        .map { |example| {example[0].as_s, example[1].as_s} }
        .select { |classes, _| filter.nil? || classes.includes?(filter) }
      cases.should_not be_empty
      differ = cases.reject { |classes, css| build.call(classes) == css }
      unexpected = differ.reject { |classes, _| pending.includes?(classes) }
      unless unexpected.empty?
        report = unexpected.first(5).map { |classes, css| "#{classes}\n--- expected\n#{css}--- built\n#{build.call(classes)}" }
        fail "#{unexpected.size} of #{cases.size} cases differ:\n\n#{report.join("\n")}"
      end
      fixed = pending.select { |classes| cases.any? { |found, _| found == classes } } - differ.map(&.[0])
      fail "now built as Tailwind does; remove from pending.txt:\n#{fixed.join("\n")}" unless fixed.empty?
    end

    it "builds every recorded case over each theme in spec/themes as Tailwind does" do
      themes = reference["themes"].as_a
      themes.should_not be_empty
      themes.each do |theme|
        loaded = Tailwind::Theme.load(theme[1].as_s)
        differ = theme[2].as_a.reject { |example| Tailwind.compile(example[0].as_s.split(' '), loaded, preflight: false) == example[1].as_s }
        next if differ.empty?
        report = differ.first(5).map { |example| "#{example[0]}\n--- expected\n#{example[1]}--- built\n#{Tailwind.compile(example[0].as_s.split(' '), loaded, preflight: false)}" }
        fail "#{differ.size} cases differ over the #{theme[0]} theme:\n\n#{report.join("\n")}"
      end
    end

    it "writes no at-rule inside a rule and no width range for a recorded case when flat" do
      reference["cases"].as_a.each do |example|
        classes = example[0].as_s
        open = [] of String
        Tailwind.compile(classes.split(' '), preflight: false, flat: true).each_line do |line|
          text = line.strip
          next open.pop if text == "}"
          next unless text.ends_with?(" {")
          fail "#{classes}: #{text} inside #{open.last}" if text.starts_with?('@') && open.any? { |head| !head.starts_with?('@') }
          fail "#{classes}: #{text}" if text.matches?(/\A@media (not )?\(width [<>]/)
          open << text
        end
      end
    end

    it "reads every recorded and rejected class back as it is written" do
      theme = Tailwind::Theme.default
      names = reference["cases"].as_a.flat_map(&.[0].as_s.split(' ')) + reference["rejected"].as_a.map(&.as_s)
      names.uniq.each do |name|
        utility = Tailwind::Scan.split(name, ':').last
        utility = utility.ends_with?('!') ? utility.rchop('!') : utility.lchop('!')
        written = case reading = Tailwind.read(theme, utility)
                  in Tailwind::Read::Static then reading.name
                  in Nil                    then next
                  in Tailwind::Read::Functional
                    "#{reading.negative ? "-" : ""}#{reading.root}#{reading.value.try { |value| "-#{value}" }}#{reading.modifier.try { |modifier| "/#{modifier}" }}"
                  end
        fail "#{name} is read as #{written}" unless written == utility
      end
    end

    it "gives a reason for each class Tailwind rejects, and reads each one it builds" do
      theme = Tailwind::Theme.default
      rejected = reference["rejected"].as_a.map(&.as_s) - pending.to_a
      rejected.each { |name| fail "#{name} has no reason" unless Tailwind.why(theme, name) }
      # A case of one class is one Tailwind builds; a longer one may hold a class it does not.
      built = reference["cases"].as_a.map(&.[0].as_s).reject { |classes| classes.includes?(' ') || pending.includes?(classes) }
      built.each do |name|
        fail "#{name} has a reason" if Tailwind.why(theme, name)
        utility = Tailwind::Scan.split(name, ':').last
        fail "#{name} is not read" unless Tailwind.read(theme, utility) || utility.starts_with?('[')
      end
    end

    it "builds no rule for a class Tailwind rejects, but the pending ones" do
      theme = Tailwind::Theme.default
      rejected = reference["rejected"].as_a.map(&.as_s)
      built = rejected.select { |name| Tailwind.parse(theme, name) }
      (built - pending.to_a).should be_empty
      (pending.to_a & rejected - built).should be_empty
    end
  end
end

describe Tailwind do
  it "builds no rule for a word that is not a utility" do
    css = Tailwind.compile(["hero", "card-title", "p-4", "p-13.3", "bg-nope-500", "nope:p-4"], preflight: false)
    css.should contain(".p-4 {")
    css.should_not contain("hero")
    css.should_not contain("13")
    css.should_not contain("nope")
  end

  it "takes any text as a class" do
    odd = ["", "-", "--", "!", "!!", ":", "::", "a:", ":a", "[", "]", "[]", "()", "p-[", "p-]", "p-[]", "p-()", "p-(--)",
           "bg-[#", "[&]:", "[&]:p-1", "[:]", "[a:]", "/", "p-4/", "/4", "p-/", "@", "@:", "@md", "*:", "**", "group-", "group-:p-1",
           "not-", "has-[]:p-1", "data-[]:p-1", "supports-[]:p-1", "min-[]:p-1", "w-1/0", "p-1e9", "é", "p-é", "\u0000", " ", "p-4 m-4"]
    odd.each { |name| Tailwind.compile([name], preflight: false).should contain("@layer theme, base, components, utilities;") }
    theme = Tailwind::Theme.default
    odd.each do |name|
      Tailwind.read(theme, name)
      Tailwind.why(theme, name).nil?.should eq(!Tailwind.parse(theme, name).nil?)
    end
  end

  it "builds no rule for a value that would end its declaration or selector" do
    theme = Tailwind::Theme.default
    escapes = ["p-[1px;color:red]", "p-[1px}body{x]", "p-(--x}body{y)", "[color:red;x]", "[color:red}body{x]", "bg-red-500/[1}body{x]",
               "text-lg/[1;x]", "[&}body{x]:flex", "[&{x}]:flex", "[@media_x{}body{y}]:flex", "data-[x}body{y]:flex", "data-[x{y]:flex",
               "aria-['x]:flex", "has-[x}body{y]:flex", "group-[.x}body{y]:flex", "nth-[2n}body{x]:flex", "min-[1px)}body{x]:flex",
               "@[1px)}body{x]:flex", "@md/x}body{y:flex", "group-hover/x}body{y:flex", "peer-focus/x;y:flex"]
    escapes.each { |name| Tailwind.parse(theme, name).should be_nil }
  end

  it "builds no rule for a class that stacks or nests more variants than a person writes" do
    theme = Tailwind::Theme.default
    Tailwind.parse(theme, "#{"hover:" * 16}flex").should_not be_nil
    Tailwind.parse(theme, "#{"hover:" * 17}flex").should be_nil
    Tailwind.parse(theme, "#{"group-" * 15}hover:flex").should_not be_nil
    Tailwind.parse(theme, "#{"group-" * 16}hover:flex").should be_nil
    ["hover:", "md:", "not-", "group-", "has-", "in-", "peer-"].each do |part|
      Tailwind.compile(["#{part * 100_000}hover:flex"], preflight: false).should_not contain("flex")
    end
  end

  it "reads a project's tokens over the default theme" do
    theme = Tailwind::Theme.load(<<-CSS)
      @theme {
        --color-brand: #1d4ed8;
        --breakpoint-3xl: 120rem;
        --radius-lg: 1rem;
      }
      CSS
    css = Tailwind.compile(["bg-brand", "bg-brand/50", "3xl:rounded-lg", "text-red-500", "container"], theme, preflight: false)
    css.should contain("--color-brand: #1d4ed8;")
    css.should contain("--radius-lg: 1rem;")
    css.should contain("@media (width >= 120rem) {")
    css.should contain("background-color: var(--color-brand);")
    css.should contain("background-color: color-mix(in srgb, #1d4ed8 50%, transparent);")
    css.should contain("max-width: 120rem;")
    css.should contain("--color-red-500:")
  end

  it "makes dark: the selector of a theme's @custom-variant dark" do
    theme = Tailwind::Theme.load("@custom-variant dark (&:where(.dark, .dark *));")
    css = Tailwind.compile(["dark:flex", "dark:hover:underline"], theme, preflight: false)
    css.should contain(".dark\\:flex:where(.dark, .dark *) {")
    css.should contain(".dark\\:hover\\:underline:where(.dark, .dark *):hover {")
    css.should_not contain("prefers-color-scheme")
    Tailwind.compile(["dark:flex"], preflight: false).should contain("@media (prefers-color-scheme: dark) {")
  end

  it "takes no other @custom-variant" do
    expect_raises(Tailwind::Error) { Tailwind::Theme.load("@custom-variant hocus (&:hover, &:focus);") }
    expect_raises(Tailwind::Error) { Tailwind::Theme.load("@custom-variant dark ();") }
    expect_raises(Tailwind::Error) { Tailwind::Theme.load("@custom-variant dark { &:where(.dark *) { @slot; } }") }
  end

  it "writes the tokens of @theme static when no class reads them" do
    theme = Tailwind::Theme.load("@theme static { --color-brand: #1d4ed8; }\n@theme { --color-quiet: #64748b; }")
    css = Tailwind.compile(["flex"], theme, preflight: false)
    css.should contain("--color-brand: #1d4ed8;")
    css.should_not contain("--color-quiet")
  end

  it "writes no token of @theme reference, and its value as the fallback" do
    theme = Tailwind::Theme.load("@theme reference { --color-brand: #1d4ed8; }")
    css = Tailwind.compile(["bg-brand"], theme, preflight: false)
    css.should contain("background-color: var(--color-brand, #1d4ed8);")
    css.should_not contain("--color-brand: ")
  end

  it "takes a gradient's interpolation as a modifier" do
    css = Tailwind.compile(["bg-linear-to-r/oklch", "bg-conic/longer", "bg-radial/[in_hsl]"], preflight: false)
    css.should contain("--tw-gradient-position: to right in oklch;")
    css.should contain("--tw-gradient-position: in oklch longer hue;")
    css.should contain("--tw-gradient-position: in hsl;")
    Tailwind.parse(Tailwind::Theme.default, "bg-linear-[45deg]/oklch").should be_nil
  end

  it "drops a namespace a theme clears" do
    theme = Tailwind::Theme.load("@theme { --color-*: initial; --color-ink: #111; }")
    css = Tailwind.compile(["text-red-500", "text-ink"], theme, preflight: false)
    css.should contain("color: var(--color-ink);")
    css.should_not contain("red")
  end

  it "writes a theme's keyframes for the animations in use" do
    theme = Tailwind::Theme.load(<<-CSS)
      @theme {
        --animate-wiggle: wiggle 1s ease-in-out infinite;
        @keyframes wiggle {
          0%, 100% { rotate: -3deg; }
          50% { rotate: 3deg; }
        }
      }
      CSS
    css = Tailwind.compile(["animate-wiggle"], theme, preflight: false)
    css.should contain("animation: var(--animate-wiggle);")
    css.should contain("@keyframes wiggle {\n  0%, 100% {\n    rotate: -3deg;\n  }")
    css.should_not contain("@keyframes spin")
  end

  it "writes no nesting and no range syntax when flat" do
    theme = Tailwind::Theme.load("@theme { --color-paper: #ffffff; --breakpoint-*: initial; --breakpoint-sm: 40rem; --breakpoint-md: 48rem; }")
    css = Tailwind.compile(["container", "text-paper/80", "max-md:hidden", "md:p-4"], theme, preflight: false, flat: true)
    css.should contain(<<-CSS)
      @layer utilities {
        .container {
          width: 100%;
        }
        @media (min-width: 40rem) {
          .container {
            max-width: 40rem;
          }
        }
        @media (min-width: 48rem) {
          .container {
            max-width: 48rem;
          }
        }
        .text-paper\\/80 {
          color: color-mix(in srgb, #ffffff 80%, transparent);
        }
        @supports (color: color-mix(in lab, red, red)) {
          .text-paper\\/80 {
            color: color-mix(in oklab, var(--color-paper) 80%, transparent);
          }
        }
        @media not all and (min-width: 48rem) {
          .max-md\\:hidden {
            display: none;
          }
        }
        @media (min-width: 48rem) {
          .md\\:p-4 {
            padding: calc(var(--spacing) * 4);
          }
        }
      }

      CSS
    nested = Tailwind.compile(["container", "text-paper/80", "max-md:hidden", "md:p-4"], theme, preflight: false)
    nested.should contain("  .text-paper\\/80 {\n    color: color-mix(in srgb, #ffffff 80%, transparent);\n    @supports")
    nested.should contain("@media (width < 48rem) {")
  end

  it "keeps a flat class's variants around its fallback, in one at-rule" do
    theme = Tailwind::Theme.load("@theme { --color-paper: #ffffff; }")
    css = Tailwind.compile(["md:hover:text-paper/80", "md:flex"], theme, preflight: false, flat: true)
    css.should contain(<<-CSS)
      @layer utilities {
        @media (min-width: 48rem) {
          .md\\:flex {
            display: flex;
          }
          @media (hover: hover) {
            .md\\:hover\\:text-paper\\/80:hover {
              color: color-mix(in srgb, #ffffff 80%, transparent);
            }
            @supports (color: color-mix(in lab, red, red)) {
              .md\\:hover\\:text-paper\\/80:hover {
                color: color-mix(in oklab, var(--color-paper) 80%, transparent);
              }
            }
          }
        }
      }

      CSS
  end

  it "writes a flat media query of one condition without range syntax, and any other as it is" do
    {
      "min-[600px]:flex"                        => "@media (min-width: 600px) {",
      "max-[calc(10px+1rem)]:flex"              => "@media not all and (min-width: calc(10px + 1rem)) {",
      "not-md:flex"                             => "@media not all and (min-width: 48rem) {",
      "not-max-md:flex"                         => "@media (min-width: 48rem) {",
      "not-hover:flex"                          => "@media not all and (hover: hover) {",
      "print:flex"                              => "@media print {",
      "@md:flex"                                => "@container (width >= 28rem) {",
      "[@media(width>=1px)and(width<5px)]:flex" => "@media (width>=1px)and(width<5px) {",
      "[@media(width>=600px)]:flex"             => "@media (width>=600px) {",
      "[@media(width_>=_600px)]:flex"           => "@media (min-width: 600px) {",
    }.each do |name, head|
      Tailwind.compile([name], preflight: false, flat: true).should contain(head)
    end
  end

  it "compiles candidates the caller parsed and changed" do
    theme = Tailwind::Theme.default
    classes = ["md:text-6xl", "p-4", "hero", "hover:bg-red-500/50"]
    candidates = classes.compact_map { |name| Tailwind.parse(theme, name) }
    Tailwind.compile(candidates, theme, flat: true, reads: "a { color: var(--color-blue-500) }").should eq(
      Tailwind.compile(classes, theme, flat: true, reads: "a { color: var(--color-blue-500) }"))

    fluid = candidates.map do |candidate|
      next candidate unless candidate.name.starts_with?("md:")
      nodes = candidate.rules.nodes.map do |node|
        next node unless node.is_a?(Tailwind::Decl) && node.property == "font-size"
        Tailwind::Decl.new("font-size", "clamp(var(--text-5xl), calc(1rem + 2.75 * 1.25vw), #{node.value})").as(Tailwind::Node)
      end
      candidate.copy_with(rules: candidate.rules.copy_with(nodes: nodes))
    end
    css = Tailwind.compile(fluid, theme, preflight: false)
    css.should contain("      font-size: clamp(var(--text-5xl), calc(1rem + 2.75 * 1.25vw), var(--text-6xl));\n      line-height: var(--tw-leading, var(--text-6xl--line-height));")
    css.should contain("--text-5xl: 3rem;")
    css.index!(".p-4 {").should be < css.index!(".md\\:text-6xl {")

    own = Tailwind::Candidate.new("card", [] of Tailwind::Variants::Variant, Tailwind::Rules.new([Tailwind::Block.new("@media print", [Tailwind::Decl.new("display", "none").as(Tailwind::Node)]).as(Tailwind::Node)]), false)
    Tailwind.compile([own], preflight: false).should contain("  @media print {\n    .card {\n      display: none;\n    }\n  }")
  end

  it "writes the tokens that other CSS reads, and the tokens those read" do
    theme = Tailwind::Theme.load("@theme { --color-ink: #111; --color-link: var(--color-ink); --color-quiet: #64748b; }")
    reads = "a { color: var(--color-link); margin: var(--gap, 1rem); }"
    css = Tailwind.compile(["flex"], theme, preflight: false, reads: reads)
    css.should contain("  :root, :host {\n    --color-ink: #111;\n    --color-link: var(--color-ink);\n  }")
    css.should_not contain("--color-quiet")
    css.should_not contain("--gap")
    css.should_not contain("margin")
    Tailwind.compile(["flex"], theme, preflight: false).should_not contain("@layer theme {")
  end

  it "builds no rule from a token of a longer namespace" do
    theme = Tailwind::Theme.default
    ["top-shadow-2xs", "inset-x-shadow-sm", "font-weight-bold"].each { |name| Tailwind.parse(theme, name).should be_nil }
    ["inset-shadow-2xs", "font-bold", "font-sans", "text-shadow-sm", "top-4"].each { |name| Tailwind.parse(theme, name).should_not be_nil }
  end

  it "says how a class without its variants is read" do
    theme = Tailwind::Theme.load("@theme { --color-ink: #111; }")
    {
      "flex"                  => Tailwind::Read::Static.new("flex"),
      "-bottom-full"          => Tailwind::Read::Static.new("-bottom-full"),
      "container"             => Tailwind::Read::Static.new("container"),
      "border-collapse"       => Tailwind::Read::Static.new("border-collapse"),
      "border-t-2"            => Tailwind::Read::Functional.new("border-t", "2", nil, false),
      "-mt-4"                 => Tailwind::Read::Functional.new("mt", "4", nil, true),
      "bg-ink/50"             => Tailwind::Read::Functional.new("bg", "ink", "50", false),
      "bg-ink/50!"            => Tailwind::Read::Functional.new("bg", "ink", "50", false),
      "text-shadow-lg"        => Tailwind::Read::Functional.new("text-shadow", "lg", nil, false),
      "text-lg"               => Tailwind::Read::Functional.new("text", "lg", nil, false),
      "rounded"               => Tailwind::Read::Functional.new("rounded", nil, nil, false),
      "w-1/2"                 => Tailwind::Read::Functional.new("w", "1", "2", false),
      "p-[13px]"              => Tailwind::Read::Functional.new("p", "[13px]", nil, false),
      "[mask-type:luminance]" => nil,
      "hero"                  => nil,
      "card-title"            => nil,
      "-hero"                 => nil,
      ""                      => nil,
    }.each do |name, reading|
      Tailwind.read(theme, name).should eq(reading)
    end
  end

  it "reads a class that does not build by the longest root its name starts with" do
    theme = Tailwind::Theme.default
    {
      "text-shadow-nope" => Tailwind::Read::Functional.new("text-shadow", "nope", nil, false),
      "bg-linear-nope"   => Tailwind::Read::Functional.new("bg-linear", "nope", nil, false),
      "border-t-nope/50" => Tailwind::Read::Functional.new("border-t", "nope", "50", false),
      "-mt-nope"         => Tailwind::Read::Functional.new("mt", "nope", nil, true),
      "bg"               => Tailwind::Read::Functional.new("bg", nil, nil, false),
      "gap-x"            => Tailwind::Read::Functional.new("gap-x", nil, nil, false),
      "bg-linear"        => Tailwind::Read::Functional.new("bg-linear", nil, nil, false),
      "bg-ink/50/2"      => Tailwind::Read::Functional.new("bg", "ink", "50/2", false),
      "-p-4"             => nil,
      "-flex"            => nil,
      "hidden/50"        => nil,
      "[color:red;x]"    => nil,
    }.each do |name, reading|
      Tailwind.parse(theme, name).should be_nil
      Tailwind.read(theme, name).should eq(reading)
    end
  end

  it "reads a class by a shorter root when the longest does not build it" do
    theme = Tailwind::Theme.load("@theme { --color-shadow-brand: #1d4ed8; }")
    Tailwind.read(theme, "text-shadow-brand").should eq(Tailwind::Read::Functional.new("text", "shadow-brand", nil, false))
    Tailwind.read(Tailwind::Theme.default, "text-shadow-brand").should eq(Tailwind::Read::Functional.new("text-shadow", "brand", nil, false))
  end

  it "says why a class builds no rule" do
    theme = Tailwind::Theme.load("@theme { --color-*: initial; --color-ink: #111; --radius-*: initial; --radius-sm: 0.25rem; --radius-md: 0.375rem; }")
    colors = ["--background-color", "--color", "--background-image"]
    spacing = ["--padding", "--spacing"]
    {
      "flex"               => nil,
      "md:hover:bg-ink/50" => nil,
      "rounded-md"         => nil,
      "hero"               => Tailwind::Why::NotUtility.new,
      "md:hero"            => Tailwind::Why::NotUtility.new,
      "dank:hero"          => Tailwind::Why::NotUtility.new,
      "dank:flex"          => Tailwind::Why::UnknownVariant.new("dank"),
      "md:dank:flex!"      => Tailwind::Why::UnknownVariant.new("dank"),
      "3xl:flex"           => Tailwind::Why::UnknownVariant.new("3xl"),
      "group-dank:bg-nope" => Tailwind::Why::UnknownVariant.new("group-dank"),
      "bg-red-500"         => Tailwind::Why::NoValue.new("bg", "red-500", colors),
      "md:bg-red-500/50"   => Tailwind::Why::NoValue.new("bg", "red-500", colors),
      "bg"                 => Tailwind::Why::NoValue.new("bg", nil, colors),
      "rounded-huge"       => Tailwind::Why::NoValue.new("rounded", "huge", ["--radius"]),
      "p-13.3"             => Tailwind::Why::NoValue.new("p", "13.3", spacing),
      "p-[13px]-x"         => Tailwind::Why::NoValue.new("p", "[13px]-x", spacing),
      "-mt-nope"           => Tailwind::Why::NoValue.new("mt", "nope", ["--margin", "--spacing"]),
      "-p-4"               => Tailwind::Why::NoNegative.new("p"),
      "-p-4/2"             => Tailwind::Why::NoNegative.new("p"),
      "-p-nope"            => Tailwind::Why::NoNegative.new("p"),
      "-hero"              => Tailwind::Why::NotUtility.new,
      "p-4/2/3"            => Tailwind::Why::NoModifier.new("p", "2/3"),
      "hero/2/3"           => Tailwind::Why::NotUtility.new,
      "gap-x"              => Tailwind::Why::NoValue.new("gap-x", nil, ["--gap", "--spacing"]),
      "[color]"            => Tailwind::Why::NotUtility.new,
      "-mt-auto"           => Tailwind::Why::NoNegative.new("mt-auto"),
      "-inset-shadow-sm"   => Tailwind::Why::NoNegative.new("inset-shadow"),
      "-flex"              => Tailwind::Why::NoNegative.new("flex"),
      "p-4/2"              => Tailwind::Why::NoModifier.new("p", "2"),
      "bg-ink/abc"         => Tailwind::Why::NoModifier.new("bg", "abc"),
      "hidden/50"          => Tailwind::Why::NoModifier.new("hidden", "50"),
      "w-full/2"           => Tailwind::Why::NoModifier.new("w-full", "2"),
      "p-[13px]/50"        => Tailwind::Why::NoModifier.new("p", "50"),
      "p-[1px;color:red]"  => Tailwind::Why::Refused.new("[1px;color:red]"),
      "p-(--x;y)"          => Tailwind::Why::Refused.new("(--x;y)"),
      "bg-ink/[1}body{x]"  => Tailwind::Why::Refused.new("[1}body{x]"),
      "[color:red;x]"      => Tailwind::Why::Refused.new("red;x"),
    }.each do |name, reason|
      Tailwind.why(theme, name).should eq(reason)
    end
  end

  it "names the namespaces a root reads, in lookup order, and the theme names the tokens in each" do
    theme = Tailwind::Theme.load("@theme { --text-*: initial; --text-lg: 1.125rem; --text-lg--line-height: 1.75; --text-shadow-glow: 0 0 4px #fff; --color-*: initial; --color-ink: #111; }")
    reason = Tailwind.why(theme, "text-nope").as(Tailwind::Why::NoValue)
    reason.namespaces.should eq(["--text-color", "--color", "--text"])
    reason.namespaces.map { |namespace| theme.names(namespace) }.should eq([[] of String, ["ink"], ["lg"]])
    reason = Tailwind.why(theme, "text-shadow-nope").as(Tailwind::Why::NoValue)
    reason.namespaces.should eq(["--text-shadow", "--color"])
    theme.names("--text-shadow").should eq(["glow"])
    reason = Tailwind.why(Tailwind::Theme.default, "max-w-nope").as(Tailwind::Why::NoValue)
    reason.namespaces.should eq(["--max-width", "--spacing", "--container"])
    Tailwind::Theme.default.names("--container").should eq(["3xs", "2xs", "xs", "sm", "md", "lg", "xl", "2xl", "3xl", "4xl", "5xl", "6xl", "7xl"])
  end
end
