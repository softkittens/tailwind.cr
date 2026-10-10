require "./tailwind/ast"
require "./tailwind/scan"
require "./tailwind/theme"
require "./tailwind/value"
require "./tailwind/tables"
require "./tailwind/utilities"
require "./tailwind/fallback"
require "./tailwind/variants"
require "./tailwind/print"

# Tailwind CSS classes compiled to a stylesheet. The output for a set of
# classes matches Tailwind's own build of them (the differential spec holds
# it to that); the utilities are tables written from Tailwind by
# script/vendor.cr.
module Tailwind
  VERSION = "0.1.0"
  # The Tailwind CSS release the tables and the default theme come from.
  TAILWIND_VERSION = {{ read_file("#{__DIR__}/tailwind/vendor/VERSION").strip }}

  HEADER    = "/*! tailwindcss v#{TAILWIND_VERSION} | MIT License | https://tailwindcss.com */\n"
  PREFLIGHT = {{ read_file("#{__DIR__}/tailwind/vendor/preflight.css") }}

  PROPERTY_ORDER = begin
    order = {} of String => Int32
    {{ read_file("#{__DIR__}/tailwind/vendor/property_order.txt") }}.each_line.with_index { |name, i| order[name.strip] ||= i }
    order
  end

  PROPERTIES_FALLBACK = "@supports ((-webkit-hyphens: none) and (not (margin-trim: inline))) or ((-moz-orient: inline) and (not (color:rgb(from red r g b))))"

  # A class this compiler builds.
  record Candidate, name : String, variants : Array(Variants::Variant), rules : Rules, important : Bool

  # The stylesheet for `classes` over `theme`: the ones that are utilities,
  # and no rule for any other word.
  def self.compile(classes : Enumerable(String), theme : Theme = Theme.default, preflight : Bool = true) : String
    candidates = classes.to_set.compact_map { |name| parse(theme, name) }
    emit(theme, sort(candidates), preflight)
  end

  # A class as a candidate, or nil when it is not a utility.
  def self.parse(theme : Theme, name : String) : Candidate?
    parts = Scan.split(name, ':')
    utility = parts.pop
    return nil if utility.empty? || parts.size > Variants::DEPTH
    important = utility.ends_with?('!') || utility.starts_with?('!')
    utility = utility.ends_with?('!') ? utility.rchop('!') : utility.lchop('!')
    variants = parts.map { |part| Variants.resolve(theme, part) || return nil }
    rules = Utilities.resolve(theme, utility) || return nil
    rules = Rules.new(rules.nodes, [Variants::CONTENT] + rules.properties) if variants.any?(&.content)
    Candidate.new(name, variants, rules, important)
  end

  # Tailwind's order: by variants, then by the first CSS property that
  # differs, then more declarations first, then by name.
  private def self.sort(candidates : Array(Candidate)) : Array(Candidate)
    keyed = candidates.map { |c| {c, variant_key(c), property_sort(c.rules.nodes)} }
    keyed.sort! do |(a, a_key, (a_order, a_count)), (z, z_key, (z_order, z_count))|
      next a_key <=> z_key unless a_key == z_key
      offset = 0
      while offset < a_order.size && offset < z_order.size && a_order[offset] == z_order[offset]
        offset += 1
      end
      by_order = (a_order[offset]? || Int32::MAX) <=> (z_order[offset]? || Int32::MAX)
      next by_order unless by_order == 0
      next z_count <=> a_count unless z_count == a_count
      natural(a.name, z.name)
    end
    keyed.map(&.[0])
  end

  # Tailwind gives every variant in use a bit, in the order it sorts them,
  # and sorts classes by the mask of theirs. A class's variants, last-sorted
  # first, compare as that mask does.
  private def self.variant_key(candidate : Candidate) : Array({Int32, Variants::Rank})
    candidate.variants.map { |variant| {variant.order, variant.rank} }.uniq!.sort! { |a, z| z <=> a }
  end

  # The indices of the properties a utility sets, breadth first, and how
  # many declarations it has. A `--tw-sort` stands for the properties after it.
  private def self.property_sort(nodes : Array(Node)) : {Array(Int32), Int32}
    order = Set(Int32).new
    count = 0
    queue = Deque(Node).new(nodes)
    sorted = false
    while node = queue.shift?
      case node
      when Decl
        count += 1
        next if sorted
        if node.property == SORT && (index = PROPERTY_ORDER[node.value]?)
          order << index
          sorted = true
          next
        end
        PROPERTY_ORDER[node.property]?.try { |index| order << index }
      when Block
        node.nodes.each { |child| queue << child }
      end
    end
    {order.to_a.sort!, count}
  end

  # Tailwind's compare: character by character, runs of digits as numbers
  # of any size, and as text when the numbers are equal.
  def self.natural(a : String, z : String) : Int32
    a_bytes = a.to_slice
    z_bytes = z.to_slice
    i = 0
    while i < a_bytes.size && i < z_bytes.size
      ac = a_bytes[i]
      zc = z_bytes[i]
      if digit?(ac) && digit?(zc)
        a_run = digits(a_bytes, i)
        z_run = digits(z_bytes, i)
        a_number = a_run.lstrip('0')
        z_number = z_run.lstrip('0')
        diff = {a_number.size, a_number, a_run} <=> {z_number.size, z_number, z_run}
        return diff unless diff == 0
      elsif ac != zc
        return ac.to_i32 - zc.to_i32
      end
      i += 1
    end
    a_bytes.size - z_bytes.size
  end

  private def self.digits(bytes : Bytes, start : Int32) : String
    stop = start + 1
    while stop < bytes.size && digit?(bytes[stop])
      stop += 1
    end
    String.new(bytes[start...stop])
  end

  private def self.digit?(byte : UInt8) : Bool
    byte >= '0'.ord && byte <= '9'.ord
  end

  private def self.emit(theme : Theme, candidates : Array(Candidate), preflight : Bool) : String
    sheet = [] of Block
    candidates.each do |candidate|
      # After sorting: Tailwind orders a class by the rule as first written.
      nodes = Variants.wrap(Fallback.rules(theme, candidate.rules).nodes, candidate.variants)
      nodes = Print.important(nodes) if candidate.important
      Print.flatten(".#{escape(candidate.name)}", nodes).each { |item| Print.append(sheet, item) }
    end
    utilities = String.build { |io| sheet.each { |item| Print.block(io, item, 2) } }
    base = preflight ? preflight_css(theme) : ""

    properties = candidates.flat_map(&.rules.properties).uniq!(&.name)

    String.build do |io|
      io << HEADER
      io << "@layer properties;\n" unless properties.empty?
      io << "@layer theme, base, components, utilities;\n"
      vars = used_vars(theme, utilities + base)
      unless vars.empty?
        io << "@layer theme {\n  :root, :host {\n"
        vars.each { |name, value| io << "    " << name << ": " << value << ";\n" }
        io << "  }\n}\n"
      end
      io << base
      if utilities.empty?
        io << "@layer utilities;\n"
      else
        io << "@layer utilities {\n" << utilities << "}\n"
      end
      properties.each { |property| Print.property(io, property) }
      keyframes(theme, vars).each { |block| Print.block(io, block, 0) }
      unless properties.empty?
        io << "@layer properties {\n  " << PROPERTIES_FALLBACK << " {\n    *, ::before, ::after, ::backdrop {\n"
        properties.each { |p| io << "      " << p.name << ": " << (p.initial || "initial") << ";\n" }
        io << "    }\n  }\n}\n"
      end
    end
  end

  # The preflight reads a default font token only when the theme declares it.
  private def self.preflight_css(theme : Theme) : String
    PREFLIGHT.gsub(/var\((--default-[a-z-]+), ([^)]*)\)/) { |whole| theme.declared.includes?($1) ? whole : $2 }
  end

  # The theme tokens the CSS reads and the ones of `@theme static`, and the
  # tokens those read, in theme order.
  private def self.used_vars(theme : Theme, css : String) : Array({String, String})
    used = theme.static.select { |name| theme.has?(name) && !theme.references.includes?(name) }.to_set
    pending = [css] + used.compact_map { |name| theme[name]? }
    while text = pending.pop?
      text.scan(/var\((--[a-zA-Z0-9_.-]+)/) do |m|
        name = m[1]
        next if used.includes?(name) || theme.inline.includes?(name) || theme.references.includes?(name)
        next unless value = theme[name]?
        used << name
        pending << value
      end
    end
    theme.vars.compact_map { |name, value| {name, value} if used.includes?(name) }
  end

  # The keyframes the emitted `--animate-*` tokens name.
  private def self.keyframes(theme : Theme, vars : Array({String, String})) : Array(Block)
    names = vars.select { |name, _| name.starts_with?("--animate-") }.flat_map { |_, value| value.split(/[\s,]+/) }
    theme.keyframes.compact_map { |name, block| block if names.includes?(name) }
  end

  # CSS.escape for a class name, as Tailwind writes selectors.
  def self.escape(name : String) : String
    String.build do |io|
      name.each_char_with_index do |c, i|
        if c == '\0'
          io << '�'
        elsif c.ord.in?(0x01..0x1f) || c.ord == 0x7f || (i == 0 && c.ascii_number?) || (i == 1 && c.ascii_number? && name[0] == '-')
          io << '\\' << c.ord.to_s(16) << ' '
        elsif i == 0 && c == '-' && name.size == 1
          io << '\\' << c
        elsif c.ord >= 0x80 || c == '-' || c == '_' || c.ascii_alphanumeric?
          io << c
        else
          io << '\\' << c
        end
      end
    end
  end
end
