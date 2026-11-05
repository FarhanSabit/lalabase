# frozen_string_literal: true

# Every heard form of the glossary has a status of its own (K4b, E3): a
# correction in a meeting without manage_glossary is a proposal, also at a
# term that is already confirmed, so it cannot work in other meetings before
# someone with the right confirmed it. Only a confirmed form at a confirmed
# term works (TermCorrection.effective).
#
# Every row written before K4b was written by hand or confirmed with the right,
# so the default says confirmed and no backfill is needed. A constant default
# on a new column is a metadata-only change in PostgreSQL. The check
# constraint is the second line behind the model's enum (pattern:
# users_email_visibility_known).
class AddStatusToTermCorrections < ActiveRecord::Migration[8.1]
  def change
    change_table :term_corrections, bulk: true do |t|
      t.string :status, null: false, default: 'confirmed'
      t.check_constraint "status IN ('proposed', 'confirmed')", name: 'term_corrections_status_known'
    end
  end
end
