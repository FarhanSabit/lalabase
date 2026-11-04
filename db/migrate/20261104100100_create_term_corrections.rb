# frozen_string_literal: true

# A heard form of a glossary term (K4a): what speech recognition wrote, who
# spoke, in which project and where. One row per correction, not per form:
# "how often and by whom" is a query, not a counter that can drift.
#
# The speaker is a person of the directory or a member, at most one of them
# (the rule of meeting_participants). line_index, char_offset and
# transcript_digest let a device find the place in its own copy of the text.
#
# Deleting a meeting keeps its corrections with their place and only clears
# meeting_id (on_delete: :nullify): a correction is knowledge of the
# organisation, not content of the conversation. Deleting a project or a
# person clears the origin or the speaker the same way.
class CreateTermCorrections < ActiveRecord::Migration[8.1]
  def change
    create_table :term_corrections, id: :uuid do |t|
      t.references :organisation, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      # No index of its own: the index on (glossary_term_id, normalized_heard) starts with it.
      t.references :glossary_term, type: :uuid, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.references :project, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :heard, null: false
      t.string :normalized_heard, null: false
      t.references :person, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :user, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :meeting, type: :uuid, foreign_key: { on_delete: :nullify }
      t.integer :line_index
      t.integer :char_offset
      t.string :transcript_digest
      t.integer :replaced_count, null: false, default: 1
      t.references :corrected_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
      t.index %i[glossary_term_id normalized_heard], name: 'index_term_corrections_on_term_and_heard'
      t.check_constraint 'num_nonnulls(person_id, user_id) <= 1', name: 'term_corrections_one_speaker'
    end
  end
end
