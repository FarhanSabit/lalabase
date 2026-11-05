# frozen_string_literal: true

module Lalabase
  module Tools
    # Lists tickets in the scoped project as JSON (summaries + pagination meta).
    # Filtering/ordering/pagination is delegated to Tickets::Filter and the JSON
    # shape to Tickets::Serializer — the SAME objects GET /api/v1/projects/:id/tickets
    # uses, so the MCP and HTTP surfaces cannot drift (D4). Project-mode (D7): the
    # PAT project-scope check authorizes the call, and Pundit.policy_scope! narrows
    # the rows to what the user may read — no ticket-read access simply yields an
    # empty list, never another project's data.
    class ListTickets < Base
      # A handful of citations is enough for the rights gate (it needs ONE row carrying
      # area 'tickets') and keeps a counting answer readable: citing a full page would
      # hang up to per_page source chips under a one-number answer, and they accumulate
      # across tool rounds.
      MAX_CITATIONS = 5

      # Reads context.actor for its Pundit scoping — declared so the Runner's
      # fail-closed bar refuses the call when no user is in the context.
      def self.requires_actor?
        true
      end

      def self.tool_name
        'list_tickets'
      end

      def self.description
        'Lists tickets in the project as JSON, newest first. Optional filters: ' \
          'status, assignee (a user UUID or "me"), tag, and q (full-text search ' \
          'over title/body). Supports page + per_page. Returns ticket summaries ' \
          'carrying both the id and the number (the "#187" users say) of each ' \
          'ticket; get_ticket takes either one. ' \
          'status_functions says what the status means in its project (is_backlog, is_new, ' \
          'is_open, is_in_progress, is_completed, is_closed), [] when the project gave it none. ' \
          'Scoped to what the authenticated user may read.'
      end

      def self.input_schema
        {
          type: 'object',
          properties: {
            status: { type: 'string',
                      description: 'Filter by status value. Status is configured PER PROJECT, ' \
                                   'not a fixed vocabulary: use one of the values listed in ' \
                                   'meta.available_statuses of an unfiltered call. Guessing a ' \
                                   'value like "open" against a project that names it ' \
                                   '"offen" returns an exact count of zero.' },
            assignee: { type: 'string', description: 'User UUID, or "me" for the token owner.' },
            tag: { type: 'string', description: 'Filter by tag name.' },
            q: { type: 'string', description: 'Full-text search over title/body.' },
            page: { type: 'integer', description: 'Page number, 1-based.' },
            per_page: { type: 'integer', description: "Items per page (max #{Tickets::Filter::MAX_PER_PAGE})." }
          }.merge(PROJECT_FILTER_SCHEMA),
          required: []
        }
      end

      def self.execute(args:, context:)
        return Result.new(error: 'project context missing') if context.project.nil? && context.scope.nil?

        args = symbolized(args)
        # The HTTP API never sees this guard because Rails coerces a bad assignee
        # to a string before the query; over MCP a hallucinated non-UUID would hit
        # the uuid column and raise PG::InvalidTextRepresentation, so we reject it.
        return Result.invalid_input('invalid assignee (expected a user UUID or "me")') if invalid_assignee?(args)

        # S3a T5: resolved BEFORE the query, so an ambiguous name answers with
        # candidates instead of a confidently wrong number.
        chosen = resolve_project_filter(args, context, area: :tickets)
        return chosen if chosen.is_a?(Result)

        filter = Tickets::Filter.new(args, current_user: context.actor)
        paging = paging_refusal(filter)
        return paging if paging

        base = Pundit.policy_scope!(context.actor, ticket_base(context, only_project_id: chosen&.id))
        scope = filter.ordered(filter.filtered(base)).includes(:creator, :assignees)
        # The org rows name their project (§14 origin), so preload it there.
        scope = scope.includes(:project) if org_wide?(context)
        # A page past the end returns zero rows next to a non-zero total. That is not just
        # a confusing answer: with no rows there is nothing to cite, so the answer would
        # carry no area and the number — the whole point of this tool — would reach every
        # reader of the shared chat ungated. Clamped HERE, not in Tickets::Filter, because
        # the HTTP API shares that object and its paging contract.
        filter = Tickets::Filter.new(args.merge(page: clamped_page(filter, scope)), current_user: context.actor)

        serializer = Tickets::Serializer.new(current_user: context.actor)
        page = filter.paginate(scope)
        serializer.preload_status_functions(page.map(&:project_id))
        coverage = coverage_for(context, area: :tickets, only_project: chosen)
        json_result(
          {
            data: page.map { |t| row(t, serializer, context) },
            meta: meta_for(filter, scope, context, coverage)
          },
          # Every returned row is cited, so the answer carries area 'tickets' and the
          # rights gate on the shared chat applies to a READER too, not just the asker
          # (Chatpost#gated_streaming?, MessageComponent#redacted?). Without this the
          # tool would be a way around the gate the content retrieval already respects.
          citations: page.first(MAX_CITATIONS).map { |t| Lalabase::Citations.ticket(t) },
          coverage: coverage
        )
      end

      # Row scope of the call: ONE project's tickets, or (S3a T3) the tickets of
      # every project the asker may read within the org scope. The org branch is
      # explicitly organisation-bound — tools never lean on the ambient tenant
      # (Context contract).
      def self.ticket_base(context, only_project_id: nil)
        return context.project.tickets if context.project

        # only_project_id (T5) is already one of the scope's ids -- ProjectResolver
        # draws its candidates FROM the scope -- so this narrows inside the rights
        # rather than stepping around them.
        ids = only_project_id ? [only_project_id] : context.scope.project_ids(area: :tickets)
        Ticket.where(organisation_id: context.organisation.id, project_id: ids)
      end
      private_class_method :ticket_base

      # Org-wide rows carry their project so the model can name the origin (§14).
      # The single-project payload stays byte-identical (MCP wire format, D4).
      def self.row(ticket, serializer, context)
        summary = serializer.summary(ticket)
        return summary unless org_wide?(context)

        summary.merge(project: { id: ticket.project_id, name: ticket.project&.name })
      end
      private_class_method :row

      # Status is a per-project select attribute (JSONB), never a fixed enum. Without
      # the vocabulary the model guesses an English value, gets zero rows and reports
      # "0 open tickets" as an exact, database-backed count — the estimate this tool
      # replaced, in a more convincing shape. Org-wide: the union over the reachable
      # projects' vocabularies, and only theirs (§12-S3a).
      def self.meta_for(filter, scope, context, coverage)
        meta = {
          page: filter.page, per_page: filter.per_page, total: filter.total(scope),
          available_statuses: available_statuses(context)
        }
        meta[:coverage] = coverage if coverage
        meta
      end
      private_class_method :meta_for

      def self.available_statuses(context)
        return TicketAttributeDefinition.ordered_value_keys_for(context.project, 'status') if context.project

        TicketAttributeDefinition.active
                                 .where(project_id: context.scope.project_ids(area: :tickets),
                                        name: 'status', field_type: 'select')
                                 .flat_map(&:ordered_value_keys).uniq
      end
      private_class_method :available_statuses

      # The requested page, clamped into the range that actually has rows. An empty result
      # set keeps the requested page (there is no last page to fall back to, and total 0
      # carries nothing to leak).
      # A page no list has, or a page or per_page that is a list or a hash: the
      # assistant passes the model's arguments in unchecked, and the MCP SDK checks
      # the type but not the size. Asked once here, before any query.
      def self.paging_refusal(filter)
        filter.page
        filter.per_page
        nil
      rescue ListPaging::InvalidArgument => e
        Result.invalid_input(e.message)
      end
      private_class_method :paging_refusal

      def self.clamped_page(filter, scope)
        total = filter.total(scope)
        return filter.page if total.zero?

        [filter.page, (total.to_f / filter.per_page).ceil].min
      end
      private_class_method :clamped_page

      def self.invalid_assignee?(args)
        value = args[:assignee].to_s
        return false if value.blank? || value == 'me'

        !value.match?(UUID_FORMAT)
      end
      private_class_method :invalid_assignee?
    end
  end
end
