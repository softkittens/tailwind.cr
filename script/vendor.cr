require "./oracle"

# Writes what the shard takes from Tailwind CSS into src/tailwind/vendor/:
# the license and version, the default theme, the preflight as Tailwind
# prints it, the property order utilities are sorted by, and every utility
# as data. Run after changing Oracle::VERSION:
#
#   crystal run script/vendor.cr
#
# static.json holds every class that takes no value, as the default theme
# builds it: the static utilities, and the keywords of the functional ones
# (list-disc, transition-all), which are the named values that are not a
# number and build a rule with no theme at all.
#
# functional.json holds each functional root as templates, a rule with §
# where the value goes, and which template each kind of value fills:
#   t         the templates
#   any       the template for an arbitrary value of no known type
#   types     the template for an arbitrary value of a type, where not `any`
#   hints     the template for a type hint ([length:…]), where not `any`
#   theme     [namespace, template] in lookup order, for a named value
#   base      [namespace, template] in lookup order, for the root alone;
#             [null, template] when the template is the whole rule
#   number    {template, decimals} for a bare number, and whether it may
#             be a decimal, which is then a multiple of 0.25
#   exact     the template, with no §, for the numbers that are not `number` filled in
#   percent   the template for a bare percentage (from-10%)
#   fraction  {template, separator} for a/b, written with that separator
#
# A rule is {nodes, properties}: a declaration is [property, value], a
# nested rule or at-rule is {head, nodes}, and properties are the names of
# the custom properties it registers, whose [syntax, initial] are in
# properties.json.
#
# variants.json holds every variant as [name, heads], in Tailwind's order,
# which is the order classes are sorted by. The heads are what a variant
# that takes no value wraps a rule in, outermost first, a head of several
# lines being a rule for each. A variant with none takes a value
# (`group-…`, `min-…`), and is built in src/tailwind/variants.cr.
class Vendor
  OUT     = "#{__DIR__}/../src/tailwind/vendor"
  HOLE    = "§"
  NUMERIC = /\A\d[\d.]*(\/\d+)?%?\z/

  # A value of each type, as written in a class and, where that differs, as
  # it appears in the rule.
  TYPES = {
    "color" => {"#12345a", nil}, "length" => {"13.37px", nil}, "percentage" => {"13.37%", nil}, "number" => {"7.37", nil},
    "integer" => {"73", nil}, "url" => {"url(zz.png)", nil}, "image" => {"linear-gradient(red,blue)", nil},
    "angle" => {"13.37deg", nil}, "position" => {"13.37px_top", "13.37px top"}, "bg-size" => {"13.37px_auto", "13.37px auto"},
    "line-width" => {"7.37_thick", "7.37 thick"}, "vector" => {"7_3_1", "7 3 1"}, "generic-name" => {"serif", nil},
    "family-name" => {"zz_qq", "zz qq"}, "absolute-size" => {"xx-small", nil}, "relative-size" => {"larger", nil},
  }
  HINTS = %w[color length percentage number integer url image position bg-size size line-width angle family-name
    generic-name absolute-size relative-size ratio vector]

  @theme : String
  # Design systems: over the default theme, and over no theme at all.
  @design : Int32
  @bare : Int32
  @namespaces : Array(String)

  def initialize(@oracle : Oracle)
    @theme = @oracle.read("theme.css")
    @design = @oracle.load(@theme)
    @bare = @oracle.load("")
    @registered = {} of String => {String, String?}
    @rules = {} of {Int32, String} => String?
    @probes = {} of String => Int32
    # Every theme namespace Tailwind's source names.
    @namespaces = @oracle.read("dist/lib.js").scan(/"(--[a-z][a-z-]*[a-z])"/).map(&.[1]).uniq!
      .reject { |name| name.starts_with?("--tw-") || name.starts_with?("--default-") }.sort!
  end

  def run : Nil
    Dir.mkdir_p(OUT)
    write "VERSION", Oracle::VERSION + "\n"
    write "LICENSE", @oracle.read("LICENSE")
    write "theme.css", @theme
    write "preflight.css", preflight
    write "property_order.txt", property_order
    statics = self.statics
    functional, review = functional(statics)
    write "static.json", table(statics)
    write "functional.json", table(functional)
    write "properties.json", table(@registered.to_a.sort_by!(&.[0]).to_h.transform_values(&.to_json))
    write "variants.json", variants
    puts "vendored tailwindcss #{Oracle::VERSION}: #{statics.size} static classes, #{functional.size} functional roots"
    puts "not read from the theme by a token's name, so written by hand in src/tailwind/roots.cr: #{review.join(" ")}"
  end

  private def write(name : String, text : String) : Nil
    File.write("#{OUT}/#{name}", text)
  end

  # One entry a line, so a change to one class is one line of a diff.
  private def table(entries : Hash(String, String)) : String
    "{\n" + entries.join(",\n") { |name, json| "#{name.to_json}: #{json}" } + "\n}\n"
  end

  # The preflight as Tailwind prints it, with every default font token
  # defined so each reads var(--default-…, <fallback>). The compiler leaves
  # the bare fallback for a token a theme does not declare.
  private def preflight : String
    tokens = ["", "mono-"].flat_map { |kind| %w[family feature-settings variation-settings].map { |part| "--default-#{kind}font-#{part}: x;" } }
    css = @oracle.build("@layer theme { @theme { #{tokens.join(" ")} } }\n@import \"tailwindcss/preflight.css\" layer(base);", [] of String)
    start = css.index!("@layer base {")
    css[start...(css.index!("\n}\n", start) + 3)]
  end

  # The property order, from the bundle.
  private def property_order : String
    bundle = @oracle.read("dist/lib.js")
    start = bundle.index(%(["container-type","pointer-events")) || abort "the property order is not where it was in dist/lib.js"
    Array(String).from_json(bundle[start..bundle.index!("]", start)]).join("\n") + "\n"
  end

  # The variants over no theme, so none is a theme's breakpoint.
  private def variants : String
    fixed = @oracle.variants(@bare).to_set
    names = @oracle.order(@bare)
    built = @oracle.compile(@bare, names.map { |name| "#{name}:flex" })
    entries = names.zip(built).map do |name, found|
      next [name, [] of String].to_json unless fixed.includes?(name)
      raise "#{name}: builds #{found.size} rules" unless found.size == 1
      [name, heads(found[0]["nodes"].as_a)].to_json
    end
    "[\n" + entries.join(",\n") + "\n]\n"
  end

  # The rules and at-rules among `nodes`, side by side, then those inside
  # the first of them.
  private def heads(nodes : Array(JSON::Any)) : Array(String)
    blocks = nodes.select { |node| node["kind"] == "rule" || node["kind"] == "at-rule" }
    return [] of String if blocks.empty?
    level = blocks.join('\n') { |node| node["kind"] == "rule" ? node["selector"].as_s : "#{node["name"]} #{node["params"]}".strip }
    [level] + heads(blocks[0]["nodes"].as_a)
  end

  private def statics : Hash(String, String)
    own = @oracle.keys(@design, "static").to_set
    names = (own.to_a + @oracle.classes(@design).map(&.[0])).uniq!.sort!
    others = names.reject { |name| own.includes?(name) }
    keywords = others.zip(@oracle.parse(@design, others)).compact_map do |name, candidate|
      next unless candidate["kind"]? == "functional" && candidate.dig?("value", "kind") == "named"
      name unless candidate.dig("value", "value").as_s.matches?(NUMERIC)
    end
    compile(@bare, keywords)
    keep = names.select { |name| own.includes?(name) || (keywords.includes?(name) && rule(@bare, name)) }
    compile(@design, keep)
    keep.compact_map { |name| rule(@design, name).try { |found| {name, found} } }.to_h
  end

  # The rows, and the roots a row does not fully describe.
  private def functional(statics : Hash(String, String)) : {Hash(String, String), Array(String)}
    rows = {} of String => String
    review = [] of String
    @oracle.keys(@design, "functional").sort!.each do |root|
      compile(@design, ["[var(--zz)]"].concat(TYPES.values.map { |raw, _| "[#{raw}]" }).concat(HINTS.map { |hint| "[#{hint}:var(--zz)]" })
        .concat(%w[73 79 7.5 0 1 73% 73/79]).map { |value| "#{root}-#{value}" } << root)
      templates = [] of String
      template = ->(system : Int32, name : String, value : String) { template(templates, system, name, value) }
      row = [] of String

      any = template.call(@design, "#{root}-[var(--zz)]", "var(--zz)")
      row << %("any":#{any}) if any
      types = TYPES.compact_map do |type, (raw, written)|
        index = template.call(@design, "#{root}-[#{raw}]", written || raw)
        {type, index} if index && index != any
      end.to_h
      row << %("types":#{types.to_json}) unless types.empty?
      hints = HINTS.compact_map do |hint|
        index = template.call(@design, "#{root}-[#{hint}:var(--zz)]", "var(--zz)")
        {hint, index} if index && index != any
      end.to_h
      row << %("hints":#{hints.to_json}) unless hints.empty?

      # A theme with a token `zzq` in every namespace shows which one the
      # root reads; without that one, which it reads next.
      theme = [] of {String, Int32?}
      loop do
        system = probe(theme.map(&.[0]))
        found = rule(system, "#{root}-zzq") || break
        used = found.match(/var\((--[a-z-]+)-zzq\)/).try(&.[1])
        if used.nil? || theme.any? { |namespace, _| namespace == used }
          review << "#{root}-<theme>"
          break
        end
        theme << {used, template.call(system, "#{root}-zzq", "var(#{used}-zzq)")}
      end
      row << %("theme":#{theme.to_json}) unless theme.empty?

      if rule(@design, root) && !statics.has_key?(root)
        base = [] of {String?, Int32?}
        loop do
          system = probe(base.compact_map(&.[0]))
          used = rule(system, root).try(&.match(/var\((--[a-z-]+)\)/)).try(&.[1])
          break if used.nil? || !@namespaces.includes?(used) || base.any? { |namespace, _| namespace == used }
          base << {used, template.call(system, root, "var(#{used})")}
        end
        # Not read from the theme by name: the rule as the default theme gives it.
        base << {nil, (templates << rule(@design, root).not_nil!).size - 1} if base.empty?
        row << %("base":#{base.to_json})
      end

      number = template.call(@design, "#{root}-73", "73")
      if number && number == template.call(@design, "#{root}-79", "79")
        row << %("number":{"template":#{number},"decimals":#{!rule(@design, "#{root}-7.5").nil?}})
        # 0 and 1 where they are not the template filled in (p-0 is 0px).
        exact = %w[0 1].compact_map do |n|
          found = rule(@design, "#{root}-#{n}")
          next if found.nil? || found == templates[number].gsub(HOLE, n)
          {n, templates.index(found) || (templates << found).size - 1}
        end.to_h
        row << %("exact":#{exact.to_json}) unless exact.empty?
      end
      if percent = template.call(@design, "#{root}-73%", "73%")
        row << %("percent":#{percent})
      end
      ["/", " / "].each do |separator|
        fraction = template.call(@design, "#{root}-73/79", "73#{separator}79") || next
        row << %("fraction":{"template":#{fraction},"separator":#{separator.to_json}})
        break
      end

      if templates.empty?
        review << root
      else
        rows[root] = %({"t":[#{templates.join(",")}]#{row.map { |field| ",#{field}" }.join}})
      end
    end
    {rows, review}
  end

  # The index in `templates` of the class's rule with § where `value` stood,
  # or nil when the class builds nothing or the value is not in its rule.
  private def template(templates : Array(String), system : Int32, name : String, value : String) : Int32?
    text = rule(system, name) || return nil
    needle = value.to_json[1...-1]
    return nil unless text.includes?(needle)
    filled = text.gsub(needle, HOLE)
    templates.index(filled) || (templates << filled).size - 1
  end

  # The default theme with a token `zzq`, and a default token, in every
  # namespace but `without`.
  private def probe(without : Array(String)) : Int32
    @probes[without.join(" ")] ||= begin
      tokens = (@namespaces - without).map { |name| "#{name}-zzq: 1px; #{name}: 1px;" }
      @oracle.load("#{@theme}\n@theme {\n#{tokens.join("\n")}\n--spacing: 0.25rem;\n}")
    end
  end

  # Asks Tailwind for many classes at once; `rule` then answers from them.
  private def compile(system : Int32, names : Array(String)) : Nil
    missing = names.reject { |name| @rules.has_key?({system, name}) }
    return if missing.empty?
    missing.zip(@oracle.compile(system, missing)) { |name, found| @rules[{system, name}] = found.size == 1 ? convert(found[0]) : nil }
  end

  # A class's rule, or nil when it builds nothing or more than one rule.
  private def rule(system : Int32, name : String) : String?
    compile(system, [name])
    @rules[{system, name}]
  end

  private def convert(node : JSON::Any) : String
    properties = [] of String
    nodes = JSON.build { |json| nodes(json, node["nodes"].as_a, properties) }
    properties.empty? ? %({"nodes":#{nodes}}) : %({"nodes":#{nodes},"properties":#{properties.to_json}})
  end

  private def nodes(json : JSON::Builder, list : Array(JSON::Any), properties : Array(String)) : Nil
    json.array do
      list.each do |node|
        case kind = node["kind"].as_s
        when "declaration"
          json.array do
            json.string node["property"].as_s
            (value = node["value"]?.try(&.as_s?)) ? json.string(value) : json.null
          end
        when "rule", "at-rule"
          json.object do
            json.field "head", kind == "rule" ? node["selector"].as_s : "#{node["name"].as_s} #{node["params"].as_s}"
            json.field("nodes") { nodes(json, node["nodes"].as_a, properties) }
          end
        when "at-root"
          node["nodes"].as_a.each do |registered|
            raise "unexpected at-root #{registered["name"]?}" unless registered["name"]? == "@property"
            fields = registered["nodes"].as_a.to_h { |decl| {decl["property"].as_s, decl["value"].as_s} }
            @registered[registered["params"].as_s] = {String.from_json(fields["syntax"]), fields["initial-value"]?}
            properties << registered["params"].as_s
          end
        else
          raise "unexpected #{kind}"
        end
      end
    end
  end
end

Vendor.new(Oracle.new).run
