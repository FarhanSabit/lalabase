# frozen_string_literal: true

module Lalabase
  module Tools
    # Creates a ticket in the scoped project through Actors::SaveTicket — the same
    # write seam the HTTP API and web UI use, so assignee sync, activity tracking
    # and embeddings all run correctly (never a raw create!). Returns the new
    # ticket summary (with id + number) as JSON.
    #
    # Mutating (D3): a read-only PAT can't reach it. Record-mode (D7): it MUST
    # authorize :create? on the project before writing, or the tripwire fires.
    class CreateTicket < Base
      # Writes on behalf of context.actor. No chat set may ever carry a mutating
      # tool, so the Runner's bar can never fire here — the declaration is kept
      # truthful anyway, so the registry guard stays a derived rule rather than a
      # hand-kept exception list.
      def self.requires_actor?
        true
      end

      def self.mutating?
        true
      end

      def self.authorization_mode
        :record
      end

      def self.tool_name
        'create_ticket'
      end

      def self.description
        "Creates a ticket in the project. Requires a title (one line, at most #{Ticket::TITLE_MAX_LENGTH} characters); optional " \
          'description (rich body), ticket_type (default "support"), summary and ' \
          'status. Returns the created ticket summary including its id and number.'
      end

      def self.input_schema
        {
          type: 'object',
          properties: {
            title: { type: 'string', description: "Ticket title (required), one line, at most #{Ticket::TITLE_MAX_LENGTH} characters." },
            description: { type: 'string', description: 'Ticket body / description.' },
            ticket_type: { type: 'string', description: 'Ticket type, defaults to "support".' },
            summary: { type: 'string', description: 'Short one-line summary.' },
            status: { type: 'string', description: 'Initial status value, e.g. "open".' }
          },
          required: ['title']
        }
      end

      def self.execute(args:, context:)
        return Result.new(error: 'project context missing') if context.project.nil?

        args = symbolized(args)
        # The title rule update_ticket checks as well (TicketTitle): a ticket is
        # never created with a title it could not be renamed to.
        title = TicketTitle.check(args[:title].nil? ? '' : args[:title])
        return title if title.is_a?(Result)

        authorize!(context, context.project.tickets.build, :create?)

        result = Actors::SaveTicket.call(
          project: context.project,
          params: build_params(args, title),
          current_user: context.actor
        )
        return Result.new(error: create_failure(result)) unless result.success?

        serializer = Tickets::Serializer.new(current_user: context.actor)
        json_result(serializer.summary(result.resource))
      end

      def self.build_params(args, title)
        params = {
          title: title,
          ticket_type: args[:ticket_type].to_s.strip.presence || 'support'
        }
        params[:summary] = args[:summary].to_s if args[:summary].present?
        params[:content] = args[:description].to_s if args[:description].present?
        params[:custom_attributes] = { 'status' => args[:status].to_s } if args[:status].present?
        params
      end
      private_class_method :build_params

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
