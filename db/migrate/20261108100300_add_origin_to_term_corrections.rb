# frozen_string_literal: true

# Where a heard form of the glossary came from (K5b): a correction in a
# meeting, a proposal of the glossary extraction, or an import. Until now only
# the correction in a meeting (Actors::CorrectMeetingTerm) wrote rows, so the
# default says meeting and no backfill is needed.
#
# A constant default on a new column is a metadata-only change in PostgreSQL
# 11 and later: the table is not rewritten, every existing row reads
# 'meeting' at once, and the lock lasts as long as the catalogue change plus
# the one scan that validates the check constraint, on a small table. The
# check constraint is the second line behind the model's validation (pattern:
# term_corrections_status_known).
class AddOriginToTermCorrections < ActiveRecord::Migration[8.1]
  def change
    change_table :term_corrections, bulk: true do |t|
      t.string :origin, null: false, default: 'meeting'
      t.check_constraint "origin IN ('meeting', 'extraction', 'import')", name: 'term_corrections_origin_known'
    end
  end
end
