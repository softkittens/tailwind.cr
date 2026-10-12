require "./scan"
require "./tables"
require "./theme"
require "./value"
require "./root"
require "./roots"

module Tailwind
  # How a utility (a class without its variants) is read.
  module Read
    # A class that takes no value, by its name: `flex`, `-bottom-full`.
    record Static, name : String
    # A root and what follows it: `bg-ink/50` is `bg`, `ink` and `50`, and
    # `-mt-4` is `mt`, `4` and negative. The value is as written, brackets
    # and all, and nil for the root alone (`rounded`).
    record Functional, root : String, value : String?, modifier : String?, negative : Bool
  end

  alias Reading = Read::Static | Read::Functional

  # A utility as the rules it emits.
  module Utilities
    # What reads a utility, and its rules when it builds.
    private record Match, reading : Reading?, rules : Rules?

    # The rules for `utility`, or nil when it is not one.
    def self.resolve(theme : Theme, utility : String) : Rules?
      match(theme, utility).try(&.rules)
    end

    # The class or root that reads `utility`, whether or not it builds: the
    # root that builds it, and the longest root its name starts with when
    # none does. Nil when none reads it: a word that is no utility, an
    # arbitrary property, the negative of a root that has none.
    def self.read(theme : Theme, utility : String) : Reading?
      match(theme, utility).try(&.reading)
    end

    private def self.match(theme : Theme, utility : String) : Match?
      if utility.starts_with?('[') && utility.ends_with?(']')
        return property(utility).try { |rules| Match.new(nil, rules) }
      end
      return Match.new(Read::Static.new(utility), container(theme)) if utility == "container"
      if found = Tables::STATIC[utility]?
        return Match.new(Read::Static.new(utility), found)
      end
      parts = Scan.split(utility, '/')
      body = parts[0]
      # What follows the first `/`, as written. One modifier builds: `[…]`,
      # `(--x)` or a name.
      modifier = parts.size > 1 ? utility[(body.size + 1)..] : nil
      valid = parts.size == 1 || (parts.size == 2 && !Value.modifier(parts[1]).nil?)
      longest = nil
      each_root(body) do |name, value|
        row = Tables::FUNCTIONAL[name]? || next
        reading = Read::Functional.new(name.lchop('-'), value, modifier, name.starts_with?('-'))
        # The whole of `body` comes last, and is the longest root when it is one.
        longest = reading if longest.nil? || value.nil?
        next unless valid
        if found = Root.for(theme, name, row, modifier).resolve(value)
          return Match.new(reading, found)
        end
      end
      longest.try { |reading| Match.new(reading, nil) }
    end

    # `[mask-type:luminance]` as its property and value, or nil when it is
    # not written as one.
    def self.declaration(utility : String) : {String, String}?
      inner = utility[1...-1]
      colon = inner.index(':') || return nil
      name = inner[0...colon]
      return nil unless name.matches?(/\A-{0,2}[a-zA-Z][\w-]*\z/)
      {name, Value.decode(inner[(colon + 1)..])}
    end

    # `[mask-type:luminance]`: any declaration.
    private def self.property(utility : String) : Rules?
      name, value = declaration(utility) || return nil
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
