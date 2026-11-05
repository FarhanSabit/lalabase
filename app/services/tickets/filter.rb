# frozen_string_literal: true

module Tickets
  # Shared ticket-LIST query shaping: filtering, ordering, pagination and the
  # total count. Used by BOTH Api::V1::TicketsController#index and the MCP
  # list_tickets tool, so the two surfaces apply identical semantics — the
  # query-side counterpart to the shared Tickets::Serializer (D4). Before this,
  # the same filter SQL lived in both places and could silently drift.
  #
  # Reads from a plain params/args object via #[], so neither caller's request
  # type leaks in: ActionController::Parameters (controller) and a symbol-keyed
  # Hash (tool) both support indifferent key access for the keys we read. The
  # caller still owns authorization scoping (policy_scope) and the includes it
  # needs — Filter only shapes the query it is handed.
  class Filter
    MAX_PER_PAGE = 100
    DEFAULT_PER_PAGE = 25

    # @param params [#[]] reads status, assignee ("me" or a user id), tag, from,
    #   to, q, page, per_page. Any absent key is a no-op.
    # @param current_user [User] resolves assignee == "me".
    def initialize(params, current_user:)
      @params = params
      @current_user = current_user
    end

    # status + assignee + tag + date-range, each a no-op when its key is absent.
    def filtered(scope)
      scope = by_status(scope)
      scope = by_assignee(scope)
      scope = by_tag(scope)
      by_date_range(scope)
    end

    # Full-text search preserves pg_search's rank order; otherwise newest-updated
    # first — the order a "what changed lately" list wants.
    def ordered(scope)
      if @params[:q].present?
        scope.text_search(@params[:q].to_s)
      else
        scope.order(updated_at: :desc)
      end
    end

    # The tag filter groups inside a subquery, so the scope stays ungrouped and
    # .count is the integer. A grouped scope handed in by a caller still counts
    # as its number of groups.
    def total(scope)
      counted = scope.count
      counted.is_a?(Hash) ? counted.size : counted
    end

    # Raises ListPaging::InvalidArgument for a page no list has and for a value
    # that is a list or a hash; the callers answer it as invalid input.
    def page
      ListPaging.page(@params[:page])
    end

    def per_page
      ListPaging.per_page(@params[:per_page], default: DEFAULT_PER_PAGE, max: MAX_PER_PAGE)
    end

    def paginate(scope)
      scope.limit(per_page).offset((page - 1) * per_page)
    end

    private

    def by_status(scope)
      return scope if @params[:status].blank?

      values = Array(@params[:status]).map { |s| s.to_s.downcase }
      scope.where("LOWER(custom_attributes->>'status') IN (?)", values)
    end

    def by_assignee(scope)
      return scope if @params[:assignee].blank?

      user_id = @params[:assignee].to_s == 'me' ? @current_user.id : @params[:assignee]
      scope.joins(:ticket_assignments).where(ticket_assignments: { user_id: user_id })
    end

    # AND semantics across multiple tags: the tickets that carry every tag named.
    # Grouped in a subquery, not on the outer scope: the search adds a rank column
    # to the outer query, and a GROUP BY there failed with PG::GroupingError (q plus
    # tag answered a 500).
    def by_tag(scope)
      return scope if @params[:tag].blank?

      names = Array(@params[:tag]).map { |n| n.to_s.downcase.strip }.reject(&:blank?)
      return scope if names.empty?

      tagged = Tagging.joins(:tag)
                      .where(taggable_type: 'Ticket', tags: { name: names })
                      .group(:taggable_id)
                      .having('COUNT(DISTINCT tags.id) = ?', names.size)
                      .select(:taggable_id)
      scope.where(id: tagged)
    end

    # A from/to that is no date PostgreSQL can store is ignored rather than
    # erroring. TimeSessions::DateBound checks the four-digit form before parsing:
    # Date.parse takes any year, and "999999999-01-01" answered a 500.
    def by_date_range(scope)
      from = TimeSessions::DateBound.call(value: @params[:from])
      to = TimeSessions::DateBound.call(value: @params[:to])
      scope = scope.where(tickets: { updated_at: Date.parse(from).beginning_of_day.. }) if from
      scope = scope.where(tickets: { updated_at: ..Date.parse(to).end_of_day }) if to
      scope
    end
  end
end
