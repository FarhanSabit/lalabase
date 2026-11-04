# frozen_string_literal: true

# The glossary of an organisation (K4a): one row per term in its right
# spelling. normalized_term (characters that show nothing dropped, NFC,
# whitespace collapsed, lower case: GlossaryText) is unique per organisation,
# so one spelling cannot stand twice. status: proposed, confirmed, rejected; a
# rejected term stays, so it is not proposed again.
class CreateGlossaryTerms < ActiveRecord::Migration[8.1]
  def change
    create_table :glossary_terms, id: :uuid do |t|
      # No index of its own: the unique index below starts with organisation_id.
      t.references :organisation, type: :uuid, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.string :term, null: false
      t.string :normalized_term, null: false
      t.string :category
      t.string :status, null: false, default: 'confirmed'
      t.references :created_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
      t.index %i[organisation_id normalized_term], unique: true
    end
  end
end
