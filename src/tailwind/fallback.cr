require "./ast"
require "./scan"
require "./theme"

module Tailwind
  # What browsers without color-mix(in lab) get: a declaration that mixes
  # with a variable is written twice, first with the theme's values in place
  # in sRGB, or as the colour alone where a variable is not the theme's, then
  # as it is inside @supports.
  module Fallback
    SUPPORTS = "@supports (color: color-mix(in lab, red, red))"
    MIX      = "color-mix("
    SPACES   = /\bin (oklab|oklch|lab|lch)\b/

    def self.rules(theme : Theme, rules : Rules) : Rules
      mixes?(rules.nodes) ? Rules.new(nodes(theme, rules.nodes), rules.properties) : rules
    end

    private def self.mixes?(nodes : Array(Node)) : Bool
      nodes.any? do |node|
        case node
        in Block then mixes?(node.nodes)
        in Decl  then node.value.includes?(MIX)
        end
      end
    end

    private def self.nodes(theme : Theme, nodes : Array(Node)) : Array(Node)
      nodes.flat_map do |node|
        case node
        in Block
          [Block.new(node.head, nodes(theme, node.nodes)).as(Node)]
        in Decl
          if safe = node.value.includes?(MIX) ? value(theme, node.value) : nil
            [Decl.new(node.property, safe), Block.new(SUPPORTS, [node.as(Node)])] of Node
          else
            [node.as(Node)]
          end
        end
      end
    end

    # The value with each color-mix() made safe, or nil when none needs it.
    private def self.value(theme : Theme, text : String) : String?
      needed = false
      result = each_call(text, MIX) do |mix|
        inlined, resolved, unknown = inline(theme, mix)
        needed ||= resolved || unknown
        resolved || unknown ? safe(inlined) : mix
      end
      needed ? result : nil
    end

    # A mix with the theme's values in place, in sRGB; where a variable or
    # currentcolor is left in it, its colour alone, made safe in its turn.
    private def self.safe(mix : String) : String
      return mix.gsub(SPACES, "in srgb") unless mix.includes?("var(") || mix.downcase.includes?("currentcolor")
      first = Scan.split(Scan.split(mix[MIX.size...-1], ',')[1]?.to_s.strip, ' ')[0]
      first.starts_with?(MIX) ? safe(first) : first
    end

    # `text` with each outermost call of `function`, written with its `(`,
    # replaced by the block's.
    private def self.each_call(text : String, function : String, & : String -> String) : String
      String.build do |io|
        at = 0
        while start = text.index(function, at)
          stop = Scan.close(text, start + function.size - 1)
          io << text[at...start] << yield text[start..stop]
          at = stop + 1
        end
        io << text[at..]
      end
    end

    # The theme's values in place of its variables; whether any was put in
    # place, and whether a variable that is not the theme's, or
    # currentcolor, is left.
    private def self.inline(theme : Theme, mix : String) : {String, Bool, Bool}
      text = mix
      8.times do
        replaced = each_call(text, "var(") { |call| theme[call[4...-1].partition(',')[0]]? || call }
        break if replaced == text
        text = replaced
      end
      {text, text != mix, text.includes?("var(") || text.downcase.includes?("currentcolor")}
    end
  end
end
