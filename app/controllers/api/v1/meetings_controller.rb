# frozen_string_literal: true

module Api
  module V1
    # POST /api/v1/organisations/:organisation_id/meetings
    #
    # Under the organisation, not the project: the project may be missing, the
    # meeting then lands in the inbox. The rule is Meetings::Intake, shared with
    # the MCP tool create_meeting; the write is Actors::SaveMeeting.
    #
    # GET /api/v1/projects/:project_id/meetings and GET /api/v1/meetings/:id (REST R8)
    # read through the web list's Meetings::ListQuery and Meetings::Readable (the gate shared
    # with the MCP tool get_meeting); the
    # fields are Meetings::Serializer's.
    #
    # * Paging and `q` by Knowledge::Lookup's strict rule, one rule for REST lists of a
    #   project: no whole number from 1 to the maximum (per_page at most 100) and a NUL in
    #   `q` are a 422, an absent or empty value the default, checked before the project, so
    #   the 422 does not depend on whether it exists.
    # * The search matches inside transcripts, so it runs on the policy scope and nowhere
    #   else. A reader who may open the project but read no meetings gets an empty list.
    class MeetingsController < BaseController
      include ReadableProject

      rescue_from Knowledge::Lookup::InvalidOption, with: :invalid_input

      idempotent :create

      def index
        # Read raw, not through strong parameters: those would drop a list and let a
        # malformed request through as "no search".
        options = Knowledge::Lookup.options(%i[q page per_page].index_with { |key| params[key] }, strict: true)
        project = readable_project(params[:project_id])

        ActsAsTenant.with_tenant(project.organisation) do
          rows = Meetings::ListQuery.call(scope: policy_scope(project.meetings), search: options.query)
          total = rows.count(:all)
          render json: { data: page_of(rows, options, total).map { |meeting| Meetings::Serializer.summary(meeting) },
                         meta: { page: options.page, per_page: options.per_page, total: total } }
        end
      end

      def show
        shown = Meetings::Readable.call(id: params[:id], user: current_user, token: current_token) do |meeting|
          authorize meeting, :show?
          render json: { data: Meetings::Serializer.full(meeting, viewer: current_user) }
        end
        raise ActiveRecord::RecordNotFound unless shown
      end

      def create
        organisation = Organisation.find(params[:organisation_id])

        with_organisation_scope(organisation) do
          intake = Meetings::Intake.new(organisation: organisation, reach: current_token.reach, viewer: current_user,
                                        input: meeting_input)
          next render_refusal(intake.refusal) if intake.refusal

          with_project_scope(intake.project) do
            authorize intake.project, :show?
            authorize intake.meeting_for_policy, :create?
            answer(intake)
          end
        end
      end

      private

      # A page beyond the total reads no rows.
      def page_of(rows, options, total)
        offset = (options.page - 1) * options.per_page
        return [] if offset >= total

        rows.limit(options.per_page).offset(offset)
      end

      def invalid_input(exception)
        render_error(error: 'invalid_input', code: 'invalid_input', message: exception.message,
                     status: :unprocessable_content)
      end

      def answer(intake)
        result = intake.save
        return render json: { data: Meetings::Intake.summary(intake.meeting) }, status: :created if result.success?
        return render_error(error: 'internal_error', status: :internal_server_error) if result.code == :internal_error

        render_error(error: 'validation_failed', errors: result.errors, status: :unprocessable_entity)
      end

      # Nothing was authorized: the refusal itself is the decision, and it comes
      # before there is a record to ask a policy about.
      def render_refusal(refusal)
        skip_authorization
        case refusal.code
        when :not_found then not_found
        when :forbidden then render_error(error: 'forbidden', reason: refusal.reason, status: :forbidden)
        when :invalid_input
          render_error(error: 'validation_failed', errors: [refusal_message(refusal)], reason: refusal.reason,
                       status: :unprocessable_entity)
        else
          render_error(error: refusal.reason, message: refusal_message(refusal), status: :unprocessable_entity)
        end
      end

      def refusal_message(refusal)
        I18n.t("services.meetings.intake.#{refusal.reason}")
      end

      # The participants pass by hand: permit drops a value of the wrong shape,
      # and a meeting silently without them reads like a meeting without them.
      # Meetings::Intake refuses what is no list of objects.
      def meeting_input
        input = params.require(:meeting)
        raise ActionController::ParameterMissing, :meeting unless input.is_a?(ActionController::Parameters)

        fields = input.permit(:project_id, *Meetings::Intake::FIELDS).to_h
        fields[:participants] = participant_rows(input[:participants]) if input.key?(:participants)
        fields[:glossary_replacements] = replacement_rows(input[:glossary_replacements]) if input.key?(:glossary_replacements)
        fields
      end

      # The same for the glossary replacements (K4d): the list passes as it came,
      # each row trimmed to its three fields; Meetings::Intake checks the rest.
      def replacement_rows(raw)
        return raw unless raw.is_a?(Array)

        raw.map { |row| row.is_a?(ActionController::Parameters) ? row.permit(:heard, :term, :count).to_h : row }
      end

      def participant_rows(raw)
        return raw unless raw.is_a?(Array)

        raw.map { |row| row.is_a?(ActionController::Parameters) ? row.permit(:display_name, :ref).to_h : row }
      end
    end
  end
end
