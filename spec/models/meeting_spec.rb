# frozen_string_literal: true

# == Schema Information
#
# Table name: meetings
#
#  id                     :uuid             not null, primary key
#  create_embeddings      :boolean          default(FALSE), not null
#  duration_minutes       :integer
#  generated_summary      :text             default(""), not null
#  notes                  :text
#  occurred_at            :datetime         not null
#  plain_text_version     :text
#  summary_creation_error :text             default(""), not null
#  summary_creation_flag  :boolean          default(FALSE), not null
#  title                  :string           not null
#  transcript             :text
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  creator_id             :uuid             not null
#  organisation_id        :uuid             not null
#  project_id             :uuid             not null
#
# Indexes
#
#  index_meetings_on_creator_id                  (creator_id)
#  index_meetings_on_organisation_id             (organisation_id)
#  index_meetings_on_project_id_and_occurred_at  (project_id,occurred_at)
#
# Foreign Keys
#
#  fk_rails_...  (creator_id => users.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#
require 'rails_helper'

# Meeting model — Slice 1a foundation.
# Intent per describe:
#  - validations: title/occurred_at required; notes+transcript BOTH optional (a
#    meeting may be a pure time/context anchor); each capped at ~1 MB (DoS guard).
#  - extract_plain_text_version: the pipeline/PgSearch contract column is the
#    blank-safe concatenation of notes + transcript.
RSpec.describe Meeting, type: :model do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:creator) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def build_meeting(**attrs)
    build(:meeting, organisation: organisation, project: project, creator: creator, **attrs)
  end

  describe '#one_line_title' do
    { de: ['03.05.2026', '04.05.2026'], en: %w[2026-05-03 2026-05-04] }.each do |locale, dates|
      it "distinguishes recurring titles by date in #{locale}" do
        I18n.with_locale(locale) do
          first = build_meeting(title: 'Jour fixe', occurred_at: Time.zone.local(2026, 5, 3, 12))
          second = build_meeting(title: 'Jour fixe', occurred_at: Time.zone.local(2026, 5, 4, 12))

          expect(first.one_line_title(max: 80)).to eq("#{dates.first} · Jour fixe")
          expect(second.one_line_title(max: 80)).to eq("#{dates.last} · Jour fixe")
        end
      end
    end

    [80, 120].each do |budget|
      it "preserves the date when truncating a title to #{budget} characters" do
        I18n.with_locale(:de) do
          meeting = build_meeting(title: "Jour\n fixe #{'x' * 200}", occurred_at: Time.zone.local(2026, 5, 3, 12))
          title = meeting.one_line_title(max: budget)

          expect(title.length).to eq(budget)
          expect(title).to start_with('03.05.2026 · Jour fixe ').and end_with('...')
          expect(title).not_to include("\n")
        end
      end
    end
  end

  describe 'validations' do
    it 'requires a title' do
      meeting = build_meeting(title: nil)
      expect(meeting).not_to be_valid
      expect(meeting.errors[:title]).to be_present
    end

    it 'requires occurred_at' do
      meeting = build_meeting(occurred_at: nil)
      expect(meeting).not_to be_valid
      expect(meeting.errors[:occurred_at]).to be_present
    end

    it 'saves a pure time/context anchor with title + occurred_at only (both content fields blank)' do
      meeting = build_meeting(notes: nil, transcript: nil)
      expect(meeting).to be_valid
      expect(meeting.save).to be(true)
    end

    it 'accepts notes/transcript up to the 1 MB cap' do
      meeting = build_meeting(notes: 'x' * Meeting::MAX_CONTENT_BYTES,
                              transcript: 'y' * Meeting::MAX_CONTENT_BYTES)
      expect(meeting).to be_valid
    end

    it 'rejects notes larger than the 1 MB cap with a readable message' do
      meeting = build_meeting(notes: 'x' * (Meeting::MAX_CONTENT_BYTES + 1))
      expect(meeting).not_to be_valid
      expect(meeting.errors[:notes].join).to match(/1 MB/)
    end

    it 'rejects transcript larger than the 1 MB cap with a readable message' do
      meeting = build_meeting(transcript: 'x' * (Meeting::MAX_CONTENT_BYTES + 1))
      expect(meeting).not_to be_valid
      expect(meeting.errors[:transcript].join).to match(/1 MB/)
    end

    it 'caps by BYTES, not characters (multibyte content over the byte cap is rejected)' do
      # "ü" is 2 bytes in UTF-8: this string is UNDER the cap by character count
      # but OVER it by bytesize — a length-based check would wrongly accept it.
      multibyte = 'ü' * ((Meeting::MAX_CONTENT_BYTES / 2) + 1)
      expect(multibyte.length).to be <= Meeting::MAX_CONTENT_BYTES
      expect(multibyte.bytesize).to be > Meeting::MAX_CONTENT_BYTES
      meeting = build_meeting(notes: multibyte)
      expect(meeting).not_to be_valid
      expect(meeting.errors[:notes]).to be_present
    end
  end

  describe 'fragments (Slice 6 embeddings)' do
    it 'has a polymorphic fragments association' do
      meeting = build_meeting.tap(&:save!)
      fragment = create(:fragment, fragmentable: meeting, organisation: organisation)
      expect(meeting.fragments).to include(fragment)
    end

    it 'deletes its fragments when the meeting is destroyed (dependent: :delete_all)' do
      meeting = build_meeting.tap(&:save!)
      create(:fragment, fragmentable: meeting, organisation: organisation)
      expect { meeting.destroy }.to change(Fragment, :count).by(-1)
    end

    # Q1 (embedding v2 PR 2): destroy must synchronously purge the sidecar rows of the
    # transcript fragments. The prepend before_destroy runs BEFORE the callback-free
    # dependent delete_all removes the fragments our subselect needs — no orphan PII
    # (the GC only ships in PR 3). The test breaks if someone drops `prepend: true`.
    it 'purges the sidecar rows of its transcript fragments on destroy' do
      meeting = build_meeting.tap(&:save!)
      fragment = create(:fragment, fragmentable: meeting, organisation: organisation)
      row = create(:content_embedding, organisation: organisation, embeddable: fragment)

      expect { meeting.destroy }.to change { ContentEmbedding.exists?(row.id) }.from(true).to(false)
    end

    # The meeting-destroy :destroy cascade destroys each analysis per-row, firing the
    # analysis's OWN prepend before_destroy — so analysis-fragment sidecar rows go too.
    it 'purges the sidecar rows of its analyses\' fragments on destroy' do
      meeting = build_meeting.tap(&:save!)
      analysis = create(:meeting_analysis, meeting: meeting)
      analysis_fragment = create(:fragment, fragmentable: analysis, organisation: organisation)
      row = create(:content_embedding, organisation: organisation, embeddable: analysis_fragment)

      expect { meeting.destroy }.to change { ContentEmbedding.exists?(row.id) }.from(true).to(false)
    end
  end

  describe '#extract_plain_text_version (before_save)' do
    it 'concatenates notes and transcript' do
      meeting = build_meeting(notes: 'hello', transcript: 'world')
      meeting.save!
      expect(meeting.plain_text_version).to eq("hello\n\nworld")
    end

    it 'uses only notes when transcript is blank' do
      meeting = build_meeting(notes: 'only notes', transcript: nil)
      meeting.save!
      expect(meeting.plain_text_version).to eq('only notes')
    end

    it 'uses only transcript when notes is blank' do
      meeting = build_meeting(notes: nil, transcript: 'only transcript')
      meeting.save!
      expect(meeting.plain_text_version).to eq('only transcript')
    end

    it 'stays blank (nil) with both fields blank — no crash' do
      meeting = build_meeting(notes: nil, transcript: nil)
      expect { meeting.save! }.not_to raise_error
      expect(meeting.plain_text_version).to be_nil
    end
  end

  describe 'multi-tenancy' do
    it 'is scoped to the organisation tenant' do
      meeting = build_meeting
      meeting.save!
      expect(meeting.organisation).to eq(organisation)
    end
  end

  describe 'duration_minutes validation' do
    it 'rejects a negative duration (server-side, not just the form min)' do
      meeting = build_meeting(duration_minutes: -30)
      expect(meeting).not_to be_valid
      expect(meeting.errors[:duration_minutes]).to be_present
    end

    it 'accepts nil and zero' do
      expect(build_meeting(duration_minutes: nil)).to be_valid
      expect(build_meeting(duration_minutes: 0)).to be_valid
    end
  end

  # Shared by the project meetings index and the org-wide index (Slice 1c) — one
  # definition, two call sites. Searches the title AND the body (notes/transcript
  # via plain_text_version + the AI generated_summary), so a word remembered from
  # the conversation — not just the title — finds the meeting.
  describe '.search_by_content' do
    it 'matches case-insensitively on the title' do
      match = build_meeting(title: 'Kickoff Sanierung').tap(&:save!)
      build_meeting(title: 'Retro').tap(&:save!)

      expect(described_class.search_by_content('kickoff')).to contain_exactly(match)
    end

    it 'matches on notes content (via plain_text_version), not just the title' do
      match = build_meeting(title: 'Retro Q3', notes: 'Budget für die Dachsanierung freigeben').tap(&:save!)
      build_meeting(title: 'Retro Q4', notes: 'nichts Relevantes').tap(&:save!)

      expect(described_class.search_by_content('dachsanierung')).to contain_exactly(match)
    end

    it 'matches on transcript content (via plain_text_version)' do
      match = build_meeting(title: 'Weekly', transcript: 'Anna: wir migrieren auf Postgres 16').tap(&:save!)
      build_meeting(title: 'Weekly', transcript: 'Bernd: nichts Neues').tap(&:save!)

      expect(described_class.search_by_content('postgres')).to contain_exactly(match)
    end

    it 'matches on the AI generated_summary' do
      match = build_meeting(title: 'Sync', generated_summary: 'Entscheidung: Vertrag verlängern').tap(&:save!)
      build_meeting(title: 'Sync').tap(&:save!)

      expect(described_class.search_by_content('vertrag')).to contain_exactly(match)
    end

    it 'returns the full scope unchanged for a blank query' do
      build_meeting(title: 'A').tap(&:save!)
      expect(described_class.search_by_content(nil)).to eq(described_class.all)
      expect(described_class.search_by_content('')).to eq(described_class.all)
    end

    it 'tolerates non-scalar input (?search[]=x) instead of raising' do
      expect { described_class.search_by_content(['x']).to_a }.not_to raise_error
    end
  end

  # Shared by the project meetings index (participant filter) and the org-wide
  # index (Slice 1c) — one definition, two call sites (no mirrored subquery).
  describe '.with_participant' do
    def meeting_with_participants(title, *names)
      build_meeting(title: title).tap do |m|
        m.save!
        # Data setup only: each participant create re-reads the tenant org — a
        # benign setup N+1, not the production path under test.
        Prosopite.pause { names.each { |n| create(:meeting_participant, meeting: m, display_name: n) } }
      end
    end

    it 'matches across umlaut spellings (transliteration equivalence)' do
      hit = meeting_with_participants('Kickoff', 'Anna Mueller')
      meeting_with_participants('Retro', 'Clara Klein')

      # Filtering by the umlaut spelling must find the transliterated participant.
      expect(described_class.with_participant('Anna Müller')).to contain_exactly(hit)
    end

    it 'returns a meeting only once even with several participants (subquery, no row dup)' do
      hit = meeting_with_participants('Workshop', 'Anna Mueller', 'Bob Builder')

      expect(described_class.with_participant('anna mueller').to_a).to eq([hit])
    end

    it 'returns the full scope unchanged for a blank filter' do
      meeting_with_participants('Kickoff', 'Anna Mueller')
      expect(described_class.with_participant(nil)).to eq(described_class.all)
      expect(described_class.with_participant('')).to eq(described_class.all)
    end
  end

  describe 'project activity trail' do
    before { Current.user = creator }
    after { Current.user = nil }

    it 'tracks creation in the project activity feed' do
      meeting = build_meeting(title: 'Auditierbar')
      expect { meeting.save! }.to(change do
        project.activities.where(action: 'meeting_created').count
      end.by(1))
    end

    it 'tracks deletion with the audit facts in parameters (meetings are PII-heavy)' do
      meeting = build_meeting(title: 'Vergänglich').tap(&:save!)
      expect { meeting.destroy! }.to(change do
        project.activities.where(action: 'meeting_deleted').count
      end.by(1))
      activity = project.activities.where(action: 'meeting_deleted').last
      expect(activity.parameters['meeting_title']).to eq('Vergänglich')
    end
  end

  # Slice 3: manual bidirectional Meeting→Ticket links via the polymorphic
  # Reference model. Deletion semantics deliberately mirror the wiki (Note):
  # a meeting owns its OUTGOING links (destroyed with it), but a deleted TICKET
  # leaves the reference as a tombstone so the meeting side never shows a dead link.
  describe 'outgoing_references (ticket links)' do
    let(:meeting) { build_meeting(title: 'Kickoff').tap(&:save!) }
    let(:ticket) { create(:ticket, project: project, organisation: organisation, creator: creator, title: 'Fix login') }

    def link!(target)
      meeting.outgoing_references.create!(
        organisation: organisation,
        target: target,
        target_title_snapshot: target.display_title
      )
    end

    it 'links a meeting to a ticket as source→target' do
      reference = link!(ticket)
      expect(reference.source).to eq(meeting)
      expect(reference.target).to eq(ticket)
      expect(meeting.outgoing_references.reload).to contain_exactly(reference)
    end

    it 'destroys its outgoing references when the meeting is deleted (dependent: :destroy)' do
      link!(ticket)
      expect { meeting.destroy! }.to change(Reference, :count).by(-1)
    end

    it 'leaves the reference as a tombstone when the TARGET ticket is hard-deleted' do
      reference = link!(ticket)
      snapshot = ticket.display_title
      expect { ticket.destroy! }.not_to change(Reference, :count)
      reference.reload
      expect(reference.target).to be_nil
      expect(reference.target_title_snapshot).to eq(snapshot)
    end

    it 'rejects a duplicate (source, target) at the DB layer — defense in depth' do
      link!(ticket)
      # Reference carries NO model-level uniqueness validation on purpose: the DB
      # unique index (source_type, source_id, target_type, target_id) is the single
      # source of truth, and the controller's rescue relies on it firing. Bypass
      # validations to prove the index is really there — if someone drops it, the
      # controller's "already linked" guard silently degrades to duplicate rows.
      duplicate = meeting.outgoing_references.build(organisation: organisation, target: ticket)
      expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'scopes outgoing_references to THIS meeting (as: :source, no cross-meeting bleed)' do
      link!(ticket)
      other_meeting = build_meeting(title: 'Anderes Gespräch').tap(&:save!)
      other_ticket = create(:ticket, project: project, organisation: organisation, creator: creator)
      other_meeting.outgoing_references.create!(organisation: organisation, target: other_ticket,
                                                target_title_snapshot: other_ticket.display_title)

      # If the association were mis-scoped (wrong `as:`/source), this meeting would
      # also surface the other meeting's link.
      expect(meeting.outgoing_references.reload.map(&:target)).to contain_exactly(ticket)
    end
  end

  # Slice 4 live-summary broadcast. Locks the contract the async job relies on:
  # a summary-column change pushes the section to the per-meeting stream with the
  # exact target/partial the view subscribes to (drift here would silently break
  # live updates), and an unrelated edit must NOT broadcast (the guard).
  describe '#lock_in_project!' do
    let(:meeting) { create(:meeting, organisation: organisation, project: project, creator: creator) }

    it 'answers true while the meeting is in the authorized project' do
      expect(Meeting.transaction { meeting.lock_in_project!(project.id) }).to be(true)
    end

    # The row is read again under the lock: a move that committed after the
    # instance was loaded counts, not the project the instance still names.
    it 'answers false once the row names another project' do
      elsewhere = create(:project, organisation: organisation)
      Meeting.where(id: meeting.id).update_all(project_id: elsewhere.id)

      expect(Meeting.transaction { meeting.lock_in_project!(project.id) }).to be(false)
    end
  end

  describe 'summary broadcast (after_update_commit)' do
    let(:meeting) { create(:meeting, organisation: organisation, project: project, creator: creator, notes: 'x') }
    let(:stream) { "#{ActionView::RecordIdentifier.dom_id(meeting)}_#{project.id}_summary" }
    let(:target) { "#{ActionView::RecordIdentifier.dom_id(meeting)}_summary_section" }

    it 'broadcasts the summary section when a summary column changes' do
      expect(meeting).to receive(:broadcast_replace_to)
        .with(stream, hash_including(target: target, partial: 'organisations/meetings/summary_section'))
      meeting.update!(summary_creation_flag: true)
    end

    # A reader of the old project may still have the meeting open after a move
    # (Actors::MoveMeeting). The stream names the project, so the summaries
    # written after the move reach only pages rendered in the new one.
    it 'sends to the stream of the project the meeting is in now' do
      elsewhere = create(:project, organisation: organisation)
      meeting.update_columns(project_id: elsewhere.id)
      moved_stream = "#{ActionView::RecordIdentifier.dom_id(meeting)}_#{elsewhere.id}_summary"

      expect(meeting).to receive(:broadcast_replace_to).with(moved_stream, anything)
      meeting.update!(summary_creation_flag: true)
    end

    # A summary job loads the meeting, a move commits, the job finishes on its
    # stale instance. The stream must name the project the row is in now:
    # the old one would hand the new summary to readers of the old project.
    it 'sends to the stream of the persisted project from a stale instance' do
      elsewhere = create(:project, organisation: organisation)
      Meeting.where(id: meeting.id).update_all(project_id: elsewhere.id)
      moved_stream = "#{ActionView::RecordIdentifier.dom_id(meeting)}_#{elsewhere.id}_summary"

      expect(meeting).to receive(:broadcast_replace_to).with(moved_stream, anything)
      meeting.update!(summary_creation_flag: true)
    end

    it 'does not broadcast on an unrelated update (title only)' do
      expect(meeting).not_to receive(:broadcast_replace_to)
      meeting.update!(title: 'Renamed meeting')
    end

    # UNSTUBBED on purpose (review #235): the broadcast renders _summary_section
    # with NO request context — a request-only helper (params/policy/current_user)
    # sneaking into the partial keeps every stubbed spec green while every
    # production broadcast raises inside after_update_commit.
    it 'renders the broadcast partial without a request context' do
      expect { meeting.update!(summary_creation_flag: true) }.not_to raise_error
    end
  end

  # Staleness valve for the pending flag (review #235): the flag is set before
  # enqueue and cleared only by the service — after the window it stops counting
  # as "running" so button + re-enqueue guard self-heal after a lost job.
  describe '#summary_generation_running?' do
    let(:meeting) { create(:meeting, organisation: organisation, project: project, creator: creator, notes: 'x') }

    it 'is true while the flag is set and fresh' do
      meeting.update!(summary_creation_flag: true)
      expect(meeting.summary_generation_running?).to be(true)
    end

    it 'is false once the flag is stale' do
      meeting.update!(summary_creation_flag: true)
      # backdating updated_at NEEDS to bypass touch
      meeting.update_column(:updated_at, (Meeting::SUMMARY_STALE_AFTER + 1.minute).ago)
      expect(meeting.reload.summary_generation_running?).to be(false)
    end

    it 'is false without the flag' do
      expect(meeting.summary_generation_running?).to be(false)
    end
  end

  # Slice 8: same staleness valve as the summary flag, independent column.
  describe '#suggestions_generation_running?' do
    let(:meeting) { create(:meeting, organisation: organisation, project: project, creator: creator, notes: 'x') }

    it 'is true while the flag is set and fresh' do
      meeting.update!(suggestions_creation_flag: true)
      expect(meeting.suggestions_generation_running?).to be(true)
    end

    it 'is false once the flag is stale (self-heals the button)' do
      meeting.update!(suggestions_creation_flag: true)
      # backdating updated_at NEEDS to bypass touch
      meeting.update_column(:updated_at, (Meeting::SUGGESTIONS_STALE_AFTER + 1.minute).ago)
      expect(meeting.reload.suggestions_generation_running?).to be(false)
    end

    it 'is false without the flag' do
      expect(meeting.suggestions_generation_running?).to be(false)
    end
  end

  # GDPR erasure consistency (review #235): the summary derives from
  # transcript/notes — editing or deleting the source must not leave a summary of
  # the removed content on display (Abriss + section render it first).
  describe 'summary invalidation on source change' do
    let(:meeting) do
      create(:meeting, organisation: organisation, project: project, creator: creator,
                       notes: 'Original', transcript: 'Transkript',
                       generated_summary: 'Alte Zusammenfassung', summary_creation_error: 'alter Fehler')
    end

    it 'clears summary and error when the notes change' do
      meeting.update!(notes: 'PII entfernt')
      expect(meeting.generated_summary).to eq('')
      expect(meeting.summary_creation_error).to eq('')
    end

    it 'clears summary and error when the transcript is blanked' do
      meeting.update!(transcript: nil)
      expect(meeting.generated_summary).to eq('')
    end

    it 'keeps the summary on an unrelated update (title only)' do
      meeting.update!(title: 'Umbenannt')
      expect(meeting.generated_summary).to eq('Alte Zusammenfassung')
    end

    it 'keeps an explicitly written summary even when the source changes in the same save' do
      meeting.update!(notes: 'neu', generated_summary: 'Frische Zusammenfassung')
      expect(meeting.generated_summary).to eq('Frische Zusammenfassung')
    end

    # The one exception (K4b, E4/E5): a term correction keeps the summary, for
    # the one save of its corrected transcript. Only Actors::SaveMeeting sets it,
    # when Actors::CorrectMeetingTerm asks (meeting_summary_exception_guard_spec).
    describe 'the exception of a term correction' do
      it 'keeps summary and error for the next save of the transcript' do
        meeting.keep_summary_for_next_save!
        meeting.update!(transcript: 'Transkript korrigiert')

        expect(meeting.reload.generated_summary).to eq('Alte Zusammenfassung')
        expect(meeting.summary_creation_error).to eq('alter Fehler')
      end

      it 'holds for that one save only' do
        meeting.keep_summary_for_next_save!
        meeting.update!(transcript: 'Transkript korrigiert')
        meeting.update!(transcript: 'Transkript bearbeitet')

        expect(meeting.reload.generated_summary).to eq('')
      end

      it 'is used up by the next save, whatever it changes' do
        meeting.keep_summary_for_next_save!
        meeting.update!(title: 'Umbenannt')
        meeting.update!(notes: 'bearbeitet')

        expect(meeting.reload.generated_summary).to eq('')
      end

      it 'belongs to the one instance it was set on' do
        meeting.keep_summary_for_next_save!
        Meeting.find(meeting.id).update!(notes: 'bearbeitet')

        expect(meeting.reload.generated_summary).to eq('')
      end
    end
  end

  # Pure function: transcripts pasted from AI tools carry a leading YAML frontmatter
  # block (---\nid: …\n---). It is metadata noise and must vanish from display/excerpt/
  # summary — but a "---" ELSEWHERE is a legitimate horizontal rule and must survive.
  describe '.strip_frontmatter' do
    it 'removes a leading frontmatter block and keeps the body' do
      text = "---\nid: abc-123\nparent: proj-9\n---\n# Gespräch\n\nInhalt."
      expect(Meeting.strip_frontmatter(text)).to eq("# Gespräch\n\nInhalt.")
    end

    it 'keeps a "---" that appears later in the text (a real horizontal rule)' do
      text = "Erster Teil\n\n---\n\nZweiter Teil"
      expect(Meeting.strip_frontmatter(text)).to eq(text)
    end

    it 'does NOT eat a body that merely starts with a "---" rule then a blank line' do
      # The block must be a tight metadata section (non-blank lines). A leading rule
      # followed by a paragraph and another rule is NOT frontmatter.
      text = "---\nEinleitung.\n\n---\n\nRest"
      expect(Meeting.strip_frontmatter(text)).to eq(text)
    end

    it 'leaves a leading "---" with no closing fence untouched' do
      text = "---\nnur eine Linie ohne Abschluss"
      expect(Meeting.strip_frontmatter(text)).to eq(text)
    end

    it 'passes blank/nil through unchanged' do
      expect(Meeting.strip_frontmatter(nil)).to be_nil
      expect(Meeting.strip_frontmatter('')).to eq('')
    end
  end

  describe '#summary_source (transcript preferred, notes fallback, frontmatter stripped)' do
    it 'strips a leading frontmatter block from the transcript source' do
      meeting = build_meeting(transcript: "---\nid: x\n---\nEchtes Transkript.", notes: nil)
      expect(meeting.summary_source).to eq('Echtes Transkript.')
    end

    it 'falls back to the notes when the transcript is ONLY a frontmatter block' do
      meeting = build_meeting(transcript: "---\nid: x\n---\n", notes: 'Kuratierte Notizen.')
      expect(meeting.summary_source).to eq('Kuratierte Notizen.')
    end

    it 'prefers the transcript over notes when both have real content' do
      meeting = build_meeting(transcript: 'VERBATIM', notes: 'NOTES')
      expect(meeting.summary_source).to eq('VERBATIM')
    end
  end
end
