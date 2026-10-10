require "json"
require "./ast"
require "./print"
require "./theme"
require "./value"

module Tailwind
  # The variants a class may carry. Each wraps a utility's declarations in
  # its heads, outermost first; a head of several lines is a rule for each.
  # `order` is Tailwind's registration order, which is also sort order, and
  # `rank` orders the variants of one root: a breakpoint by its unit and
  # width, a variant around another (`group-hover:`) by that one, and one
  # with a value by the value, a named one first.
  module Variants
    alias Rank = Array({Int32, String, Float64})

    record Variant, order : Int32, heads : Array(String), rank : Rank = Rank.new, content : Bool = false

    # Tailwind's variants in its order, as script/vendor.cr writes them:
    # [name, heads]. One with no heads takes a value, and is built in
    # `resolve`.
    LIST = Array({String, Array(String)}).from_json({{ read_file("#{__DIR__}/vendor/variants.json") }})

    ORDER = LIST.each_with_index.to_h { |(name, _), index| {name, index} }
    FIXED = LIST.each_with_index.compact_map do |(name, heads), index|
      next if heads.empty?
      written = heads.map(&.split('\n').join('\n') { |head| head.starts_with?('@') ? head : Print.selector(head) })
      {name, Variant.new(index, written, content: name == "before" || name == "after")}
    end.to_h
    # An arbitrary variant sorts after every other.
    ARBITRARY = LIST.size

    # The roots that take a value, longest first: `nth-last-of-type-3`.
    ROOTS = LIST.compact_map { |name, heads| name if heads.empty? && !name.starts_with?('@') }.sort_by! { |name| -name.size }

    # What follows `data-` or `aria-` inside an attribute selector: a name,
    # then an operator and a value.
    ATTRIBUTE = /\A(\\.|[a-zA-Z0-9_-]|[^\x00-\x7F])+[ \t\n\r]*((=|[~|^$*]=)[ \t\n\r]*((["'])(\\.|[^\\])*\5|(?!["'])[^ \t\n\r]+)[ \t\n\r]*([iIsS][ \t\n\r]*)?)?\z/

    # `before:` and `after:` give their pseudo-element its content.
    CONTENT      = Property.new("--tw-content", "*", %(""), initial_first: true)
    CONTENT_DECL = Decl.new("content", "var(--tw-content)")

    # How many variants a class stacks, and how many one variant nests
    # (`group-has-not-…`), before the class builds no rule. Tailwind has no
    # such limit; a class past it is not one a person wrote.
    DEPTH = 16

    # A variant as written before the `:`, or nil when it is not one.
    def self.resolve(theme : Theme, text : String, depth : Int32 = 1) : Variant?
      return nil if depth > DEPTH
      if text == "dark" && (written = theme.dark)
        return dark(written)
      end
      if found = FIXED[text]?
        return found
      end
      if text.starts_with?('[') && text.ends_with?(']')
        return arbitrary(text[1...-1])
      end
      if width = theme["--breakpoint-#{text}"]?
        return Variant.new(ORDER["min"], ["@media (width >= #{width})"], by_width(width, false))
      end
      return container(theme, text) if text.starts_with?('@')
      ROOTS.each do |root|
        next unless text.starts_with?("#{root}-")
        if found = valued(theme, root, text[(root.size + 1)..], depth)
          return found
        end
      end
      nil
    end

    # `dark:` as a theme's `@custom-variant dark` writes it: the selectors
    # as one rule, then a rule for each at-rule. It keeps `dark:`'s order.
    private def self.dark(written : String) : Variant
      at_rules, selectors = Scan.split(written, ',').map(&.strip).partition(&.starts_with?('@'))
      heads = selectors.empty? ? at_rules : [Print.selector(selectors.join(", "))] + at_rules
      Variant.new(ORDER["dark"], [heads.join('\n')])
    end

    # `[&_svg]`, `[@media(min-width:1px)]`, `[.dark_&]`.
    private def self.arbitrary(inner : String) : Variant?
      selector = Value.decode(inner)
      return nil if selector.blank? || !Scan.contained?(selector)
      return Variant.new(ARBITRARY, [selector.sub(/\A(@[a-z-]+)\(/) { "#{$1} (" }], by_value(selector)) if selector.starts_with?('@')
      return nil if selector.matches?(/\A[>+~]/)
      selector = "&:is(#{selector})" unless selector.includes?('&')
      Variant.new(ARBITRARY, [Print.selector(selector)], by_value(selector))
    end

    # A variant that takes a value: another variant for `group-`, `peer-`,
    # `not-`, `has-` and `in-`, and for the rest a name, `[…]` or `(--x)`.
    private def self.valued(theme : Theme, root : String, value : String, depth : Int32) : Variant?
      return nil if value.empty?
      order = ORDER[root]
      inner = Value.written(value)
      case root
      when "group", "peer"
        return marked(theme, root, value, order, depth)
      when "not", "has", "in"
        # `has-[>svg]`: a relative selector, as it is.
        if root == "has" && inner && inner.matches?(/\A[>+~]/)
          return Variant.new(order, ["&:has(#{Print.selector(inner)})"], [{ARBITRARY, "", 0.0}] + by_value(inner))
        end
        found = resolve(theme, value, depth + 1) || return nil
        heads = case root
                when "not" then negated(found)
                when "has" then rewrite(found) { |head| "&:has(#{Print.selector(head.gsub('&', '*'))})" }
                else            rewrite(found) { |head| ":where(#{Print.selector(head.gsub('&', '*'))}) &" }
                end
        return heads && Variant.new(order, heads, around(found))
      end

      return nil unless inner || value.matches?(Value::NAME)
      rank = by_value(inner || value, arbitrary: !inner.nil?)
      case root
      when "aria"
        attribute("aria", inner || %(#{value}="true"), order, rank)
      when "data"
        attribute("data", inner || value, order, rank)
      when "nth", "nth-last", "nth-of-type", "nth-last-of-type"
        return nil unless inner || value.matches?(Value::INTEGER)
        pseudo = {"nth" => "nth-child", "nth-last" => "nth-last-child"}[root]? || root
        Variant.new(order, ["&:#{pseudo}(#{inner || value})"], inner ? rank : by_number(value.to_f))
      when "supports"
        Variant.new(order, [supports(inner || value)], rank)
      when "min", "max"
        width = inner || theme["--breakpoint-#{value}"]? || return nil
        return nil if width.includes?("var(")
        compare = root == "min" ? ">=" : "<"
        Variant.new(order, ["@media (width #{compare} #{width})"], by_width(width, root == "max"))
      end
    end

    # `supports-grid` and `supports-[display:grid]` as a declaration to
    # test; a condition (`not(…)`, `selector(…)`, `(…)and(…)`) as it is,
    # with the spaces Tailwind puts around its keywords.
    private def self.supports(text : String) : String
      return "@supports #{text.gsub(/\b(and|or|not)\b/, " \\1 ")}" if text.matches?(/\A[\w-]*\s*\(/)
      text = "#{text}: var(--tw)" unless text.includes?(':')
      text.starts_with?('(') && text.ends_with?(')') ? "@supports #{text}" : "@supports (#{text})"
    end

    # `group-hover:` and `peer-checked:`: another variant's state on an
    # ancestor with class `group`, or an earlier sibling with class `peer`.
    # `group-hover/name:` names the group.
    private def self.marked(theme : Theme, root : String, value : String, order : Int32, depth : Int32) : Variant?
      marker = ".#{root}"
      value, name = named(value) || return nil
      marker = ".#{root}\\/#{name}" if name
      after = root == "group" ? "*" : "~ *"
      inner = resolve(theme, value, depth + 1) || return nil
      heads = rewrite(inner) do |head|
        selector = head.gsub('&', ":where(#{marker})")
        selector = ":is(#{selector})" if Scan.split(selector, ',').size > 1
        "&:is(#{selector} #{after})"
      end
      return nil unless heads
      Variant.new(order, heads, around(inner) + by_value(name || "", arbitrary: !name.nil?))
    end

    # What a variant is made of, to a variant built around it. None when
    # nothing can be: a pseudo-element, an at-rule that is not a query, a
    # selector and a query side by side, `*` and `**`.
    @[Flags]
    enum Parts
      AtRules
      Rules
    end

    private def self.parts(variant : Variant) : Parts
      return Parts::None if variant.order == ORDER["*"] || variant.order == ORDER["**"]
      variant.heads.reduce(Parts::None) do |found, level|
        kinds = level.split('\n').map do |head|
          if head.starts_with?('@')
            return Parts::None unless head.matches?(/\A@(media|supports|container)\b/)
            Parts::AtRules
          else
            return Parts::None if head.includes?("::")
            Parts::Rules
          end
        end
        return Parts::None if kinds.uniq.size > 1
        found | kinds.first
      end
    end

    # `inner`'s heads for `group-`, `peer-`, `has-` and `in-`: each selector
    # as the block rewrites it, the at-rules as they are. Nil when it has no
    # selector, or one inside another.
    private def self.rewrite(inner : Variant, & : String -> String) : Array(String)?
      return nil unless parts(inner).rules?
      levels = inner.heads.map(&.split('\n'))
      return nil if levels.count(&.any? { |head| !head.starts_with?('@') }) > 1
      levels.map(&.map { |head| head.starts_with?('@') ? head : yield head }.join('\n'))
    end

    # `inner`'s heads for `not-`: its selector inside `:not()` and its query
    # negated, side by side when it has both (`not-hover:`). Nil when it has
    # more than one of either.
    private def self.negated(inner : Variant) : Array(String)?
      return nil if parts(inner).none? || inner.heads.any?(&.includes?('\n'))
      queries, selectors = inner.heads.partition(&.starts_with?('@'))
      return nil if queries.size > 1 || selectors.size > 1
      heads = selectors.map { |head| "&:not(#{Print.selector(head.gsub('&', '*'))})" }
      queries.each { |head| heads << (negate(head) || return nil) }
      [heads.join('\n')]
    end

    # `@media (…)` as `@media not (…)`, and back. A container's name stays
    # before the `not`. Nil for a list of queries.
    private def self.negate(head : String) : String?
      name, _, query = head.partition(' ')
      return nil if Scan.split(query, ',').size > 1
      named = name == "@container" ? query.match(/\A(?!not )([^\s(]+) (.+)\z/m) : nil
      lead, query = named ? {"#{named[1]} ", named[2]} : {"", query}
      "#{name} #{lead}#{query.starts_with?("not ") ? query.lchop("not ") : "not #{query}"}"
    end

    # The rank of a variant around another: that one's order, then its rank.
    private def self.around(inner : Variant) : Rank
      [{inner.order, "", 0.0}] + inner.rank
    end

    # The rank of a variant with a value: named ones first, then by the
    # value. A named group or peer follows the unnamed one the same way.
    private def self.by_value(value : String, arbitrary : Bool = false) : Rank
      [{arbitrary ? 1 : 0, value, 0.0}]
    end

    private def self.by_number(number : Float64) : Rank
      [{0, "", number}]
    end

    # `data-[state=open]` as `&[data-state="open"]`. Nil when the brackets
    # hold anything but an attribute, an operator and a value.
    private def self.attribute(prefix : String, inner : String, order : Int32, rank : Rank) : Variant?
      if equals = inner.index('=')
        value = inner[(equals + 1)..].strip
        unless value.starts_with?('"') || value.starts_with?('\'')
          flag = value.match(/\A(.+) ([iIsS])\z/m)
          inner = %(#{inner[0...equals]}="#{flag ? flag[1] : value}"#{flag ? " #{flag[2]}" : ""})
        end
      end
      selector = "#{prefix}-#{inner}"
      selector.matches?(ATTRIBUTE) ? Variant.new(order, ["&[#{selector}]"], rank) : nil
    end

    # A variant's text and the name after its `/`: `hover/sidebar`. Nil when
    # the name is not a word, `[…]` or `(--x)`, or there is a second `/`.
    private def self.named(text : String) : {String, String?}?
      parts = Scan.split(text, '/')
      return {text, nil} if parts.size == 1
      return nil unless parts.size == 2
      name = Value.modifier(parts[1]) || return nil
      {parts[0], name}
    end

    # `@md:`, `@max-md:`, `@[400px]:`, `@md/sidebar:`: container queries
    # over `--container-*`.
    private def self.container(theme : Theme, text : String) : Variant?
      text, name = named(text.lchop('@')) || return nil
      max = text.starts_with?("max-")
      text = text.lchop(max ? "max-" : "min-")
      width = Value.written(text) || theme["--container-#{text}"]? || return nil
      return nil if width.includes?("var(")
      # `@md:` and `@min-md:` are one variant to the sort order.
      head = "@container #{name ? "#{name} " : ""}(width #{max ? "<" : ">="} #{width})"
      Variant.new(ORDER[max ? "@max" : "@"], [head], by_width(width, max))
    end

    # The rank of a breakpoint: by unit, then width, the widest first for a
    # `max-`.
    private def self.by_width(width : String, widest_first : Bool) : Rank
      number = width.to_f?(strict: false) || 0.0
      [{0, width.lstrip("0123456789.-"), widest_first ? -number : number}]
    end

    # The utility's nodes inside each variant, the first variant written
    # outermost: `md:hover:x` is a media query around a hover rule.
    def self.wrap(nodes : Array(Node), variants : Array(Variant)) : Array(Node)
      variants.reverse_each do |variant|
        nodes = [CONTENT_DECL.as(Node)] + nodes if variant.content
        variant.heads.reverse_each { |head| nodes = head.split('\n').map { |one| Block.new(one, nodes).as(Node) } }
      end
      nodes
    end
  end
end
