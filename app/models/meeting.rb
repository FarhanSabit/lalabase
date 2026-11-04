# frozen_string_literal: true

# Meeting (Gespräche) — a conversation/meeting as a first-class project work
# object: verbatim transcript + curated notes + a time/context anchor. Distinct
# from a knowledge Note (which is for finding); a Meeting is for working. See
# doc/gespraeche_plan.md.
#
# Slice 1a covers the CRUD foundation. Later slices added: participants (1b),
# time-session subject (2), ticket references (3), AI summary (4), participant
# detection (5). Slice 6 (this one) wires the embeddings/search opt-in:
# create_embeddings (opt-in per meeting, default false) now drives BOTH the
# knowledge full-text search AND chat embeddings, via has_many :fragments and
# Actors::SaveMeeting.
# == Schema Information
#
# Table name: meetings
#
#  id                         :uuid             not null, primary key
#  create_embeddings          :boolean          default(FALSE), not null
#  duration_minutes           :integer
#  embedding_creation_error   :text
#  embeddings_creation_flag   :boolean
#  generated_summary          :text             default(""), not null
#  notes                      :text
#  occurred_at                :datetime         not null
#  plain_text_version         :text
#  suggestions_creation_error :text             default(""), not null
#  suggestions_creation_flag  :boolean          default(FALSE), not null
#  summary_creation_error     :text             default(""), not null
#  summary_creation_flag      :boolean          default(FALSE), not null
#  title                      :string           not null
#  transcript                 :text
#  created_at                 :datetime         not null
#  updated_at                 :datetime         not null
#  creator_id                 :uuid             not null
#  organisation_id            :uuid             not null
#  project_id                 :uuid             not null
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
class Meeting < ApplicationRecord
  include OneLineText

  # Shared bounded title for the assistant's offer, reference chip and prompt.
  def one_line_title(max:)
    # The shared chip also truncates visually: put the distinguishing date first.
    one_line("#{I18n.l(occurred_at.to_date)} · #{title}", max:)
  end

  # dom_id for the Slice 4 summary broadcast target (same as DocumentVersion).
  include ActionView::RecordIdentifier

  acts_as_tenant(:organisation)

  belongs_to :project
  belongs_to :creator, class_name: 'User'

  # Slice 1b: structured participants. Chips-sync happens in Actors::SaveMeeting;
  # dependent: :destroy so removing a meeting takes its participation rows with it.
  has_many :meeting_participants, dependent: :destroy

  # Slice 7a: AI analyses with a selectable prompt (private per creator, publishable).
  # dependent: :destroy — an analysis is metadata about the meeting; deleting the
  # meeting takes them (and their fragments, via MeetingAnalysis) with it.
  has_many :meeting_analyses, dependent: :destroy

  # Slice 8: AI ticket suggestions derived from the meeting's source. dependent:
  # :destroy — a suggestion is metadata about the meeting; the created/similar
  # tickets are NOT touched (FK nullify), only the suggestion rows go.
  has_many :meeting_ticket_suggestions, dependent: :destroy

  # Slice 3: manual bidirectional links to tickets, reusing the polymorphic
  # Reference model (source: Meeting → target: Ticket). Same deletion semantics as
  # the wiki's Note (note.rb:50): dependent: :destroy so deleting a meeting removes
  # its OUTGOING links. The reverse case — deleting a linked ticket — is NOT handled
  # here: Reference#target is optional, so the row survives as a tombstone
  # (target_title_snapshot) and the meeting side shows the stored title instead of a
  # dead link. Backlinks on the ticket side are Reference.pointing_to(ticket).
  has_many :outgoing_references, class_name: 'Reference', as: :source, dependent: :destroy

  # Booked time (Gespräche Slice 2): the meeting is a first-class time subject like
  # a ticket. On meeting deletion the sessions are kept and their meeting_id nulled
  # (DB on_delete: :nullify mirrors this) — a billed/grouped session must NEVER ride
  # along on a meeting delete (plan decision 7). This deliberately differs from the
  # :destroy above: participation rows are metadata about the meeting, time sessions
  # are billable records that outlive it.
  has_many :time_sessions, dependent: :nullify

  # Search & chat opt-in (Gespräche Slice 6): when create_embeddings is on, the
  # concatenated plain_text_version is chunked into fragments by the shared
  # EmbeddingProcessingService (enqueued from Actors::SaveMeeting#enqueue_jobs).
  # dependent: :delete_all mirrors Note (note.rb:43) — a cheap bulk delete, no
  # per-row callbacks needed. Toggling the opt-in OFF ALSO deletes the fragments
  # synchronously in the actor (PII data class: a de-indexed transcript must leave
  # no retrievable trace) — which Note deliberately does NOT do.
  has_many :fragments, as: :fragmentable, dependent: :delete_all

  # DoS guard (plan §3): notes/transcript are free-text paste targets with no
  # natural bound. A 2h transcript is ~100-200 KB, so a 1 MB cap per field is
  # generous but keeps the write path bounded. Bytes, not characters — the risk
  # is payload size (precedent: EmailLog::MAX_DECOMPRESSED_SIZE bytesize check).
  MAX_CONTENT_BYTES = 1.megabyte

  # A leading YAML frontmatter block that AI transcript exporters put at the very
  # top ("---\nid: …\nparent: …\n---") is metadata noise, not content. It is stripped
  # for DISPLAY, the header excerpt AND the LLM summary source — see .strip_frontmatter.
  # Anchored at the start; the body lines must be NON-BLANK so a document that merely
  # begins with a "---" horizontal rule (rule, blank line, another "---") is not
  # mistaken for frontmatter — only a tight top-of-file metadata block matches. A
  # "---" anywhere else stays a legitimate rule.
  FRONTMATTER_BLOCK = /\A---[ \t]*\r?\n(?:[^\n]+\r?\n)*?---[ \t]*(?:\r?\n|\z)/

  # A pending summary generation counts as "running" only within this window.
  # The flag is set before enqueue and cleared only by the service — without a
  # staleness valve a lost job (worker outage, enqueue raising after commit)
  # would brick the button and spinner forever (review #235). Any meeting update
  # bumps updated_at and extends the window; that imprecision is accepted.
  SUMMARY_STALE_AFTER = 10.minutes

  # Same staleness valve as SUMMARY_STALE_AFTER, for the ticket-suggestion run
  # (Slice 8): a lost job must not brick the "generate suggestions" button forever.
  SUGGESTIONS_STALE_AFTER = 10.minutes

  validates :title, presence: true
  validates :occurred_at, presence: true
  # Bounded server-side, not just via the form's number_field min: 0 — a crafted
  # POST could otherwise persist a negative duration (review PR #219, red team).
  validates :duration_minutes, numericality: { only_integer: true, greater_than_or_equal_to: 0 },
                               allow_nil: true
  # notes AND transcript are BOTH optional — a meeting may be a pure time/context
  # anchor with no content (plan decision 11). Only their SIZE is validated.
  validate :content_within_byte_limit

  before_save :extract_plain_text_version
  # The summary derives from transcript/notes — when the source changes it must
  # not keep masquerading as current (GDPR erasure consistency: PII removed from
  # the transcript must not survive in the derived summary). Review #235.
  before_save :invalidate_stale_summary
  # Project activity trail, mirroring Note (note.rb:75). Meetings are PII-heavy,
  # so creation AND deletion must both be auditable (plan §5 Slice 1a).
  after_create_commit :track_meeting_created_in_project
  after_destroy_commit :track_meeting_deleted_in_project
  # Live summary updates (Slice 4): when the async job finishes — or the controller
  # sets the pending flag — push the rebuilt summary section to everyone viewing
  # this meeting. Reuses the Turbo broadcast infra (DocumentVersion#broadcast_updated
  # pattern); guarded to the summary columns so ordinary edits (title/notes) don't
  # broadcast. The partial renders with no request context (see its header note).
  after_update_commit :broadcast_summary_if_changed
  # PII guarantee (embedding v2 PR 2): purge the sidecar embeddings of this meeting's
  # fragments BEFORE the dependent delete_all below removes the fragments (callback-
  # free — nothing else would clean the sidecar, and the orphan GC only ships in PR 3;
  # transcript derivatives must not outlive the meeting). prepend: true — must run
  # before the has_many dependent callbacks, which are also before_destroy callbacks
  # and would otherwise delete the fragment rows our subselect needs. The analysis
  # branch is covered by MeetingAnalysis's own prepend callback via the :destroy cascade.
  before_destroy :purge_fragment_content_embeddings, prepend: true

  # Full-content search for the master list; lives in the model so the project
  # index and the org-wide index (Slice 1c) reuse ONE definition. Matches the
  # title AND the meeting body: plain_text_version (= notes + transcript, kept in
  # sync by extract_plain_text_version, so ONE column covers both and it is
  # populated regardless of the create_embeddings opt-in) plus the AI
  # generated_summary. Scans within the caller's policy scope, so only readable
  # meetings can surface — no reliance on the embeddings opt-in (that gates the
  # external vectorizer, not this local ILIKE).
  # .to_s so a non-scalar param (?search[]=x → Array) can't raise inside
  # sanitize_sql_like (which #gsubs its arg); it stringifies harmlessly and
  # matches nothing. Value is bound via the placeholder (no injection).
  # Perf: ILIKE '%q%' cannot use a b-tree index and detoasts plain_text_version
  # per candidate row. Fine at current per-project/per-org meeting counts; if a
  # tenant's meeting volume makes this slow, add a pg_trgm GIN index on
  # (title, plain_text_version) — trigram indexes accept the leading wildcard.
  scope :search_by_content, lambda { |query|
    next all if query.blank?

    term = "%#{sanitize_sql_like(query.to_s)}%"
    where('meetings.title ILIKE :q OR meetings.plain_text_version ILIKE :q OR meetings.generated_summary ILIKE :q',
          q: term)
  }

  # Filter to meetings that include the given person, matched by normalized name
  # (so "Müller" also finds "Mueller"). A subquery, NOT a join, so the caller's
  # select stays clean and a meeting with several matching participants is still
  # returned exactly once. Shared by the project index participant filter and the
  # org-wide index (Slice 1c) — one definition, no mirrored subquery to drift.
  # Security note: this only narrows; the caller composes it onto a policy scope,
  # so an unreadable meeting can never surface through the filter.
  scope :with_participant, lambda { |name|
    next all if name.blank?

    Meetings::ParticipantFilter.call(all, [name])
  }

  # Removes a leading YAML frontmatter block (FRONTMATTER_BLOCK) from `text`. Pure
  # function (mirrors MeetingParticipant.normalize_name) so display, the excerpt and
  # summary_source share ONE codepath — the raw value in the DB / edit textarea is
  # never touched, only what we render or feed the LLM. Blank/nil pass through.
  def self.strip_frontmatter(text)
    return text if text.blank?

    text.sub(FRONTMATTER_BLOCK, '')
  end

  # THE lock for a write that was authorized against a project: takes the
  # meeting's row lock and answers whether the meeting is still in that
  # project. Actors::MoveMeeting holds the same lock while it moves the
  # meeting, so a write that answers true cannot land after a move, and one
  # that answers false treats the meeting as gone from that project. Call it
  # inside the write's transaction. Guard: spec/architecture/meeting_lock_guard_spec.rb.
  def lock_in_project!(authorized_project_id)
    lock!
    project_id == authorized_project_id
  end

  # The live summary stream names the project: after a move (Actors::MoveMeeting)
  # a page still open in the old project hears nothing of what is written in
  # the new one. The view subscribes through the same method.
  def summary_stream_name(for_project_id = project_id)
    "#{dom_id(self)}_#{for_project_id}_summary"
  end

  # The single source rule for the AI summary (plan decision 11): transcript
  # preferred, notes fallback. Both are frontmatter-stripped BEFORE the presence
  # check, so a transcript that is nothing but a metadata block still falls through
  # to the notes, and the LLM never sees the id:/parent: noise. Controller guard,
  # view gate and Meetings::SummaryService all derive from THIS method so the rule
  # cannot drift apart (review #235).
  def summary_source
    self.class.strip_frontmatter(transcript).presence || self.class.strip_frontmatter(notes).presence
  end

  # "Running" = pending flag set AND recently touched (see SUMMARY_STALE_AFTER).
  # Drives both the controller's re-enqueue guard and the view's spinner state, so
  # a stale flag self-heals: the button returns and a fresh POST may re-enqueue.
  def summary_generation_running?
    summary_creation_flag? && updated_at > SUMMARY_STALE_AFTER.ago
  end

  # D11 (Slice 7a): one analysis run per meeting at a time. True while ANY analysis
  # of the meeting is still generating within its staleness window — the controller
  # rejects a second create/flip with 422 until it clears (deters double-click and
  # credit spam; a stale flag self-heals via MeetingAnalysis::STALE_AFTER).
  def analysis_generation_running?
    meeting_analyses.running.exists?
  end

  # "Running" = the suggestions flag is set AND recently touched (Slice 8). Same
  # self-healing valve as summary_generation_running? — one run per meeting at a
  # time, but a lost job releases the button after SUGGESTIONS_STALE_AFTER.
  def suggestions_generation_running?
    suggestions_creation_flag? && updated_at > SUGGESTIONS_STALE_AFTER.ago
  end

  private

  # See the before_destroy declaration: subselect the fragment ids (they still
  # exist because this runs BEFORE the dependent delete_all) and drop their sidecar
  # rows synchronously — a de-indexed/deleted transcript leaves no retrievable trace.
  #
  # One deliberate exception (glossary K4a, E4, decided 2026-11-04): the heard
  # forms of the glossary (term_corrections) STAY, with their place in the
  # transcript (line_index, char_offset, transcript_digest); only meeting_id is
  # cleared, by the foreign key (on_delete: :nullify), nothing here. A correction
  # is knowledge of the organisation that a person confirmed, not content of the
  # conversation. Do not purge them here, and do not turn that key into a cascade.
  def purge_fragment_content_embeddings
    ContentEmbedding.purge_for(embeddable_type: 'Fragment', embeddable_ids: fragments.select(:id))
  end

  def track_meeting_created_in_project
    project.track_meeting_created(self) if project.respond_to?(:track_meeting_created)
  end

  def track_meeting_deleted_in_project
    project.track_meeting_deleted(self) if project.respond_to?(:track_meeting_deleted)
  end

  def broadcast_summary_if_changed
    return unless saved_change_to_generated_summary? || saved_change_to_summary_creation_flag? ||
                  saved_change_to_summary_creation_error?

    # The persisted project, not this instance's: a summary job loads the
    # meeting, a move commits, and the job finishes on its stale copy.
    broadcast_replace_to(
      summary_stream_name(Meeting.unscoped.where(id: id).pick(:project_id) || project_id),
      target: "#{dom_id(self)}_summary_section",
      partial: 'organisations/meetings/summary_section',
      locals: { meeting: self }
    )
  end

  # Clears the summary trio remnants when transcript or notes change. Skipped when
  # generated_summary is written in the same save — the service persisting a fresh
  # summary never touches the source. Known race, accepted: a job finishing AFTER
  # a source edit re-writes a summary of the old source; the next edit clears it
  # again (review #235).
  def invalidate_stale_summary
    return if new_record?
    return if will_save_change_to_attribute?(:generated_summary)
    return unless will_save_change_to_attribute?(:transcript) || will_save_change_to_attribute?(:notes)

    self.generated_summary = ''
    self.summary_creation_error = ''
  end

  # plain_text_version = notes + transcript (both already plaintext), the
  # pipeline/PgSearch contract column — same idea as Note#extract_plain_text_content
  # (note.rb). With both fields blank the column stays nil: no crash, and later
  # (Slice 6) no embedding is enqueued for an empty meeting.
  def extract_plain_text_version
    self.plain_text_version = [notes, transcript].compact_blank.join("\n\n").presence
  end

  # One readable error per oversized field. bytesize is safe on the text columns
  # (String or nil); blank fields are skipped.
  def content_within_byte_limit
    %i[notes transcript].each do |field|
      value = public_send(field)
      next if value.blank? || value.bytesize <= MAX_CONTENT_BYTES

      errors.add(field, :content_too_large)
    end
  end
end
