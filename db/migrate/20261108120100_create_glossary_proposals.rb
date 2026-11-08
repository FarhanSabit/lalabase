# frozen_string_literal: true

# A proposal of the glossary extraction (K5b): a term found in the texts of an
# organisation, for a person to accept, merge or dismiss. One proposal per
# compared form (normalized_term, GlossaryText.normalize) and organisation,
# like glossary_terms; its spelling variants stand in variants.
#
# The check constraints are the second line behind the model's validations,
# for a write past the model (update_all, insert_all, a console fix):
# * category: one of GlossaryTerm::CATEGORIES or none, written out here
#   because a migration must not change with the constant.
# * variants: a list of at most ten texts (GlossaryProposal::MAX_VARIANTS).
#   The CASE runs the length and the element test on a list only, whatever
#   order PostgreSQL would pick for an AND, so an object fails the check
#   instead of making jsonb_array_length raise. The path runs in strict
#   mode: lax mode unwraps a nested list and would pass ["a", ["b"]].
# * status and occurrences.
# term, hint: the string limits are the model's maximums as well.
#
# Deleting the organisation takes its proposals along. Deleting the run or the
# glossary term only clears the reference: a proposal outlives the run that
# found it, and a decision outlives the term it led to. Deleting the account
# that decided clears decided_by_id.
class CreateGlossaryProposals < ActiveRecord::Migration[8.1]
  CATEGORIES = %w[person company product place domain foreign].freeze

  def change
    create_table :glossary_proposals, id: :uuid do |t|
      # No index of its own: both indexes below start with organisation_id.
      t.references :organisation, type: :uuid, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.references :glossary_extraction_run, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :term, null: false, limit: 255
      t.string :normalized_term, null: false
      t.string :category
      t.jsonb :variants, null: false, default: []
      t.string :hint, null: false, default: '', limit: 160
      t.integer :occurrences, null: false, default: 0
      t.string :status, null: false, default: 'open'
      t.references :glossary_term, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :decided_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :decided_at
      t.timestamps
      t.index %i[organisation_id normalized_term], unique: true, name: 'index_glossary_proposals_on_org_and_normalized_term'
      t.index %i[organisation_id status]
      t.check_constraint "category IS NULL OR category IN (#{CATEGORIES.map { |category| "'#{category}'" }.join(', ')})",
                         name: 'glossary_proposals_category_known'
      t.check_constraint <<~SQL.squish, name: 'glossary_proposals_variants_shape'
        CASE WHEN jsonb_typeof(variants) = 'array'
          THEN jsonb_array_length(variants) <= 10
            AND NOT jsonb_path_exists(variants, 'strict $[*] ? (@.type() != "string")')
          ELSE false
        END
      SQL
      t.check_constraint 'occurrences >= 0', name: 'glossary_proposals_occurrences_not_negative'
      t.check_constraint "status IN ('open', 'accepted', 'dismissed')", name: 'glossary_proposals_status_known'
    end
  end
end
