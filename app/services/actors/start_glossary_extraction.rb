# frozen_string_literal: true

# app/services/actors/start_glossary_extraction.rb
#
# Starts a run of the glossary extraction (K5b) for an organisation: the write
# behind the start button. The controller authorizes (GlossaryPolicy#start?); the
# actor asks for the right again under the lock, as Actors::StartTicketSuggestionRun
# does.
#
# * The lock: the organisation's row, the row the runs belong to, as
#   StartTicketSuggestionRun locks the meeting. Two starts of one organisation wait
#   for each other, so the second sees the first run; the AI configuration actors
#   (SaveAiConfiguration, SelectAiPackage, RemoveAiConfiguration) take the same lock,
#   so the AI gate below answers from a configuration nobody writes at that moment.
#   It is held for the few queries of this transaction only.
# * Under it: manage_glossary (GlossaryPolicy.manage_allowed?, an active membership),
#   else :forbidden. An active run that has not moved for STALE_AFTER ends as stale
#   (its worker is gone) and the start goes on; any other active run is :run_active.
#   Without AI for the extraction (organisation.ai_available_for?) :ai_unavailable,
#   in the words of the registry (FeatureRegistry.unavailable_hint, the one source
#   of that text).
# * The run: queued, a fresh job id, started by this person, scope kind
#   organisation; everything only when it is true itself: a full read reads up to
#   Glossary::Extraction::MAX_SOURCES texts again, and like any run it sends the
#   model at most MAX_CANDIDATES candidates, in calls of BATCH_SIZE (five calls
#   today; MAX_AI_CALLS is the net should those numbers change). The partial
#   unique index one_active_glossary_extraction_run still catches a start that
#   raced past the check: :run_active.
# * The job only after the commit, under the run's job id; an enqueue that fails
#   ends the run (Glossary::ExtractionJob.enqueue_run).
module Actors
  class StartGlossaryExtraction < BaseActor
    def initialize(organisation:, current_user:, everything: false)
      super()
      @organisation = organisation
      @current_user = current_user
      @everything = everything == true
      @run = nil
    end

    def record
      @run
    end

    def perform
      @organisation.lock!
      refuse(:forbidden) unless GlossaryPolicy.manage_allowed?(current_user, @organisation)

      end_stale_runs
      refuse(:run_active) if runs.where(status: GlossaryExtractionRun::ACTIVE_STATUSES).exists?
      availability = @organisation.ai_available_for?(:glossary_extraction)
      refuse(:ai_unavailable, Lalabase::Llm::FeatureRegistry.unavailable_hint(availability, @organisation)) unless availability.available?

      @run = create_run
    end

    def enqueue_jobs
      run = @run
      enqueue_after_commit { Glossary::ExtractionJob.enqueue_run(run: run) }
    end

    private

    attr_reader :current_user

    def refuse(code, message = I18n.t("controllers.glossary.runs.#{code}"))
      raise ActorError.new(message, code: code)
    end

    def runs
      GlossaryExtractionRun.where(organisation_id: @organisation.id)
    end

    # By the row: a run that moved or ended in the meantime keeps its state.
    def end_stale_runs
      runs.where(status: GlossaryExtractionRun::ACTIVE_STATUSES).find_each do |run|
        run.mark_stale! if run.stale?
      end
    end

    # The job id is a fresh UUID, so the one unique index a start can hit is the
    # one active run per organisation.
    def create_run
      GlossaryExtractionRun.create!(
        organisation: @organisation, started_by: current_user, status: 'queued', job_id: SecureRandom.uuid,
        scope: { 'kind' => Glossary::Extraction::KIND, 'everything' => @everything, 'since' => nil }
      )
    rescue ActiveRecord::RecordNotUnique
      refuse(:run_active)
    end
  end
end
