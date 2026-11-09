# frozen_string_literal: true

require 'rails_helper'

# The run bar on top of the review list (K5b) and the start of a run behind
# its button. Every reader of the glossary sees the line about the last run;
# only manage_glossary sees the button, which is off with its reason while a
# run is active or without AI for the extraction. While a run is queued or
# running the bar asks the page to reload the list (glossary-run-poll). The
# start goes through Actors::StartGlossaryExtraction and lands on the review
# list. The AI gate is stubbed per key; invented words only.
RSpec.describe 'Organisations::Glossary runs', :ci_guard, type: :request do
  include ActiveJob::TestHelper

  let(:organisation) { create(:organisation) }

  around do |example|
    original = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
    ActiveJob::Base.queue_adapter = original
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def role_with(*glossary_actions)
    role = create(:role, organisation: organisation)
    glossary_actions.each { |action| create(:permission, role: role, category: 'glossary', action: action, allowed: true) }
    role
  end

  def member_with(role)
    user = create(:user, first_name: 'Anna', last_name: "Beispiel#{SecureRandom.hex(2)}")
    create(:membership, user: user, organisation: organisation, role: role)
    user
  end

  let(:viewer) { member_with(role_with('view_glossary')) }
  let(:manager) { member_with(role_with('manage_glossary')) }
  let(:nobody) { member_with(role_with) }

  let(:available) { Lalabase::Llm::FeatureRegistry::Availability.new(available: true) }
  let(:unavailable) do
    Lalabase::Llm::FeatureRegistry::Availability.new(available: false, reason: :no_credential, required_provider: 'openai')
  end
  let(:gr) { 'views.organisations.glossary.runs' }

  def ai(availability)
    allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve).and_call_original
    allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve).with(:glossary_extraction, anything).and_return(availability)
  end

  def review_list(**params)
    get organisation_glossary_terms_path(organisation, view: 'proposals', **params)
  end

  def page
    Nokogiri::HTML(response.body)
  end

  def bar
    page.at_css('[data-glossary-run-bar]')
  end

  def start_form
    bar.at_css(%(form[action="#{runs_organisation_glossary_terms_path(organisation)}"]))
  end

  def start_button
    start_form.at_css('button[type="submit"]')
  end

  def reason
    bar.at_css('[data-glossary-run-reason]')&.text&.squish
  end

  # The line about the last run, for every reader: running, finished, failed
  # or none yet.
  def status_line
    bar.at_css('[data-glossary-run-status]')&.text&.squish
  end

  # The start of a run as the bar names it: a clock time in the reader's zone.
  def clock(run, reader)
    I18n.l(run.created_at.in_time_zone(reader.time_zone), format: :long)
  end

  def run_of(status, **attributes)
    create(:glossary_extraction_run, organisation: organisation, started_by: manager, status: status, **attributes)
  end

  def runs
    GlossaryExtractionRun.where(organisation: organisation)
  end

  def start(**params)
    post runs_organisation_glossary_terms_path(organisation), params: { view: 'proposals' }.merge(params)
  end

  describe 'the bar' do
    it 'offers the start and the full read to manage_glossary, and says that nothing ran yet' do
      ai(available)
      sign_in manager

      review_list

      expect(response).to have_http_status(:ok)
      expect(start_button.text.squish).to eq(I18n.t("#{gr}.start"))
      expect(start_button['disabled']).to be_nil
      expect(start_form['data-turbo-frame']).to eq('_top')
      box = start_form.at_css('input[type="checkbox"][name="everything"]')
      expect([box['value'], box['checked']]).to eq(['1', nil])
      expect(start_form.text.squish).to include(I18n.t("#{gr}.everything"))
      expect(start_form.at_css('input[name="view"]')['value']).to eq('proposals')
      expect(reason).to be_nil
      expect(status_line).to eq(I18n.t("#{gr}.never"))
      expect(bar['data-controller']).to eq('glossary-run-poll')
      expect(bar['data-glossary-run-poll-active-value']).to eq('false')
    end

    it 'turns the start off without AI and says why, in the words of the registry' do
      ai(unavailable)
      sign_in manager

      review_list

      expect(start_button['disabled']).to eq('disabled')
      expect(reason).to eq(Lalabase::Llm::FeatureRegistry.unavailable_hint(unavailable, organisation))
      expect(start_button['aria-describedby']).to eq(bar.at_css('[data-glossary-run-reason]')['id'])
    end

    it 'turns the start off while a run is active and asks the page to reload the list' do
      ai(available)
      run = run_of('running')
      sign_in manager

      review_list(category: 'product')

      expect(start_button['disabled']).to eq('disabled')
      expect(status_line).to eq(I18n.t("#{gr}.running_since", time: clock(run, manager)))
      expect(start_button['aria-describedby']).to eq(bar.at_css('[data-glossary-run-status]')['id'])
      expect(reason).to be_nil
      expect(bar['data-controller']).to eq('glossary-run-poll')
      expect(bar['data-glossary-run-poll-active-value']).to eq('true')
      expect(bar['data-glossary-run-poll-url-value']).to eq(organisation_glossary_terms_path(organisation, view: 'proposals', category: 'product'))
      expect(bar['data-glossary-run-poll-frame-value']).to eq(Organisations::GlossaryController::LIST_FRAME_ID)
      expect(bar.ancestors('turbo-frame').first['id']).to eq(Organisations::GlossaryController::LIST_FRAME_ID)
    end

    it 'polls for a queued run as well, also for a reader with view_glossary only' do
      run = run_of('queued')
      sign_in viewer

      review_list

      expect(bar['data-glossary-run-poll-active-value']).to eq('true')
      expect(status_line).to eq(I18n.t("#{gr}.running_since", time: clock(run, viewer)))
    end

    # A run that has not moved for STALE_AFTER has lost its worker: the next
    # start ends it, so the start is on and nothing polls for it.
    it 'counts a stale run as ended: the start is on and nothing polls' do
      ai(available)
      run_of('running').update_columns(updated_at: (GlossaryExtractionRun::STALE_AFTER + 1.minute).ago)
      sign_in manager

      review_list

      expect(start_button['disabled']).to be_nil
      expect(bar['data-glossary-run-poll-active-value']).to eq('false')
      expect(status_line).to include(I18n.t('services.glossary_extraction.errors.stale'))
    end

    it 'names the start of a run in the clock of the reader, not of the server' do
      run = run_of('running', created_at: Time.utc(2026, 11, 8, 12, 0))
      viewer.update!(timezone: 'America/New_York')
      sign_in viewer

      review_list

      expect(status_line).to include('07:00')
      expect(status_line).not_to include('12:00')
      expect(status_line).to eq(I18n.t("#{gr}.running_since", time: clock(run, viewer.reload)))
    end

    it 'names the reason of a failed run' do
      run = run_of('failed', error_code: 'provider_error', finished_at: Time.current)
      sign_in viewer

      review_list

      expect(status_line).to eq(
        "#{I18n.t("#{gr}.failed", date: clock(run, viewer))} " \
        "#{I18n.t('services.glossary_extraction.errors.provider_error')}"
      )
    end

    it 'names what the last run read and found, from how many of the projects' do
      run = run_of('succeeded', finished_at: Time.current, stats: {
                     'sources' => { 'tickets' => 400, 'posts' => 10, 'notes' => 2 },
                     'projects_reached' => 3, 'projects_total' => 5, 'proposals_created' => 12, 'truncated' => false
                   })
      sign_in viewer

      review_list

      summary = [I18n.t("#{gr}.sources_read", count: 412), I18n.t("#{gr}.projects", count: 5, reached: 3),
                 I18n.t("#{gr}.proposals_created", count: 12)].join(', ')
      expect(status_line).to eq(I18n.t("#{gr}.last_run", date: clock(run, viewer), summary: summary))
      expect(status_line).to include('aus 3 von 5 Projekten')
      expect(bar.at_css('[data-glossary-run-truncated]')).to be_nil
    end

    it 'says so when the last run was cut short' do
      run_of('succeeded', finished_at: Time.current, stats: {
               'sources' => { 'tickets' => 2000 }, 'projects_reached' => 1, 'projects_total' => 1,
               'proposals_created' => 0, 'truncated' => true
             })
      sign_in viewer

      review_list

      expect(status_line).to include(I18n.t("#{gr}.proposals_created", count: 0), I18n.t("#{gr}.truncated"))
      expect(bar.at_css('[data-glossary-run-truncated]')['title']).to eq(I18n.t("#{gr}.truncated_hint"))
    end

    it 'shows the line about the last run but no start to a reader with view_glossary only' do
      ai(available)
      run_of('succeeded', finished_at: Time.current, stats: { 'proposals_created' => 1 })
      sign_in viewer

      review_list

      expect(bar.css('form, button')).to be_empty
      expect(status_line).to include(I18n.t("#{gr}.proposals_created", count: 1))
    end

    it 'reads only the runs of this organisation' do
      other = create(:organisation)
      ActsAsTenant.with_tenant(other) { create(:glossary_extraction_run, organisation: other, status: 'running') }
      ai(available)
      sign_in manager

      review_list

      expect(start_button['disabled']).to be_nil
      expect(status_line).to eq(I18n.t("#{gr}.never"))
    end

    it 'stands on the phone too, and not above the terms' do
      run_of('running')
      sign_in viewer

      review_list(viewport: 'mobile')
      expect(page.css('.people-mobile-grid')).to be_present
      expect(bar['data-glossary-run-poll-active-value']).to eq('true')

      get organisation_glossary_terms_path(organisation)
      expect(bar).to be_nil
    end

    # K5c: a run over one document. Its title is project content, and every
    # reader of the glossary sees this line, so it names the document only to
    # a reader of that document.
    describe 'the line about a run over one document' do
      let(:gd) { 'views.organisations.glossary.document_runs' }
      let(:project) { create(:project, organisation: organisation) }
      let(:document) { create(:document, organisation: organisation, project: project) }
      let(:version) do
        create(:document_version, organisation: organisation, document: document, title: 'Zorbel-Handbuch',
                                  plain_text_version: 'Wir nutzen Quarnix im Team.')
          .tap { |current| document.update!(current_version: current) }
      end
      let(:document_reader) do
        member_with(role_with('view_glossary')).tap do |user|
          create(:project_permission, user: user, project: project, documents_access: 'read_only')
        end
      end

      def document_run(status, **attributes)
        run_of(status, scope: { 'kind' => 'document', 'document_version_id' => version.id, 'since' => nil }, **attributes)
      end

      def source(reader)
        if reader == :hidden
          I18n.t("#{gd}.source_hidden")
        else
          I18n.t("#{gd}.source", title: 'Zorbel-Handbuch')
        end
      end

      it 'names the title of the document to a reader of it while the run runs' do
        run = document_run('running')
        sign_in document_reader

        review_list

        expect(status_line).to eq(I18n.t("#{gd}.running_since", time: clock(run, document_reader), source: source(:title)))
      end

      it 'says only that it was a document to a reader of the glossary who may not read it' do
        run = document_run('running')
        sign_in viewer

        review_list

        expect(status_line).to eq(I18n.t("#{gd}.running_since", time: clock(run, viewer), source: source(:hidden)))
        expect(status_line).to include('aus einem Dokument')
        expect(response.body).not_to include('Zorbel-Handbuch')
      end

      it 'names what a finished run read and found, with the document where the projects stand' do
        run = document_run('succeeded', finished_at: Time.current, stats: {
                             'sources' => { 'document_versions' => 1 }, 'projects_reached' => 1, 'projects_total' => 1,
                             'proposals_created' => 3, 'truncated' => false
                           })

        [[document_reader, :title], [viewer, :hidden]].each do |reader, shown|
          sign_in reader

          review_list

          summary = [I18n.t("#{gr}.sources_read", count: 1), source(shown), I18n.t("#{gr}.proposals_created", count: 3)].join(', ')
          expect(status_line).to eq(I18n.t("#{gr}.last_run", date: clock(run, reader), summary: summary))
          expect(status_line).not_to include(I18n.t("#{gr}.projects", count: 1, reached: 1))
        end
      end

      it 'names why a run over a document failed, with the document as the reader may see it' do
        run = document_run('failed', error_code: 'document_unavailable', finished_at: Time.current)

        [[document_reader, :title], [viewer, :hidden]].each do |reader, shown|
          sign_in reader

          review_list

          expect(status_line).to eq(
            "#{I18n.t("#{gd}.failed", date: clock(run, reader), source: source(shown))} " \
            "#{I18n.t('services.glossary_extraction.errors.document_unavailable')}"
          )
        end
      end

      it 'says it was a document once the document is gone' do
        run = document_run('succeeded', finished_at: Time.current, stats: { 'proposals_created' => 0 })
        document.update_columns(current_version_id: nil)
        DocumentVersion.where(id: version.id).delete_all
        sign_in document_reader

        review_list

        summary = [I18n.t("#{gr}.sources_read", count: 0), source(:hidden), I18n.t("#{gr}.proposals_created", count: 0)].join(', ')
        expect(status_line).to eq(I18n.t("#{gr}.last_run", date: clock(run, document_reader), summary: summary))
      end

      it 'turns the start off while a run over a document is active' do
        ai(available)
        document_run('queued')
        sign_in manager

        review_list

        expect(start_button['disabled']).to eq('disabled')
        expect(bar['data-glossary-run-poll-active-value']).to eq('true')
      end
    end

    %w[de en].each do |locale|
      it "renders in #{locale} without a missing text" do
        ai(available)
        run_of('succeeded', finished_at: Time.current, stats: {
                 'sources' => { 'tickets' => 1 }, 'projects_reached' => 1, 'projects_total' => 2,
                 'proposals_created' => 1, 'truncated' => true
               })
        manager.update!(language_preference: locale)
        sign_in manager

        review_list

        expect(response.body).not_to include('translation missing', 'Translation missing')
        I18n.with_locale(locale) do
          expect(start_button.text.squish).to eq(I18n.t("#{gr}.start"))
          expect(status_line).to include(I18n.t("#{gr}.projects", count: 2, reached: 1), I18n.t("#{gr}.truncated"))
        end
      end
    end
  end

  describe 'the start' do
    it 'writes a queued run, enqueues its job and lands on the review list' do
      ai(available)
      sign_in manager

      expect { start(status: 'dismissed') }.to change(runs, :count).by(1)

      run = runs.sole
      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, view: 'proposals'))
      expect(flash[:notice]).to eq(I18n.t('controllers.glossary.runs.success'))
      expect(run.slice(:status, :started_by_id)).to eq('status' => 'queued', 'started_by_id' => manager.id)
      expect(run.scope).to include('everything' => false)
      expect(Glossary::ExtractionJob).to have_been_enqueued.with(run_id: run.id)
    end

    it 'reads everything again when the box is checked' do
      ai(available)
      sign_in manager

      start(everything: '1')

      expect(runs.sole.scope).to include('everything' => true)
    end

    it 'keeps the phone view' do
      ai(available)
      sign_in manager

      start(viewport: 'mobile')

      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, view: 'proposals', viewport: 'mobile'))
    end

    it 'refuses a second start while a run is active and writes nothing' do
      ai(available)
      run_of('running')
      sign_in manager

      expect { start }.not_to change(runs, :count)

      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, view: 'proposals'))
      expect(flash[:alert]).to eq(I18n.t('controllers.glossary.runs.run_active'))
      expect(enqueued_jobs).to be_empty
    end

    it 'refuses a start without AI with the words of the registry' do
      ai(unavailable)
      sign_in manager

      expect { start }.not_to change(runs, :count)

      expect(flash[:alert]).to eq(Lalabase::Llm::FeatureRegistry.unavailable_hint(unavailable, organisation))
    end

    { 'view_glossary only' => :viewer, 'no glossary right' => :nobody }.each do |label, reader|
      it "answers 403 for #{label} and writes nothing" do
        ai(available)
        sign_in public_send(reader)

        expect { start }.not_to change(GlossaryExtractionRun, :count)

        expect(response).to have_http_status(:forbidden)
        expect(enqueued_jobs).to be_empty
      end
    end
  end
end
