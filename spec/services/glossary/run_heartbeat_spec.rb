# frozen_string_literal: true

require 'rails_helper'

# What: Glossary::RunHeartbeat, the thread that touches a running extraction run
#   while its worker waits on the model (K5b).
# Type: Service spec against the real row, with a short beat.
# Why: a call to the provider can take longer than GlossaryExtractionRun::STALE_AFTER.
#   Without a beat a second start ends the run as stale while the answer is still
#   coming, the answer is thrown away, and the next run pays for the same candidates
#   again. A beat that goes on after the block, or touches a run that is no longer
#   running, would undo exactly the stale rule it is meant to serve.
RSpec.describe Glossary::RunHeartbeat, :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:run) { create(:glossary_extraction_run, :running, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def age!
    run.class.unscoped.where(id: run.id).update_all(updated_at: 1.hour.ago)
  end

  def stored_updated_at
    ActsAsTenant.without_tenant { GlossaryExtractionRun.unscoped.where(id: run.id).pick(:updated_at) }
  end

  it 'beats every fifth of STALE_AFTER, so one lost beat leaves four' do
    expect(described_class::EVERY).to eq(GlossaryExtractionRun::STALE_AFTER / 5)
    expect(described_class::EVERY).to be < GlossaryExtractionRun::STALE_AFTER
  end

  it 'touches the running run while the block runs and answers what the block answers' do
    age!

    answer = described_class.call(run: run, every: 0.02) do
      sleep 0.15
      :answer
    end

    expect(answer).to eq(:answer)
    expect(stored_updated_at).to be > 1.minute.ago
  end

  it 'stops beating once the block has ended' do
    described_class.call(run: run, every: 0.02) { sleep 0.05 }
    age!
    sleep 0.1

    expect(stored_updated_at).to be < 30.minutes.ago
  end

  it 'stops beating when the block raises, and raises on' do
    expect do
      described_class.call(run: run, every: 0.02) do
        sleep 0.05
        raise 'provider down'
      end
    end.to raise_error('provider down')
    age!
    sleep 0.1

    expect(stored_updated_at).to be < 30.minutes.ago
  end

  it 'leaves a run that is no longer running as it is, in the database and in memory' do
    run.class.unscoped.where(id: run.id).update_all(status: 'failed', error_code: 'stale', updated_at: 1.hour.ago)
    before = stored_updated_at
    in_memory = run.attributes

    described_class.call(run: run, every: 0.02) { sleep 0.1 }

    expect(stored_updated_at).to eq(before)
    expect(run.attributes).to eq(in_memory)
  end

  it 'touches only this run' do
    elsewhere = create(:organisation)
    other = ActsAsTenant.with_tenant(elsewhere) { create(:glossary_extraction_run, :running, organisation: elsewhere) }
    other.class.unscoped.where(id: other.id).update_all(updated_at: 1.hour.ago)

    described_class.call(run: run, every: 0.02) { sleep 0.1 }

    expect(ActsAsTenant.without_tenant { GlossaryExtractionRun.unscoped.where(id: other.id).pick(:updated_at) }).to be < 30.minutes.ago
  end
end
