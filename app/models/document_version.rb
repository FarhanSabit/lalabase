# frozen_string_literal: true

# == Schema Information
#
# Table name: document_versions
#
#  id                       :uuid             not null, primary key
#  create_embeddings        :boolean          default(TRUE)
#  create_summary           :boolean          default(FALSE)
#  description              :text
#  embedding_creation_error :text
#  embeddings_creation_flag :boolean
#  generated_summary        :text             default("")
#  number                   :integer
#  plain_text_version       :text
#  plain_text_word_count    :integer
#  summary_creation_error   :text             default("")
#  summary_creation_flag    :boolean          default(FALSE)
#  title                    :string
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  document_id              :uuid             not null
#  organisation_id          :uuid             not null
#  user_id                  :uuid
#
# Indexes
#
#  index_document_versions_on_document_id      (document_id)
#  index_document_versions_on_document_id_and_number  (document_id,number) UNIQUE
#  index_document_versions_on_organisation_id  (organisation_id)
#  index_document_versions_on_user_id          (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#

class DocumentVersion < ApplicationRecord
  include ActionView::RecordIdentifier

  # Multi-tenant support
  acts_as_tenant(:organisation)

  has_one_attached :document_version_file

  # Associations
  belongs_to :document
  # Uploader of this version. Optional: historic versions predate the column
  # and have no recorded uploader (shown as "Unknown" in the UI).
  belongs_to :user, optional: true

  # Fragments for embeddings
  has_many :fragments, as: :fragmentable, dependent: :destroy

  # The versions as the document view lists them: newest first, with the
  # uploader and the file preloaded (the row names both), ONE owner for the
  # page load (knowledge/_knowledge_lane) and the frame request
  # (documents#show). The lane used to load them bare and paid a query per row.
  scope :listed, -> { with_attached_document_version_file.includes(:user).order(created_at: :desc) }

  # Validations
  validates :title, presence: true
  validates :document_version_file, presence: true
  # v1, v2, ... per document (doc/dokumentansicht_plan.md, S1): assigned by the
  # actors on create (Document#next_version_number), by documents:number_versions
  # for the stock. Nil is allowed until that task has run; the unique index
  # holds the pair at the database as well.
  validates :number, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :document_id }, allow_nil: true

  # "v3" wherever the version is named; nil before the stock is numbered.
  def label
    number ? "v#{number}" : nil
  end

  # What a reader may say about this version's text, in the four words of
  # ExtractPlainTextProcessingService.text_status (a version without a file is
  # unavailable). The ONE rule for "has text": the button in the lane, the start
  # of a glossary run over this version, the run itself (Glossary::Extraction)
  # and Lalabase::Tools::GetDocument all ask here, so none of them can disagree
  # on the same version.
  def text_status
    ExtractPlainTextProcessingService.file_text_status(plain_text_version, document_version_file)
  end

  def text_available?
    text_status == 'available'
  end

  after_update_commit -> { broadcast_updated }

  # The row, and the head's AI status with it (review of #783): the status
  # reads the CURRENT version's flag, and a retry that succeeds while the
  # document is open would otherwise clear the row's failure and leave the
  # head's standing. Both partials render without a viewer on this road
  # (ApplicationHelper#viewer_user), and the status takes the organisation
  # as a local because there is no @current_organisation here.
  def broadcast_updated
    stream = "#{dom_id(document)}_document_versions"
    broadcast_replace_to(
      stream,
      partial: 'organisations/documents/version_row',
      locals: { version: self, project: document.project, document: document, scroll_to: false },
      target: "#{dom_id(self)}_document_versions"
    )
    broadcast_replace_to(
      stream,
      partial: 'organisations/documents/ai_state',
      locals: { document: document, organisation: document.organisation },
      target: "#{dom_id(document)}_ai_state"
    )
  end
end
