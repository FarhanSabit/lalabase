# frozen_string_literal: true

# A proposal of the glossary extraction (K5b): a term a run found in the texts
# of an organisation, for a person to accept (into the glossary), merge or
# dismiss. One proposal per compared form (normalized_term, GlossaryText) and
# organisation, like a glossary term; its other spellings, grouped by
# GlossaryText.compact, stand in variants. A run keeps up to MAX_SOURCES
# places where it found the term (GlossaryProposalSource).
#
# status: open, accepted, dismissed. glossary_term is the term an accepted
# proposal became or was merged into; decided_by and decided_at say who
# decided and when.
#
# Deleting the organisation takes the proposal along, deleting the proposal
# takes its sources along; deleting the run, the glossary term or the account
# that decided only clears the reference (all in the database). The check
# constraints repeat the rules on category, variants, status and occurrences
# for a write past the model.
#
# Rights: GlossaryPolicy (accept?, dismiss?, restore? ask manage_glossary).
class GlossaryProposal < ApplicationRecord
  # The references to rows of an organisation, declared BEFORE acts_as_tenant:
  # acts_as_tenant 1.0.1 checks the tenant only of references declared before
  # the call, and only through the current tenant. same_organisation_references
  # holds them to the row's organisation on top, with or without a tenant set.
  TENANT_REFERENCES = %i[glossary_extraction_run glossary_term].freeze

  belongs_to :glossary_extraction_run, optional: true
  belongs_to :glossary_term, optional: true

  acts_as_tenant(:organisation)

  # After acts_as_tenant: users have no organisation of their own.
  belongs_to :decided_by, class_name: 'User', optional: true

  # The database deletes them with the proposal (on_delete: :cascade), in one
  # statement and with or without a tenant set.
  has_many :glossary_proposal_sources, dependent: nil

  STATUSES = %w[open accepted dismissed].freeze
  MAX_VARIANTS = 10
  MAX_HINT = 160
  MAX_SOURCES = 5

  # Authorization provenance of the hint: every snippet source in the model
  # call, including other and dropped candidates. These references survive
  # trimming/merging the example sources and never come from model output.
  HintSource = Data.define(:source_type, :source_id)
  SOURCE_ID_FORMAT = /\A\h{8}(?:-\h{4}){3}-\h{12}\z/

  enum :status, STATUSES.index_by(&:itself), validate: true

  # Terms, heard forms, runs and proposals share one right (GlossaryPolicy),
  # for authorize, policy and policy_scope alike.
  def self.policy_class
    GlossaryPolicy
  end

  before_validation :clean_values

  validates :term, presence: true, length: { maximum: GlossaryTerm::MAX_LENGTH }
  validates :normalized_term, presence: true
  validates :category, inclusion: { in: GlossaryTerm::CATEGORIES }, allow_nil: true
  validates :hint, length: { maximum: MAX_HINT }
  validates :occurrences, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :term_not_taken
  validate :variants_shape
  validate :hint_sources_shape
  validate :same_organisation_references

  # The most frequent first, then by spelling: the order of the review list.
  scope :in_review_order, -> { order(occurrences: :desc, normalized_term: :asc, id: :asc) }

  # Missing or malformed provenance grants no access, also for rows written
  # before the column existed or past validation. Current source rights are
  # resolved by GlossaryHelper within the reader's organisation.
  def hint_source_references
    return [] unless hint_sources.is_a?(Array)

    hint_sources.map do |source|
      return [] unless source.is_a?(Hash) && source.keys.sort == %w[source_id source_type] &&
                       GlossaryProposalSource::SOURCE_TYPES.include?(source['source_type']) &&
                       source['source_id'].is_a?(String) && source['source_id'].match?(SOURCE_ID_FORMAT)

      HintSource.new(source_type: source['source_type'], source_id: source['source_id'])
    end
  end

  private

  def hint_sources_shape
    errors.add(:hint_sources, :invalid) unless hint_sources.is_a?(Array) && hint_source_references.size == hint_sources.size
  end

  # The term as GlossaryTerm cleans it; a variant through the same cleaning,
  # without blanks, without a second spelling of one compared form and
  # without the term itself. Anything in variants that is no text stays for
  # variants_shape to refuse.
  def clean_values
    self.term = GlossaryText.clean(term) unless term.nil?
    self.normalized_term = GlossaryText.normalize(term)
    self.category = category.presence
    self.hint = GlossaryText.clean(hint)
    self.variants = cleaned_variants if variants.is_a?(Array)
  end

  def cleaned_variants
    seen = Set[normalized_term]
    variants.each_with_object([]) do |variant, kept|
      if variant.is_a?(String)
        cleaned = GlossaryText.clean(variant)
        kept << cleaned if cleaned.present? && seen.add?(GlossaryText.normalize(cleaned))
      elsif !variant.nil?
        kept << variant
      end
    end
  end

  # One proposal per compared form and organisation, as GlossaryTerm keeps one
  # term. The message stands on term, the field a person reads. The unique
  # index catches two saves at once.
  def term_not_taken
    return if normalized_term.blank? || !will_save_change_to_normalized_term?
    return unless self.class.where(organisation_id: organisation_id, normalized_term: normalized_term).where.not(id: id).exists?

    errors.add(:term, :taken)
  end

  # A list of at most MAX_VARIANTS texts, each no longer than a term. The
  # check constraint glossary_proposals_variants_shape holds the list and the
  # texts in the database too. Positions count from 1.
  def variants_shape
    return errors.add(:variants, :not_a_list) unless variants.is_a?(Array)
    return errors.add(:variants, :too_many, count: MAX_VARIANTS) if variants.size > MAX_VARIANTS

    variants.each.with_index(1) do |variant, position|
      if !variant.is_a?(String)
        errors.add(:variants, :not_text, position: position)
      elsif variant.length > GlossaryTerm::MAX_LENGTH
        errors.add(:variants, :variant_too_long, position: position, count: GlossaryTerm::MAX_LENGTH)
      end
    end
  end

  # Read without the tenant's scope: a reference to a row of another
  # organisation must fail, not read as "no row" (an optional reference would
  # pass that way and keep the foreign id). The rule of TermCorrection.
  def same_organisation_references
    TENANT_REFERENCES.each do |name|
      reflection = self.class.reflect_on_association(name)
      id = public_send(reflection.foreign_key)
      next if id.blank? || !will_save_change_to_attribute?(reflection.foreign_key)

      owner = ActsAsTenant.without_tenant { reflection.klass.unscoped.where(id: id).pick(:organisation_id) }
      errors.add(name, :invalid) unless owner && owner == organisation_id
    end
  end
end
