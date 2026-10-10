require "./scan"
require "./tables"
require "./theme"
require "./value"
require "./root"
require "./roots"

module Tailwind
  # A utility (a class without its variants) as the rules it emits.
  module Utilities
    # The rules for `utility`, or nil when it is not one.
    def self.resolve(theme : Theme, utility : String) : Rules?
      return property(utility) if utility.starts_with?('[') && utility.ends_with?(']')
      return container(theme) if utility == "container"
      if found = Tables::STATIC[utility]?
        return found
      end
      parts = Scan.split(utility, '/')
      body = parts[0]
      modifier = parts[1]?
      # One modifier: `[…]`, `(--x)` or a name.
      return nil if parts.size > 2 || (modifier && !Value.modifier(modifier))
      each_root(body) do |name, value|
        row = Tables::FUNCTIONAL[name]? || next
        if found = Root.for(theme, name, row, modifier).resolve(value)
          return found
        end
      end
      nil
    end

    # `[mask-type:luminance]`: any declaration.
    private def self.property(utility : String) : Rules?
      inner = utility[1...-1]
      colon = inner.index(':') || return nil
      name = inner[0...colon]
      return nil unless name.matches?(/\A-{0,2}[a-zA-Z][\w-]*\z/)
      value = Value.decode(inner[(colon + 1)..])
      return nil if value.blank? || !Scan.contained?(value)
      Rules.new([Decl.new(name, value).as(Node)])
    end

    # A width that steps up with the theme's breakpoints.
    private def self.container(theme : Theme) : Rules
      nodes = [Decl.new(SORT, "--tw-container-component"), Decl.new("width", "100%")] of Node
      theme.breakpoints.each do |_, value|
        nodes << Block.new("@media (width >= #{value})", [Decl.new("max-width", value).as(Node)])
      end
      Rules.new(nodes)
    end

    # Each way to read `body` as a root and a value, the longest root first.
    private def self.each_root(body : String, &) : Nil
      if body.ends_with?(']') || body.ends_with?(')')
        if at = body.index(body.ends_with?(']') ? "-[" : "-(")
          yield body[0...at], body[(at + 1)..]
        end
        return
      end
      at = body.size
      while at > 0 && (at = body.rindex('-', at - 1))
        yield body[0...at], body[(at + 1)..] if at > 0
      end
      yield body, nil
    end
  end
end
