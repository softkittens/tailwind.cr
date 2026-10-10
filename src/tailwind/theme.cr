require "./ast"
require "./value"

module Tailwind
  # A problem in a theme's CSS, at a line.
  class Error < Exception
    getter line : Int32

    def initialize(@line : Int32, message : String)
      super(message)
    end
  end

  # The design tokens utilities read, as ordered `--name => value`: Tailwind's
  # default theme, then a project's own `@theme { --name: value; }` blocks. A
  # token with a default's name replaces its value and keeps its place.
  # `--color-*: initial` removes a namespace's tokens, `--*: initial` all of
  # them, and `@keyframes` inside a block is kept for `animate-*`.
  #
  # A block's options are Tailwind's: `@theme inline`, `@theme static` and
  # `@theme reference`, alone or together.
  #
  # `@custom-variant dark (&:where(.dark, .dark *));` beside the blocks makes
  # `dark:` that selector instead of the `prefers-color-scheme` media query.
  class Theme
    DEFAULT_CSS = {{ read_file("#{__DIR__}/vendor/theme.css") }}

    getter vars = {} of String => String
    # Tokens of `@theme inline`: a utility writes their value, not var().
    getter inline = Set(String).new
    getter keyframes = {} of String => Block
    # Tokens of `@theme static`: written to the sheet when no class reads them.
    getter static = Set(String).new
    # Tokens of `@theme reference`: never written to the sheet, so a utility
    # writes var() with their value to fall back on.
    getter references = Set(String).new
    # Tokens a theme names, with a value or without one.
    getter declared = Set(String).new
    # What `dark:` wraps a rule in, when it is not the media query: the
    # selectors and at-rules between the brackets of `@custom-variant dark`.
    getter dark : String?

    # Tailwind's default theme.
    class_getter default : Theme { new.tap(&.add(DEFAULT_CSS)) }

    # The default theme with `css` on top of it.
    def self.load(css : String) : Theme
      new.tap do |theme|
        theme.add(DEFAULT_CSS)
        theme.add(css)
      end
    end

    protected def add(css : String) : Nil
      Parser.new(css).statements(top: true).each do |node|
        next @dark = node.value unless node.is_a?(Block)
        options = node.head.split
        # `@keyframes` at the top is read as one inside a block.
        (options[0] == "@keyframes" ? [node.as(Node)] : node.nodes).each do |child|
          case child
          in Block then keyframes[child.head.lchop("@keyframes ").strip] = child if child.head.starts_with?("@keyframes ")
          in Decl  then set(child.property, child.value, options)
          end
        end
      end
    end

    private def set(name : String, value : String, options : Array(String)) : Nil
      if name.ends_with?('*')
        prefix = name.rchop('*')
        vars.reject! { |key, _| key.starts_with?(prefix) } if value == "initial"
        return
      end
      declared << name
      # `--theme(--font-sans, initial)`: that token, when the theme has it.
      if match = value.match(/\A--theme\((--[\w-]+), initial\)\z/)
        return vars.delete(name) unless vars.has_key?(match[1])
        value = "var(#{match[1]})"
      end
      vars[name] = value
      options.includes?("inline") ? inline.add(name) : inline.delete(name)
      options.includes?("static") ? static.add(name) : static.delete(name)
      options.includes?("reference") ? references.add(name) : references.delete(name)
    end

    def []?(name : String) : String?
      vars[name]?
    end

    def has?(name : String) : Bool
      vars.has_key?(name)
    end

    # A namespace's token as a utility writes it: `var(--radius-lg)`, or the
    # value itself for an inline token.
    def resolve(namespace : String, key : String) : String?
      return nil unless key.matches?(Value::NAME)
      reference("#{namespace}-#{key.gsub('.', '_')}")
    end

    def reference(name : String) : String?
      value = vars[name]? || return nil
      return value if inline.includes?(name)
      references.includes?(name) ? "var(#{name}, #{value})" : "var(#{name})"
    end

    # `--breakpoint-*` as {name, value}, smallest first.
    def breakpoints : Array({String, String})
      found = vars.compact_map do |name, value|
        {name.lchop("--breakpoint-"), value} if name.starts_with?("--breakpoint-")
      end
      found.sort_by { |_, value| value.to_f?(strict: false) || 0.0 }
    end

    # CSS as nested declarations and blocks: enough for `@theme` and
    # `@keyframes`.
    private class Parser
      DARK = /\A@custom-variant\s+dark\s*\(\s*(\S.*?)\s*\)\z/m

      def initialize(css : String)
        @chars = css.chars
        @i = 0
        @line = 1
      end

      # At the top, only `@theme` and `@keyframes` blocks, and
      # `@custom-variant dark (…);`, which is read as a declaration.
      def statements(top : Bool = false) : Array(Node)
        out = [] of Node
        loop do
          skip_space
          break if eof? || char == '}'
          line = @line
          text = read_statement
          if top && char != '{' && (dark = text.match(DARK))
            advance if char == ';'
            out << Decl.new("dark", dark[1])
            next
          end
          if top && !(char == '{' && text.matches?(/\A@(theme|keyframes)\b/))
            raise Error.new(line, "expected @theme { … } or @custom-variant dark (…)")
          end
          if char == '{'
            advance
            nodes = statements
            raise Error.new(line, "#{text} { is not closed") unless char == '}'
            advance
            out << Block.new(text.gsub(/\s+/, " "), nodes)
          else
            advance if char == ';'
            colon = text.index(':') || raise Error.new(line, "expected a declaration, found #{text}")
            out << Decl.new(text[0...colon].strip, text[(colon + 1)..].strip)
          end
        end
        out
      end

      # Up to the `;`, `{` or `}` that is not inside quotes or brackets, with
      # comments removed. A value keeps its line breaks, as Tailwind prints it.
      private def read_statement : String
        depth = 0
        quote = nil
        text = String.build do |io|
          until eof?
            c = char
            if quote
              quote = nil if c == quote
            elsif c == '"' || c == '\''
              quote = c
            elsif c == '/' && @chars[@i + 1]? == '*'
              skip_comment
              next
            elsif c == '(' || c == '['
              depth += 1
            elsif c == ')' || c == ']'
              depth -= 1
            elsif depth == 0 && (c == ';' || c == '{' || c == '}')
              break
            end
            io << c
            advance
          end
        end
        text.strip
      end

      private def skip_space : Nil
        until eof?
          if char.whitespace?
            advance
          elsif char == '/' && @chars[@i + 1]? == '*'
            skip_comment
          else
            break
          end
        end
      end

      private def skip_comment : Nil
        line = @line
        advance
        advance
        until eof? || (char == '*' && @chars[@i + 1]? == '/')
          advance
        end
        raise Error.new(line, "a comment is not closed") if eof?
        advance
        advance
      end

      private def advance : Nil
        @line += 1 if @chars[@i]? == '\n'
        @i += 1
      end

      private def char : Char
        @chars[@i]? || '\0'
      end

      private def eof? : Bool
        @i >= @chars.size
      end
    end
  end
end
