# frozen_string_literal: true

# Where a proposal of the glossary extraction was found (K5b): one ticket,
# comment, ticket file, comment file, note or document version, how often the
# term stands in it, and a short snippet around it. The run keeps up to
# GlossaryProposal::MAX_SOURCES per proposal.
#
# The source is polymorphic and has NO foreign key: a deleted source leaves
# the row, and the page asks when it shows the row whether the source is
# still there and whether the reader may read it. The run wrote it from what
# the starting account could read; that says nothing about the reader.
#
# Deleting the proposal or the organisation takes the row along; deleting the
# project only clears project_id (in the database).
class GlossaryProposalSource < ApplicationRecord
  # The references to rows of an organisation, declared BEFORE acts_as_tenant:
  # acts_as_tenant 1.0.1 checks the tenant only of references declared before
  # the call, and only through the current tenant. same_organisation_references
  # holds them to the row's organisation on top, with or without a tenant set.
  TENANT_REFERENCES = %i[glossary_proposal project].freeze

  belongs_to :glossary_proposal
  belongs_to :project, optional: true

  acts_as_tenant(:organisation)

  # acts_as_tenant checks no polymorphic reference; source_in_organisation
  # does, for the six kinds of SOURCE_TYPES.
  belongs_to :source, polymorphic: true, optional: true

  SOURCE_TYPES = %w[Ticket Post TicketDocument PostDocument Note DocumentVersion].freeze
  MAX_SNIPPET = 240

  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validates :source_id, presence: true
  validates :snippet, length: { maximum: MAX_SNIPPET }
  validates :occurrences, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validate :same_organisation_references
  validate :source_in_organisation

  private

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

  # The source row must be there and belong to this organisation when the
  # source is written; later it may go (see above). All six tables of
  # SOURCE_TYPES carry organisation_id themselves (not null), so the row is
  # asked directly, without the tenant's scope, and none through a parent.
  def source_in_organisation
    return unless SOURCE_TYPES.include?(source_type) && source_id.present?
    return unless will_save_change_to_source_type? || will_save_change_to_source_id?

    model = self.class.polymorphic_class_for(source_type)
    owner = ActsAsTenant.without_tenant { model.unscoped.where(id: source_id).pick(:organisation_id) }
    errors.add(:source, :invalid) unless owner && owner == organisation_id
  end
end
