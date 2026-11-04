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

  # Terms and heard forms share one right (GlossaryPolicy), for authorize,
  # policy and policy_scope alike.
  def self.policy_class
    GlossaryPolicy
  end

  before_validation :normalize_heard

  validates :heard, presence: true, length: { maximum: GlossaryTerm::MAX_LENGTH }
  validates :normalized_heard, presence: true
  validates :replaced_count, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :line_index, :char_offset, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :transcript_digest, format: { with: DIGEST_FORMAT }, allow_nil: true
  validate :one_speaker
  validate :same_organisation_references
  validate :speaker_is_member, if: -> { user_id.present? && will_save_change_to_user_id? }

  # Newest first within a heard form: the order of the lane.
  scope :in_lane_order, -> { order(:normalized_heard, created_at: :desc, id: :asc) }

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
