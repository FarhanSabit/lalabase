# frozen_string_literal: true

# A heard form of a glossary term (K4a): what speech recognition wrote, who
# spoke, in which project and where in the transcript. One row per
# correction, not per form: "how often and by whom" is a query, not a counter
# that can drift. K4b writes the rows; K4a shows them and deletes one that was
# learnt wrong.
#
# The speaker is a person of the directory (person_id) or a member
# (user_id), at most one of them, the rule of meeting_participants: the
# validation one_speaker and the check constraint term_corrections_one_speaker
# (which also catches update_all) hold it. A speaker without a link stays
# empty.
#
# Deleting the meeting keeps the row with its place (line_index, char_offset,
# transcript_digest) and only clears meeting_id (E4, on_delete: :nullify; see
# Meeting#purge_fragment_content_embeddings). Deleting the project or the
# person clears the origin or the speaker the same way. Deleting the term or
# the organisation takes the row with it.
#
# Every row has a status of its own (K4b, E3): a correction in a meeting
# without manage_glossary is proposed, also at a confirmed term, so it works
# nowhere before someone with the right confirmed it. Rows written before K4b
# are confirmed (the column's default; the check constraint
# term_corrections_status_known holds the two values). What works is a
# confirmed row at a confirmed term: .effective, the one reader K4c and the
# device (M4) go through.
#
# Every row also says where it came from (origin, K5b): a correction in a
# meeting, a proposal of the glossary extraction or an import; rows written
# before K5b came from meetings (the column's default, held by the check
# constraint term_corrections_origin_known), and .effective does not read it.
class TermCorrection < ApplicationRecord
  # The references to rows of an organisation, declared BEFORE acts_as_tenant:
  # acts_as_tenant 1.0.1 checks the tenant only of references declared before
  # the call, and only through the current tenant. same_organisation_references
  # holds them to the row's organisation on top, with or without a tenant set.
  TENANT_REFERENCES = %i[glossary_term project person meeting].freeze

  belongs_to :glossary_term
  belongs_to :project, optional: true
  belongs_to :person, optional: true
  belongs_to :meeting, optional: true

  acts_as_tenant(:organisation)

  # The speaker as a member, and who corrected. Users have no organisation of
  # their own; the speaker must be a member of this one.
  belongs_to :user, optional: true
  belongs_to :corrected_by, class_name: 'User', optional: true

  DIGEST_FORMAT = /\A\h{64}\z/
  STATUSES = %w[proposed confirmed].freeze
  ORIGINS = %w[meeting extraction import].freeze

  enum :status, STATUSES.index_by(&:itself), validate: true

  # Terms and heard forms share one right (GlossaryPolicy), for authorize,
  # policy and policy_scope alike.
  def self.policy_class
    GlossaryPolicy
  end

  # The heard forms that work: confirmed, at a confirmed term. A proposal (at
  # any term) and any form of a proposed or rejected term do not. Inside the
  # tenant like every other query of this model.
  scope :effective, -> { confirmed.joins(:glossary_term).merge(GlossaryTerm.confirmed) }

  before_validation :normalize_heard

  validates :heard, presence: true, length: { maximum: GlossaryTerm::MAX_LENGTH }
  validates :normalized_heard, presence: true
  validates :origin, inclusion: { in: ORIGINS }
  validates :replaced_count, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :line_index, :char_offset, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :transcript_digest, format: { with: DIGEST_FORMAT }, allow_nil: true
  validate :one_speaker
  validate :same_organisation_references
  validate :speaker_is_member, if: -> { user_id.present? && will_save_change_to_user_id? }

  # Newest first within a heard form: the order of the lane.
  scope :in_lane_order, -> { order(:normalized_heard, created_at: :desc, id: :asc) }

  # Whether a speaker is linked at all (a member or a row of the directory).
  def speaker?
    user_id.present? || person_id.present?
  end

  private

  def normalize_heard
    self.heard = GlossaryText.clean(heard) unless heard.nil?
    self.normalized_heard = GlossaryText.normalize(heard)
  end

  def one_speaker
    errors.add(:base, :one_speaker) if person_id.present? && user_id.present?
  end

  # Read without the tenant's scope: a reference to a row of another
  # organisation must fail, not read as "no row" (an optional reference would
  # pass that way and keep the foreign id).
  def same_organisation_references
    TENANT_REFERENCES.each do |name|
      reflection = self.class.reflect_on_association(name)
      id = public_send(reflection.foreign_key)
      next if id.blank? || !will_save_change_to_attribute?(reflection.foreign_key)

      owner = ActsAsTenant.without_tenant { reflection.klass.unscoped.where(id: id).pick(:organisation_id) }
      errors.add(name, :invalid) unless owner && owner == organisation_id
    end
  end

  def speaker_is_member
    return if Membership.exists?(organisation_id: organisation_id, user_id: user_id)

    errors.add(:user, :invalid)
  end
end
