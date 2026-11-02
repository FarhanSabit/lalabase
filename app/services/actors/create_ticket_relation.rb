# frozen_string_literal: true

# app/services/actors/create_ticket_relation.rb
#
# Links two tickets of one organisation (doc/ticket_relations_plan.md, revision 4, §6.1).
# `kind` is one of the seven labels of TicketRelation::KINDS, read from `ticket`'s side. A
# backwards label (blocked_by, duplicated_by, follows) is stored flipped, so the other ticket
# becomes the source: one row per relation, whichever page it was set on.
#
# A waiting edge (TicketRelation::WAITING_TYPES) must not close a cycle. Two writers could each
# find none and together close one (A -> B and B -> A at the same time, or two edges that share
# no ticket and close a ring of four), so the lock is per organisation, and lock, cycle check
# and save! run in this actor's one transaction, in that order.
#
# No rights checks here. The caller makes sure the user may write tickets in the project of
# `ticket` and may read `other_ticket`, found through Tickets::RelationAccess#other_ticket with
# the caller's token.
# The ticket objects passed in do not learn about the new row (TicketRelation has no inverse on
# its belongs_to, on purpose): a caller that loaded ticket.outgoing_relations or
# incoming_relations before reads them fresh afterwards, or renders from a new query.
# No activity and no notification either (plan §6.2): TicketRelation is not Trackable, and
# neither ticket is written.

module Actors
  class CreateTicketRelation < BaseActor
    def initialize(ticket:, other_ticket:, kind:, current_user:, delay_days: nil)
      super()
      @ticket = ticket
      @other_ticket = other_ticket
      @kind = kind.to_s
      @delay_days = delay_days
      @current_user = current_user
      @relation = nil
    end

    def record
      @relation
    end

    def perform
      orientation = TicketRelation::KINDS[@kind]
      raise ActorError.new(I18n.t('services.actors.create_ticket_relation.unknown_kind'), code: :unknown_kind) unless orientation

      source, target = orientation[:flipped] ? [@other_ticket, @ticket] : [@ticket, @other_ticket]
      @relation = TicketRelation.new(source_ticket: source, target_ticket: target,
                                     relation_type: orientation[:relation_type], delay_days: @delay_days)
      refuse_cycle(source, target) if @relation.waiting_edge?
      # A savepoint: when the index refuses the row, PostgreSQL aborts the transaction it runs
      # in, and inside a caller's transaction the caller's next query would fail.
      TicketRelation.transaction(requires_new: true) { @relation.save! }
    rescue ActiveRecord::RecordNotUnique
      # The index caught a concurrent write of the same pair that the validation could not
      # see yet.
      raise ActorError.new(I18n.t('services.actors.create_ticket_relation.already_linked'), code: :already_linked)
    rescue ActiveRecord::InvalidForeignKey
      # A ticket was deleted by another request between the validation and the INSERT.
      raise ActorError.new(I18n.t('services.actors.create_ticket_relation.ticket_missing'), code: :ticket_missing)
    end

    private

    # For the new edge source -> target the question is whether target already reaches source.
    # A missing ticket is left to the validation of save!.
    def refuse_cycle(source, target)
      return if source.nil? || target.nil?

      lock_waiting_edges(source.organisation_id)
      return unless Tickets::CycleCheck.call(edges: :waiting_relations, from: target.id, to: source.id)

      # No ticket named: the cycle may run through tickets the user cannot read.
      raise ActorError.new(I18n.t('services.actors.create_ticket_relation.would_create_cycle'), code: :cycle)
    end

    # Held until the transaction ends. The organisation id is a bind, never part of the SQL.
    # SELECT 1 FROM: the function returns void, which ActiveRecord warns about as unknown OID.
    def lock_waiting_edges(organisation_id)
      TicketRelation.connection.select_value(
        "SELECT 1 FROM pg_advisory_xact_lock(hashtextextended('ticket_relations:' || $1, 0))",
        'Actors::CreateTicketRelation lock', [organisation_id.to_s]
      )
    end
  end
end
