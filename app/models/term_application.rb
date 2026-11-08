# frozen_string_literal: true

# What the glossary did to a meeting (K4d): one heard spelling the recording
# app replaced by a term before it sent the transcript, and how often. Not a
# correction (TermCorrection): nothing was learnt, nothing is confirmed or
# proposed here, and TermCorrection.effective never sees these rows. They show
# a reader that the glossary worked, on the meeting page and under the heard
# form of the term.
#
# A row belongs to its meeting and goes with it (on_delete: :cascade). The term
# is found by its normalized spelling when the row is written and may be gone
# later (deleted: the reference is cleared, `term` keeps the spelling; merged:
# Actors::MergeGlossaryTerms moves the reference). A heard form deleted in the
# glossary as learnt wrong leaves its applications standing: they lead to the
# meetings it was applied in (plan m4d §3, decided 08.11.2026).
#
# Written only by Meetings::Intake (.record!), in the transaction of the
# meeting it belongs to. Invented words only in tests.
class TermApplication < ApplicationRecord
  # The references to rows of an organisation, declared BEFORE acts_as_tenant
  # (see TermCorrection::TENANT_REFERENCES).
  TENANT_REFERENCES = %i[meeting project glossary_term].freeze

  SOURCES = %w[device].freeze
  # Rows one meeting may bring. A transcript of two hours has a few dozen.
  MAX_ENTRIES = 500

  belongs_to :meeting
  belongs_to :project, optional: true
  belongs_to :glossary_term, optional: true

  acts_as_tenant(:organisation)

  enum :source, SOURCES.index_by(&:itself), validate: true

  before_validation :normalize

  validates :term, presence: true, length: { maximum: GlossaryTerm::MAX_LENGTH }
  validates :heard, presence: true, length: { maximum: GlossaryTerm::MAX_LENGTH }
  validates :normalized_heard, presence: true
  validates :replaced_count, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validate :same_organisation_references

  # The order of the list on the meeting: as written, then by spelling.
  scope :in_text_order, -> { order(:created_at, :normalized_heard, :heard, :id) }

  # Whether only the spelling was righted: the heard form is the term in another
  # case or spacing. Such a form was never learnt, the glossary shows it at the term.
  def spelling?
    GlossaryText.normalize(heard) == GlossaryText.normalize(term)
  end

  # Writes what a device reports with a meeting (Meetings::Intake). entries are
  # the checked rows { heard:, term:, count: } (strings cleaned, count >= 1); one
  # spelling sent twice is summed. The term is looked up by its normalized
  # spelling in the meeting's organisation; none found (deleted since the device
  # fetched its glossary) leaves the reference empty. Two statements whatever the
  # length of the list (one lookup, one insert): the rows were checked by the
  # caller, and every reference comes from the meeting itself or from a query
  # bound to its organisation. Runs in the caller's transaction.
  def self.record!(meeting:, entries:)
    summed = {}
    entries.each do |entry|
      heard = GlossaryText.clean(entry[:heard])
      key = [GlossaryText.normalize(heard), heard]
      row = summed[key] ||= { heard: heard, term: GlossaryText.clean(entry[:term]), count: 0 }
      row[:count] += entry[:count]
    end
    return 0 if summed.empty?

    terms = GlossaryTerm.where(organisation_id: meeting.organisation_id,
                               normalized_term: summed.values.map { |row| GlossaryText.normalize(row[:term]) }.uniq)
                        .pluck(:normalized_term, :id).to_h
    rows = summed.map do |(normalized_heard, heard), row|
      { organisation_id: meeting.organisation_id, meeting_id: meeting.id, project_id: meeting.project_id,
        glossary_term_id: terms[GlossaryText.normalize(row[:term])], term: row[:term],
        heard: heard, normalized_heard: normalized_heard, replaced_count: row[:count], source: 'device' }
    end
    insert_all!(rows).length
  end

  private

  def normalize
    self.term = GlossaryText.clean(term) unless term.nil?
    self.heard = GlossaryText.clean(heard) unless heard.nil?
    self.normalized_heard = GlossaryText.normalize(heard)
  end

  # Read without the tenant's scope: a reference to a row of another
  # organisation must fail, not read as "no row" (see TermCorrection).
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
