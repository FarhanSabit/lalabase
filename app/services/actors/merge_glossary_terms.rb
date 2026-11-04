# frozen_string_literal: true

# app/services/actors/merge_glossary_terms.rb
#
# Merges one glossary term into another (K4a, plan §6): two spellings of the
# same thing stood as two terms. The heard forms of the source move to the
# target, then the source is deleted. The target keeps its spelling, its
# category and its status, so no spelling can collide. Rights are the
# caller's (GlossaryPolicy, manage_glossary); the caller resolves the target
# through the policy scope, never from a raw id.
#
# Refused: a term into itself, and two terms of different organisations. Both
# rows are locked in one statement in the order of their ids (the lock order
# of Glossary::TermLock), so two merges of the same pair at once, or a merge
# and another write on one of the terms, wait for each other instead of
# deadlocking; a term deleted in the meantime is refused as gone, and nothing
# moves.
module Actors
  class MergeGlossaryTerms < BaseActor
    def initialize(source:, target:, current_user:)
      super()
      @source = source
      @target = target
      @current_user = current_user
    end

    def record
      @target
    end

    def perform
      refuse(:same_term) if @source.id == @target.id
      refuse(:other_glossary) unless @source.organisation_id == @target.organisation_id

      lock_both
      TermCorrection.where(glossary_term_id: @source.id).update_all(glossary_term_id: @target.id, updated_at: Time.current)
      @target.touch
      @source.destroy!
    end

    private

    attr_reader :current_user

    def refuse(code)
      raise ActorError.new(I18n.t("controllers.glossary.merge.#{code}"), code: code)
    end

    # One query, rows locked in the order of their ids; the locked rows
    # replace the given ones, so the merge works on what is stored now.
    def lock_both
      locked = GlossaryTerm.where(id: [@source.id, @target.id]).order(:id).lock.index_by(&:id)
      @source = locked[@source.id]
      @target = locked[@target.id]
      raise ActorError.new(I18n.t('controllers.glossary.not_found'), code: :not_found) unless @source && @target
    end
  end
end
