# frozen_string_literal: true

# app/services/actors/reject_heard_form.rb
#
# Rejects an open heard form of a glossary term (K4b, E3): the proposals of
# that form at that term, named by one of its corrections, are deleted, as
# "delete a heard form" deletes (Actors::DestroyHeardForm), but only the
# proposals. A confirmed correction of the same form stays: someone with the
# right confirmed it, and it works. Rights are the caller's (GlossaryPolicy,
# manage_glossary).
#
# The term is locked first (Glossary::TermLock). A term gone in the meantime is
# refused as gone, a form with nothing open any more as not open.
module Actors
  class RejectHeardForm < BaseActor
    def initialize(correction:, current_user:)
      super()
      @correction = correction
      @current_user = current_user
    end

    # A rejection leaves no surviving primary record of its own.
    def record
      nil
    end

    def perform
      Glossary::TermLock.call(term: @correction.glossary_term)
      deleted = TermCorrection.where(glossary_term_id: @correction.glossary_term_id, normalized_heard: @correction.normalized_heard,
                                     status: 'proposed').delete_all
      raise ActorError.new(I18n.t('controllers.glossary.heard_form.not_open'), code: :not_open) if deleted.zero?
    end

    private

    attr_reader :current_user
  end
end
