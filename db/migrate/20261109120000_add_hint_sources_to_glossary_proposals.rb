# frozen_string_literal: true

# A hint may use any context in its classifier call, including candidates the
# model drops. Keep that provenance separately from the proposal's five example
# sources, which a merge may trim. Existing hints have unknown provenance and
# remain hidden; their own example sources cannot reconstruct the original batch.
class AddHintSourcesToGlossaryProposals < ActiveRecord::Migration[8.1]
  def change
    add_column :glossary_proposals, :hint_sources, :jsonb, null: false, default: []
    add_check_constraint :glossary_proposals, "jsonb_typeof(hint_sources) = 'array'",
                         name: 'glossary_proposals_hint_sources_array'
  end
end
