# frozen_string_literal: true

require 'rails_helper'

# What: Glossary::ExtractionJob, the background job around one run of the glossary
#   extraction (K5b): it loads the run without a tenant, works within the run's
#   organisation, claims a queued run once, and ends a run that is left running.
# Type: Job spec. Glossary::Extraction is stubbed; its own spec covers the run.
# Why: Solid Queue dequeues with no tenant, a job can be delivered twice, and a
#   worker can die. None of these may run the extraction twice (the provider bills
#   every call) or leave a run that blocks every later start.
RSpec.describe Glossary::ExtractionJob, :ci_guard, type: :job do
  include ActiveJob::TestHelper

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, organisation: organisation) }
  let(:run) do
    ActsAsTenant.with_tenant(organisation) do
      create(:glossary_extraction_run, organisation: organisation, started_by: user)
    end
  end

  # What the extraction saw when it ran: the tenant, the run's status, the run.
  let(:seen) { [] }

  before do
    run
    ActsAsTenant.current_tenant = nil
    allow(Glossary::Extraction).to receive(:call) do |run:|
      seen << [ActsAsTenant.current_tenant, run.status, run.id]
      run.class.unscoped.where(id: run.id).update_all(status: 'succeeded', finished_at: Time.current)
    end
  end

  after { ActsAsTenant.current_tenant = nil }

  def perform(job = described_class.new(run_id: run.id))
    job.perform_now
  end

  def stored
    ActsAsTenant.without_tenant { GlossaryExtractionRun.find(run.id) }
  end

  it 'uses the default queue' do
    expect(described_class.new(run_id: run.id).queue_name).to eq('default')
  end

  it 'loads the run without a tenant and runs the extraction within its organisation, on the claimed run' do
    expect(ActsAsTenant.current_tenant).to be_nil

    perform

    expect(seen).to eq([[organisation, 'running', run.id]])
    expect(stored.status).to eq('succeeded')
    expect(ActsAsTenant.current_tenant).to be_nil
  end

  it 'claims a queued run once: a second perform of the same job does nothing' do
    job = described_class.new(run_id: run.id)

    perform(job)
    perform(job)

    expect(Glossary::Extraction).to have_received(:call).once
    expect(stored).to have_attributes(status: 'succeeded', error_code: nil)
  end

  it 'claims no run that has finished already' do
    run.update_columns(status: 'failed', error_code: 'stale', finished_at: Time.current)

    perform

    expect(Glossary::Extraction).not_to have_received(:call)
    expect(stored).to have_attributes(status: 'failed', error_code: 'stale')
  end

  it 'marks the run failed as internal_error when the extraction raises, logs the class only and raises nothing' do
    allow(Glossary::Extraction).to receive(:call).and_raise(RuntimeError, 'Quarnix stand im Ticket')
    allow(Rails.logger).to receive(:error)

    expect { perform }.not_to raise_error

    expect(stored).to have_attributes(status: 'failed', error_code: 'internal_error')
    expect(stored.finished_at).to be_present
    expect(Rails.logger).to have_received(:error).with(a_string_including('RuntimeError'))
    expect(Rails.logger).not_to have_received(:error).with(a_string_including('Quarnix'))
  end

  it 'marks a run the extraction left running as interrupted' do
    allow(Glossary::Extraction).to receive(:call)

    perform

    expect(stored).to have_attributes(status: 'failed', error_code: 'interrupted')
  end

  it 'marks a run it finds running (its worker is gone) as interrupted and does not extract again' do
    run.update_columns(status: 'running')

    perform

    expect(Glossary::Extraction).not_to have_received(:call)
    expect(stored).to have_attributes(status: 'failed', error_code: 'interrupted')
  end

  it 'leaves the run alone while another worker holds its lock' do
    other = ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.new(ActiveRecord::Base.connection_db_config.configuration_hash)
    key = described_class.execution_lock_key(run.id)
    # SELECT 1 FROM: the function returns void, which ActiveRecord warns about as an unknown OID.
    other.select_value("SELECT 1 FROM pg_advisory_lock(#{key})")

    perform

    expect(Glossary::Extraction).not_to have_received(:call)
    expect(stored.status).to eq('queued')
  ensure
    other&.select_value("SELECT pg_advisory_unlock(#{key})")
    other&.disconnect!
  end

  it 'discards a job whose run is gone' do
    allow(Rails.logger).to receive(:warn)

    expect { described_class.perform_now(run_id: SecureRandom.uuid) }.not_to raise_error

    expect(Glossary::Extraction).not_to have_received(:call)
    expect(Rails.logger).to have_received(:warn).with(a_string_including('Glossary::ExtractionJob discarded'))
  end

  describe '.enqueue_run' do
    around do |example|
      original = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      example.run
      ActiveJob::Base.queue_adapter = original
    end

    it "enqueues the job for the run under the run's job id" do
      described_class.enqueue_run(run: run)

      job = enqueued_jobs.sole
      expect(job).to include(job: described_class, 'job_id' => run.job_id)
      expect(described_class).to have_been_enqueued.with(run_id: run.id)
    end

    it 'marks the run failed when the job cannot be enqueued' do
      allow_any_instance_of(described_class).to receive(:enqueue).and_return(false)
      allow(Rails.logger).to receive(:error)

      described_class.enqueue_run(run: run)

      expect(stored).to have_attributes(status: 'failed', error_code: 'internal_error')
      expect(Rails.logger).to have_received(:error).with(a_string_including('ActiveJob::EnqueueError'))
    end
  end
end
