# frozen_string_literal: true

module Lalabase
  module Tools
    # Creates a meeting by the rule POST /api/v1/organisations/:id/meetings writes
    # by (Meetings::Intake, Actors::SaveMeeting). Token-scoped: the project may be
    # missing, the meeting then lands in the organisation's inbox, so there is no
    # project for the seam to gate and this tool sets the tenant itself. A flat
    # name of its own class, like McpFindPeople; only in the :mcp set, a write.
    class CreateMeeting < Base
      ORGANISATION_NOT_REACHABLE = 'organisation not found or not reachable with this token'

      def self.requires_actor?
        true
      end

      def self.mutating?
        true
      end

      def self.scope_mode
        :token
      end

      def self.authorization_mode
        :record
      end

      def self.tool_name
        'create_meeting'
      end

      def self.description
        'Creates a meeting with its transcript. Without project_id it lands in the inbox project of the ' \
          'organisation. Write the transcript as lines of "Name: text", the names as in participants; a ' \
          'participant may carry ref, the id from find_people. Returns the meeting without the transcript.'
      end

      def self.input_schema
        {
          type: 'object',
          properties: {
            organisation_id: { type: 'string', description: 'UUID of the organisation (list_organisations names them).' },
            project_id: { type: 'string', description: 'Optional. UUID of the project; without it the inbox project.' },
            title: { type: 'string', description: 'Meeting title (required).' },
            occurred_at: { type: 'string', description: 'When it took place, ISO 8601 (required).' },
            duration_minutes: { type: 'integer', description: 'Length in minutes.' },
            notes: { type: 'string', description: 'Notes.' },
            transcript: { type: 'string', description: 'Transcript, lines of "Name: text".' },
            participants: {
              type: 'array',
              description: 'Who took part.',
              items: {
                type: 'object',
                properties: {
                  display_name: { type: 'string', description: 'Name as in the transcript.' },
                  ref: { type: 'string', description: 'Optional. The id from find_people (person:<uuid>, member:<uuid>).' }
                },
                required: ['display_name']
              }
            }
          },
          required: %w[organisation_id title occurred_at]
        }
      end

      def self.execute(args:, context:)
        return Result.new(error: 'token context missing') unless token_wide?(context)

        args = symbolized(args)
        organisation = reachable_organisation(args[:organisation_id], context)
        return organisation if organisation.is_a?(Result)

        ActsAsTenant.with_tenant(organisation) { create(organisation, args, context) }
      end

      def self.reachable_organisation(raw, context)
        id = raw.to_s.strip
        return Result.invalid_input("invalid organisation_id #{raw.inspect} (expected a UUID)") unless Lalabase::Uuid.valid?(id)

        organisation = Organisation.find_by(id: id)
        return organisation if organisation && context.reach.organisation?(organisation.id)

        Result.new(error: ORGANISATION_NOT_REACHABLE, code: :not_found)
      end
      private_class_method :reachable_organisation

      def self.create(organisation, args, context)
        intake = Meetings::Intake.new(organisation: organisation, reach: context.reach, viewer: context.actor,
                                      input: args.except(:organisation_id))
        return refused(intake.refusal, context) if intake.refusal

        authorize!(context, intake.meeting_for_policy, :create?)

        result = intake.save
        return Result.new(error: create_failure(result)) unless result.success?

        Result.new(content: Meetings::Intake.summary(intake.meeting).to_json)
      end
      private_class_method :create

      # The refusal is the decision here, as in the REST controller; the policy has
      # no record to ask about yet.
      def self.refused(refusal, context)
        context.authorization&.record!
        message = I18n.t("services.meetings.intake.#{refusal.reason}")
        Result.new(error: message, code: refusal.code, reason: refusal.reason)
      end
      private_class_method :refused

      # An unexpected failure (BaseActor's :internal_error where it does not
      # re-raise, i.e. in production) gets a fixed text: its message may name the
      # database. A refused save keeps its messages, as post_comment does.
      def self.create_failure(result)
        return 'create failed: unexpected error' if result.code == :internal_error

        "create failed: #{Array(result.errors).join(', ')}"
      end
      private_class_method :create_failure
    end
  end
end
