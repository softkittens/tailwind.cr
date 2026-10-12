require "./tables"
require "./theme"
require "./utilities"
require "./value"

module Tailwind
  # Why a class builds no rule, as data: the caller writes the words.
  module Why
    # No root or class names the word: `hero`, `md:hero`.
    record NotUtility
    # A variant, as written before its `:`, that is not one: `dank:flex`.
    record UnknownVariant, variant : String
    # The root does not take the value: `bg-red-500` over a theme with no
    # `--color-red-500`, `rounded-huge`, `p-13.3`. The value is nil for a
    # root that builds nothing alone (`bg`). The namespaces are the ones the
    # root looks a named value up in, in that order; `Theme#names` gives
    # the names a theme has in one.
    record NoValue, root : String, value : String?, namespaces : Array(String)
    # The root, or the class that takes no value, has no negative: `p` for
    # `-p-4`, `flex` for `-flex`, `mt-auto` for `-mt-auto`.
    record NoNegative, root : String
    # The root or class builds without the modifier, and not with it: `p`
    # for `p-4/2`, `hidden` for `hidden/50`.
    record NoModifier, root : String, modifier : String
    # An arbitrary value, modifier or property's value that Tailwind
    # refuses, as written: `[1px;color:red]`.
    record Refused, value : String

    # Why `utility`, a class without its variants, builds no rule; nil when
    # it builds one.
    def self.of(theme : Theme, utility : String) : Reason?
      return nil if Utilities.resolve(theme, utility)
      if utility.starts_with?('[') && utility.ends_with?(']')
        return Utilities.declaration(utility).try { |_, value| Refused.new(value) } || NotUtility.new
      end
      reading = Utilities.read(theme, utility).as?(Read::Functional)
      if reading
        value = reading.value
        return Refused.new(value) if value && arbitrary?(value) && Value.parse(value).nil?
        modifier = reading.modifier
        return Refused.new(modifier) if modifier && arbitrary?(modifier) && Value.written(modifier).nil?
      end
      # `-p-4`, `-flex`: no root reads it, and one reads it without the `-`.
      # `-mt-auto`: what builds without the `-` has no negative.
      if (positive = utility.lchop?('-')) && (reading.nil? || Utilities.resolve(theme, positive))
        Utilities.read(theme, positive).try { |found| return NoNegative.new(named(found)) }
      end
      body = Scan.split(utility, '/')[0]
      if body.size < utility.size && Utilities.resolve(theme, body)
        Utilities.read(theme, body).try { |found| return NoModifier.new(named(found), utility[(body.size + 1)..]) }
      end
      return NotUtility.new unless reading
      name = reading.negative ? "-#{reading.root}" : reading.root
      NoValue.new(reading.root, reading.value, Root.for(theme, name, Tables::FUNCTIONAL[name], nil).namespaces)
    end

    # The class or root a reading names.
    private def self.named(reading : Reading) : String
      case reading
      in Read::Static     then reading.name
      in Read::Functional then reading.root
      end
    end

    private def self.arbitrary?(text : String) : Bool
      (text.starts_with?('[') && text.ends_with?(']')) || (text.starts_with?('(') && text.ends_with?(')'))
    end
  end

  alias Reason = Why::NotUtility | Why::UnknownVariant | Why::NoValue | Why::NoNegative | Why::NoModifier | Why::Refused
end
