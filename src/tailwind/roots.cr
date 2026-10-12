require "./root"
require "./scan"

module Tailwind
  # `text-*`: a size or a colour. A size brings its token's line height,
  # letter spacing and weight, or the line height of a modifier: `text-lg/7`.
  class Text < Root
    # What `leading-*`, `tracking-*` and `font-*` on the element set, so
    # they win over the size's own.
    OVERRIDES = {"line-height" => "--tw-leading", "letter-spacing" => "--tw-tracking", "font-weight" => "--tw-font-weight"}

    private def written(index : Int32, text : String) : Rules?
      modifier = @modifier
      modifier && index != color ? sized(text, modifier) : super
    end

    private def token(namespace : String, value : String, index : Int32, found : String) : Rules?
      modifier = @modifier
      modifier && index != color ? sized(found, modifier) : super
    end

    private def sub_token(name : String, property : String) : String?
      found = super || return nil
      override = OVERRIDES[property]?
      override ? "var(#{override}, #{found})" : found
    end

    private def sized(size : String, modifier : String) : Rules?
      height = Value.written(modifier) || (modifier == "none" ? "1" : @theme.resolve("--leading", modifier))
      height ||= "calc(var(--spacing) * #{modifier})" if number?(modifier) && quarters?(modifier) && @theme.has?("--spacing")
      height.try { |found| Rules.new([Decl.new("font-size", size), Decl.new("line-height", found)] of Node) }
    end
  end

  # `@container`, and `@container/main` for one with a name.
  class Container < Root
    private def alone : Rules?
      _, index = @row.base.first? || return nil
      rules = fill(index, "")
      modifier = @modifier || return rules
      return nil unless modifier.matches?(/\A[\w-]+\z/)
      Rules.new(rules.nodes + [Decl.new("container-name", modifier).as(Node)], rules.properties)
    end
  end

  # `bg-linear-*`, `bg-conic-*` and `bg-radial-*`: a modifier is how the
  # colours between the stops are interpolated, in place of OKLab:
  # `bg-linear-to-r/oklch`, `bg-conic/longer`, `bg-radial/[in_hsl]`.
  class Gradient < Root
    NAMES = {"bg-linear", "-bg-linear", "bg-conic", "-bg-conic", "bg-radial"}
    OKLAB = "in oklab"
    HUES  = {"longer", "shorter", "increasing", "decreasing"}

    # The class without its modifier, with the modifier's interpolation in
    # place of OKLab. An arbitrary value takes no modifier.
    def resolve(value : String?) : Rules?
      modifier = @modifier || return super
      return nil if value && (value.ends_with?(']') || value.ends_with?(')'))
      method = Value.written(modifier) || space(modifier)
      rules = Root.new(@theme, @name, @row, nil).resolve(value) || Tables::STATIC["#{@name}-#{value}"]? || return nil
      Rules.new(interpolated(rules.nodes, method), rules.properties)
    end

    # A named modifier: a colour space, or a way around OKLCH's hue circle.
    private def space(modifier : String) : String
      HUES.includes?(modifier) ? "in oklch #{modifier} hue" : "in #{modifier}"
    end

    private def interpolated(nodes : Array(Node), method : String) : Array(Node)
      nodes.map do |node|
        case node
        in Block then Block.new(node.head, interpolated(node.nodes, method)).as(Node)
        in Decl  then node.value.ends_with?(OKLAB) ? Decl.new(node.property, node.value.rchop(OKLAB) + method).as(Node) : node.as(Node)
        end
      end
    end
  end

  # `shadow-*`, `inset-shadow-*`, `text-shadow-*` and `drop-shadow-*`: a
  # value is a list of shadows, each given the colour variable that the
  # root's colour classes set, and a modifier is the alpha of the shadows'
  # own colours: `shadow-lg/20`, `shadow/[0.35]`, `drop-shadow-md/(--x)`.
  class Shadow < Root
    # A root's theme namespace is `--<root>`, and the variable its colour
    # classes set `--tw-<root>-color`.
    NAMES = {"shadow", "inset-shadow", "text-shadow", "drop-shadow"}

    # Where a colour can take an alpha of its own. Outside it, a shadow
    # whose colour or alpha is a variable is written without the alpha.
    RELATIVE = "@supports (color: lab(from red l a b))"

    # What a shadow holds beside its colour.
    KEYWORDS = {"inset", "inherit", "initial", "revert", "unset"}
    LENGTH   = /\A-?(\d|\.\d)/
    MATH     = /\A(calc|clamp|max|min|--spacing)\(/i
    COLOR    = /\A(color|color-mix|contrast-color|device-cmyk|hsla?|hwb|lab|lch|light-dark|oklab|oklch|rgba?|--alpha)\(/i

    def namespaces : Array(String)
      (["--#{@name}"] + super + ["--color"]).uniq!
    end

    # A shadow's colour is told from its value by type: only `drop-shadow`
    # lists the theme's colours.
    private def color : Int32?
      super || @row.types["color"]?
    end

    private def alone : Rules?
      from_token("--#{@name}", alone: true)
    end

    private def written(index : Int32, text : String) : Rules?
      return super if index == color
      sized(text, arbitrary: true) unless refused?
    end

    private def named(value : String) : Rules?
      return nil if @modifier && @name != "drop-shadow" && (value == "none" || value == "inherit")
      return from_token("--#{@name}-#{value}") if @theme.has?("--#{@name}-#{value}")
      super || @theme.resolve("--color", value).try { |found| color.try { |index| colored(index, found) } }
    end

    # Of the theme, only a colour: the shadows are read in `from_token`.
    private def token(namespace : String, value : String, index : Int32, found : String) : Rules?
      index == color ? super : nil
    end

    # `shadow-md`, or `shadow` alone: the token's shadows. A drop shadow's
    # filter reads the token itself when the class gives no alpha, and
    # always for `drop-shadow` alone.
    private def from_token(name : String, alone : Bool = false) : Rules?
      raw = @theme[name]? || return nil
      return nil if refused? && !alone
      return sized(raw) unless @name == "drop-shadow" && (alone || !amount)
      token = @theme.reference(name) || return nil
      sized(raw, filter: Scan.split(token, ',').join(" ") { |one| "drop-shadow(#{one})" })
    end

    # Tailwind passes over a modifier that is no alpha, but on a drop shadow.
    private def refused? : Bool
      @name == "drop-shadow" && !@modifier.nil? && amount.nil?
    end

    # The modifier as an alpha: one in brackets as it is written, a number
    # as a percentage.
    private def amount : String?
      modifier = @modifier || return nil
      Value.written(modifier) || ("#{modifier}%" if number?(modifier) && quarters?(modifier))
    end

    # The rule for a list of shadows, at the modifier's alpha.
    private def sized(value : String, arbitrary : Bool = false, filter : String? = nil) : Rules
      amount = self.amount
      relative = false
      mixed = colors(value) do |color|
        next color unless amount
        next faded(color, percent(amount)) if color.starts_with?("current")
        relative ||= color.starts_with?("var(") || amount.starts_with?("var(")
        "oklab(from #{color} l a b / #{percent(amount)})"
      end
      plain = colors(value) { |color| color } if relative
      template = @row.templates[@row.any || 0]
      nodes = template.nodes.flat_map do |node|
        next [node] unless node.is_a?(Decl)
        if node.absent?
          amount ? [Decl.new(node.property, amount).as(Node)] : [] of Node
        elsif node.value.includes?(Tables::HOLE)
          after = Decl.new(node.property, joined(mixed, arbitrary)).as(Node)
          plain ? [Decl.new(node.property, joined(plain, arbitrary)).as(Node), Block.new(RELATIVE, [after]).as(Node)] : [after]
        elsif filter && node.property == "--tw-drop-shadow"
          [Decl.new(node.property, filter).as(Node)]
        else
          [node.as(Node)]
        end
      end
      Rules.new(nodes, template.properties)
    end

    # The shadows as the root's declaration lists them. An arbitrary inset
    # shadow is given the `inset` a token has of its own.
    private def joined(shadows : Array(String), arbitrary : Bool) : String
      case @name
      when "drop-shadow"  then shadows.join(" ") { |shadow| "drop-shadow(#{shadow})" }
      when "inset-shadow" then shadows.join(", ") { |shadow| arbitrary ? "inset #{shadow}" : shadow }
      else                     shadows.join(", ")
      end
    end

    # Each shadow with its colour as `var(--tw-shadow-color, <colour>)`, the colour
    # as the block gives it back. The colour is the first one written, else
    # the one word that is no length and no keyword, else currentcolor. A
    # shadow without two lengths, or with more such words, is left as it is.
    private def colors(value : String, & : String -> String) : Array(String)
      Scan.split(value, ',').map do |shadow|
        shadow = shadow.strip
        parts = Scan.split(shadow, ' ').reject(&.empty?)
        at = parts.index { |part| part.starts_with?('#') || Value::NAMED.includes?(part.downcase) || part.matches?(COLOR) }
        unless at
          lengths, others = parts.each_index.reject { |i| KEYWORDS.includes?(parts[i].downcase) }.partition do |i|
            parts[i].matches?(LENGTH) || parts[i].matches?(MATH)
          end
          next shadow if lengths.size < 2 || others.size > 1
          at = others.first? || parts.size
        end
        parts[at..at] = "var(--tw-#{@name}-color, #{yield parts[at]? || "currentcolor"})"
        parts.join(" ")
      end
    end
  end
end
