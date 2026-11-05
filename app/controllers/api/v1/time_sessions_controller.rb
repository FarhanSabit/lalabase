# frozen_string_literal: true

module Api
  module V1
    class TimeSessionsController < BaseController
      include Api::V1::ReadableTicket

      idempotent :create

      # Deliberate opt-out for #open: it reads across organisations without a
      # tenant, so there is no single record to authorize. What it shows is
      # decided in TimeSessions::OpenHours: own bookings (creator_id), the
      # token's reach (organisations AND projects, PersonalAccessToken#reach),
      # the web's time-viewing rule (TimeSessions::ViewingScope) and, for each
      # row's ticket, TicketPolicy::Scope. All other actions remain
      # Pundit-required.
      skip_after_action :verify_authorized, only: :open

      MAX_PER_PAGE = 100
      DEFAULT_PER_PAGE = 25

      # GET /api/v1/tickets/:ticket_id/time_sessions
      def index
        with_readable_ticket(params[:ticket_id]) do |ticket|
          # Controller helper instead of Pundit.policy_scope: identical scope class,
          # but only the helper sets the tripwire's verify_policy_scoped flag.
          relation = policy_scope(ticket.time_sessions)
                     .includes(:creator)
                     .order(occurred_on: :desc)
          paged, total = paginate(relation)

          render json: {
            data: paged.map { |s| TimeSessions::Serializer.row(s) },
            meta: pagination_meta(total)
          }
        end
      end

      # GET /api/v1/time_sessions/open
      # Returns the current user's "open hours": not yet billed AND not yet
      # assigned to any TimeSessionGroup, across the token's reach. A booking on
      # a ticket the user may not read keeps its row, with ticket null.
      def open
        hours = TimeSessions::OpenHours.call(user: current_user, reach: current_token.reach,
                                             page: page_param, per_page: per_page_param)

        render json: {
          data: hours.rows.map { |s| serialize_open(s, hours.tickets) },
          meta: {
            page: page_param,
            per_page: per_page_param,
            total: hours.total,
            total_minutes: hours.total_minutes,
            total_hours_decimal: (hours.total_minutes / 60.0).round(2)
          }
        }
      end

      # POST /api/v1/tickets/:ticket_id/time_sessions
      # Books by the rule the MCP tool create_time_session books by
      # (TimeSessions::Booking): the day in the token owner's zone, one duration,
      # the write through Actors::SaveTimeSession. The input is checked inside
      # the read gate, so a refusal of it only ever answers for a ticket the
      # token can read and tells nothing the 404 does not.
      def create
        with_readable_ticket(params[:ticket_id]) do |ticket, _project|
          booking = TimeSessions::Booking.parse(actor: current_user, **session_params)
          next render_booking_refusal(booking.refusal) if booking.refused?

          session = booking.build(ticket: ticket)
          authorize session, :create?

          result = booking.save(session)
          if result.success?
            render json: { data: TimeSessions::Serializer.row(result.resource) }, status: :created
          else
            render_booking_failure(result)
          end
        end
      end

      private

      def render_booking_refusal(refusal)
        render_error(error: 'validation_failed', errors: [I18n.t("services.time_session_booking.#{refusal}")],
                     status: :unprocessable_entity)
      end

      # A failure the actor did not expect (BaseActor answers :internal_error
      # where it does not re-raise) is no refusal of the input: a 500 without the
      # exception's text, which may name the database.
      def render_booking_failure(result)
        if result.code == :internal_error
          render_error(error: 'internal_error', status: :internal_server_error)
        else
          render_error(error: result.code, errors: result.errors, status: :unprocessable_entity)
        end
      end

      def session_params
        input = params.require(:time_session)
        # require hands back a string or a list unchanged, and permit on it raised
        # NoMethodError into a 500. The same guard as MeetingsController#meeting_input.
        raise ActionController::ParameterMissing, :time_session unless input.is_a?(ActionController::Parameters)

        permitted = input.permit(
          :occurred_on, :duration_minutes, :duration_string,
          :description, :customer_description
        )
        # Booking must see supplied arrays/objects too: scalar permit drops them,
        # turning an invalid date into today or hiding a second duration. Only
        # these three explicit inputs bypass filtering; Booking validates them.
        permitted.to_h.symbolize_keys.merge(
          occurred_on: input[:occurred_on], duration_minutes: input[:duration_minutes],
          duration_string: input[:duration_string]
        )
      end

      def paginate(relation)
        total = relation.count
        page = page_param
        per = per_page_param
        [relation.limit(per).offset((page - 1) * per).to_a, total]
      end

      def pagination_meta(total)
        { page: page_param, per_page: per_page_param, total: total }
      end

      # ListPaging::InvalidArgument (a page no list has, a list or a hash) answers
      # 400 through BaseController.
      def page_param
        ListPaging.page(params[:page])
      end

      def per_page_param
        ListPaging.per_page(params[:per_page], default: DEFAULT_PER_PAGE, max: MAX_PER_PAGE)
      end

      # Serializer for the open-hours view: includes project + ticket inline,
      # so that Claude does not have to fetch them separately. `tickets` holds
      # only the tickets the user may read (TimeSessions::OpenHours); any other
      # ticket, a missing one or one of another organisation shows as null.
      def serialize_open(session, tickets)
        {
          id: session.id,
          occurred_on: session.occurred_on&.iso8601,
          duration_minutes: session.duration,
          duration_hours_decimal: (session.duration / 60.0).round(2),
          description: session.description,
          customer_description: session.customer_description,
          project: build_project_payload(session),
          ticket: session.ticket_id && tickets[[session.organisation_id, session.ticket_id]],
          created_at: session.created_at.iso8601
        }
      end

      def build_project_payload(session)
        project = session.project
        # Like the ticket: a project of another organisation (broken data) is none.
        return nil unless project && project.organisation_id == session.organisation_id

        { id: project.id, name: project.name }
      end
    end
  end
end
