# frozen_string_literal: true

# app/services/actors/destroy_glossary_term.rb
#
# Deletes one term of the glossary with its heard forms (K4a, plan §3.3).
# Rights are the caller's (GlossaryPolicy, manage_glossary).
#
# The term row is locked first, the order Actors::MergeGlossaryTerms locks in:
# a delete and a merge of the same term at once then wait for each other.
# Deleting the heard forms first held their rows while waiting for the term
# the merge held, and the merge waited for those rows (deadlock; review round 1
# of #113). A term deleted in the meantime is refused as gone.
module Actors
  class DestroyGlossaryTerm < BaseActor
    def initialize(term:, current_user:)
      super()
      @term = term
      @current_user = current_user
    end

    # A destroy leaves no surviving primary record.
    def record
      nil
    end

    def perform
      lock_term
      @term.destroy!
    end

    private

    attr_reader :current_user

    def lock_term
      @term.lock!
    rescue ActiveRecord::RecordNotFound
      raise ActorError.new(I18n.t('controllers.glossary.not_found'), code: :not_found)
    end
  end
end
