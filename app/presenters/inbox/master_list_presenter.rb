# frozen_string_literal: true

# Encapsulates the complete display logic of the inbox master list:
# - Filters (state_filters, search, project, event_type)
# - Pagination (pagy)
# - Grouping by date (for the grouped view)
# - Empty-state logic
# - Active-filter detection
#
# Used both in Controller#index and in turbo_stream re-renders, so that the
# initial and live update take the exact same code path — date headers
# disappear automatically when the last item of a group is removed, the
# empty state appears as soon as nothing is left at all.
module Inbox
  class MasterListPresenter
    PAGE_SIZE = 50

    # The four status views the list offers, one at a time, in the order of
    # the head (user, 2026-11-10: "Alle" first and the default, "Gelesen"
    # new). Each is a set of state filters; a URL that names another set (an
    # old bookmark with "unread" and "archived", say) shows its rows and marks
    # no view as active, and its empty list says so (empty_reason
    # :other_filter).
    STATUS_VIEWS = {
      'all' => %w[read unread],
      'unread' => %w[unread],
      'read' => %w[read],
      'archived' => %w[archived]
    }.freeze

    # The headings of the grouped view, newest first: a row stands under the
    # period of its newest notification.
    PERIODS = %i[today yesterday this_week older].freeze

    # What narrows the rows beyond the status view.
    NARROWING = %i[search project_id event_type].freeze

    # The status view a set of state filters names, or nil. No filter at all
    # is the default list (unread and read), so it is "all" as well.
    def self.status_view(state_filters)
      filters = Array(state_filters).compact_blank.uniq.sort
      return 'all' if filters.empty?

      STATUS_VIEWS.find { |_key, set| set.sort == filters }&.first
    end

    # The pagy helper needs a class instance that understands `params` and the
    # `pagy_*` helpers — the controller passes itself. time_zone: the zone the
    # reader's days run in (User#time_zone), for the period headings.
    def initialize(pagy_helper:, scope:, params:, time_zone: Time.zone)
      @pagy_helper = pagy_helper
      @scope = scope
      @params = params
      @time_zone = time_zone
      compute!
    end

    attr_reader :pagy, :notifications, :grouped_notifications, :view_mode,
                :total_count, :active_state_filters

    def grouped?
      view_mode == 'grouped'
    end

    # Number of notifications that belong to the same notifiable (ticket) as
    # the passed one — basis for the "N updates" badge. Minimum 1.
    def group_total(notification)
      @group_total.fetch([notification.notifiable_type, notification.notifiable_id], 1)
    end

    # Of those, the unread ones — controls the unread styling of the bundled row:
    # the row counts as unread as long as ANY of its notifications is unread
    # (not just the displayed representative).
    def group_unread(notification)
      @group_unread.fetch([notification.notifiable_type, notification.notifiable_id], 0)
    end

    delegate :empty?, to: :notifications

    def status_view
      self.class.status_view(active_state_filters)
    end

    # A search, a project or a type narrows the rows beyond the status view.
    def narrowed?
      NARROWING.any? { |key| @params[key].present? }
    end

    # The list state as query parameters, for the links of a list a stream
    # redraws: the request it answers is an action, so the links cannot read
    # their filters from its address. Search and project included, or the
    # first click in a redrawn list would drop both from the address.
    def query_context
      context = {}
      context[:state_filters] = active_state_filters if active_state_filters.any?
      context[:view_mode] = view_mode unless grouped?
      NARROWING.each { |key| context[key] = @params[key] if @params[key].present? }
      context
    end

    # Why the list is empty, for the sentence it shows: a narrowed list found
    # nothing, an empty unread view means everything is read (a good state,
    # not an error), the archive and the whole list simply hold nothing yet.
    # A set of states that is none of the three views (an old address) is no
    # empty inbox: its sentence leads to the view that shows everything.
    def empty_reason
      return :no_match if narrowed?

      case status_view
      when 'unread' then :all_read
      when 'read' then :nothing_read
      when 'archived' then :nothing_archived
      when 'all' then :nothing_yet
      else :other_filter
      end
    end

    private

    def compute!
      @active_state_filters = derive_active_state_filters
      @filtered = apply_state_filters(@scope)
      @view_mode = (@params[:view_mode].presence || 'grouped').to_s
      @total_count = @filtered.count
      @group_total = {}
      @group_unread = {}

      # Pagy 9: page size via :limit. NOT :items — that is not a Pagy 9
      # variable at all and would silently yield the default. It is not the URL
      # parameter name either, whatever this comment used to claim: the limit
      # extra sets that to :limit. See the closing note in
      # config/initializers/pagy.rb.
      if grouped?
        compute_grouped!
      else
        @notifications = @filtered.for_notification_center.recent
        @pagy, @notifications = @pagy_helper.send(:pagy, @notifications, limit: PAGE_SIZE)
      end
    end

    # Grouping = bundling per notifiable (ticket): ONE row per ticket,
    # represented by the NEWEST notification. Pagination runs at the ticket
    # level (PAGE_SIZE tickets/page), not at the notification level.
    # The rows are grouped by the date of their representative →
    # a ticket appears globally only ONCE, under the day of its last
    # activity. group_total/group_unread provide the bundle counts.
    def compute_grouped!
      # DISTINCT ON: one representative (newest) per notifiable. The subquery
      # returns only the IDs; ORDER BY must lead with the DISTINCT columns.
      rep_ids = @filtered.reorder(nil)
                         .select('DISTINCT ON (notifications.notifiable_type, notifications.notifiable_id) notifications.id')
                         .order(Arel.sql('notifications.notifiable_type, notifications.notifiable_id, notifications.created_at DESC'))

      rep_scope = Notification.where(id: rep_ids)
                              .for_notification_center
                              .order(created_at: :desc)

      @pagy, reps = @pagy_helper.send(:pagy, rep_scope, limit: PAGE_SIZE)

      # Counts over the ENTIRE filtered scope (not just this page), so that
      # the badge shows the real total count per ticket.
      @group_total = count_by_notifiable(@filtered)
      @group_unread = count_by_notifiable(@filtered.unread)

      @grouped_notifications = group_by_period(reps)
      @notifications = reps
    end

    # { period => representatives } in PERIODS order, empty periods left out.
    # "This week" starts on the week's Monday; yesterday counts as yesterday
    # even when it was in the previous week. The days are the reader's: in
    # the app zone (UTC) the hour after a Berlin midnight still belongs to the
    # day before, and all of that day would read "Heute".
    def group_by_period(reps)
      today = Time.current.in_time_zone(@time_zone).to_date
      grouped = reps.group_by do |notification|
        date = notification.created_at.in_time_zone(@time_zone).to_date
        if date >= today then :today
        elsif date == today - 1 then :yesterday
        elsif date >= today.beginning_of_week then :this_week
        else :older
        end
      end
      PERIODS.filter_map { |period| [period, grouped[period]] if grouped[period] }.to_h
    end

    def derive_active_state_filters
      arr = Array(@params[:state_filters]).reject(&:blank?)
      arr << @params[:state] if arr.empty? && @params[:state].present?
      arr.uniq
    end

    def apply_state_filters(scope)
      if active_state_filters.any?
        allowed = []
        allowed += %w[queued sent delivered] if active_state_filters.include?('unread')
        allowed << 'read'     if active_state_filters.include?('read')
        allowed << 'archived' if active_state_filters.include?('archived')
        scope.where(state: allowed)
      else
        scope.where.not(state: Notification.states[:archived])
      end
    end

    # { [notifiable_type, notifiable_id] => count } over the scope.
    # reorder(nil) removes any ORDER BY columns that would otherwise have to go
    # into the GROUP BY clause (Postgres error).
    def count_by_notifiable(scope)
      scope.reorder(nil).group(:notifiable_type, :notifiable_id).count
    end
  end
end
