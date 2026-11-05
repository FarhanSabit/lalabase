# frozen_string_literal: true

# The ticket search behind the "Link" modal (doc/ticket_relations_plan.md, revision 4, §7):
# up to LIMIT tickets of `scope` whose number is the term, then those whose title matches it.
#
# The caller hands in what the user may read (policy_scope(Ticket)); relations cross projects,
# so this search must never be run over anything wider. It searches number and TITLE only: a
# picker term is a title, and a search over comment text would need the readable ones only
# (Post.readable_by), or a hit would tell the searcher what a private comment says.
#
# No SQL is built from the term here. The number goes in as an integer, the title through
# pg_search (Ticket.search_title), which strips tsquery syntax and quotes the rest; the raw
# term in to_tsquery would raise on "foo:" or "(" while somebody is still typing.
module Tickets
  class Lookup
    LIMIT = 20
    # Longer terms are cut: a picker term is a few words, and every word is a tsquery lexeme.
    MAX_TERM_LENGTH = 100
    # A number with more digits than this cannot be a ticket number (a 4-byte integer column),
    # and casting it would raise instead of finding nothing.
    MAX_NUMBER_DIGITS = 9

    def self.call(**)
      new(**).call
    end

    def initialize(scope:, term:, exclude_id: nil)
      @scope = scope
      @term = term.to_s.strip.first(MAX_TERM_LENGTH)
      @exclude_id = exclude_id.presence
    end

    def call
      return [] if @term.empty?

      by_number = number ? candidates.where(number: number).order(:number, :id).limit(LIMIT).to_a : []
      by_title = candidates.search_title(@term).where.not(id: by_number.map(&:id)).limit(LIMIT - by_number.size).to_a
      by_number + by_title
    end

    private

    def candidates
      scope = @scope.includes(:project)
      @exclude_id ? scope.where.not(id: @exclude_id) : scope
    end

    def number
      digits = @term.delete_prefix('#')
      digits.to_i if digits.match?(/\A\d{1,#{MAX_NUMBER_DIGITS}}\z/o)
    end
  end
end
