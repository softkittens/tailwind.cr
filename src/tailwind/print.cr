require "./ast"
require "./scan"

module Tailwind
  # A class's nested rule as Tailwind writes it out: selectors resolved,
  # the at-rules around a rule lifted outside it, and neighbouring classes
  # under the same at-rule sharing one block.
  module Print
    # `nodes` under `selector`, as rules and the at-rules around them. A
    # rule with declarations of its own is written as it is, at-rules and
    # all. One with none is only a wrapper: its nested rules take its
    # selector, and its at-rules move outside it. `flat` writes no rule as
    # it is: every at-rule moves outside, with the rule repeated inside it,
    # and a media query is written without range syntax.
    def self.flatten(selector : String, nodes : Array(Node), flat : Bool = false) : Array(Block)
      return [Block.new(selector, distinct(nodes))] if declares?(nodes) && !flat
      lift(selector, nodes, flat)
    end

    # A nested rule under `selector`, or an at-rule moved outside it. A
    # list of selectors stands in the nested one as `:is(…)`.
    private def self.nested(selector : String, block : Block, flat : Bool) : Array(Block)
      if block.at_rule?
        return [Block.new(flat ? ranged(block.head) : block.head, lift(selector, block.nodes, flat).map(&.as(Node)))]
      end
      parent = Scan.split(selector, ',').size > 1 ? ":is(#{selector})" : selector
      flatten(block.head.gsub('&', parent), block.nodes, flat)
    end

    # `nodes` moved outside `selector`: each run of declarations becomes a
    # rule, and each at-rule and nested rule moves out too.
    private def self.lift(selector : String, nodes : Array(Node), flat : Bool) : Array(Block)
      runs = nodes.chunk_while { |a, z| a.is_a?(Decl) && z.is_a?(Decl) }
      runs.flat_map do |run|
        first = run.first
        next nested(selector, first, flat) if first.is_a?(Block)
        declares?(run) ? [Block.new(selector, distinct(run))] : [] of Block
      end.to_a
    end

    # A media query of one condition as browsers without range syntax read
    # it: `(width >= X)` as `(min-width: X)`, `(width < X)` as `not all and
    # (min-width: X)`, and `not (…)` as `not all and (…)`. Any other at-rule
    # as it is.
    private def self.ranged(head : String) : String
      match = head.match(/\A@media (not )?(\(.+\))\z/m) || return head
      query = match[2]
      return head unless Scan.close(query, 0) == query.size - 1
      negated = !match[1]?.nil?
      if width = query.match(/\A\(width (>=|<) (.+)\)\z/m)
        negated ^= width[1] == "<"
        query = "(min-width: #{width[2]})"
      end
      "@media #{negated ? "not all and " : ""}#{query}"
    end

    # Whether any of `nodes` is a declaration that is printed.
    private def self.declares?(nodes : Array(Node)) : Bool
      nodes.any? { |node| node.is_a?(Decl) && node.property != SORT }
    end

    # A declaration written twice is kept where it is written last.
    private def self.distinct(nodes : Array(Node)) : Array(Node)
      nodes.reverse.uniq!.reverse!
    end

    # A selector as Tailwind writes one: spaces around combinators and after
    # commas, and no `*` before a pseudo-class, attribute or class. What is
    # in `[…]` or `:nth-child(…)` is not a selector, and stays as written.
    def self.selector(text : String) : String
      String.build do |io|
        depth = 0
        quote = nil
        text.each_char_with_index do |c, i|
          if quote
            quote = nil if c == quote
          elsif c == '"' || c == '\''
            quote = c
          elsif c == '[' || (c == '(' && (depth > 0 || text[0, i].matches?(/:nth-[a-z-]+\z/)))
            depth += 1
          elsif c == ']' || (c == ')' && depth > 0)
            depth -= 1
          elsif depth == 0
            case c
            when '>', '+', '~' then next io << ' ' << c << ' '
            when ','           then next io << ", "
            when '*'           then next if text[i + 1]?.try(&.in?(':', '[', '.', '#'))
            end
          end
          io << c
        end
      end.gsub(/ {2,}/, " ")
    end

    # Adds a rule or an at-rule to a sheet, inside the at-rule before it
    # when both are the same one.
    def self.append(sheet : Array, item : Block) : Nil
      last = sheet.last?
      if item.at_rule? && last.is_a?(Block) && last.head == item.head
        item.nodes.each { |child| append(last.nodes, child) if child.is_a?(Block) }
      else
        sheet << item
      end
    end

    # Every declaration with `!important`.
    def self.important(nodes : Array(Node)) : Array(Node)
      nodes.map do |node|
        case node
        in Decl  then (node.property == SORT ? node : Decl.new(node.property, node.value, true)).as(Node)
        in Block then Block.new(node.head, important(node.nodes)).as(Node)
        end
      end
    end

    # `@property`, with the initial value where Tailwind writes it.
    def self.property(io : IO, property : Property) : Nil
      io << "@property " << property.name << " {\n  syntax: \"" << property.syntax << "\";\n"
      initial = property.initial.try { |value| "  initial-value: #{value};\n" }
      io << initial if property.initial_first
      io << "  inherits: false;\n"
      io << initial unless property.initial_first
      io << "}\n"
    end

    def self.block(io : IO, block : Block, indent : Int32) : Nil
      io << " " * indent << block.head << " {\n"
      block.nodes.each do |node|
        case node
        in Decl
          next if node.property == SORT
          io << " " * (indent + 2) << node.property << ": " << node.value
          io << " !important" if node.important
          io << ";\n"
        in Block
          block(io, node, indent + 2)
        end
      end
      io << " " * indent << "}\n"
    end
  end
end
