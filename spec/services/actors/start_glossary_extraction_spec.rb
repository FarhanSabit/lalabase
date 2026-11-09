# frozen_string_literal: true

require 'rails_helper'

# What: Actors::StartGlossaryExtraction, the write behind the start button of the
#   glossary extraction (K5b): one active run per organisation, a run that has not
#   moved for STALE_AFTER ends as stale, no run without the right or without AI,
#   and the job only after the commit.
# Type: Actor spec. The AI gate is stubbed per key, as in the classifier spec, and
#   once read from the organisation's real settings.
# Why: a start costs the organisation up to MAX_AI_CALLS model calls, and a second
#   run beside the first would pay twice for the same proposals.
RSpec.describe Actors::StartGlossaryExtraction, :ci_guard do
  include ActiveJob::TestHelper

  let(:organisation) { create(:organisation) }

  around do |example|
    original = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
    ActiveJob::Base.queue_adapter = original
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def role_with(*actions, title: nil)
    role = create(:role, organisation: organisation, **{ title: title }.compact)
    actions.each { |action| create(:permission, role: role, category: 'glossary', action: action, allowed: true) }
    role
  end

  def member_with(role, active: true)
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: role, active: active)
    User.find(user.id)
  end

  let(:manager) { member_with(role_with('manage_glossary')) }
  let(:availability) { Lalabase::Llm::FeatureRegistry::Availability.new(available: true) }

  before do
    allow(organisation).to receive(:ai_available_for?).with(:glossary_extraction).and_return(availability)
  end

  def start(user = manager, **options)
    described_class.call(organisation: organisation, current_user: user, **options)
  end

  def runs
    GlossaryExtractionRun.where(organisation: organisation)
  end

  it 'creates a queued run and enqueues its job only after the commit, under the run job id' do
    result = nil
    ActiveRecord::Base.transaction do
      result = start
      expect(enqueued_jobs).to be_empty
    end

    run = result.resource
    expect(result).to be_success
    expect(run).to be_persisted
    expect(run).to have_attributes(status: 'queued', organisation_id: organisation.id, started_by_id: manager.id,
                                   error_code: nil, finished_at: nil)
    expect(run.scope).to eq('kind' => 'organisation', 'everything' => false, 'since' => nil)
    expect(run.job_id).to be_present
    expect(enqueued_jobs.sole).to include(job: Glossary::ExtractionJob, 'job_id' => run.job_id)
    expect(Glossary::ExtractionJob).to have_been_enqueued.with(run_id: run.id)
  end

  it 'puts everything into the scope when asked to read everything' do
    expect(start(everything: true).resource.scope).to include('everything' => true)
  end

  it 'reads only true as everything, so a stray value cannot start a full and costly run' do
    expect(start(everything: 'true').resource.scope).to include('everything' => false)
  end

  it 'locks the organisation row first, so two starts of one organisation wait for each other' do
    allow(organisation).to receive(:lock!).and_call_original

    start

    expect(organisation).to have_received(:lock!)
  end

  it 'lets an account admin start without a permission row' do
    expect(start(member_with(role_with(title: Role::ACCOUNT_ADMIN_TITLE)))).to be_success
  end

  describe 'one active run per organisation' do
    %w[queued running].each do |status|
      it "refuses a second start while a run is #{status}" do
        create(:glossary_extraction_run, organisation: organisation, status: status)

        result = start

        expect(result).not_to be_success
        expect(result.code).to eq(:run_active)
        expect(result.errors).to eq([I18n.t('controllers.glossary.runs.run_active')])
        expect(runs.count).to eq(1)
        expect(enqueued_jobs).to be_empty
      end
    end

    it 'ends an active run that has not moved for STALE_AFTER as stale and starts a new one' do
      old = create(:glossary_extraction_run, :running, organisation: organisation)
      old.update_columns(updated_at: (GlossaryExtractionRun::STALE_AFTER + 1.minute).ago)

      result = start

      expect(result).to be_success
      expect(old.reload).to have_attributes(status: 'failed', error_code: 'stale')
      expect(old.finished_at).to be_present
      expect(result.resource).to have_attributes(status: 'queued')
      expect(enqueued_jobs.size).to eq(1)
    end

    it 'keeps an active run that moved within STALE_AFTER' do
      old = create(:glossary_extraction_run, :running, organisation: organisation)
      old.update_columns(updated_at: (GlossaryExtractionRun::STALE_AFTER - 1.minute).ago)

      expect(start.code).to eq(:run_active)
      expect(old.reload.status).to eq('running')
    end

    it 'does not count a run of another organisation' do
      other = create(:organisation)
      ActsAsTenant.with_tenant(other) { create(:glossary_extraction_run, organisation: other) }

      expect(start).to be_success
    end

    it 'answers run_active when the unique index catches a start that raced past the check' do
      allow(GlossaryExtractionRun).to receive(:create!).and_wrap_original do |original, attributes|
        # Another start writes its run between the check and this insert.
        original.call(attributes.merge(job_id: SecureRandom.uuid))
        original.call(attributes)
      end

      result = start

      expect(result.code).to eq(:run_active)
      expect(runs.count).to eq(0)
      expect(enqueued_jobs).to be_empty
    end
  end

  describe 'AI' do
    let(:availability) do
      Lalabase::Llm::FeatureRegistry::Availability.new(available: false, reason: :no_credential,
                                                       required_provider: 'openai')
    end

    it 'refuses with the hint of the registry when the extraction has no AI, and writes no run' do
      result = start

      expect(result.code).to eq(:ai_unavailable)
      expect(result.errors).to eq([Lalabase::Llm::FeatureRegistry.unavailable_hint(availability, organisation)])
      expect(runs).to be_empty
      expect(enqueued_jobs).to be_empty
    end

    it 'asks the real gate with its own key' do
      allow(organisation).to receive(:ai_available_for?).and_call_original
      organisation.update_columns(ai_enabled: false)

      result = start

      expect(organisation).to have_received(:ai_available_for?).with(:glossary_extraction)
      expect(result.code).to eq(:ai_unavailable)
      expect(runs).to be_empty
    end
  end

  describe 'the right' do
    it 'refuses a member who may only view the glossary' do
      result = start(member_with(role_with('view_glossary')))

      expect(result.code).to eq(:forbidden)
      expect(result.errors).to eq([I18n.t('controllers.glossary.runs.forbidden')])
      expect(runs).to be_empty
      expect(enqueued_jobs).to be_empty
    end

    it 'refuses a deactivated member, also with the manage right' do
      result = start(member_with(role_with('manage_glossary'), active: false))

      expect(result.code).to eq(:forbidden)
      expect(runs).to be_empty
    end

    it 'refuses before it ends a stale run' do
      old = create(:glossary_extraction_run, :running, organisation: organisation)
      old.update_columns(updated_at: (GlossaryExtractionRun::STALE_AFTER + 1.minute).ago)

      expect(start(member_with(role_with('view_glossary'))).code).to eq(:forbidden)
      expect(old.reload.status).to eq('running')
    end
  end
end

# A worker commits after the starter reads a stale snapshot. Its write must
# survive a refused start, so these examples use a separate database connection.
RSpec.describe Actors::StartGlossaryExtraction, 'beside a worker update', type: :service do
  self.use_transactional_tests = false

  around do |example|
    original = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
  ensure
    ActiveJob::Base.queue_adapter = original
  end

  before do
    DatabaseCleaner.clean
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.start
    Prosopite.pause
  end

  after do
    Prosopite.resume
    ActsAsTenant.current_tenant = nil
  end

  %w[queued running].each do |status|
    it "keeps a #{status} run refreshed after the stale snapshot was read" do
      organisation = create(:organisation)
      ActsAsTenant.current_tenant = organisation
      role = create(:role, organisation: organisation, title: Role::ACCOUNT_ADMIN_TITLE)
      manager = create(:user)
      create(:membership, organisation: organisation, user: manager, role: role)
      run = create(:glossary_extraction_run, organisation: organisation, status: status,
                                             updated_at: (GlossaryExtractionRun::STALE_AFTER + 1.minute).ago)
      allow(organisation).to receive(:ai_available_for?).with(:glossary_extraction).and_return(double(available?: true))
      worker = nil
      refreshed_at = nil
      allow_any_instance_of(GlossaryExtractionRun).to receive(:stale?).and_wrap_original do |original|
        original.call.tap do |stale|
          next unless original.receiver.id == run.id && stale

          # The job claim and extraction heartbeat both refresh updated_at.
          worker = Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              GlossaryExtractionRun.unscoped.where(id: run.id, status: status)
                                   .update_all(status: 'running', updated_at: Time.current)
              GlossaryExtractionRun.unscoped.find(run.id).updated_at
            end
          end
          raise 'worker update did not finish' unless worker.join(5)

          refreshed_at = worker.value
        end
      end

      result = described_class.call(organisation: organisation, current_user: manager)

      expect(refreshed_at).to be_present
      expect(result.code).to eq(:run_active)
      expect(result).not_to be_success
      expect(run.reload).to have_attributes(status: 'running', updated_at: refreshed_at, error_code: nil, finished_at: nil)
      expect(GlossaryExtractionRun.where(organisation: organisation).count).to eq(1)
      expect(enqueued_jobs).to be_empty
    ensure
      worker&.kill if worker&.alive?
      worker&.join
    end
  end
end
