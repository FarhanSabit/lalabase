# frozen_string_literal: true

# One run of the glossary extraction (K5b): a background job that reads the
# tickets, public comments, attachments, notes and documents of an
# organisation that the starting account may read, finds candidate terms
# without AI, lets a model classify them and stores GlossaryProposal rows for
# a person to accept, merge or dismiss.
#
# One active run (queued or running) per organisation: the partial unique
# index one_active_glossary_extraction_run refuses a second one, also for two
# starts at the same moment. A run that has not moved for STALE_AFTER is
# stale; mark_failed! ends it by the row, not by the copy in memory.
#
# Both JSONB columns read with string keys, also right after a Hash with
# symbol keys was assigned (the JSONB type casts through JSON).
#
# scope, what the run read:
#   { "kind" => "organisation" (SCOPE_KINDS), "everything" => true | false,
#     "since" => an ISO 8601 time or nil: the bound the run used }
# stats, what it found (written by the run):
#   { "sources" => { "tickets", "posts", "ticket_documents", "post_documents",
#                    "notes", "document_versions" => count },
#     "projects_reached", "projects_total", "candidates", "ai_calls",
#     "proposals_created", "proposals_updated" => count,
#     "truncated" => true | false }
#
# Deleting the organisation takes its runs along; deleting the account that
# started one only clears started_by_id (both in the database). Rights:
# GlossaryPolicy (start? asks manage_glossary).
class GlossaryExtractionRun < ApplicationRecord
  STATUSES = %w[queued running succeeded failed].freeze
  ACTIVE_STATUSES = %w[queued running].freeze
  STALE_AFTER = 10.minutes
  SCOPE_KINDS = %w[organisation].freeze
  ERROR_CODES = %w[starter_inactive ai_unavailable ai_disabled not_configured quota_exceeded invalid_key
                   provider_error parse_error interrupted stale internal_error].freeze

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
  validate :scope_kind_known

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

    now = Time.current
    values = { status: 'failed', error_code: code, finished_at: now, updated_at: now }
    changed = self.class.unscoped.where(id: id, organisation_id: organisation_id, status: from).update_all(values) == 1
    return false unless changed

    values.each { |name, value| self[name] = value }
    clear_attribute_changes(values.keys)
    true
  end

  private

  def scope_kind_known
    kind = scope['kind'] if scope.is_a?(Hash)
    errors.add(:scope, :inclusion, value: kind) unless SCOPE_KINDS.include?(kind)
  end
end
