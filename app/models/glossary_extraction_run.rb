# frozen_string_literal: true

# One run of the glossary extraction (K5b): a background job that reads the
# tickets, public comments, attachments, notes and documents of an
# organisation that the starting account may read, finds candidate terms
# without AI, lets a model classify them and stores GlossaryProposal rows for
# a person to accept, merge or dismiss. Since K5c a run can read one document
# instead, started from its lane: the version its scope names, whole.
#
# One active run (queued or running) per organisation, whatever its kind: the
# partial unique index one_active_glossary_extraction_run refuses a second
# one, also for two starts at the same moment. A run that has not moved for
# STALE_AFTER is stale; mark_stale! checks the timestamp again in the update
# that ends it.
#
# Both JSONB columns read with string keys, also right after a Hash with
# symbol keys was assigned (the JSONB type casts through JSON).
#
# scope, what the run read, one of two kinds (SCOPE_KINDS):
#   { "kind" => "organisation", "everything" => true | false,
#     "since" => an ISO 8601 time or nil: the bound the run used }
#   { "kind" => "document", "document_version_id" => the version it read
#     (a row of this organisation, checked without the tenant's scope),
#     "since" => nil: a run over one document reads it whole, and only runs
#     over the organisation set the bound of the next one }
# stats, what it found (written by the run):
#   { "sources" => { "tickets", "posts", "ticket_documents", "post_documents",
#                    "notes", "document_versions" => count },
#     "projects_reached", "projects_total", "candidates", "ai_calls",
#     "parse_errors", "proposals_created", "proposals_updated" => count,
#     "truncated" => true | false,
#     "since" => an ISO 8601 time or nil: the bound, as in scope }
#
# Deleting the organisation takes its runs along; deleting the account that
# started one only clears started_by_id (both in the database). Rights:
# GlossaryPolicy (start? asks manage_glossary).
class GlossaryExtractionRun < ApplicationRecord
  STATUSES = %w[queued running succeeded failed].freeze
  ACTIVE_STATUSES = %w[queued running].freeze
  STALE_AFTER = 10.minutes
  SCOPE_KINDS = %w[organisation document].freeze
  # The kind of a run started from the lane of one document (K5c).
  DOCUMENT_KIND = 'document'
  # document_unavailable (K5c): the version of a run over one document is
  # gone, out of the starter's reach when the run runs, or has no text.
  ERROR_CODES = %w[starter_inactive ai_unavailable ai_disabled not_configured quota_exceeded invalid_key
                   provider_error parse_error interrupted stale internal_error document_unavailable].freeze

  acts_as_tenant(:organisation)

  # After acts_as_tenant: users have no organisation of their own.
  belongs_to :started_by, class_name: 'User', optional: true

  # A proposal outlives the run that found it: the database clears the
  # reference (on_delete: :nullify), without loading a proposal.
  has_many :glossary_proposals, dependent: nil

  enum :status, STATUSES.index_by(&:itself), validate: true

  # Terms, heard forms, runs and proposals share one right (GlossaryPolicy),
  # for authorize, policy and policy_scope alike.
  def self.policy_class
    GlossaryPolicy
  end

  validates :job_id, presence: true
  validates :error_code, inclusion: { in: ERROR_CODES }, allow_nil: true
  validate :scope_known

  def active?
    ACTIVE_STATUSES.include?(status)
  end

  # An active run that has not moved for STALE_AFTER: its worker is gone.
  def stale?
    active? && updated_at.present? && updated_at < STALE_AFTER.ago
  end

  def everything?
    scope.is_a?(Hash) && scope['everything'] == true
  end

  # Check the stored timestamp in the same UPDATE that ends the run. A
  # worker claim or heartbeat after stale? keeps its fresh, active row.
  def mark_stale!
    now = Time.current
    stale = self.class.unscoped.where(id: id, organisation_id: organisation_id, status: ACTIVE_STATUSES)
                .where('updated_at < ?', now - STALE_AFTER)
    fail_run(stale, 'stale', now: now)
  end

  # A run over one document (K5c), not over the organisation.
  def document?
    scope.is_a?(Hash) && scope['kind'] == DOCUMENT_KIND
  end

  # The version a run over one document reads; nil for a run over the
  # organisation.
  def document_version_id
    scope['document_version_id'] if document?
  end

  # Ends the run as failed with an error code, in ONE update_all whose
  # condition is the status of the row: true only when it changed the row,
  # then the copy in memory says the same. A run that already left the given
  # states keeps its row and gets false, never an exception; the copy in
  # memory stays as it was. An unknown code is a mistake of the caller and
  # raises before anything is written. The row is named by id and
  # organisation, without the tenant's scope, so a sweep without a tenant can
  # call it too.
  def mark_failed!(code, from: ACTIVE_STATUSES)
    raise ArgumentError, "unknown error code: #{code.inspect}" unless ERROR_CODES.include?(code)

    eligible = self.class.unscoped.where(id: id, organisation_id: organisation_id, status: from)
    fail_run(eligible, code, now: Time.current)
  end

  private

  def fail_run(eligible, code, now:)
    values = { status: 'failed', error_code: code, finished_at: now, updated_at: now }
    changed = eligible.update_all(values) == 1
    return false unless changed

    values.each { |name, value| self[name] = value }
    clear_attribute_changes(values.keys)
    true
  end

  # A known kind; a run over one document names a version of this
  # organisation, a run over the organisation names none.
  def scope_known
    kind = scope['kind'] if scope.is_a?(Hash)
    return errors.add(:scope, :inclusion, value: kind) unless SCOPE_KINDS.include?(kind)

    version_id = scope['document_version_id']
    if kind == DOCUMENT_KIND
      errors.add(:scope, :invalid) unless version_in_organisation?(version_id)
    elsif !version_id.nil?
      errors.add(:scope, :invalid)
    end
  end

  # Read without the tenant's scope, as TermCorrection checks its references:
  # a version of another organisation must fail, not read as "no row". The
  # uuid type reads a malformed id as no id, so it finds no row either. Asked
  # when the scope is written; the version may go later (the run fails then).
  def version_in_organisation?(version_id)
    return false unless version_id.is_a?(String) && version_id.present?
    return true unless will_save_change_to_scope?

    owner = ActsAsTenant.without_tenant { DocumentVersion.unscoped.where(id: version_id).pick(:organisation_id) }
    owner.present? && owner == organisation_id
  end
end
