# frozen_string_literal: true

# One run of the glossary extraction (K5b): a background job that reads the
# texts of an organisation the starting account may read, finds candidate
# terms and stores proposals for a person to decide (glossary_proposals).
#
# One active run per organisation: the partial unique index
# one_active_glossary_extraction_run holds it also for two starts at the same
# moment (pattern: one_active_ticket_suggestion_run). It covers only the
# active rows, so organisation_id keeps an index of its own for the cascade
# and for the list of finished runs.
#
# scope says what the run read, stats what it found (shapes in the header of
# GlossaryExtractionRun). The check constraint on status is the second line
# behind the model's enum. Deleting the organisation takes its runs along;
# deleting the account that started one only clears started_by_id.
class CreateGlossaryExtractionRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :glossary_extraction_runs, id: :uuid do |t|
      t.references :organisation, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :started_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :job_id, null: false, index: { unique: true }
      t.string :status, null: false, default: 'queued'
      t.jsonb :scope, null: false, default: {}
      t.jsonb :stats, null: false, default: {}
      t.string :error_code
      t.datetime :finished_at
      t.timestamps
      t.index :organisation_id, unique: true, where: "status IN ('queued', 'running')",
                                name: 'one_active_glossary_extraction_run'
      t.check_constraint "status IN ('queued', 'running', 'succeeded', 'failed')",
                         name: 'glossary_extraction_runs_status_known'
    end
  end
end
