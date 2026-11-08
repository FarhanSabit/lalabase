# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

# Committed fixtures and separate PostgreSQL connections: hold the recorder
# between its term lookup and INSERT, where a delete used to invalidate the FK
# and roll back the meeting. Observe the competing backend waiting on THIS
# recorder, then let both real writes finish and check the surviving data.
RSpec.describe TermApplication, :ci_guard, type: :model do
  self.use_transactional_tests = false

  before do
    @workers = []
    @releases = []
    DatabaseCleaner.clean
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.start
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
  end

  after do
    @releases.each { |release| release << true }
    @workers.each do |worker|
      worker.join(2) || worker.kill.join(2)
    end
    Prosopite.resume
    ActsAsTenant.current_tenant = nil
  end

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:term) { create(:glossary_term, organisation: organisation, term: 'Lala Base') }
  let(:target) { create(:glossary_term, organisation: organisation, term: 'Lalabase') }
  let(:entries) { [{ heard: 'lala bass', term: term.term, count: 3 }] }

  def intake
    Meetings::Intake.new(
      organisation: organisation, viewer: user,
      reach: PersonalAccessToken::Reach.new(project_ids_by_organisation: { organisation.id => [project.id] }),
      input: { project_id: project.id, title: 'Glossary recording', occurred_at: Time.current.iso8601,
               transcript: 'Lala Base bleibt im Protokoll.', glossary_replacements: entries }
    )
  end

  def release_queue
    Queue.new.tap { |queue| @releases << queue }
  end

  def await(queue)
    Timeout.timeout(10) { queue.pop }
  end

  def in_connection(&block)
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        ActsAsTenant.with_tenant(organisation) { block.call(connection) }
      ensure
        Current.reset
      end
    rescue StandardError => e
      # Re-raise in the example, after joining, so failed workers cannot escape
      # cleanup or leave the main thread waiting indefinitely for their value.
      e
    end
    @workers << worker
    worker
  end

  def finish(worker)
    expect(worker.join(10)).to be(worker), 'database worker did not finish'
    result = worker.value
    raise result if result.is_a?(Exception)

    result
  end

  def expect_blocked_by(worker, waiter_pid:, recorder_pid:)
    Timeout.timeout(5) do
      ActiveRecord::Base.uncached do
        loop do
          blocked = ActiveRecord::Base.connection.select_value(
            "SELECT #{Integer(recorder_pid)} = ANY(pg_blocking_pids(#{Integer(waiter_pid)}))"
          )
          return if blocked

          unless worker.alive?
            finish(worker)
            raise 'glossary write completed before the recorder released its term lock'
          end
          Thread.pass
        end
      end
    end
  end

  # The wrappers only pause execution; lookup, INSERT, locks, delete/merge and
  # commit all run against PostgreSQL. The second pause is AFTER record! returns,
  # proving its transaction joins Intake's and keeps the lock until outer commit.
  def race_recording(recording:, outer_transaction: false, &mutation)
    looked_up = Queue.new
    insert_release = release_queue
    recorded = Queue.new
    commit_release = release_queue
    allow(described_class).to receive(:insert_all!).and_wrap_original do |original, rows, **options|
      looked_up << [ActiveRecord::Base.connection.raw_connection.backend_pid, rows]
      await(insert_release)
      original.call(rows, **options)
    end
    if outer_transaction
      allow(described_class).to receive(:record!).and_wrap_original do |original, **arguments|
        original.call(**arguments).tap do |count|
          recorded << count
          await(commit_release)
        end
      end
    end

    recorder = in_connection { recording.call }
    recorder_pid, rows = await(looked_up)
    expect(rows.sole[:glossary_term_id]).to eq(term.id)
    mutation_started = Queue.new
    writer = in_connection do |connection|
      mutation_started << connection.raw_connection.backend_pid
      mutation.call
    end
    waiter_pid = await(mutation_started)
    expect(waiter_pid).not_to eq(recorder_pid)
    expect_blocked_by(writer, waiter_pid: waiter_pid, recorder_pid: recorder_pid)

    insert_release << true
    if outer_transaction
      expect(await(recorded)).to eq(1)
      expect_blocked_by(writer, waiter_pid: waiter_pid, recorder_pid: recorder_pid)
      expect(Meeting.where(id: rows.sole[:meeting_id])).not_to exist
      expect(described_class.where(meeting_id: rows.sole[:meeting_id])).not_to exist
      commit_release << true
    end
    [finish(recorder), finish(writer)]
  end

  def expect_preserved(meeting, glossary_term_id:)
    expect(meeting.reload).to have_attributes(organisation_id: organisation.id, project_id: project.id,
                                              creator_id: user.id, transcript: 'Lala Base bleibt im Protokoll.')
    expect(meeting.term_applications.reload.sole).to have_attributes(
      organisation_id: organisation.id, project_id: project.id, glossary_term_id: glossary_term_id,
      term: 'Lala Base', heard: 'lala bass', normalized_heard: 'lala bass', replaced_count: 3, source: 'device'
    )
  end

  it 'keeps an intake meeting and its application when deletion arrives between lookup and insert' do
    submission = intake
    expect(submission.refusal).to be_nil

    saved, deleted = race_recording(recording: -> { submission.save }, outer_transaction: true) do
      Actors::DestroyGlossaryTerm.call(term: GlossaryTerm.find(term.id), current_user: user)
    end

    expect(saved).to be_success
    expect(deleted).to be_success
    expect(GlossaryTerm.where(id: term.id)).not_to exist
    expect(Meeting.count).to eq(1)
    expect_preserved(submission.meeting, glossary_term_id: nil)
  end

  it 'lets a waiting merge carry the newly recorded application to its target after intake commits' do
    submission = intake
    destination = target
    expect(submission.refusal).to be_nil

    saved, merged = race_recording(recording: -> { submission.save }, outer_transaction: true) do
      Actors::MergeGlossaryTerms.call(source: GlossaryTerm.find(term.id), target: GlossaryTerm.find(destination.id),
                                      current_user: user)
    end

    expect(saved).to be_success
    expect(merged).to be_success
    expect(GlossaryTerm.where(id: term.id)).not_to exist
    expect(destination.reload.term).to eq('Lalabase')
    expect(Meeting.count).to eq(1)
    expect_preserved(submission.meeting, glossary_term_id: destination.id)
  end

  it 'protects the lookup through insert even when record! has no surrounding transaction' do
    meeting = create(:meeting, organisation: organisation, project: project, creator: user,
                               transcript: 'Lala Base bleibt im Protokoll.')
    replacements = entries

    written, deleted = race_recording(recording: -> { described_class.record!(meeting: meeting, entries: replacements) }) do
      Actors::DestroyGlossaryTerm.call(term: GlossaryTerm.find(term.id), current_user: user)
    end

    expect(written).to eq(1)
    expect(deleted).to be_success
    expect(GlossaryTerm.where(id: term.id)).not_to exist
    expect_preserved(meeting, glossary_term_id: nil)
  end

  it 'keeps the reported spelling with no reference when the term was deleted before lookup' do
    submission = intake
    deleted = in_connection do
      Actors::DestroyGlossaryTerm.call(term: GlossaryTerm.find(term.id), current_user: user)
    end
    expect(finish(deleted)).to be_success

    expect(submission.save).to be_success

    expect(GlossaryTerm.where(id: term.id)).not_to exist
    expect(Meeting.count).to eq(1)
    expect_preserved(submission.meeting, glossary_term_id: nil)
  end
end
