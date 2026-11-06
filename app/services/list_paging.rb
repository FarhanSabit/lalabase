# frozen_string_literal: true

# The page and per_page of a token list, read one of two ways.
#
# * Lenient (.page, .per_page): the ticket list of REST and MCP and the time sessions of
#   /api/v1 read them the way those lists always did: a string that is no number is the
#   default. Only what used to raise past the callers into a 500 is refused: a page so far
#   out that the offset leaves PostgreSQL's bigint, and a value that is a list or a hash
#   (`page[]=1`), where `.to_i` raised NoMethodError.
# * Strict (.strict_number): the lists that refuse what they cannot read rather than take
#   the default, so a program never gets fewer rows than it asked for without being told: the
#   glossary (Glossary::Lookup, REST and MCP) and, over /api/v1, the people directory and the
#   knowledge and meetings lists (Knowledge::Lookup, strict: true). One rule and one wording
#   for them all, in the language of the moment (the token owner's on a token request).
#
# Three lists keep a rule of their own: the inbox (Notifications::InboxQuery clamps per_page
# and reads a page below 1 as 1), the posts of a ticket (Tickets::Reading, which may clamp
# posts_per_page) and the MCP tool list_projects (clamps per_page).
#
# Entry point: page
class ListPaging
  # Far beyond any real list (100_000 pages of 100 rows), close enough to keep
  # (page - 1) * per_page inside PostgreSQL's OFFSET range. The inbox's bound.
  MAX_PAGE = 100_000
  # How much of a refused value a strict refusal quotes back: enough to recognise it, not a
  # mirror for any amount of input.
  QUOTED_LENGTH = 20

  class InvalidArgument < ArgumentError; end

  # => Integer, at least 1. Absent or no number is 1.
  def self.page(value)
    number = scalar(value, name: 'page').to_i
    raise InvalidArgument, "invalid page (at most #{MAX_PAGE})" if number > MAX_PAGE

    [number, 1].max
  end

  # => Integer from 1 to max. Absent, no number or below 1 is the default.
  def self.per_page(value, default:, max:)
    number = scalar(value, name: 'per_page').to_i
    return default if number <= 0

    [number, max].min
  end

  # => Integer from 1 to max; absent or empty is the default. A whole number as text (the
  # query string: digits only) or as a JSON number (an Integer, or a Float with a whole value,
  # which JSON Schema counts as an integer: 2.0). Anything else is refused, the value quoted
  # back only when it is text or a number, and only its start: a list or a nested value would
  # show Ruby's insides.
  #
  # @raise [InvalidArgument]
  def self.strict_number(value, name:, default:, max:)
    return default if value.nil? || value == ''

    number = value if value.is_a?(Integer)
    number = value.to_i if value.is_a?(Float) && value.finite? && value == value.floor
    number = Integer(value, 10) if value.is_a?(String) && value.match?(/\A\d+\z/)
    return number if number&.between?(1, max)

    shown = value.is_a?(String) || value.is_a?(Numeric) ? " #{value.to_s.truncate(QUOTED_LENGTH).inspect}" : ''
    raise InvalidArgument, I18n.t('services.list_paging.invalid_number', name: name, shown: shown, max: max)
  end

  def self.scalar(value, name:)
    return value if value.nil? || value.is_a?(String) || value.is_a?(Integer)

    raise InvalidArgument, "invalid #{name} (expected a whole number)"
  end
  private_class_method :scalar
end
