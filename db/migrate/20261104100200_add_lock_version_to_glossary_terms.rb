# frozen_string_literal: true

# Optimistic locking for a glossary term (review round 4 of #113): the form
# sends the lock_version it was opened with, so a save over someone else's
# change in the meantime is refused instead of writing the old spelling or
# category back (Actors::SaveGlossaryTerm, as Actors::SavePerson).
class AddLockVersionToGlossaryTerms < ActiveRecord::Migration[8.1]
  def change
    add_column :glossary_terms, :lock_version, :integer, default: 0, null: false
  end
end
