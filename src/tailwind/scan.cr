module Tailwind
  # A class's text outside its brackets: a `:`, `/`, `,` or space inside
  # `[…]`, `(…)`, `{…}` or a string is part of a value, and separates
  # nothing. Brackets, strings and `\` are read as Tailwind reads them, so a
  # bracket or a string left open takes the rest of the text with it.
  module Scan
    # `text` split at each `separator` outside brackets.
    def self.split(text : String, separator : Char) : Array(String)
      parts = [] of String
      start = 0
      each(text) do |c, i, depth|
        next unless depth == 0 && c == separator
        parts << text[start...i]
        start = i + 1
      end
      parts << text[start..]
    end

    # Where the bracket opened at `open` closes; the end of the text when it
    # does not.
    def self.close(text : String, open : Int32) : Int32
      depth = 0
      open.upto(text.size - 1) do |i|
        case text[i]
        when '(', '[' then depth += 1
        when ')', ']' then depth -= 1
        end
        return i if depth == 0
      end
      text.size - 1
    end

    # Whether an arbitrary value stays inside the declaration or selector it
    # is written into: no `;` and no closing bracket but inside brackets the
    # value opens itself. Tailwind's own test, with its limits: it knows
    # nothing of comments or `url(`, and lets a `{` through.
    def self.contained?(text : String) : Bool
      each(text, curly: false) do |c, _, depth|
        return false if depth == 0 && (c == ';' || c == ')' || c == ']' || c == '}')
      end
      true
    end

    # Each character that is not escaped or in a string, with where it is
    # and how many brackets are open around it.
    private def self.each(text : String, curly : Bool = true, & : Char, Int32, Int32 ->) : Nil
      closers = [] of Char
      quote = nil
      escaped = false
      text.each_char_with_index do |c, i|
        if escaped
          escaped = false
        elsif c == '\\'
          escaped = true
        elsif quote
          quote = nil if c == quote
        else
          yield c, i, closers.size
          case c
          when '"', '\'' then quote = c
          when '('       then closers << ')'
          when '['       then closers << ']'
          when '{'       then closers << '}' if curly
          when ')', ']', '}'
            closers.pop if closers.last? == c
          end
        end
      end
    end
  end
end
