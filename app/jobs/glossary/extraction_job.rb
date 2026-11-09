# frozen_string_literal: true

module Glossary
  # Runs one glossary extraction (K5b) off the request path: Glossary::Extraction for
  # the run Actors::StartGlossaryExtraction wrote. Tenant-safe the way
  # Meetings::TicketSuggestionJob is: Solid Queue dequeues with no tenant (or the one
  # of the request that enqueued), so the run is loaded without one, and the work runs
  # within the run's organisation.
  #
  # * One execution per run: an advisory lock per run (released with the session,
  #   so a dead worker leaves none), then the claim queued -> running in one UPDATE.
  #   A second delivery of the job, or a second job for the run, does nothing.
  # * A run left running when the extraction returns, or found running under the
  #   lock (its worker is gone), ends as interrupted. A run is never retried by
  #   itself: a person starts a new one.
  # * Any error of the extraction ends the run as internal_error and is not raised
  #   again: a retry would run the classifier again, and the provider bills every
  #   call. Logged by class only; the message may repeat the organisation's texts.
  class ExtractionJob < ApplicationJob
    queue_as :default

    discard_on ActiveRecord::RecordNotFound do |_job, error|
      Rails.logger.warn("Glossary::ExtractionJob discarded: #{error.message}")
    end

    # Enqueues the job under the run's job id. A job that cannot be enqueued ends
    # the run, so the next start is not refused by a run that never runs.
    def self.enqueue_run(run:)
      job = new(run_id: run.id)
      job.job_id = run.job_id
      raise ActiveJob::EnqueueError, 'enqueue failed' unless job.enqueue
    rescue StandardError => e
      Rails.logger.error("Glossary::ExtractionJob enqueue for run #{run.id} failed: #{e.class.name}")
      run.mark_failed!('internal_error', from: ['queued'])
    end

    # The key of the advisory lock of one run. Public so a spec can hold the lock
    # from a second session.
    def self.execution_lock_key(run_id)
      Digest::SHA256.hexdigest("glossary-extraction-run:#{run_id}")[0, 15].to_i(16)
    end

    def perform(run_id:)
      run = ActsAsTenant.without_tenant { GlossaryExtractionRun.find(run_id) }

      ActsAsTenant.with_tenant(run.organisation) do
        with_execution_lock(run) do
          extract(run.reload) if claim(run)
        ensure
          run.mark_failed!('interrupted', from: ['running'])
        end
      end
    end

    private

    # Exactly one row, or the run is not queued: another delivery took it, or it
    # ended.
    def claim(run)
      GlossaryExtractionRun.where(id: run.id, organisation_id: run.organisation_id, status: 'queued')
                           .update_all(status: 'running', updated_at: Time.current) == 1
    end

    def extract(run)
      Glossary::Extraction.call(run: run)
    rescue StandardError => e
      Rails.logger.error("Glossary::ExtractionJob: run #{run.id} failed: #{e.class.name}")
      run.mark_failed!('internal_error', from: ['running'])
    end

    # Session-level, not transaction-level: the extraction commits many times and
    # holds no transaction across a call to the model. Without the lock the block
    # does not run.
    def with_execution_lock(run)
      key = self.class.execution_lock_key(run.id)
      GlossaryExtractionRun.connection_pool.with_connection do |connection|
        next unless connection.select_value(GlossaryExtractionRun.sanitize_sql_array(['SELECT pg_try_advisory_lock(?)', key]))

        begin
          yield
        ensure
          connection.select_value(GlossaryExtractionRun.sanitize_sql_array(['SELECT pg_advisory_unlock(?)', key]))
        end
      end
    end
  end
end
