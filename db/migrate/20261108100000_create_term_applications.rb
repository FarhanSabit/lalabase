# frozen_string_literal: true

# What the glossary did to a meeting (K4d): one row per heard spelling that the
# recording app replaced by a term before it sent the transcript, with how
# often. An application, not a correction (term_corrections): nothing was
# learnt here, the glossary of the organisation was applied, and the row
# shows it on the meeting and under the heard form.
#
# The row belongs to the meeting (on_delete: :cascade): without the meeting it
# says nothing. The term is a reference that may go (on_delete: :nullify); its
# spelling stays in `term`, so the row outlives a term that was deleted or
# merged (the merge moves the reference). The project is the origin, as on a
# correction. One row per spelling and meeting: the writer sums a spelling
# sent twice.
class CreateTermApplications < ActiveRecord::Migration[8.1]
  def change
    create_table :term_applications, id: :uuid do |t|
      t.references :organisation, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      # No index of its own: the unique index on (meeting_id, normalized_heard, heard) starts with it.
      t.references :meeting, type: :uuid, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.references :project, type: :uuid, foreign_key: { on_delete: :nullify }
      # No index of its own: the index on (glossary_term_id, normalized_heard) starts with it.
      t.references :glossary_term, type: :uuid, index: false, foreign_key: { on_delete: :nullify }
      t.string :term, null: false
      t.string :heard, null: false
      t.string :normalized_heard, null: false
      t.integer :replaced_count, null: false, default: 1
      t.string :source, null: false, default: 'device'
      t.timestamps
      t.index %i[glossary_term_id normalized_heard], name: 'index_term_applications_on_term_and_heard'
      t.index %i[meeting_id normalized_heard heard], unique: true, name: 'index_term_applications_on_meeting_and_heard'
      t.check_constraint 'replaced_count >= 1', name: 'term_applications_count_positive'
      t.check_constraint "source IN ('device')", name: 'term_applications_source_known'
    end
  end
end
