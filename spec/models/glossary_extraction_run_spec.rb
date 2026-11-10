# frozen_string_literal: true

require 'rails_helper'

# One run of the glossary extraction (K5b): tenant bound, one active run per
# organisation (the partial unique index one_active_glossary_extraction_run),
# stale when an active run stops moving, and mark_failed! ends an active run
# once, by the row and not by the copy in memory. Invented words only.
RSpec.describe GlossaryExtractionRun, :ci_guard, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:connection) { ActiveRecord::Base.connection }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def run_with(**attributes)
    create(:glossary_extraction_run, organisation: organisation, **attributes)
  end

  def built_with(**attributes)
    build(:glossary_extraction_run, organisation: organisation, **attributes)
  end

  it 'is bound to the tenant' do
    mine = run_with
    theirs = ActsAsTenant.with_tenant(other_organisation) { create(:glossary_extraction_run, organisation: other_organisation) }

    expect(described_class.all).to contain_exactly(mine)
    expect(described_class.unscoped.where(id: theirs.id)).to exist
  end

  it 'is asked through the glossary policy' do
    expect(Pundit::PolicyFinder.new(described_class.new).policy).to eq(GlossaryPolicy)
  end

  describe 'the status' do
    it 'is queued unless set, and knows four states' do
      expect(described_class.new.status).to eq('queued')
      expect(described_class::STATUSES).to eq(%w[queued running succeeded failed])
      expect(described_class::ACTIVE_STATUSES).to eq(%w[queued running])
      expect(built_with(status: 'paused')).not_to be_valid
      expect(built_with(status: nil)).not_to be_valid
    end

    it 'stores every known status in the database' do
      run = run_with

      Prosopite.pause do
        described_class::STATUSES.each do |status|
          run.update_column(:status, status)
          expect(run.reload.status).to eq(status)
        end
      end
    end

    it 'is held by the database too' do
      run = run_with

      expect { run.update_column(:status, 'bogus') }
        .to raise_error(ActiveRecord::StatementInvalid, /glossary_extraction_runs_status_known/)
    end
  end

  describe 'one active run per organisation' do
    it 'refuses a second queued or running run of the same organisation' do
      run_with

      expect { run_with }.to raise_error(ActiveRecord::RecordNotUnique, /one_active_glossary_extraction_run/)
      expect { run_with(status: 'running') }.to raise_error(ActiveRecord::RecordNotUnique, /one_active_glossary_extraction_run/)
    end

    it 'refuses a second active run that only becomes active later' do
      run_with(status: 'running')
      finished = run_with(status: 'succeeded')

      expect { finished.update_column(:status, 'queued') }
        .to raise_error(ActiveRecord::RecordNotUnique, /one_active_glossary_extraction_run/)
    end

    it 'lets runs that succeeded or failed stand beside an active one' do
      run_with(status: 'succeeded')
      run_with(status: 'failed', error_code: 'ai_unavailable')
      run_with(status: 'running')
      run_with(status: 'succeeded')

      expect(described_class.where(organisation: organisation).count).to eq(4)
    end

    it 'does not count the active run of another organisation' do
      ActsAsTenant.with_tenant(other_organisation) { create(:glossary_extraction_run, organisation: other_organisation) }

      expect { run_with }.not_to raise_error
    end

    it 'frees the place once the active run has failed' do
      run = run_with(status: 'running')
      run.mark_failed!('interrupted')

      expect { run_with }.not_to raise_error
    end
  end

  describe '#active? and #stale?' do
    it 'is active while queued or running' do
      expect(described_class::STATUSES.select { |status| built_with(status: status).active? }).to eq(%w[queued running])
    end

    it 'is stale when an active run has not moved for longer than STALE_AFTER' do
      expect(described_class::STALE_AFTER).to eq(10.minutes)

      freeze_time do
        long_ago = described_class::STALE_AFTER.ago - 1.second

        expect(built_with(status: 'queued', updated_at: long_ago)).to be_stale
        expect(built_with(status: 'running', updated_at: long_ago)).to be_stale
        expect(built_with(status: 'running', updated_at: described_class::STALE_AFTER.ago)).not_to be_stale
        expect(built_with(status: 'succeeded', updated_at: long_ago)).not_to be_stale
        expect(built_with(status: 'failed', updated_at: long_ago)).not_to be_stale
      end
    end

    it 'reads the time of the row' do
      run = run_with(status: 'running')
      expect(run).not_to be_stale

      run.update_column(:updated_at, (described_class::STALE_AFTER + 1.minute).ago)
      expect(run.reload).to be_stale
    end

    it 'is not stale before it was saved' do
      expect(described_class.new).not_to be_stale
    end
  end

  describe '#mark_stale!' do
    %w[queued running].each do |status|
      [-1, 0, 1].each do |seconds_from_boundary|
        it "checks the stale boundary for #{status} at #{seconds_from_boundary} seconds" do
          freeze_time do
            run = run_with(status: status, updated_at: described_class::STALE_AFTER.ago + seconds_from_boundary.seconds)
            stored = run.reload.attributes

            expect(run.mark_stale!).to be(seconds_from_boundary.negative?)

            if seconds_from_boundary.negative?
              expect(run).to have_attributes(status: 'failed', error_code: 'stale', finished_at: Time.current, updated_at: Time.current)
              expect(run.changed?).to be(false)
              expect(run.reload).to have_attributes(status: 'failed', error_code: 'stale', finished_at: Time.current, updated_at: Time.current)
              expect(run.mark_stale!).to be(false)
            else
              expect(run.reload.attributes).to eq(stored)
            end
          end
        end
      end
    end

    it 'leaves completed runs unchanged even when their timestamp is old' do
      Prosopite.pause do
        %w[succeeded failed].each do |status|
          run = run_with(status: status, error_code: (status == 'failed' ? 'interrupted' : nil),
                         finished_at: 1.hour.ago, updated_at: 1.hour.ago)
          stored = run.reload.attributes

          expect(run.mark_stale!).to be(false)
          expect(run.reload.attributes).to eq(stored)
        end
      end
    end

    %w[queued running].each do |status|
      it "keeps a refreshed #{status} row even when the instance is stale" do
        freeze_time do
          run = run_with(status: status, updated_at: 1.hour.ago)
          described_class.where(id: run.id).update_all(status: 'running', updated_at: Time.current)

          expect(run).to be_stale
          expect(run.mark_stale!).to be(false)
          expect(run.reload).to have_attributes(status: 'running', updated_at: Time.current, error_code: nil, finished_at: nil)
        end
      end
    end
  end

  describe '#mark_failed!' do
    it 'fails an active run once, with the code and the time it ended' do
      run = run_with(status: 'running', updated_at: 1.hour.ago)

      freeze_time do
        expect(run.mark_failed!('interrupted')).to be(true)
        expect([run.status, run.error_code, run.finished_at]).to eq(['failed', 'interrupted', Time.current])
        expect(run.changed?).to be(false)

        run.reload
        expect([run.status, run.error_code, run.finished_at, run.updated_at])
          .to eq(['failed', 'interrupted', Time.current, Time.current])
      end
      expect(run.mark_failed!('stale')).to be(false)
      expect(run.reload.error_code).to eq('interrupted')
    end

    it 'fails a queued run too' do
      run = run_with

      expect(run.mark_failed!('starter_inactive')).to be(true)
      expect(run.reload).to be_failed
    end

    it 'leaves a run that already succeeded or failed as it is, and does not raise' do
      Prosopite.pause do
        %w[succeeded failed].each do |status|
          run = run_with(status: status, error_code: (status == 'failed' ? 'ai_unavailable' : nil), finished_at: 1.hour.ago)
          stored = run.reload.attributes

          expect(run.mark_failed!('stale')).to be(false)
          expect(run.reload.attributes).to eq(stored)
        end
      end
    end

    it 'asks the row, not the copy in memory' do
      run = run_with
      described_class.unscoped.where(id: run.id).update_all(status: 'succeeded')

      expect(run).to be_queued
      expect(run.mark_failed!('interrupted')).to be(false)
      expect(run.reload).to be_succeeded
      expect(run.error_code).to be_nil
    end

    it 'fails only from the states it is given' do
      run = run_with(status: 'running')

      expect(run.mark_failed!('stale', from: %w[queued])).to be(false)
      expect(run.reload).to be_running
      expect(run.mark_failed!('stale', from: %w[running])).to be(true)
      expect(run.reload.error_code).to eq('stale')
    end

    it 'refuses a code it does not know, before it writes anything' do
      run = run_with

      expect { run.mark_failed!('exploded') }.to raise_error(ArgumentError)
      expect(run.reload).to be_queued
    end
  end

  describe 'validations' do
    it 'requires a job id' do
      run = built_with(job_id: nil)

      expect(run).not_to be_valid
      expect(run.errors.details[:job_id]).to include(error: :blank)
    end

    it 'refuses a job id twice, in the database' do
      run_with(job_id: 'zorbel-job', status: 'succeeded')

      expect { run_with(job_id: 'zorbel-job', status: 'failed') }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'knows the error codes, and no code is fine' do
      expect(described_class::ERROR_CODES).to eq(%w[starter_inactive ai_unavailable ai_disabled not_configured quota_exceeded
                                                    invalid_key provider_error parse_error interrupted stale internal_error
                                                    document_unavailable])
      described_class::ERROR_CODES.each { |code| expect(built_with(error_code: code)).to be_valid }
      expect(built_with(error_code: nil)).to be_valid

      unknown = built_with(error_code: 'exploded')
      expect(unknown).not_to be_valid
      expect(unknown.errors.details[:error_code]).to include(a_hash_including(error: :inclusion))
    end

    it 'knows two scope kinds, the whole organisation and one document, and no other' do
      expect(described_class::SCOPE_KINDS).to eq(%w[organisation document])
      expect(built_with(scope: { 'kind' => 'organisation' })).to be_valid

      [{ 'kind' => 'ticket' }, {}, ['organisation'], nil].each do |scope|
        run = built_with(scope: scope)
        expect(run).not_to be_valid, scope.inspect
        expect(run.errors.details[:scope]).to include(a_hash_including(error: :inclusion))
      end
    end

    it 'reads a scope and stats written with symbol keys as the database gives them back' do
      run = built_with(scope: { kind: 'organisation', everything: true, since: nil }, stats: { sources: { tickets: 3 } })

      expect(run.scope).to eq('kind' => 'organisation', 'everything' => true, 'since' => nil)
      expect(run.stats).to eq('sources' => { 'tickets' => 3 })
      expect(run).to be_valid
      expect(run).to be_everything
    end

    it 'starts with empty stats' do
      expect(described_class.new.stats).to eq({})
    end
  end

  # K5c: a run over one document reads the version its scope names. The
  # version is a row of an organisation, so the run holds it to its own, read
  # without the tenant's scope (the rule of TermCorrection).
  describe 'a run over one document' do
    let(:project) { create(:project, organisation: organisation) }

    def version_in(owner, project)
      document = create(:document, organisation: owner, project: project)
      create(:document_version, organisation: owner, document: document, title: 'Zorbel-Handbuch')
    end

    let(:version) { version_in(organisation, project) }

    def document_scope(version_id)
      { 'kind' => 'document', 'document_version_id' => version_id, 'since' => nil }
    end

    it 'names a version of its own organisation' do
      run = built_with(scope: document_scope(version.id))

      expect(run).to be_valid
      expect(run).to be_document
      expect(run.document_version_id).to eq(version.id)
      expect(run).not_to be_everything
    end

    it 'needs a version: none, an empty or malformed id, or the id of no row is no document run' do
      Prosopite.pause do
        [document_scope(nil), document_scope(''), { 'kind' => 'document' }, document_scope(SecureRandom.uuid),
         document_scope('zorbel'), document_scope(['zorbel'])].each do |scope|
          run = built_with(scope: scope)
          expect(run).not_to be_valid, scope.inspect
          expect(run.errors.details[:scope]).to include(a_hash_including(error: :invalid))
        end
      end
    end

    it 'refuses a version of another organisation, also when no tenant is set' do
      foreign = ActsAsTenant.with_tenant(other_organisation) do
        version_in(other_organisation, create(:project, organisation: other_organisation))
      end

      expect(built_with(scope: document_scope(foreign.id))).not_to be_valid
      ActsAsTenant.without_tenant do
        run = described_class.new(organisation: organisation, job_id: 'zorbel-job', scope: document_scope(foreign.id))
        expect(run).not_to be_valid
        expect(run.errors.details[:scope]).to include(a_hash_including(error: :invalid))
      end
    end

    it 'lets a run over the organisation name no version' do
      run = built_with(scope: { 'kind' => 'organisation', 'everything' => true, 'document_version_id' => version.id })

      expect(run).not_to be_valid
      expect(run.errors.details[:scope]).to include(a_hash_including(error: :invalid))
      expect(built_with(scope: { 'kind' => 'organisation', 'document_version_id' => nil })).to be_valid
    end

    it 'is no document run over the organisation, and names no version there' do
      run = built_with(scope: { 'kind' => 'organisation', 'everything' => true })

      expect(run).not_to be_document
      expect(run.document_version_id).to be_nil
      expect(described_class.new(scope: nil)).not_to be_document
    end
  end

  describe '#everything?' do
    it 'is true only for a scope that says so' do
      expect(built_with(scope: { 'kind' => 'organisation', 'everything' => true })).to be_everything
      expect(built_with(scope: { 'kind' => 'organisation', 'everything' => false })).not_to be_everything
      expect(built_with(scope: { 'kind' => 'organisation', 'everything' => 'true' })).not_to be_everything
      expect(built_with(scope: { 'kind' => 'organisation' })).not_to be_everything
    end
  end

  describe 'deleting' do
    it 'says the delete rules in the foreign keys' do
      keys = connection.foreign_keys('glossary_extraction_runs').to_h { |key| [key.column, [key.to_table, key.on_delete]] }

      expect(keys).to eq('organisation_id' => ['organisations', :cascade], 'started_by_id' => ['users', :nullify])
    end

    it 'the starter leaves the run without a starter' do
      starter = create(:user)
      run = run_with(started_by: starter)

      User.where(id: starter.id).delete_all

      expect(run.reload.started_by_id).to be_nil
    end
  end
end
