require "spec"
require "../src/tailwind"

describe Tailwind::Value do
  # Each of these is also a class in spec/fixtures/cases.txt, so the result
  # is what Tailwind writes.
  it "decodes an arbitrary value" do
    {
      "1fr_auto"                           => "1fr auto",
      "'a_b'"                              => "'a b'",
      "'a\\_b'"                            => "'a_b'",
      "var(--my_var)"                      => "var(--my_var)",
      "url('/a_b-c.png')"                  => "url('/a_b-c.png')",
      "200px_minmax(900px,_1fr)_100px"     => "200px minmax(900px, 1fr) 100px",
      "calc(100%-2rem)"                    => "calc(100% - 2rem)",
      "calc(100vh_-_4rem)"                 => "calc(100vh - 4rem)",
      "calc(100dvh-4rem-1px)"              => "calc(100dvh - 4rem - 1px)",
      "calc(1px*-1)"                       => "calc(1px * -1)",
      "calc(1px+-2px)"                     => "calc(1px + -2px)",
      "calc(-1*var(--x))"                  => "calc(-1 * var(--x))",
      "calc(var(--a)-1px)"                 => "calc(var(--a) - 1px)",
      "calc(10px-var(--a))"                => "calc(10px - var(--a))",
      "calc(var(--my_var)+1px)"            => "calc(var(--my_var) + 1px)",
      "calc(var(--a,1px)+2px)"             => "calc(var(--a,1px) + 2px)",
      "calc((100%-2rem)/2)"                => "calc((100% - 2rem) / 2)",
      "calc(.5rem+1px)"                    => "calc(.5rem + 1px)",
      "min(100%,20rem)"                    => "min(100%, 20rem)",
      "max(1px,calc(2px+3px))"             => "max(1px, calc(2px + 3px))",
      "clamp(1rem,2vw+1rem,3rem)"          => "clamp(1rem, 2vw + 1rem, 3rem)",
      "round(up,10.5px,1px)"               => "round(up, 10.5px, 1px)",
      "repeat(2,minmax(0,calc(50%-1rem)))" => "repeat(2,minmax(0,calc(50% - 1rem)))",
    }.each { |raw, css| Tailwind::Value.decode(raw).should eq(css) }
  end

  it "reads a value in brackets, with its hint" do
    Tailwind::Value.parse("[13px]").should eq(Tailwind::Value::Arbitrary.new("13px", nil))
    Tailwind::Value.parse("[length:var(--y)]").should eq(Tailwind::Value::Arbitrary.new("var(--y)", "length"))
    Tailwind::Value.parse("(--x)").should eq(Tailwind::Value::Arbitrary.new("var(--x)", nil))
    Tailwind::Value.parse("(color:--x)").should eq(Tailwind::Value::Arbitrary.new("var(--x)", "color"))
    Tailwind::Value.parse("[]").should be_nil
    Tailwind::Value.parse("(x)").should be_nil
  end

  it "tells which of a root's types a value is, as Tailwind tests them" do
    {
      {"#fff", %w[color length]}                     => "color",
      {"13px", %w[color length]}                     => "length",
      {"13px", %w[length position bg-size]}          => "position",
      {"50%", %w[percentage position]}               => "percentage",
      {"1px 2px", %w[color line-width length]}       => "line-width",
      {"thin", %w[color line-width length]}          => "line-width",
      {"auto 100%", %w[position bg-size length]}     => "bg-size",
      {"url(a.png)", %w[image color url]}            => "image",
      {"1 2 3", %w[angle vector]}                    => "vector",
      {"45deg", %w[angle vector]}                    => "angle",
      {"Inter", %w[number generic-name family-name]} => "family-name",
      {"450", %w[number generic-name family-name]}   => "number",
      {"xx-large", %w[color length absolute-size]}   => "absolute-size",
      {"calc(1px + 2px)", %w[color number length]}   => "length",
      {"1px 2px", %w[color length]}                  => nil,
      {"var(--x)", %w[color length]}                 => nil,
    }.each { |(text, among), kind| Tailwind::Value.kind(text, among).should eq(kind) }
  end
end
