# frozen_string_literal: true

module Lalabase
  module Tools
    # Sums the booked time of the scoped project by billing bucket, as JSON. The
    # first REPORT tool (doc/persoenlicher_assistent_plan.md, S2): it returns
    # numbers, never rows, so "how many hours are not invoiced yet" gets a counted
    # answer from the database instead of an estimate.
    #
    # Rights, and why this tool checks them itself (§6.4, §13-9): the area gate for
    # :time_sessions answers `can_view_own || can_view_all` and cannot tell a user
    # who may see only their own hours from one who may see everyone's. A sum over
    # ALL sessions handed to a can_view_own user would pass that gate. So the tool
    # narrows through TimeSessions::ViewingScope BEFORE it counts, reports the tier
    # (`scope`) so the model can say "your own hours", and refuses a user with no
    # persisted permission row. The area is still set on the citation (below); it
    # is what makes the answer content-bearing for the rights gate.
    #
    # Filters go through TimeSessionFilterService, the same object the time list
    # uses, so a number here is the number the same filters show in the UI. Dates
    # are validated HERE because that service swallows a malformed date silently,
    # which would return a project-wide sum wearing a period label.
    class SummarizeTimeSessions < Base
      CREATOR_ME = 'me'
      MINUTES_PER_HOUR = 60.0

      # Narrows through TimeSessions::ViewingScope and resolves "me" against
      # context.actor — declared so the Runner's fail-closed bar refuses the call
      # when no user is in the context.
      def self.requires_actor?
        true
      end

      def self.tool_name
        'summarize_time_sessions'
      end

      def self.description
        'Sums the booked time of the project by billing state, from the database. ' \
          'Returns minutes, hours and session counts for three buckets: billed ' \
          '(invoice number recorded), in_billing (assigned to an open billing, not ' \
          'invoiced yet), without_billing (not assigned to any billing); plus total ' \
          'and not_invoiced (= in_billing + without_billing). Optional filters: ' \
          'start_date / end_date (YYYY-MM-DD, inclusive), creator ("me" or a user ' \
          'UUID), ticket (UUID or the "#187" number). The scope field says whether ' \
          'the numbers cover ALL sessions of the project or only the asking ' \
          'user\'s OWN ("own"); when it is "own", say so in the answer. Returns no ' \
          'individual sessions. In an org-wide assistant thread the sums span ' \
          'every project whose time the user may see, each narrowed to its own ' \
          'permission tier; scope is then "all", "own" or "mixed", and coverage ' \
          'says how many of the organisation\'s projects the numbers cover - ' \
          'state both in the answer.'
      end

      def self.input_schema
        {
          type: 'object',
          properties: {
            start_date: { type: 'string', description: 'First day to include, YYYY-MM-DD.' },
            end_date: { type: 'string', description: 'Last day to include, YYYY-MM-DD (inclusive).' },
            creator: { type: 'string', description: 'Only sessions booked by this user: "me" or a user UUID.' },
            ticket: { type: 'string',
                      description: 'Only sessions booked on this ticket: its UUID or the number shown ' \
                                   'in the app, e.g. "187" or "#187".' }
          }.merge(PROJECT_FILTER_SCHEMA),
          required: []
        }
      end

      def self.execute(args:, context:)
        return org_execute(args, context) if org_wide?(context)
        return Result.new(error: 'project context missing') if context.project.nil?

        viewing = TimeSessions::ViewingScope.call(user: context.actor, project: context.project)
        # Fail-closed, and consistent with the area gate: no persisted permission row
        # means no numbers and no citation, not a sum of zero.
        return Result.new(error: 'no access to the time sessions of this project') if viewing.none?

        args = symbolized(args)
        filters = resolve_filters(args, context)
        return filters if filters.is_a?(Result)

        base = viewing.apply(context.project.time_sessions)
        scope = filtered_sessions(base, context.project, filters)

        buckets = bucket_totals(scope)
        json_result(
          {
            scope: viewing.tier.to_s,
            filters: filters,
            buckets: buckets,
            not_invoiced: sum_of(buckets.values_at('in_billing', 'without_billing')),
            total: sum_of(buckets.values)
          },
          # The one citation that makes the answer content-bearing: its area is what
          # Chatpost#gated_streaming? and MessageComponent#redacted? gate on. Without
          # it a number-only answer would count as content-free (PR #534).
          citations: [Lalabase::Citations.time_report(context.project, citation_filters(filters))]
        )
      end

      # S3a T3 (Plan §9.1): the org-wide sum. Each project is narrowed through
      # its OWN ViewingScope tier before counting (§13-9) — "all" in one project
      # never widens "own" in another, and a project with no persisted permission
      # row contributes nothing (fail-closed, §12-S3a). Coverage counts the
      # projects with any tier against all projects of the organisation (L7).
      def self.org_execute(args, context)
        args = symbolized(args)
        # The reach comes FIRST here, unlike in the ticket tools. This tool's
        # reach is not a per-area gate -- ProjectPermission has no
        # `time_sessions` area, the all/own/none rule lives in
        # TimeSessions::ViewingScope (§2.4) -- so the filter has to resolve
        # against the projects this pass actually found, not against an area
        # query that would raise.
        viewing = TimeSessions::ViewingScope.for_organisation(user: context.actor, organisation: context.organisation)
        candidates = reachable_projects(context, viewing)
        if candidates.empty?
          return Result.new(error: 'no access to the time sessions of any project',
                            coverage: context.scope.coverage_with(searched: 0))
        end

        # S3a T5: resolved before the sum -- an ambiguous project name must answer
        # with candidates, not with a sum over the wrong set of projects.
        chosen = resolve_project_filter(args, context,
                                        candidates: Project.where(id: candidates.map { |project, _t| project.id }))
        return chosen if chosen.is_a?(Result)

        reachable = chosen ? candidates.select { |project, _t| project.id == chosen.id } : candidates
        # Named, not counted, when the question itself named the project (T5
        # review) -- same rule as the chip, same sentence under the answer.
        coverage = context.scope.coverage_with(searched: reachable.size, chosen: chosen&.name)

        filters = resolve_filters(args, context, time_project_ids: reachable.map { |project, _t| project.id })
        if filters.is_a?(Result)
          # Candidate lists and refused filters wear the reach too (see GetTicket).
          filters.coverage ||= coverage
          return filters
        end

        buckets = bucket_totals(org_sessions(reachable, viewing, context, filters))
        json_result(
          {
            scope: combined_tier(reachable),
            filters: filters,
            buckets: buckets,
            not_invoiced: sum_of(buckets.values_at('in_billing', 'without_billing')),
            total: sum_of(buckets.values),
            coverage: coverage
          },
          # One citation per included project: the area keeps the answer
          # content-bearing, and the per-project chips are the §14 origin trail.
          citations: reachable.map { |project, _t| Lalabase::Citations.time_report(project, citation_filters(filters)) },
          coverage: coverage
        )
      end
      private_class_method :org_execute

      # The projects whose time the asker may see AT ALL, each paired with its
      # tier. The tiers come from ONE read of the permission rows
      # (ViewingScope.for_organisation, the same owner of the all/own/none rule
      # as .call): asking .call per project cost three queries per project
      # (API review 2026-11-05). The area gate cannot tell own from all (§2.4).
      # Unnarrowed on purpose: the T5 project filter resolves AGAINST this list
      # (org_execute above), so this pass is what defines the reach the filter may
      # pick from, and narrowing here would be the wrong order.
      def self.reachable_projects(context, viewing)
        context.scope.projects.order(:created_at).filter_map do |project|
          tier = viewing.tier_for(project.id)
          [project, tier] unless tier == :none
        end
      end
      private_class_method :reachable_projects

      # What the org-wide numbers cover: one tier when every project agrees,
      # otherwise 'mixed' — the model states it either way (description).
      def self.combined_tier(reachable)
        tiers = reachable.map { |_p, tier| tier }.uniq
        tiers.one? ? tiers.first.to_s : 'mixed'
      end
      private_class_method :combined_tier

      # The sessions of every reached project in ONE relation, narrowed by the
      # same ViewingScope that gave the tiers, so "all" in one project never
      # widens "own" in another (§13-9). Bounded to the reached projects first:
      # its #apply expects an organisation's relation and covers every project
      # with a tier, not only those the token and the project filter reach.
      # Summed in one query instead of one per project. No `project:` for the
      # filter service: it reads it only to skip a project filter not passed here.
      def self.org_sessions(reachable, viewing, context, filters)
        reached = TimeSession.where(organisation_id: context.organisation.id,
                                    project_id: reachable.map { |project, _t| project.id })
        filtered_sessions(viewing.apply(reached), nil, filters)
      end
      private_class_method :org_sessions

      # Same filter object the time list uses (see class comment), so a number
      # here is the number the same filters show in the UI (one project, or the
      # organisation's list).
      def self.filtered_sessions(base, project, filters)
        TimeSessionFilterService.new(
          base_query: base, project: project,
          start_date: filters[:start_date], end_date: filters[:end_date],
          creator_id: filters[:creator_id], ticket_id: filters.dig(:ticket, :id)
        ).call
      end
      private_class_method :filtered_sessions

      # The applied filters, echoed back so the model states what the numbers cover.
      # Returns a Result on a refused argument. `time_project_ids` (org path only)
      # bounds the ticket filter to the projects whose time the asker may see.
      def self.resolve_filters(args, context, time_project_ids: nil)
        filters = {}
        %i[start_date end_date].each do |key|
          value = args[key].to_s.strip
          next if value.empty?
          return Result.new(error: "invalid #{key} (expected YYYY-MM-DD)") unless valid_date?(value)

          filters[key] = value
        end

        creator_id = resolve_creator(args[:creator], context)
        return creator_id if creator_id.is_a?(Result)

        filters[:creator_id] = creator_id if creator_id

        ticket = resolve_ticket(args[:ticket], context, time_project_ids)
        return ticket if ticket.is_a?(Result)

        filters[:ticket] = { id: ticket.id, number: ticket.number, title: ticket.title } if ticket
        filters
      end
      private_class_method :resolve_filters

      # Form first, then the calendar: the form rejects "31.08.2026", the calendar
      # rejects "2026-13-40", and four digits keep the year inside what Postgres
      # stores. Since S3c T3 that rule has ONE owner (TimeSessions::DateBound) --
      # it was written by hand here and copied into the assistant's report panel,
      # where the form half went missing and a crafted address answered with a 500.
      def self.valid_date?(value)
        TimeSessions::DateBound.valid?(value: value)
      end
      private_class_method :valid_date?

      # "me" is the asker; anything else must be a UUID. A foreign UUID under an :own
      # tier simply sums to zero — the narrowing above runs first and never widens.
      def self.resolve_creator(raw, context)
        value = raw.to_s.strip
        return nil if value.empty?
        return context.actor.id if value == CREATOR_ME
        return value if value.match?(UUID_FORMAT)

        Result.new(error: 'invalid creator (expected "me" or a user UUID)')
      end
      private_class_method :resolve_creator

      # UUID or number, resolved inside the asker's ticket read scope: a ticket the
      # asker may not read is "no ticket", so the filter cannot confirm its existence.
      # Org-wide a number may match several projects — that answers with the shared
      # §9.2 candidate payload (Tools::TicketCandidates), never with an error.
      def self.resolve_ticket(raw, context, time_project_ids)
        value = raw.to_s.strip
        return nil if value.empty?

        readable = Pundit.policy_scope!(context.actor, ticket_lookup_base(context, time_project_ids))
        if value.match?(UUID_FORMAT)
          finish_ticket_lookup(readable.find_by(id: value), value)
        else
          number = TicketNumber.parse(value)
          return Result.new(error: 'invalid ticket (expected a UUID or a number like 187 or "#187")') if number.nil?

          matches = readable.where(number: number).to_a
          return ticket_candidates(matches, number) if matches.many?

          finish_ticket_lookup(matches.first, value)
        end
      end
      private_class_method :resolve_ticket

      def self.finish_ticket_lookup(ticket, value)
        return Result.new(content: "No ticket found for #{value}.", citations: [], kind: :empty) if ticket.nil?

        ticket
      end
      private_class_method :finish_ticket_lookup

      # Candidate titles are content — cite them so the answer stays gated (PR #534).
      def self.ticket_candidates(matches, number)
        shown = matches.first(TicketCandidates::DEFAULT_LIMIT)
        json_result(
          TicketCandidates.payload(matches, number),
          citations: shown.map { |ticket| Lalabase::Citations.ticket(ticket) }
        )
      end
      private_class_method :ticket_candidates

      # The lookup scope of the ticket FILTER: the asker's readable tickets of the
      # project, or — org-wide — of the projects whose TIME the asker may see. The
      # policy scope adds the tickets-area check on top; both must hold. Without
      # the time bound a readable ticket in a project without time reach filtered
      # the other projects' sessions and reported an exact zero under scope "all"
      # (T3 second review) — a wrong number with database authority.
      def self.ticket_lookup_base(context, time_project_ids)
        return context.project.tickets if context.project

        Ticket.where(organisation_id: context.organisation.id, project_id: time_project_ids).includes(:project)
      end
      private_class_method :ticket_lookup_base

      # One grouped query for sums and counts; every bucket is present, zero or not,
      # so the model never has to infer a missing key.
      def self.bucket_totals(scope)
        raw_bucket_totals(scope).transform_values { |t| with_hours(t) }
      end
      private_class_method :bucket_totals

      # The aggregation itself lives in TimeSessions::BucketTotals since S3c T3:
      # the assistant's report panel shows the rows behind these very numbers, and
      # two hand-written GROUP BYs over one rule are two totals waiting to differ.
      def self.raw_bucket_totals(scope)
        TimeSessions::BucketTotals.call(scope: scope)
      end
      private_class_method :raw_bucket_totals

      def self.sum_of(parts)
        with_hours(minutes: parts.sum { |p| p[:minutes] }, sessions: parts.sum { |p| p[:sessions] })
      end
      private_class_method :sum_of

      def self.with_hours(totals)
        totals.merge(hours: (totals[:minutes] / MINUTES_PER_HOUR).round(2))
      end
      private_class_method :with_hours

      # What the citation link needs to reopen the same view: scalar ids only, the
      # ticket title is display data and stays in the payload.
      def self.citation_filters(filters)
        filters.slice(:start_date, :end_date, :creator_id)
               .merge(ticket_id: filters.dig(:ticket, :id))
               .compact
      end
      private_class_method :citation_filters
    end
  end
end
