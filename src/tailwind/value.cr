require "./scan"

module Tailwind
  # An arbitrary value: `[13px]`, `[length:var(--x)]`, `(--x)`, `(color:--x)`.
  module Value
    record Arbitrary, text : String, hint : String?

    HINT = /\A([a-z][a-z-]*):(?!\/\/)(.+)\z/m
    # A value or a modifier given by name, and a whole number as Tailwind
    # writes one.
    NAME    = /\A[a-zA-Z0-9_.%-]+\z/
    INTEGER = /\A(0|[1-9]\d*)\z/
    MATH    = %w[calc min max clamp mod rem sin cos tan asin acos atan atan2 pow sqrt hypot log exp round]

    # A CSS number, and the units and functions Tailwind tells a type by.
    NUM      = /[+-]?\d*\.?\d+(?:[eE][+-]?\d+)?/
    NUMBER   = /\A#{NUM}\z/
    PERCENT  = /\A#{NUM}%\z/
    ANGLE    = /\A#{NUM}(deg|rad|grad|turn)\z/
    VECTOR   = /\A#{NUM} +#{NUM} +#{NUM}\z/
    UNITS    = "cm|mm|Q|in|pc|pt|px|em|ex|ch|rem|lh|rlh|vw|vh|vmin|vmax|vb|vi|svw|svh|lvw|lvh|dvw|dvh|cqw|cqh|cqi|cqb|cqmin|cqmax"
    LENGTH   = /\A(#{NUM}(#{UNITS})|--spacing\(.*)\z/m
    COLOR_FN = /\A(rgba?|hsla?|hwb|color|(ok)?(lab|lch)|light-dark|color-mix|--alpha)\(/i
    URL      = /\Aurl\(.*\)\z/m
    IMAGE_FN = /\A((repeating-)?(conic|linear|radial)-gradient|element|image|cross-fade|image-set)\(/
    SIDES    = {"center", "top", "right", "bottom", "left"}
    WIDTHS   = {"thin", "medium", "thick"}
    GENERIC  = {"serif", "sans-serif", "monospace", "cursive", "fantasy", "system-ui", "ui-serif", "ui-sans-serif", "ui-monospace",
                "ui-rounded", "math", "emoji", "fangsong"}
    ABSOLUTE = {"xx-small", "x-small", "small", "medium", "large", "x-large", "xx-large", "xxx-large"}
    NAMED    = Set.new(%w[
      aliceblue antiquewhite aqua aquamarine azure beige bisque black blanchedalmond blue blueviolet brown
      burlywood cadetblue chartreuse chocolate coral cornflowerblue cornsilk crimson cyan darkblue darkcyan
      darkgoldenrod darkgray darkgreen darkgrey darkkhaki darkmagenta darkolivegreen darkorange darkorchid
      darkred darksalmon darkseagreen darkslateblue darkslategray darkslategrey darkturquoise darkviolet
      deeppink deepskyblue dimgray dimgrey dodgerblue firebrick floralwhite forestgreen fuchsia gainsboro
      ghostwhite gold goldenrod gray green greenyellow grey honeydew hotpink indianred indigo ivory khaki
      lavender lavenderblush lawngreen lemonchiffon lightblue lightcoral lightcyan lightgoldenrodyellow
      lightgray lightgreen lightgrey lightpink lightsalmon lightseagreen lightskyblue lightslategray
      lightslategrey lightsteelblue lightyellow lime limegreen linen magenta maroon mediumaquamarine
      mediumblue mediumorchid mediumpurple mediumseagreen mediumslateblue mediumspringgreen mediumturquoise
      mediumvioletred midnightblue mintcream mistyrose moccasin navajowhite navy oldlace olive olivedrab
      orange orangered orchid palegoldenrod palegreen paleturquoise palevioletred papayawhip peachpuff peru
      pink plum powderblue purple rebeccapurple red rosybrown royalblue saddlebrown salmon sandybrown
      seagreen seashell sienna silver skyblue slateblue slategray slategrey snow springgreen steelblue tan
      teal thistle tomato turquoise violet wheat white whitesmoke yellow yellowgreen transparent
      currentcolor canvas canvastext linktext visitedtext activetext buttonface buttontext buttonborder field
      fieldtext highlight highlighttext selecteditem selecteditemtext mark marktext graytext accentcolor
      accentcolortext
    ])

    # Each type an arbitrary value can be, with Tailwind's test for it. A
    # root takes the first of these that it tells apart from the others.
    KINDS = {
      "color"        => ->(text : String) { text.starts_with?('#') || text.matches?(COLOR_FN) || NAMED.includes?(text.downcase) },
      "image"        => ->(text : String) { each?(text, ',') { |part| part.matches?(URL) || part.matches?(IMAGE_FN) } },
      "url"          => ->(text : String) { text.matches?(URL) },
      "angle"        => ->(text : String) { text.matches?(ANGLE) },
      "vector"       => ->(text : String) { text.matches?(VECTOR) },
      "percentage"   => ->(text : String) { percentage?(text) },
      "position"     => ->(text : String) { each?(text, ' ') { |part| SIDES.includes?(part) || length?(part) || percentage?(part) } },
      "bg-size"      => ->(text : String) { size?(text) },
      "line-width"   => ->(text : String) { Scan.split(text, ' ').all? { |part| length?(part) || number?(part) || WIDTHS.includes?(part) } },
      "length"       => ->(text : String) { length?(text) },
      "integer"      => ->(text : String) { text.matches?(INTEGER) },
      "number"       => ->(text : String) { number?(text) },
      "generic-name" => ->(text : String) { GENERIC.includes?(text) },
      # Only `font-*` takes a family, and it takes a number first.
      "family-name"   => ->(text : String) { !number?(text) && each?(text, ',') { |part| !part[0]?.try(&.ascii_number?) } },
      "absolute-size" => ->(text : String) { ABSOLUTE.includes?(text) },
      "relative-size" => ->(text : String) { text == "larger" || text == "smaller" },
    }

    # `[…]` or `(…)` as written in a class, with its type hint. Nil when it
    # holds nothing or would not stay inside its declaration.
    def self.parse(raw : String) : Arbitrary?
      match = raw[1...-1].match(HINT)
      text = written(match ? "#{raw[0]}#{match[2]}#{raw[-1]}" : raw)
      text.try { |found| Arbitrary.new(found, match.try(&.[1])) }
    end

    # A variant's value or a modifier that is not a name: `[…]` decoded, and
    # `(--x)` as `var(--x)`, with no type hint. Nil for a name, and for
    # brackets that hold nothing or would not stay inside what they are
    # written into.
    def self.written(raw : String) : String?
      if raw.starts_with?('[') && raw.ends_with?(']')
        inner = decode(raw[1...-1])
        inner unless inner.blank? || !Scan.contained?(inner)
      elsif raw.starts_with?('(') && raw.ends_with?(')')
        inner = decode(raw[1...-1])
        "var(#{inner})" if inner.starts_with?("--") && Scan.contained?(inner)
      end
    end

    # What follows a `/`: `written`, or a name as it is.
    def self.modifier(raw : String) : String?
      written(raw) || (raw if raw.matches?(NAME))
    end

    # The CSS a class's value stands for: `_` is a space, `\_` an underscore,
    # and operators in a math function get the spaces CSS wants around them.
    # Custom property names and url() are left as written.
    def self.decode(raw : String) : String
      text = String.build do |io|
        i = 0
        while i < raw.size
          c = raw[i]
          if c == '\\' && raw[i + 1]? == '_'
            io << '_'
            i += 2
          elsif c == '_'
            io << ' '
            i += 1
          elsif raw[i, 4] == "url("
            close = raw.index(')', i) || raw.size - 1
            io << raw[i..close]
            i = close + 1
          elsif c == '-' && raw[i + 1]? == '-'
            start = i
            i += 2
            while i < raw.size && (raw[i].ascii_alphanumeric? || raw[i] == '-' || raw[i] == '_')
              i += 1
            end
            io << raw[start...i]
          else
            io << c
            i += 1
          end
        end
      end
      space_math(text)
    end

    # A name (with its leading dashes), a number with its unit, a run of
    # spaces, or any one character.
    TOKEN = /\G(?:(?<word>-{0,2}[a-zA-Z_][\w-]*)|(?<number>(?:\d+\.?\d*|\.\d+)[a-zA-Z%]*)|(?<space> +)|.)/m

    # `calc(100%-2rem)` as `calc(100% - 2rem)`: inside a math function, one
    # space around each operator and after each comma, and none elsewhere
    # but between two values.
    def self.space_math(text : String) : String
      return text unless MATH.any? { |name| text.includes?("#{name}(") }
      math = [] of Bool # for each open bracket, whether it is a math function's
      operand = false   # whether the last token was a value
      gap = false       # whether a space waits for the next value
      at = 0
      String.build do |io|
        while match = TOKEN.match(text, at)
          token = match[0]
          inside = math.last? || false
          # `1px-2px`: a minus after a value, not the start of a name.
          token = "-" if inside && operand && token.starts_with?('-') && !token.starts_with?("--")
          at += token.size
          if inside && (token == "*" || token == "/" || (operand && (token == "+" || token == "-")))
            io << ' ' << token << ' '
            operand = gap = false
          elsif inside && token == ","
            io << ", "
            operand = gap = false
          elsif match["space"]?
            inside ? (gap = operand) : (io << token)
          else
            io << ' ' if gap
            io << token
            gap = false
            operand = !!(match["word"]? || match["number"]?) || token == ")"
            if token == "("
              math << inside
            elsif token == ")"
              math.pop?
            elsif match["word"]? && text[at]? == '('
              math << MATH.includes?(token)
              io << '('
              at += 1
              operand = false
            end
          end
        end
      end
    end

    # The first type in KINDS that is one of `among` and that the value can
    # be; none for a value that cannot be told (`var(--x)`).
    def self.kind(text : String, among : Enumerable(String)) : String?
      return nil if text.starts_with?("var(")
      KINDS.each { |kind, test| return kind if among.includes?(kind) && test.call(text) }
    end

    # Whether a list has a part that is not a variable, and each such part
    # passes the block.
    private def self.each?(text : String, separator : Char, & : String -> Bool) : Bool
      parts = Scan.split(text, separator).reject(&.starts_with?("var("))
      !parts.empty? && parts.all? { |part| yield part }
    end

    # `cover`, `contain`, or one or two of `auto`, a length and a percentage,
    # in a list where no part has more words.
    private def self.size?(text : String) : Bool
      found = false
      Scan.split(text, ',').each do |part|
        words = Scan.split(part, ' ')
        next found = true if part == "cover" || part == "contain"
        return false if words.size > 2
        found = true if words.all? { |word| word == "auto" || length?(word) || percentage?(word) }
      end
      found
    end

    # A value that holds a math function can be a length, a percentage or a
    # number.
    private def self.math?(text : String) : Bool
      text.includes?('(') && MATH.any? { |name| text.includes?("#{name}(") }
    end

    private def self.length?(text : String) : Bool
      text.matches?(LENGTH) || math?(text)
    end

    private def self.percentage?(text : String) : Bool
      text.matches?(PERCENT) || math?(text)
    end

    private def self.number?(text : String) : Bool
      text.matches?(NUMBER) || math?(text)
    end
  end
end
