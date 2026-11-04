# frozen_string_literal: true

# One term of the glossary of an organisation (K4a), in its right spelling.
# The glossary holds for the whole organisation, not per project (E1); the
# project stays on every heard form (TermCorrection) as its origin.
#
# normalized_term (GlossaryText) is unique per organisation: "Lalabase" and
# "lalabase" are one term. status (E5): proposed, confirmed, rejected. Only
# K4b and K5 propose; a term written by hand is confirmed. A rejected term
# stays, so it is not proposed again.
#
# Rights: GlossaryPolicy (view_glossary / manage_glossary). Writes go through
# the glossary actors (Actors::SaveGlossaryTerm and its siblings).
class GlossaryTerm < ApplicationRecord
  CATEGORIES = %w[person company product place domain foreign].freeze
  STATUSES = %w[proposed confirmed rejected].freeze
  MAX_LENGTH = 255

  belongs_to :created_by, class_name: 'User', optional: true

  acts_as_tenant(:organisation)

  # The database removes them too (on_delete: :cascade); delete_all says the
  # same in Rails and runs one DELETE, no callbacks.
  has_many :term_corrections, dependent: :delete_all

  enum :status, STATUSES.index_by(&:itself), validate: true

  # Terms and heard forms share one right (GlossaryPolicy), for authorize,
  # policy and policy_scope alike.
  def self.policy_class
    GlossaryPolicy
  end

  before_validation :normalize_term

  validates :term, presence: true, length: { maximum: MAX_LENGTH }
  validates :normalized_term, presence: true
  validates :category, inclusion: { in: CATEGORIES }, allow_nil: true
  validate :term_not_taken

  # Open proposals first, then confirmed, then rejected (STATUSES), each by
  # spelling.
  scope :ordered, -> { in_order_of(:status, STATUSES).order(:normalized_term, :id) }

  private

  def normalize_term
    self.term = GlossaryText.clean(term) unless term.nil?
    self.normalized_term = GlossaryText.normalize(term)
    self.category = category.presence
  end

  # One spelling once per organisation, compared in normalized form. The
  # message stands on term, the field the writer typed. The unique index
  # catches two saves at once (the actors map RecordNotUnique to the same
  # message).
  def term_not_taken
    return if normalized_term.blank? || !will_save_change_to_normalized_term?
    return unless self.class.where(organisation_id: organisation_id, normalized_term: normalized_term).where.not(id: id).exists?

    errors.add(:term, :taken)
  end
end
