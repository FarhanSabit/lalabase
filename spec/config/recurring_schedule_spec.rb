# frozen_string_literal: true

require 'rails_helper'
require 'fugit'

# What: config/recurring.yml — Solid Queue recurring schedule drift guard.
# Type: Config spec.
# Why:  A `class:` entry referencing a renamed/deleted job fails only AT
#       RUNTIME on the production scheduler; this catches it in the suite.
#       (The repo has no CI, so this is the only automated net.)
RSpec.describe 'config/recurring.yml' do
  let(:schedule) { YAML.load_file(Rails.root.join('config/recurring.yml')) }

  %w[production staging].each do |env|
    describe env do
      it 'references only existing ApplicationJob classes' do
        schedule.fetch(env).each_value do |entry|
          next unless entry['class']

          klass = entry['class'].constantize
          expect(klass.ancestors).to include(ApplicationJob),
                                     "#{entry['class']} is not an ApplicationJob"
        end
      end

      it 'every entry has a schedule' do
        schedule.fetch(env).each do |name, entry|
          expect(entry['schedule']).to be_present, "#{name} has no schedule"
        end
      end

      # Without a sweep the file store keeps every expired entry for good.
      it 'contains the hourly cache cleanup' do
        entry = schedule.fetch(env)['cache_cleanup']
        expect(entry).to be_present
        expect(entry['class']).to eq('CacheCleanupJob')
        expect(Fugit.parse(entry['schedule'])).to be_present
      end

      it 'contains the documentation polling sync (Slice-2 auto-sync contract)' do
        entry = schedule.fetch(env)['documentation_polling_sync']
        expect(entry).to be_present
        expect(entry['class']).to eq('DocumentationPollingJob')
      end

      # Bot defence S4: without this entry the purge exists as a class nobody
      # ever calls -- the same "documented but never runs" failure the export
      # cleanup pin below was written for.
      it 'contains the unconfirmed signup purge (bot defence S4)' do
        entry = schedule.fetch(env)['unconfirmed_signup_purge']
        expect(entry).to be_present
        expect(entry['class']).to eq('UnconfirmedSignupPurgeJob')
      end

      # T17: the monthly rollup is what turns running AI consumption into
      # something an organisation's deletion cannot take with it — the flush
      # only ever covers the org currently being deleted. Pinned by name for
      # the same reason as the GC below.
      it 'contains the AI usage rollup (T17 billing history contract)' do
        entry = schedule.fetch(env)['ai_usage_rollup']
        expect(entry).to be_present
        expect(entry['class']).to eq('AiUsageRollupJob')
      end

      # Embedding v2 PR 3 (R7): the daily orphan GC bounds the GDPR retention window
      # for derived vectors of deleted content to <= 24h. Pinned by name so it cannot
      # rot into "documented but never runs".
      it 'contains the embeddings orphan GC (PR-3 GDPR retention contract)' do
        entry = schedule.fetch(env)['embeddings_orphan_gc']
        expect(entry).to be_present
        expect(entry['class']).to eq('Embeddings::OrphanGcJob')
      end

      # Datenschutzerklärung § 4.2: the recorded origin of a registration has a
      # twelve-month deadline. Without this entry the promise is prose the
      # customer reads and nothing ever keeps. Pinned by name for that reason.
      it 'contains the acquisition purge (privacy policy § 4.2 retention)' do
        entry = schedule.fetch(env)['acquisition_purge']
        expect(entry).to be_present
        expect(entry['class']).to eq('AcquisitionPurgeJob')
      end

      # AVV § 12 Abs. 4: blobs without an attachment row enter no deletion
      # deadline at all unless this runs. Pinned by name for the same reason.
      it 'contains the unattached blob purge (AVV § 12 Abs. 4 deletion contract)' do
        entry = schedule.fetch(env)['unattached_blob_purge']
        expect(entry).to be_present
        expect(entry['class']).to eq('UnattachedBlobPurgeJob')
      end

      # AVV § 12 Abs. 7 promises three things about the deletion register, and
      # two of them are jobs: the backup expiry is carried over, and the register
      # itself expires after three years. Both are pinned by name — an entry that
      # quietly disappears here turns a contract sentence into a false statement.
      it 'contains the backup confirmation carry-over (AVV § 12 Abs. 7)' do
        entry = schedule.fetch(env)['attachment_backup_confirmation']
        expect(entry).to be_present
        expect(entry['class']).to eq('AttachmentBackupConfirmationJob')
      end

      it 'contains the deletion register retention (AVV § 12 Abs. 7)' do
        entry = schedule.fetch(env)['attachment_deletion_record_purge']
        expect(entry).to be_present
        expect(entry['class']).to eq('AttachmentDeletionRecordPurgeJob')
      end

      # Privacy policy § 4.1 promises the callback number goes once the request
      # is decided, at the latest after three months. Pinned by name because the
      # promise is PUBLIC: without the job it is a sentence on a website that
      # the code does not keep.
      it 'contains the founder callback number cleanup (privacy § 4.1 retention promise)' do
        entry = schedule.fetch(env)['founder_signup_callback_number_cleanup']
        expect(entry).to be_present
        expect(entry['class']).to eq('FounderSignupCallbackNumberCleanupJob')
      end
    end
  end

  # M0c: the ONLY entry that is deliberately production-only, so it is pinned
  # outside the two-environment loop above. Both halves are pinned: that it runs
  # on production, and that staging omits it. The omission is a decision (no
  # opening backfill there, so the job would report every account every night),
  # and an absence that nobody wrote down looks exactly like one somebody forgot.
  describe 'seat stream drift check (M0c)' do
    it 'runs on production' do
      entry = schedule.fetch('production')['seat_stream_drift_check']

      expect(entry).to be_present
      expect(entry['class']).to eq('SeatStreamDriftCheckJob')
    end

    it 'is deliberately absent from staging' do
      expect(schedule.fetch('staging')).not_to have_key('seat_stream_drift_check')
    end
  end

  # M1b: production-only for the same reason as the drift check above, and
  # pinned on both halves for the same reason too. Without this entry the
  # boundaries are never laid down, and M2 has nothing to replay from -- an
  # absence that only shows up when someone asks for an invoice.
  describe 'seat snapshot (M1b)' do
    it 'runs on production, monthly' do
      entry = schedule.fetch('production')['seat_snapshot']

      expect(entry).to be_present
      expect(entry['class']).to eq('SeatSnapshotJob')
      # Day-of-month 1: the boundary it writes is the one that just began.
      expect(entry['schedule']).to eq('40 6 1 * *')
    end

    it 'is deliberately absent from staging' do
      expect(schedule.fetch('staging')).not_to have_key('seat_snapshot')
    end
  end

  # The demo banner names the hour of the reset (Lalabase::Demo::RESET_HOUR_UTC).
  # A schedule moved here without the constant would make the banner lie. In UTC
  # explicitly: a cron line without a zone runs in the server's local time.
  describe 'demo reset' do
    it 'runs nightly at the hour the banner names' do
      entry = schedule.fetch('production')['demo_reset']
      expect(entry['class']).to eq('DemoResetJob')

      cron = Fugit.parse_cron(entry['schedule'])
      expect([cron.hours, cron.minutes, cron.timezone&.name]).to eq([[Lalabase::Demo::RESET_HOUR_UTC], [0], 'UTC'])
    end
  end

  # A duplicated key does not raise: YAML keeps the last one and drops the first
  # silently, so a task can vanish from the schedule while the file still shows
  # it. Parsing cannot catch this — the duplicate is gone by then — so the check
  # runs on the raw text.
  it 'declares every task name only once per environment' do
    section = nil
    seen = Hash.new { |h, k| h[k] = [] }

    Rails.root.join('config/recurring.yml').each_line do |line|
      next if line.lstrip.start_with?('#')

      case line
      when /\A(\w+):\s*\z/ then section = Regexp.last_match(1)
      when /\A  (\w+):\s*\z/ then seen[section] << Regexp.last_match(1)
      end
    end

    seen.each do |env, names|
      duplicates = names.tally.select { |_, count| count > 1 }.keys
      expect(duplicates).to be_empty, "#{env} declares #{duplicates.join(', ')} more than once"
    end
  end
end
