require "spec"
require "../src/tailwind"

describe Tailwind::Theme do
  it "starts from Tailwind's default theme" do
    theme = Tailwind::Theme.load("")
    theme["--spacing"]?.should eq("0.25rem")
    theme["--color-red-500"]?.should eq("oklch(63.7% 0.237 25.331)")
    theme.breakpoints.map(&.[0]).should eq(["sm", "md", "lg", "xl", "2xl"])
    theme.keyframes.keys.should eq(["spin", "ping", "pulse", "bounce"])
  end

  it "reads tokens, comments and a value over several lines" do
    theme = Tailwind::Theme.load(<<-CSS)
      /* brand */
      @theme {
        --color-brand: #1d4ed8; /* blue */
        --font-display:
          "Fraunces", serif;
        --shadow-card: 0 1px 2px rgb(0 0 0 / 0.1), 0 0 0 1px rgb(0 0 0 / 0.05);
      }
      CSS
    theme["--color-brand"]?.should eq("#1d4ed8")
    theme["--font-display"]?.should eq(%("Fraunces", serif))
    theme["--shadow-card"]?.should eq("0 1px 2px rgb(0 0 0 / 0.1), 0 0 0 1px rgb(0 0 0 / 0.05)")
    theme.resolve("--color", "brand").should eq("var(--color-brand)")
    theme.resolve("--color", "nope").should be_nil
  end

  it "keeps a replaced token where the default was" do
    theme = Tailwind::Theme.load("@theme { --breakpoint-md: 50rem; --breakpoint-xs: 30rem; }")
    theme.breakpoints.should eq([{"xs", "30rem"}, {"sm", "40rem"}, {"md", "50rem"}, {"lg", "64rem"}, {"xl", "80rem"}, {"2xl", "96rem"}])
    theme.vars.keys.index("--breakpoint-md").not_nil!.should be < theme.vars.keys.index("--breakpoint-lg").not_nil!
  end

  it "writes an inline token by its value" do
    theme = Tailwind::Theme.load("@theme inline { --radius-card: 12px; }")
    theme.resolve("--radius", "card").should eq("12px")
    theme.resolve("--radius", "lg").should eq("var(--radius-lg)")
  end

  it "clears a namespace, or everything" do
    Tailwind::Theme.load("@theme { --color-*: initial; }").vars.keys.any?(&.starts_with?("--color-")).should be_false
    Tailwind::Theme.load("@theme { --*: initial; --spacing: 4px; }").vars.should eq({"--spacing" => "4px"})
  end

  it "does not change the default theme" do
    Tailwind::Theme.load("@theme { --spacing: 1px; }")
    Tailwind::Theme.default["--spacing"]?.should eq("0.25rem")
  end

  it "says where a theme does not parse" do
    {
      "@theme {\n  --color-brand #fff;\n}" => 2,
      "\n\n.card { color: red; }"          => 3,
      "@theme {\n  --a: 1;\n"              => 1,
      "@theme { --a: 1; }\n/* open"        => 2,
    }.each do |css, line|
      error = expect_raises(Tailwind::Error) { Tailwind::Theme.load(css) }
      error.line.should eq(line)
    end
  end

  it "loads over a base the caller gives, and leaves the base as it was" do
    base = Tailwind::Theme.load("@theme { --spacing: 0.25rem; --breakpoint-md: 48rem; --color-ink: #111; }", Tailwind::Theme.new)
    base.vars.keys.should eq(["--spacing", "--breakpoint-md", "--color-ink"])
    theme = Tailwind::Theme.load("@theme inline { --color-ink: #222; --color-paper: #fff; }\n@custom-variant dark (&:where(.dark *));", base)
    theme.vars.should eq({"--spacing" => "0.25rem", "--breakpoint-md" => "48rem", "--color-ink" => "#222", "--color-paper" => "#fff"})
    theme.resolve("--color", "ink").should eq("#222")
    theme.resolve("--color", "red-500").should be_nil
    theme.keyframes.should be_empty
    base["--color-ink"]?.should eq("#111")
    base.resolve("--color", "ink").should eq("var(--color-ink)")
    base.has?("--color-paper").should be_false
    base.dark.should be_nil
    Tailwind::Theme.load("", base).vars.should eq(base.vars)
  end

  it "says the line in the caller's CSS when it loads over a base" do
    base = Tailwind::Theme.load("@theme {\n  --spacing: 0.25rem;\n\n\n}\n", Tailwind::Theme.new)
    error = expect_raises(Tailwind::Error) { Tailwind::Theme.load("@theme {\n  --color-brand #fff;\n}", base) }
    error.line.should eq(2)
  end

  it "reads no token of a longer namespace, and names none" do
    theme = Tailwind::Theme.default
    theme.resolve("--inset", "shadow-2xs").should be_nil
    theme.resolve("--font", "weight-bold").should be_nil
    theme.resolve("--font-weight", "bold").should eq("var(--font-weight-bold)")
    theme.resolve("--inset-shadow", "2xs").should eq("var(--inset-shadow-2xs)")
    theme.names("--font").should eq(["sans", "serif", "mono"])
    theme.names("--text").should eq(["xs", "sm", "base", "lg", "xl", "2xl", "3xl", "4xl", "5xl", "6xl", "7xl", "8xl", "9xl"])
    theme.names("--inset").should be_empty
    theme.names("--spacing").should be_empty
    theme.names("--nope").should be_empty
  end
end
