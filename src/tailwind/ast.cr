module Tailwind
  # A declaration. A template's declaration with an empty value is one read
  # from a theme token's own sub-token (`--text-lg--line-height`), and is left
  # out when the theme has none.
  record Decl, property : String, value : String, important : Bool = false do
    def absent? : Bool
      value.empty?
    end
  end

  # A nested rule or at-rule: `&:hover`, `:where(& > :not(:last-child))`,
  # `@media (hover: hover)`.
  class Block
    getter head : String
    getter nodes : Array(Node)

    def initialize(@head : String, @nodes : Array(Node))
    end

    def at_rule? : Bool
      head.starts_with?('@')
    end
  end

  alias Node = Decl | Block

  # A registered custom property: `@property`, with a fallback for browsers
  # without it. `initial_first` writes its initial value before `inherits`,
  # as Tailwind writes the `--tw-content` that `before:` and `after:` register.
  record Property, name : String, syntax : String, initial : String?, initial_first : Bool = false

  # What one utility emits.
  record Rules, nodes : Array(Node), properties : Array(Property) = [] of Property

  # `--tw-sort` only steers sorting, as in Tailwind: never printed.
  SORT = "--tw-sort"
end
