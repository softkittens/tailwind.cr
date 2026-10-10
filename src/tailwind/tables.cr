require "json"
require "./ast"

module Tailwind
  struct Rules
    # A rule as the tables hold one: `{"nodes": […], "properties": [names]}`.
    def self.new(pull : JSON::PullParser) : self
      nodes = [] of Node
      properties = [] of Property
      pull.read_object do |key|
        case key
        when "nodes"      then nodes = Tables.nodes(pull)
        when "properties" then pull.read_array { properties << Tables::PROPERTIES[pull.read_string] }
        else                   pull.skip
        end
      end
      new(nodes, properties)
    end
  end

  # The utilities, as script/vendor.cr wrote them from Tailwind's own
  # output: every class that takes no value (static.json), and each root
  # that takes one as templates with § where the value goes
  # (functional.json).
  module Tables
    HOLE = "§"

    # The template a bare number fills, and whether the number may be a
    # decimal: then a multiple of 0.25, as spacing steps are.
    record Number, template : Int32, decimals : Bool do
      include JSON::Serializable
    end

    # The template `a/b` fills, written with `separator` between the two.
    record Fraction, template : Int32, separator : String do
      include JSON::Serializable
    end

    # A functional root. Each field names a template by its index.
    struct Row
      include JSON::Serializable

      @[JSON::Field(key: "t")]
      getter templates : Array(Rules)
      # For an arbitrary value of no known type.
      getter any : Int32?
      # For an arbitrary value by its type, inferred or hinted, where not `any`.
      getter types = {} of String => Int32
      getter hints = {} of String => Int32
      # For a named value: each theme namespace, in lookup order.
      getter theme = [] of {String, Int32}
      # For the root alone: read from a namespace's default token, or, with
      # no namespace, the template as it is.
      getter base = [] of {String?, Int32}
      getter number : Number?
      # For the numbers that are not `number` filled in: `p-0` is `0px`.
      getter exact = {} of String => Int32
      # For a bare percentage: `from-10%`.
      getter percent : Int32?
      getter fraction : Fraction?

      # The template a colour of the theme fills.
      def color : Int32?
        theme.find { |namespace, _| namespace == "--color" }.try(&.[1])
      end
    end

    # The custom properties utilities register, by name.
    PROPERTIES = Hash(String, {String, String?})
      .from_json({{ read_file("#{__DIR__}/vendor/properties.json") }})
      .to_h { |name, (syntax, initial)| {name, Property.new(name, syntax, initial)} }

    STATIC     = Hash(String, Rules).from_json({{ read_file("#{__DIR__}/vendor/static.json") }})
    FUNCTIONAL = Hash(String, Row).from_json({{ read_file("#{__DIR__}/vendor/functional.json") }})

    # A rule's nodes: a declaration is `[property, value]`, with a null value
    # for one a theme token's own sub-token fills; a nested rule or at-rule
    # is `{"head": …, "nodes": […]}`.
    def self.nodes(pull : JSON::PullParser) : Array(Node)
      nodes = [] of Node
      pull.read_array do
        if pull.kind.begin_array?
          pull.read_begin_array
          property = pull.read_string
          value = pull.read_string_or_null
          pull.read_end_array
          nodes << Decl.new(property, value || "")
        else
          head = ""
          children = [] of Node
          pull.read_object do |key|
            case key
            when "head"  then head = pull.read_string
            when "nodes" then children = nodes(pull)
            else              pull.skip
            end
          end
          nodes << Block.new(head, children)
        end
      end
      nodes
    end
  end
end
