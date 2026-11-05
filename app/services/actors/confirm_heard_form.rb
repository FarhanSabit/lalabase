# frozen_string_literal: true

# app/services/actors/confirm_heard_form.rb
#
# Confirms an open heard form of a glossary term (K4b, E3): the proposals of
# that form at that term, named by one of its corrections, become confirmed,
# so they work from now on (TermCorrection.effective). A correction in a
# meeting without manage_glossary made them. Rights are the caller's
# (GlossaryPolicy, manage_glossary).
#
# The term is locked first (Glossary::TermLock). A term gone in the meantime is
# refused as gone, a form with nothing open any more (someone confirmed or
# rejected it meanwhile) as not open.
module Actors
  class ConfirmHeardForm < BaseActor
    def initialize(correction:, current_user:)
      super()
      @correction = correction
      @current_user = current_user
    end

    def record
      @correction
    end

    def perform
      Glossary::TermLock.call(term: @correction.glossary_term)
      changed = TermCorrection.where(glossary_term_id: @correction.glossary_term_id, normalized_heard: @correction.normalized_heard,
                                     status: 'proposed').update_all(status: 'confirmed', updated_at: Time.current)
      raise ActorError.new(I18n.t('controllers.glossary.heard_form.not_open'), code: :not_open) if changed.zero?
    end

    private

    attr_reader :current_user
  end
end
