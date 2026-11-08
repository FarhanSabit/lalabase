# frozen_string_literal: true

# app/services/actors/dismiss_glossary_proposal.rb
#
# Dismisses a proposal of the glossary extraction, or restores a dismissed one
# (K5b, restore: true). A dismissed proposal stays, with who dismissed it and
# when, so a later run does not propose its form again; restoring opens it
# again and clears both. The controller authorizes (GlossaryPolicy#dismiss?,
# #restore?); the actor asks for the right again under the lock.
#
# * The row is locked first; a proposal gone in the meantime (merged into
#   another one) is :already_processed. Then manage_glossary again
#   (GlossaryPolicy.manage_allowed?, an active membership): :forbidden
#   without. No term is locked: no glossary term is written.
# * Then one UPDATE whose condition is the status of the row: open to
#   dismissed, or dismissed to open. Anything but exactly one row, that is a
#   proposal in any other state, is :already_processed, whatever the copy in
#   memory says.
module Actors
  class DismissGlossaryProposal < BaseActor
    def initialize(proposal:, current_user:, restore: false)
      super()
      @proposal = proposal
      @current_user = current_user
      @restore = restore
    end

    def record
      @proposal
    end

    def perform
      lock_row
      refuse(:forbidden) unless GlossaryPolicy.manage_allowed?(current_user, @proposal.organisation)

      now = Time.current
      from, to, decided_by_id, decided_at = @restore ? ['dismissed', 'open', nil, nil] : ['open', 'dismissed', current_user.id, now]
      changed = GlossaryProposal.where(id: @proposal.id, organisation_id: @proposal.organisation_id, status: from)
                                .update_all(status: to, decided_by_id: decided_by_id, decided_at: decided_at, updated_at: now)
      refuse(:already_processed) unless changed == 1

      @proposal.reload
    end

    private

    attr_reader :current_user

    def refuse(code)
      raise ActorError.new(I18n.t("controllers.glossary.proposals.#{code}"), code: code)
    end

    def lock_row
      @proposal.lock!
    rescue ActiveRecord::RecordNotFound
      refuse(:already_processed)
    end
  end
end
