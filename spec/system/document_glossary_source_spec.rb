# frozen_string_literal: true

require 'rails_helper'

# The page is already open when the processing job finishes. Request specs
# alone cannot catch a button that keeps its initial disabled state.
RSpec.describe 'Document glossary source readiness', type: :system do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:document) { create(:document, organisation: organisation, project: project) }
  let(:version) do
    create(:document_version, organisation: organisation, document: document,
                              plain_text_version: nil, create_embeddings: false, create_summary: false)
  end
  let(:button_label) { I18n.t('views.organisations.documents.glossary_source.propose') }
  let(:availability) { Lalabase::Llm::FeatureRegistry::Availability.new(available: true) }

  before do
    driven_by :selenium_chrome_headless_full
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, active: true,
                        role: create(:admin_role, organisation: organisation))
    document.update!(current_version: version)
    allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve).and_call_original
    allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve).with(:glossary_extraction, anything).and_return(availability)
    sign_in user
  end

  after { Prosopite.resume }

  it 'enables the button after processing without replacing the page or document lane' do
    visit organisation_project_knowledge_index_path(organisation, project, document_id: document.id)
    expect(page).to have_button(button_label, disabled: true)
    page.execute_script("window.originalDocumentLane = document.querySelector('.document-content')")

    DocumentVersionProcessingJob.perform_now(version)

    expect(page).to have_button(button_label, disabled: false, wait: 12)
    expect(page).to have_no_css('[data-document-glossary-reason]')
    expect(page.evaluate_script("window.originalDocumentLane === document.querySelector('.document-content')")).to be(true)
  end
end
