# frozen_string_literal: true

module Glossary
  # Blanks what a proposal of the glossary extraction still holds of a source
  # that is gone (K5b). A place of a proposal (GlossaryProposalSource) names its
  # source without a foreign key, on purpose: a deleted ticket, comment, file,
  # note or document version leaves the row, and the page says "source gone"
  # instead of losing the place. But the row also holds up to MAX_SNIPPET
  # characters of that source, and the proposal's hint may have been written
  # from it, and the page shows neither ever again
  # (GlossaryHelper#glossary_source_access, #glossary_proposal_hint). Kept, they
  # would outlive a deletion that may have been made because of what they say.
  #
  # Once a day, across every organisation, without a tenant:
  # * the snippet of a place whose source no longer exists is blanked, one
  #   UPDATE per kind (NOT EXISTS against the table of that kind, so an id that
  #   lives on in another kind's table does not count);
  # * the hint of a proposal is blanked unless every source its model call read
  #   (hint_sources) still exists, read through the model's own reader
  #   (GlossaryProposal#hint_source_references): a provenance that is empty or
  #   unreadable shows the hint to nobody either, so it goes too.
  # The rows stay, and so do project, count and provenance. Like the vectors
  # Embeddings::OrphanGcJob reclaims, the text of deleted content lives at most
  # a day longer than its source. Nothing here reads a request or the model.
  class GoneSourceSnippetPurgeJob < ApplicationJob
    queue_as :default

    # Proposals read at a time for the hints.
    BATCH = 500

    def perform
      ActsAsTenant.without_tenant do
        snippets = blank_snippets
        hints = blank_hints
        return if snippets.zero? && hints.zero?

        Rails.logger.info("Glossary::GoneSourceSnippetPurgeJob: blanked #{snippets} snippet(s) and #{hints} hint(s) of gone sources")
      end
    end

    private

    def blank_snippets
      places = GlossaryProposalSource.arel_table
      GlossaryProposalSource::SOURCE_TYPES.sum do |type|
        rows = kind(type).arel_table
        still_there = rows.project(Arel.sql('1')).where(rows[:id].eq(places[:source_id]))
        GlossaryProposalSource.unscoped.where(source_type: type).where.not(snippet: '').where(still_there.exists.not)
                              .update_all(snippet: '', updated_at: Time.current)
      end
    end

    def blank_hints
      blanked = 0
      GlossaryProposal.unscoped.where.not(hint: '').select(:id, :hint_sources).find_in_batches(batch_size: BATCH) do |proposals|
        existing = existing_sources(proposals)
        ids = proposals.reject { |proposal| hint_showable?(proposal, existing) }.map(&:id)
        next if ids.empty?

        blanked += GlossaryProposal.unscoped.where(id: ids).where.not(hint: '').update_all(hint: '', updated_at: Time.current)
      end
      blanked
    end

    # { kind => the ids of that kind, among those the batch names, that exist }.
    def existing_sources(proposals)
      proposals.flat_map(&:hint_source_references).group_by(&:source_type).to_h do |type, references|
        [type, kind(type).unscoped.where(id: references.map(&:source_id).uniq).pluck(:id).to_set]
      end
    end

    # The rule of GlossaryHelper::SourceAccess#all_readable?, for existence
    # alone: a provenance, and every source in it is still there.
    def hint_showable?(proposal, existing)
      references = proposal.hint_source_references
      references.any? && references.all? { |reference| existing.fetch(reference.source_type).include?(reference.source_id) }
    end

    def kind(type)
      GlossaryProposalSource.polymorphic_class_for(type)
    end
  end
end
