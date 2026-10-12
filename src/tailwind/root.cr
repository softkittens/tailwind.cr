require "./tables"
require "./theme"
require "./value"

module Tailwind
  # A functional root reading one class: which of its row's templates the
  # value fills, and with what. The roots whose rule is more than a template
  # are its subclasses, in roots.cr.
  class Root
    COLOR_KEYWORDS = {"current" => "currentcolor", "transparent" => "transparent", "inherit" => "inherit"}

    def self.for(theme : Theme, name : String, row : Tables::Row, modifier : String?) : Root
      kind = case name
             when "text"                then Text
             when "@container"          then Container
             when .in?(Gradient::NAMES) then Gradient
             when .in?(Shadow::NAMES)   then Shadow
             else                            Root
             end
      kind.new(theme, name, row, modifier)
    end

    def initialize(@theme : Theme, @name : String, @row : Tables::Row, @modifier : String?)
    end

    # The rules for the root with `value`: nil for the root alone, `[…]` or
    # `(…)` for an arbitrary value, else a name. Nil when the root does not
    # take the value.
    def resolve(value : String?) : Rules?
      return alone if value.nil?
      if value.starts_with?('[') || value.starts_with?('(')
        arbitrary = Value.parse(value) || return nil
        index = pick(arbitrary) || return nil
        return written(index, arbitrary.text)
      end
      named(value)
    end

    # The theme namespaces a named value is looked up in, in order.
    def namespaces : Array(String)
      @row.theme.map(&.[0])
    end

    # The template a colour fills, with an opacity modifier when the class
    # has one.
    private def color : Int32?
      @row.color
    end

    # The root alone, from the theme's default token: `rounded`, `blur`.
    private def alone : Rules?
      return nil if @modifier
      @row.base.each do |namespace, index|
        return fill(index, "") unless namespace
        found = @theme.reference(namespace) || next
        return fill(index, found)
      end
      nil
    end

    # An arbitrary value, in the template its type picked.
    private def written(index : Int32, text : String) : Rules?
      return colored(index, text) if index == color
      @modifier ? nil : fill(index, text)
    end

    # A name: a theme token, a colour keyword, a fraction or a number.
    private def named(value : String) : Rules?
      @row.theme.each do |namespace, index|
        found = @theme.resolve(namespace, value) || next
        if rules = token(namespace, value, index, found)
          return rules
        end
      end
      if (index = color) && (keyword = COLOR_KEYWORDS[value]?)
        return colored(index, keyword)
      end
      if modifier = @modifier
        fraction = @row.fraction || return nil
        return nil unless integer?(value) && integer?(modifier) && modifier != "0"
        return fill(fraction.template, "#{value}#{fraction.separator}#{modifier}")
      end
      bare(value)
    end

    # A theme token of `namespace`, found as var() or as its value.
    private def token(namespace : String, value : String, index : Int32, found : String) : Rules?
      return colored(index, found) if index == color
      return nil if @modifier
      fill(index, found) { |property| sub_token("#{namespace}-#{value}--#{property}", property) }
    end

    # A bare number or percentage.
    private def bare(value : String) : Rules?
      if index = @row.exact[value]?
        return fill(index, "")
      end
      if (percent = @row.percent) && value.ends_with?('%') && number?(value.rchop('%'))
        return fill(percent, value)
      end
      number = @row.number || return nil
      fill(number.template, value) if integer?(value) || (number.decimals && number?(value) && quarters?(value))
    end

    # The template an arbitrary value fills: by its hint, else by the first
    # of its types the root tells apart, else the root's own.
    private def pick(arbitrary : Value::Arbitrary) : Int32?
      if hint = arbitrary.hint
        return @row.hints[hint]? || @row.any
      end
      Value.kind(arbitrary.text, @row.types.keys).try { |kind| @row.types[kind] } || @row.any
    end

    private def fill(index : Int32, value : String) : Rules
      fill(index, value) { nil }
    end

    # The template with `value` in place of §. A declaration the template
    # leaves absent takes what the block gives for its property, or is
    # dropped.
    private def fill(index : Int32, value : String, &sub : String -> String?) : Rules
      template = @row.templates[index]
      Rules.new(fill(template.nodes, value, sub), template.properties)
    end

    private def fill(nodes : Array(Node), value : String, sub : String -> String?) : Array(Node)
      nodes.compact_map do |node|
        case node
        in Block
          Block.new(node.head, fill(node.nodes, value, sub)).as(Node)
        in Decl
          found = node.absent? ? sub.call(node.property) : node.value.gsub(Tables::HOLE, value)
          found.try { |text| Decl.new(node.property, text).as(Node) }
        end
      end
    end

    # A token's own sub-token, when the theme has it: `font-sans` reads
    # `--font-sans--font-feature-settings`.
    private def sub_token(name : String, property : String) : String?
      @theme.reference(name)
    end

    # A colour at the alpha of the class's opacity modifier.
    private def colored(index : Int32, value : String) : Rules?
      modifier = @modifier || return fill(index, value)
      amount = alpha(modifier) || return nil
      fill(index, faded(value, amount))
    end

    # A colour mixed with transparent in OKLab.
    private def faded(color : String, amount : String) : String
      amount == "100%" ? color : "color-mix(in oklab, #{color} #{amount}, transparent)"
    end

    # An opacity modifier as a percentage: `/50`, `/[0.5]`, `/(--x)`, or a
    # `--opacity-*` token.
    private def alpha(modifier : String) : String?
      if written = Value.written(modifier)
        return percent(written)
      end
      @theme.resolve("--opacity", modifier) || (number?(modifier) && quarters?(modifier) ? "#{modifier}%" : nil)
    end

    # A number as a percentage: 0.35 is 35%. Anything else as it is.
    private def percent(text : String) : String
      return text unless text.matches?(Value::NUMBER)
      scaled = text.to_f * 100
      "#{scaled == scaled.floor ? scaled.to_i : scaled}%"
    end

    private def integer?(value : String) : Bool
      value.matches?(Value::INTEGER)
    end

    # A number as Tailwind writes one: 1.5, not 1.50.
    private def number?(value : String) : Bool
      value.matches?(/\A(0|[1-9]\d*)(\.\d*[1-9])?\z/)
    end

    # Whether a number is a multiple of 0.25, as spacing steps are.
    private def quarters?(value : String) : Bool
      scaled = value.to_f * 4
      scaled == scaled.floor
    end
  end
end
