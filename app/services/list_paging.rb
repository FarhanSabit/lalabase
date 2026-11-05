# frozen_string_literal: true

# The page and per_page of a token list (the ticket list of REST and MCP, the time
# sessions of /api/v1), read the lenient way those lists always read them: a string
# that is no number is the default. Only what used to raise past the callers into a
# 500 is refused: a page so far out that the offset leaves PostgreSQL's bigint, and
# a value that is a list or a hash (`page[]=1`), where `.to_i` raised NoMethodError.
#
# The inbox (Notifications::InboxQuery) and knowledge (Knowledge::Lookup) read
# their paging strictly by a contract of their own; this does not replace theirs.
#
# Entry point: page
class ListPaging
  # Far beyond any real list (100_000 pages of 100 rows), close enough to keep
  # (page - 1) * per_page inside PostgreSQL's OFFSET range. The inbox's bound.
  MAX_PAGE = 100_000

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

  def self.scalar(value, name:)
    return value if value.nil? || value.is_a?(String) || value.is_a?(Integer)

    raise InvalidArgument, "invalid #{name} (expected a whole number)"
  end
  private_class_method :scalar
end
