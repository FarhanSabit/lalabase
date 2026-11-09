# frozen_string_literal: true

require 'rails_helper'

# What: a document as the source of a glossary extraction run (K5c): the
#   button "Begriffe fürs Glossar vorschlagen" in the lane of a document, and
#   the POST behind it (DocumentsController#propose_glossary_terms).
# Type: request spec.
# Why: the run reads the document with the rights of the person who starts it
#   and puts what it finds onto a list every reader of the glossary sees. So
#   the button is only there for manage_glossary, only in the lane of a
#   document the reader can read, and off with its reason while the document
#   has no text, there is no AI or a run is active; the POST asks both rights
#   and starts no run for a document of another organisation. The AI gate is
#   stubbed per key; invented words only.
RSpec.describe 'Organisations::Documents as a glossary source', :ci_guard, type: :request do
  include ActiveJob::TestHelper

  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  around do |example|
    original = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
    ActiveJob::Base.queue_adapter = original
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:gs) { 'views.organisations.documents.glossary_source' }
  let(:available) { Lalabase::Llm::FeatureRegistry::Availability.new(available: true) }
  let(:unavailable) do
    Lalabase::Llm::FeatureRegistry::Availability.new(available: false, reason: :no_credential, required_provider: 'openai')
  end

  before { ai(available) }

  def ai(availability)
    allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve).and_call_original
    allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve).with(:glossary_extraction, anything).and_return(availability)
  end

  def role_with(*glossary_actions)
    role = create(:role, organisation: organisation, title: "Rolle #{SecureRandom.hex(3)}")
    glossary_actions.each { |action| create(:permission, role: role, category: 'glossary', action: action, allowed: true) }
    role
  end

  # A member whose every right in the project comes from a project permission.
  def member_with(role, **areas)
    user = create(:user, first_name: 'Anna', last_name: "Beispiel#{SecureRandom.hex(2)}")
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    create(:project_permission, user: user, project: project, **areas) if areas.any?
    user
  end

  let(:manager) { member_with(role_with('manage_glossary'), documents_access: 'read_only') }

  def upload(type, name, content = 'Quarnix')
    Rack::Test::UploadedFile.new(StringIO.new(content), type, true, original_filename: name)
  end

  # A document with one version, current, holding text (nil: not read out yet).
  def document_with(text: 'Wir nutzen Quarnix im Team.', type: 'text/plain', name: 'zorbel.txt', project: self.project,
                    title: 'Zorbel-Handbuch', content: 'Quarnix')
    ActsAsTenant.with_tenant(project.organisation) do
      Prosopite.pause do
        doc = create(:document, organisation: project.organisation, project: project)
        version = create(:document_version, organisation: project.organisation, document: doc, title: title,
                                            plain_text_version: text, document_version_file: upload(type, name, content))
        doc.update!(current_version: version)
        doc
      end
    end
  end

  let(:document) { document_with }

  def lane(document = self.document)
    get organisation_project_knowledge_index_path(organisation, project, document_id: document.id)
  end

  def page
    Nokogiri::HTML(response.body)
  end

  def propose_path(document = self.document)
    propose_glossary_terms_organisation_project_document_path(organisation, project, document)
  end

  def propose_form
    page.at_css(%(form[action="#{propose_path}"]))
  end

  def propose_button
    propose_form&.at_css('button[type="submit"]')
  end

  def reason
    page.at_css('[data-document-glossary-reason]')&.text&.squish
  end

  def runs
    ActsAsTenant.with_tenant(organisation) { GlossaryExtractionRun.where(organisation: organisation).to_a }
  end

  def propose(document = self.document)
    post propose_path(document)
  end

  describe 'the button' do
    it 'offers the run to manage_glossary in the lane, on, leaving the frame for the review list' do
      sign_in manager

      lane

      expect(response).to have_http_status(:ok)
      expect(page.at_css('.document-content')).to be_present
      expect(propose_button.text.squish).to eq(I18n.t("#{gs}.propose"))
      expect(propose_button['disabled']).to be_nil
      expect(propose_button['title']).to eq(I18n.t("#{gs}.hint"))
      expect(propose_form['method']).to eq('post')
      expect(propose_form['data-turbo-frame']).to eq('_top')
      expect(propose_form.ancestors('.document-content')).to be_present
      expect(reason).to be_nil
    end

    it 'stands in the frame the lane loads as well' do
      sign_in manager

      get organisation_project_document_path(organisation, project, document, frame: 'content', frame_id: 'knowledge_display_frame')

      expect(response).to have_http_status(:ok)
      expect(propose_button['disabled']).to be_nil
    end

    {
      'view_glossary only' => ['view_glossary'],
      'no glossary right' => []
    }.each do |label, actions|
      it "is not there for a reader of the document with #{label}" do
        sign_in member_with(role_with(*actions), documents_access: 'read_write')

        lane

        expect(page.at_css('.document-content')).to be_present
        expect(propose_form).to be_nil
        expect(response.body).not_to include(I18n.t("#{gs}.propose"))
      end
    end

    it 'is not there for manage_glossary without the read right on the document: no lane, no button' do
      sign_in member_with(role_with('manage_glossary'), notes_access: 'read_only')

      lane

      expect(response).to have_http_status(:ok)
      expect(page.at_css('.labor-layout-view')).to be_present
      expect(page.at_css('.document-content')).to be_nil
      expect(propose_form).to be_nil
    end

    {
      'not read out yet' => [{ text: nil }, 'text_unavailable'],
      'of a type without text' => [{ text: nil, type: 'image/png', name: 'zorbel.png' }, 'text_unsupported'],
      'empty, as in a scanned file' => [{ text: '', type: 'application/pdf', name: 'zorbel.pdf' }, 'text_empty']
    }.each do |label, (file, key)|
      it "is off with its reason while the text is #{label}" do
        bare = document_with(**file)
        sign_in manager

        lane(bare)

        button = page.at_css(%(form[action="#{propose_path(bare)}"] button[type="submit"]))
        expect(button['disabled']).to eq('disabled')
        expect(reason).to eq(I18n.t("#{gs}.#{key}"))
        expect(button['aria-describedby']).to eq(page.at_css('[data-document-glossary-reason]')['id'])
      end
    end

    # unavailable is also the state of a file whose reading failed: the
    # service clears its text then. So the reason may not promise a reading.
    it 'says of a missing text that it is not read yet or could not be read, in both languages' do
      bare = document_with(text: nil)
      sign_in manager

      lane(bare)

      expect(reason).to eq(I18n.t("#{gs}.text_unavailable"))
      expect(I18n.t("#{gs}.text_unavailable", locale: :de)).to include('ließ sich nicht lesen')
      expect(I18n.t("#{gs}.text_unavailable", locale: :en)).to include('could not be read')
    end

    it 'turns on once a Markdown file that is not valid UTF-8 has been read' do
      latin1 = document_with(text: nil, type: 'text/markdown', name: 'kueche.md', content: "Die K\xFCche von Quarnix".b)
      Prosopite.pause { DocumentVersionProcessingJob.perform_now(latin1.current_version) }
      sign_in manager

      lane(latin1)

      expect(latin1.current_version.reload.plain_text_version).to eq("Die K\uFFFDche von Quarnix")
      expect(page.at_css(%(form[action="#{propose_path(latin1)}"] button[type="submit"]))['disabled']).to be_nil
      expect(reason).to be_nil
    end

    it 'takes a Markdown file with text as text' do
      markdown = document_with(text: '# Zorbel-Hub', type: 'text/markdown', name: 'zorbel.md')
      sign_in manager

      lane(markdown)

      expect(page.at_css(%(form[action="#{propose_path(markdown)}"] button[type="submit"]))['disabled']).to be_nil
    end

    it 'is off without AI for the extraction, in the words of the registry' do
      ai(unavailable)
      sign_in manager

      lane

      expect(propose_button['disabled']).to eq('disabled')
      expect(reason).to eq(Lalabase::Llm::FeatureRegistry.unavailable_hint(unavailable, organisation))
      expect(propose_button['aria-describedby']).to eq(page.at_css('[data-document-glossary-reason]')['id'])
    end

    # A queued run is as active as a running one (GlossaryExtractionRun::ACTIVE_STATUSES).
    %w[queued running].each do |status|
      it "is off while a #{status} run over the whole organisation is active" do
        create(:glossary_extraction_run, organisation: organisation, status: status,
                                         scope: { 'kind' => 'organisation', 'everything' => false, 'since' => nil })
        sign_in manager

        lane

        expect(propose_button['disabled']).to eq('disabled')
        expect(reason).to eq(I18n.t("#{gs}.run_active"))
      end

      it "is off while a #{status} run over a second document is active" do
        document
        second = document_with(title: 'Vexoria-Leitfaden', text: 'Wir nutzen Vexoria im Team.', name: 'leitfaden.txt')
        run = create(:glossary_extraction_run, organisation: organisation, status: status,
                                               scope: { 'kind' => 'document', 'document_version_id' => second.current_version_id,
                                                        'since' => nil })
        expect(second.id).not_to eq(document.id)
        expect(run.document_version_id).not_to eq(document.current_version_id)
        sign_in manager

        lane

        expect(propose_button['disabled']).to eq('disabled')
        expect(reason).to eq(I18n.t("#{gs}.run_active"))
      end

      it "counts a stale #{status} run as ended, as the bar of the review list does" do
        create(:glossary_extraction_run, organisation: organisation, status: status)
          .update_columns(updated_at: (GlossaryExtractionRun::STALE_AFTER + 1.minute).ago)
        sign_in manager

        lane

        expect(propose_button['disabled']).to be_nil
        expect(reason).to be_nil
      end

      it "does not count the #{status} run of another organisation" do
        other = create(:organisation)
        ActsAsTenant.with_tenant(other) { create(:glossary_extraction_run, organisation: other, status: status) }
        sign_in manager

        lane

        expect(propose_button['disabled']).to be_nil
      end
    end

    %w[de en].each do |locale|
      it "renders in #{locale} without a missing text" do
        bare = document_with(text: nil)
        manager.update!(language_preference: locale)
        sign_in manager

        lane(bare)

        expect(response.body).not_to include('translation missing', 'Translation missing')
        I18n.with_locale(locale) do
          expect(page.at_css(%(form[action="#{propose_path(bare)}"] button)).text.squish).to eq(I18n.t("#{gs}.propose"))
          expect(reason).to eq(I18n.t("#{gs}.text_unavailable"))
        end
      end
    end
  end

  describe 'refreshing the glossary control' do
    def refresh_control(chosen = document)
      get glossary_source_organisation_project_document_path(organisation, project, chosen),
          headers: { 'Turbo-Frame' => "document_#{chosen.id}_glossary_source" }
    end

    def polling?
      page.at_css('[data-controller="glossary-run-poll"]')['data-glossary-run-poll-active-value'] == 'true'
    end

    it 'refreshes only the control and stops polling once the text is available' do
      bare = document_with(text: nil)
      sign_in manager

      refresh_control(bare)

      expect(response).to have_http_status(:ok)
      expect(page.at_css("turbo-frame#document_#{bare.id}_glossary_source")).to be_present
      expect(page.at_css('.document-content')).to be_nil
      expect(page.at_css('button[disabled]')).to be_present
      expect(polling?).to be(true)

      Prosopite.pause { DocumentVersionProcessingJob.perform_now(bare.current_version) }
      refresh_control(bare)

      expect(page.at_css('button[disabled]')).to be_nil
      expect(reason).to be_nil
      expect(polling?).to be(false)
    end

    it 'stops polling when the file has been read and is empty' do
      bare = document_with(text: nil, content: '')
      sign_in manager
      Prosopite.pause { DocumentVersionProcessingJob.perform_now(bare.current_version) }

      refresh_control(bare)

      expect(page.at_css('button[disabled]')).to be_present
      expect(reason).to eq(I18n.t("#{gs}.text_empty"))
      expect(polling?).to be(false)
    end

    it 'waits for another run to end before enabling the control' do
      document
      run = create(:glossary_extraction_run, :running, organisation: organisation)
      sign_in manager

      refresh_control

      expect(propose_button['disabled']).to eq('disabled')
      expect(polling?).to be(true)

      run.mark_failed!('interrupted')
      refresh_control

      expect(propose_button['disabled']).to be_nil
      expect(polling?).to be(false)
    end

    it 'refuses a refresh after the glossary right is revoked' do
      sign_in manager
      refresh_control
      expect(response).to have_http_status(:ok)
      Permission.where(role: manager.role_in_organisation(organisation), category: 'glossary').update_all(allowed: false)

      refresh_control

      expect(response).to have_http_status(:forbidden)
      expect(propose_form).to be_nil
    end

    it 'refuses a refresh after the document read right is revoked' do
      sign_in manager
      refresh_control
      ProjectPermission.find_by!(user: manager, project: project).update!(documents_access: 'no_access')

      refresh_control

      expect(response).to redirect_to(organisation_project_path(organisation, project))
      expect(propose_form).to be_nil
    end

    it 'finds no document of another organisation' do
      other = create(:organisation)
      foreign_project = ActsAsTenant.with_tenant(other) { create(:project, organisation: other) }
      foreign = document_with(project: foreign_project)
      sign_in manager

      refresh_control(foreign)

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include(I18n.t("#{gs}.propose"))
    end

    it 'answers 404 when there is no current version' do
      bare = create(:document, organisation: organisation, project: project)
      sign_in manager

      refresh_control(bare)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'the start' do
    it 'starts a run over the current version, enqueues its job and lands on the review list' do
      document
      sign_in manager

      propose

      run = runs.sole
      expect(run).to have_attributes(status: 'queued', started_by_id: manager.id)
      expect(run.scope).to include('kind' => 'document', 'document_version_id' => document.current_version_id)
      expect(Glossary::ExtractionJob).to have_been_enqueued.with(run_id: run.id)
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, view: 'proposals'))
      expect(flash[:notice]).to eq(I18n.t('controllers.documents.propose_glossary_terms.success', title: 'Zorbel-Handbuch'))
    end

    it 'takes the version that is current now, not an older one' do
      sign_in manager
      newer = ActsAsTenant.with_tenant(organisation) do
        create(:document_version, organisation: organisation, document: document, title: 'Zorbel-Handbuch 2',
                                  plain_text_version: 'Wir nutzen Vexoria im Team.')
          .tap { |version| document.update!(current_version: version) }
      end

      propose

      expect(runs.sole.document_version_id).to eq(newer.id)
    end

    it "lands back on the document with the actor's reason when it refuses, and writes no run" do
      bare = document_with(text: nil)
      sign_in manager

      propose(bare)

      expect(runs).to be_empty
      expect(enqueued_jobs).to be_empty
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(organisation_project_knowledge_index_path(organisation, project, document_id: bare.id, type: 'all'))
      expect(flash[:alert]).to eq(I18n.t('controllers.glossary.runs.document_unavailable'))
    end

    %w[queued running].each do |status|
      it "refuses a second run while one is #{status}, in the words of the actor" do
        document
        create(:glossary_extraction_run, organisation: organisation, status: status)
        sign_in manager

        expect { propose }.not_to(change { runs.size })

        expect(flash[:alert]).to eq(I18n.t('controllers.glossary.runs.run_active'))
        expect(enqueued_jobs).to be_empty
      end
    end

    it 'refuses without AI, in the words of the registry' do
      document
      ai(unavailable)
      sign_in manager

      propose

      expect(runs).to be_empty
      expect(flash[:alert]).to eq(Lalabase::Llm::FeatureRegistry.unavailable_hint(unavailable, organisation))
    end

    {
      'view_glossary only' => ['view_glossary'],
      'no glossary right' => []
    }.each do |label, actions|
      it "answers 403 for a reader of the document with #{label}, and writes nothing" do
        document
        sign_in member_with(role_with(*actions), documents_access: 'read_write')

        propose

        expect(response).to have_http_status(:forbidden)
        expect(runs).to be_empty
        expect(enqueued_jobs).to be_empty
      end
    end

    it 'refuses manage_glossary without the read right on the document as the documents controller does, and writes nothing' do
      document
      sign_in member_with(role_with('manage_glossary'), notes_access: 'read_only')

      propose

      expect(response).to redirect_to(organisation_project_path(organisation, project))
      expect(flash[:alert]).to eq(I18n.t('flash.shared.not_authorized'))
      expect(runs).to be_empty
      expect(enqueued_jobs).to be_empty
    end

    describe 'a document of another organisation' do
      let(:other) { create(:organisation) }
      let(:other_project) { ActsAsTenant.with_tenant(other) { create(:project, organisation: other) } }
      let(:foreign) { document_with(project: other_project) }

      def foreign_runs
        ActsAsTenant.without_tenant { GlossaryExtractionRun.where(organisation_id: [organisation.id, other.id]).to_a }
      end

      # One request per example: after a 404 the test session is signed out.
      it 'answers 404 by its id under a project of this organisation, and writes no run' do
        foreign
        sign_in manager

        propose(foreign)

        expect(response).to have_http_status(:not_found)
        expect(foreign_runs).to be_empty
        expect(enqueued_jobs).to be_empty
      end

      it 'sends the address of an organisation the reader is not in to the organisation picker, and writes no run' do
        foreign
        sign_in manager

        post propose_glossary_terms_organisation_project_document_path(other, other_project, foreign)

        expect(response).to redirect_to(select_organisation_path)
        expect(foreign_runs).to be_empty
      end

      it 'finds no project of another organisation in this address, and writes no run' do
        foreign
        sign_in manager

        post propose_glossary_terms_organisation_project_document_path(organisation, other_project, foreign)

        expect(response).to redirect_to(organisation_projects_path(organisation))
        expect(foreign_runs).to be_empty
      end
    end

    it 'answers 404 for a document that is not there' do
      sign_in manager

      post propose_glossary_terms_organisation_project_document_path(organisation, project, SecureRandom.uuid)

      expect(response).to have_http_status(:not_found)
      expect(runs).to be_empty
    end

    # Without a version the actor would start a run over the whole
    # organisation: the controller never hands it a document's nil.
    it 'answers 404 for a document without a current version, and starts no run over the organisation' do
      bare = ActsAsTenant.with_tenant(organisation) { create(:document, organisation: organisation, project: project) }
      sign_in manager

      propose(bare)

      expect(response).to have_http_status(:not_found)
      expect(runs).to be_empty
      expect(enqueued_jobs).to be_empty
    end
  end
end
