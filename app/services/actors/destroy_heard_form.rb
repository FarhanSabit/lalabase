# frozen_string_literal: true

# app/services/actors/destroy_heard_form.rb
#
# Deletes one heard form of a glossary term that was learnt wrong (K4a, plan
# §6): every correction of that form at this term, named by one of them, so
# the form is no longer learnt at all. The term and its other forms stay, also
# when the term is left without any heard form. Rights are the caller's
# (GlossaryPolicy, manage_glossary).
#
# The term is locked first (Glossary::TermLock). A form or a term gone in the
# meantime (deleted, or merged into another term) is refused as gone.
module Actors
  class DestroyHeardForm < BaseActor
    def initialize(correction:, current_user:)
      super()
      @correction = correction
      @current_user = current_user
    end

    # A destroy leaves no surviving primary record.
    def record
      nil
    end

    def perform
      Glossary::TermLock.call(term: @correction.glossary_term)
      deleted = TermCorrection.where(glossary_term_id: @correction.glossary_term_id,
                                     normalized_heard: @correction.normalized_heard).delete_all
      raise ActorError.new(I18n.t('controllers.glossary.heard_form.not_found'), code: :not_found) if deleted.zero?
    end

    private

    attr_reader :current_user
  end
end
