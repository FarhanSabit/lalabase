# frozen_string_literal: true

# Keeps a running glossary extraction run from turning stale while its worker
# waits on the model (K5b). Glossary::Extraction touches the run before each
# load batch and in each write, but a call to the provider can take longer than
# GlossaryExtractionRun::STALE_AFTER (the Anthropic SDK waits up to ten minutes
# per attempt and tries three times). Without a beat a second start would end
# the run as stale, the answer would be thrown away once it came, and the next
# run would pay for the same candidates again.
#
# So while the block runs, a thread of its own touches the run every EVERY, on a
# connection of its own, with ONE update under the status condition like
# Extraction#update_running: a run that is no longer running is not touched,
# whatever ended it. Nothing in memory changes, and the thread never raises into
# the caller: a beat that fails is logged, and the caller's next touch tells
# whether the run is lost. The thread holds no lock and no transaction, and it
# waits outside the executor, so it can never hold up a reload.
#
# Entry point: .call(run:) { ... }, answers what the block answers.
module Glossary
  class RunHeartbeat
    # Five beats per STALE_AFTER: a beat lost to a slow connection still leaves
    # four before the run turns stale.
    EVERY = GlossaryExtractionRun::STALE_AFTER / 5

    def self.call(run:, every: EVERY, &block)
      new(run: run, every: every).call(&block)
    end

    def initialize(run:, every:)
      @run = run
      @every = every
      @stop = Queue.new
    end

    def call
      thread = Thread.new { beat_until_stopped }
      thread.report_on_exception = false
      yield
    ensure
      @stop << true
      thread&.join
    end

    private

    # Queue#pop with a timeout: nil after EVERY (beat), true once the block ended.
    def beat_until_stopped
      beat until @stop.pop(timeout: @every)
    end

    def beat
      Rails.application.executor.wrap do
        GlossaryExtractionRun.connection_pool.with_connection do
          GlossaryExtractionRun.unscoped.where(id: @run.id, organisation_id: @run.organisation_id, status: 'running')
                               .update_all(updated_at: Time.current)
        end
      end
    rescue StandardError => e
      Rails.logger.warn("Glossary::RunHeartbeat: the beat for run #{@run.id} failed: #{e.class.name}")
    end
  end
end
