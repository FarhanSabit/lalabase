# frozen_string_literal: true

# app/services/actors/merge_glossary_proposals.rb
#
# Merges one proposal of the glossary extraction into another (K5b): the run
# found two spellings of one thing as two proposals. The target stays open
# and gains what the source knew; the source is deleted, not dismissed, so a
# later run finds its spelling as a variant of the target instead of
# proposing it again. The controller authorizes (GlossaryPolicy#accept?) and
# resolves both through the policy scope; the actor asks for the right again
# under the lock.
#
# * Refused before anything is locked: a proposal into itself
#   (:same_proposal) and two of different organisations (:other_glossary).
# * Both rows are locked in one statement in the order of their ids (the rule
#   of Actors::MergeGlossaryTerms), so two merges of one pair, or a merge and
#   another decision on one of them, wait for each other instead of
#   deadlocking. The locked rows replace the given ones. A proposal gone in
#   the meantime, or one that is no longer open, is :already_processed;
#   without manage_glossary (GlossaryPolicy.manage_allowed?, an active
#   membership) :forbidden. No term is locked: no glossary term is written.
# * The target gains the source's spelling and variants as variants, once per
#   compared form, never its own term, at most GlossaryProposal::MAX_VARIANTS
#   with its own first, but the source's spelling always (in the place of the
#   target's last own variant when it is full); the source's occurrences; its
#   category only where the target has none. Never its hint or hint_sources:
#   those belong to the model call that wrote that hint.
# * The source's places move to the target. A place both have stays once,
#   with the occurrences of both. Then the target keeps the
#   GlossaryProposal::MAX_SOURCES places with the most occurrences.
# * The target keeps its own hint and hint_sources, even when the trim drops
#   its own example places. The page authorizes the hint against the complete
#   model input in hint_sources, independently of the remaining examples.
module Actors
  class MergeGlossaryProposals < BaseActor
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
      refuse(:same_proposal) if @source.id == @target.id
      refuse(:other_glossary, 'controllers.glossary.merge.other_glossary') unless @source.organisation_id == @target.organisation_id

      lock_both
      refuse(:forbidden) unless GlossaryPolicy.manage_allowed?(current_user, @target.organisation)
      refuse(:already_processed) unless @source.open? && @target.open?

      move_places
      keep_busiest_places
      absorb_source
      @source.destroy!
    end

    private

    attr_reader :current_user

    def refuse(code, key = "controllers.glossary.proposals.#{code}")
      raise ActorError.new(I18n.t(key), code: code)
    end

    # One query, rows locked in the order of their ids.
    def lock_both
      locked = GlossaryProposal.where(id: [@source.id, @target.id], organisation_id: @target.organisation_id)
                               .order(:id).lock.index_by(&:id)
      refuse(:already_processed) unless locked.key?(@source.id) && locked.key?(@target.id)

      @source = locked[@source.id]
      @target = locked[@target.id]
    end

    def absorb_source
      @target.variants = merged_variants
      @target.occurrences += @source.occurrences
      @target.category ||= @source.category
      @target.save!
    end

    # The source's spelling always gets a place, if need be the place of the
    # target's last own variant: the source is deleted, and a spelling of it
    # nobody keeps would be proposed again by the next run. Its other variants
    # fill what is left.
    def merged_variants
      seen = Set[@target.normalized_term]
      fresh = ->(texts) { texts.grep(String).select { |text| seen.add?(GlossaryText.normalize(text)) } }
      own = fresh.call(@target.variants)
      spelling = fresh.call([@source.term])
      others = fresh.call(@source.variants)
      [*own.first(GlossaryProposal::MAX_VARIANTS - spelling.size), *spelling, *others].first(GlossaryProposal::MAX_VARIANTS)
    end

    # The places of both in one query. A place is its source row: kind and id.
    # A place both have keeps the target's row.
    def move_places
      by_proposal = places.where(glossary_proposal_id: [@source.id, @target.id]).group_by(&:glossary_proposal_id)
      own = by_proposal.fetch(@target.id, []).index_by { |place| [place.source_type, place.source_id] }
      shared, moving = by_proposal.fetch(@source.id, []).partition { |place| own.key?([place.source_type, place.source_id]) }
      now = Time.current

      shared.each do |place|
        places.where(id: own[[place.source_type, place.source_id]].id)
              .update_all(occurrences: GlossaryProposalSource.arel_table[:occurrences] + place.occurrences, updated_at: now)
      end
      places.where(id: shared.map(&:id)).delete_all
      places.where(id: moving.map(&:id)).update_all(glossary_proposal_id: @target.id, updated_at: now)
    end

    # The most frequent first; among equal counts the older place.
    # The lock on the target keeps a run from
    # adding a place in between (Glossary::Extraction locks it too).
    def keep_busiest_places
      ids = places.where(glossary_proposal_id: @target.id).order(occurrences: :desc, created_at: :asc, id: :asc).pluck(:id)
      dropped = ids.drop(GlossaryProposal::MAX_SOURCES)
      places.where(id: dropped).delete_all if dropped.any?
    end

    def places
      GlossaryProposalSource.where(organisation_id: @target.organisation_id)
    end
  end
end
