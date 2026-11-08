# frozen_string_literal: true

# Where a proposal of the glossary extraction was found (K5b): a ticket, a
# comment, a file, a note or a document version, with a short snippet. The
# run keeps a few per proposal (GlossaryProposal::MAX_SOURCES).
#
# The source is polymorphic (source_type, source_id) and has NO foreign key: a
# deleted source leaves the row, and the page asks when it shows the row
# whether the source is still there and readable. The check constraint holds
# the six kinds the run reads (GlossaryProposalSource::SOURCE_TYPES).
#
# Deleting the proposal or the organisation takes the rows along; deleting
# the project only clears project_id.
class CreateGlossaryProposalSources < ActiveRecord::Migration[8.1]
  def change
    create_table :glossary_proposal_sources, id: :uuid do |t|
      t.references :organisation, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      # No index of its own: the unique index on (glossary_proposal_id, source_type, source_id) starts with it.
      t.references :glossary_proposal, type: :uuid, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.string :source_type, null: false
      t.uuid :source_id, null: false
      t.references :project, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :snippet, null: false, default: '', limit: 240
      t.integer :occurrences, null: false, default: 1
      t.timestamps
      t.index %i[source_type source_id]
      t.index %i[glossary_proposal_id source_type source_id], unique: true,
                                                              name: 'index_glossary_proposal_sources_on_proposal_and_source'
      t.check_constraint "source_type IN ('Ticket', 'Post', 'TicketDocument', 'PostDocument', 'Note', 'DocumentVersion')",
                         name: 'glossary_proposal_sources_source_type_known'
      t.check_constraint 'occurrences >= 1', name: 'glossary_proposal_sources_occurrences_positive'
    end
  end
end
