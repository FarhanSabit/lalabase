# frozen_string_literal: true

# The person's own open hours seen through a Personal Access Token, for
# GET /api/v1/time_sessions/open: their bookings that are neither billed nor
# assigned to a billing, across the organisations of the token's reach.
#
# Reads across organisations WITHOUT a tenant, so every filter is explicit
# here and asks its usual owner, never a copy of its rule:
#
# * the token's reach, organisations AND projects (PersonalAccessToken::Reach),
#   the rule the inbox (Notifications::InboxQuery) and the REST ticket routes
#   (Api::V1::ReadableTicket) apply. Until 2026-10-08 this stopped at the
#   organisation, and a token linked to one project listed the bookings,
#   project names and tickets of every other project too;
# * the web's rule for whose hours a person sees (TimeSessions::ViewingScope,
#   the rule TimeSessionPolicy::Scope applies to every time list), so a
#   booking in a project the person was removed from, or one where they may
#   not see their own time, is no row here either;
# * TicketPolicy::Scope for the ticket of each row. A booking does not grant
#   the right to read its ticket: the row keeps its minutes and its own words,
#   and a ticket the person may not read (or the token does not reach) is
#   left out entirely, like a booking without one. Before, the API printed
#   its id, number and title.
#
# The web time lists still print such a title, without a link
# (_subject_cell.html.erb). That difference is known and has its own entry.
#
# The loop "per organisation of the reach: set the tenant, narrow to the
# reach, ask the policy" now exists in InboxQuery, Api::V1::ProjectsController,
# TicketRelation.visible_to, Api::V1::ReadableTicket and here. The rule itself
# has one owner each time; a shared helper on Reach was considered and left
# for when the next reader across organisations arrives.
#
# Entry point: call
module TimeSessions
  class OpenHours
    # rows: the page, with project preloaded.
    # total, total_minutes: over every row the page is cut from.
    # tickets: { [organisation_id, ticket_id] => { id:, number:, title: } } for the
    #   tickets of the page the person may read, keyed by the BOOKING's
    #   organisation as well: a booking that points at another organisation's
    #   ticket must not find it through a booking of that organisation on the
    #   same page. A booking whose key is missing here shows no ticket.
    Page = Struct.new(:rows, :total, :total_minutes, :tickets, keyword_init: true)

    def self.call(user:, reach:, page:, per_page:)
      new(user: user, reach: reach, page: page, per_page: per_page).call
    end

    def initialize(user:, reach:, page:, per_page:)
      @user = user
      @reach = reach
      @page = page
      @per_page = per_page
    end

    def call
      ActsAsTenant.without_tenant do
        relation = open_hours
        rows = relation.limit(@per_page).offset((@page - 1) * @per_page).includes(:project).to_a
        Page.new(rows: rows, total: relation.count, total_minutes: relation.sum(:duration),
                 tickets: readable_tickets(rows))
      end
    end

    private

    # Newest first; the id breaks ties, so bookings of the same moment cannot
    # appear on two pages or on none.
    def open_hours
      branches = organisations.map { |organisation| open_hours_in_organisation(organisation) }
      relation = branches.reduce { |acc, branch| acc.or(branch) } || TimeSession.none
      relation.unbilled.without_group.order(occurred_on: :desc, id: :desc)
    end

    # One organisation's share: own bookings, within the token's projects, as
    # far as the person sees time there. Named so the per-organisation
    # resolution of ViewingScope has a frame of its own in the Prosopite stack
    # (allow-listed there, bounded by the organisations of the token).
    def open_hours_in_organisation(organisation)
      relation = TimeSession.where(organisation_id: organisation.id, creator_id: @user.id)
      project_ids = @reach.project_ids_for(organisation.id)
      relation = relation.where(project_id: project_ids) unless project_ids.nil?
      TimeSessions::ViewingScope.for_organisation(user: @user, organisation: organisation).apply(relation)
    end

    def readable_tickets(rows)
      ticket_ids = rows.select(&:ticket_id).group_by(&:organisation_id).transform_values { |r| r.map(&:ticket_id) }
      organisations.select { |organisation| ticket_ids.key?(organisation.id) }.each_with_object({}) do |organisation, found|
        found.merge!(readable_open_hour_tickets(organisation, ticket_ids[organisation.id]))
      end
    end

    # The tickets of one organisation's rows that the person may read: the same
    # question as Tickets::ReadableForToken, asked here by hand for a reach that
    # is already at hand, and not held by its guard. Narrowed to the token's
    # projects by the TICKET's project: until 2026-09-16 a booking moved to another project kept the
    # ticket of its old one. Looked up in the booking's organisation, so a
    # booking that points at a ticket of another one (Codebase imports before
    # 2026-09-16) shows none. Only readable tickets are read from the database
    # at all. Named for Prosopite like open_hours_in_organisation.
    def readable_open_hour_tickets(organisation, ticket_ids)
      ActsAsTenant.with_tenant(organisation) do
        tickets = Ticket.where(organisation_id: organisation.id, id: ticket_ids)
        project_ids = @reach.project_ids_for(organisation.id)
        tickets = tickets.where(project_id: project_ids) unless project_ids.nil?
        Pundit.policy_scope!(@user, tickets).pluck(:id, :number, :title).to_h do |id, number, title|
          [[organisation.id, id], { id: id, number: number, title: title }]
        end
      end
    end

    def organisations
      @organisations ||= Organisation.where(id: @reach.organisation_ids).to_a
    end
  end
end
