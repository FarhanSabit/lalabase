# frozen_string_literal: true

require 'rails_helper'

# The glossary page and its writes (K4a). Every action against the right
# (GlossaryPolicy, E2): 403 without it, view_glossary reads but never writes,
# manage_glossary writes (a guest role too), an account admin needs no row,
# and a term of another organisation answers 404. What a reader sees (E3):
# heard forms with speaker and project from every project, but a meeting's
# title only with read access to that meeting, and a link to a person only
# with view_people. Invented words and names only.
RSpec.describe 'Organisations::Glossary', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def role_with(*rights, billable: true, title: nil)
    role = create(:role, organisation: organisation, billable: billable, **{ title: title }.compact)
    rights.each do |right|
      category, action = right.include?(':') ? right.split(':') : ['glossary', right]
      create(:permission, role: role, category: category, action: action, allowed: true)
    end
    role
  end

  def member_with(role, active: true)
    user = create(:user, first_name: 'Max', last_name: "Muster#{SecureRandom.hex(2)}")
    create(:membership, user: user, organisation: organisation, role: role, active: active)
    user
  end

  let(:admin) { member_with(role_with(title: Role::ACCOUNT_ADMIN_TITLE)) }
  let(:viewer) { member_with(role_with('view_glossary')) }
  let(:manager) { member_with(role_with('manage_glossary')) }
  let(:nobody) { member_with(role_with) }

  let(:open_project) { create(:project, organisation: organisation, name: 'Projekt Ahorn') }
  let(:closed_project) { create(:project, organisation: organisation, name: 'Projekt Birke') }
  let(:speaker) { create(:person, organisation: organisation, name: 'Erika Beispiel') }
  let(:open_meeting) { create(:meeting, organisation: organisation, project: open_project, title: 'Abstimmung Ahorn', creator: admin) }
  let(:closed_meeting) { create(:meeting, organisation: organisation, project: closed_project, title: 'Geheimrunde Birke', creator: admin) }
  let!(:term) { create(:glossary_term, organisation: organisation, term: 'Lalabase', category: 'product') }
  let!(:open_correction) do
    create(:term_correction, organisation: organisation, glossary_term: term, heard: 'lala bass', project: open_project,
                             meeting: open_meeting, person: speaker)
  end
  let!(:closed_correction) do
    create(:term_correction, organisation: organisation, glossary_term: term, heard: 'la la base', project: closed_project,
                             meeting: closed_meeting)
  end
  let!(:proposal) { create(:glossary_term, :proposed, organisation: organisation, term: 'Zirbelholz', category: 'domain') }

  let(:frame_headers) { { 'Turbo-Frame' => Organisations::GlossaryController::DETAIL_FRAME_ID } }
  let(:valid_params) { { glossary_term: { term: 'Wortmarke', category: 'company' } } }

  # Every write of the page, one example each: Prosopite reads requests sent
  # from one line of a loop as an N+1.
  def self.write_names
    %w[create update destroy confirm reject merge destroy_correction]
  end

  # [verb, path, params] of a write, against the given term.
  def write_request(name, target = term)
    {
      'create' => [:post, organisation_glossary_terms_path(organisation), valid_params],
      'update' => [:patch, organisation_glossary_term_path(organisation, target), { glossary_term: { term: 'Umbenannt' } }],
      'destroy' => [:delete, organisation_glossary_term_path(organisation, target), {}],
      'confirm' => [:patch, confirm_organisation_glossary_term_path(organisation, target), {}],
      'reject' => [:patch, reject_organisation_glossary_term_path(organisation, target), {}],
      'merge' => [:post, merge_organisation_glossary_term_path(organisation, target), { target_id: proposal.id }],
      'destroy_correction' => [:delete, correction_organisation_glossary_term_path(organisation, target, correction_id: open_correction.id), {}]
    }.fetch(name)
  end

  def self.frame_names
    %w[show new edit]
  end

  def frame_path(name)
    {
      'show' => organisation_glossary_term_path(organisation, term),
      'new' => new_organisation_glossary_term_path(organisation),
      'edit' => edit_organisation_glossary_term_path(organisation, term)
    }.fetch(name)
  end

  def glossary_state
    [GlossaryTerm.order(:id).pluck(:id, :term, :status, :category), TermCorrection.order(:id).pluck(:id, :glossary_term_id)]
  end

  describe 'without the right' do
    before { sign_in nobody }

    it 'answers 403 on the page' do
      get organisation_glossary_terms_path(organisation)

      expect(response).to have_http_status(:forbidden)
    end

    frame_names.each do |name|
      it "answers 403 on the #{name} frame" do
        get frame_path(name), headers: frame_headers

        expect(response).to have_http_status(:forbidden)
      end
    end

    write_names.each do |name|
      it "answers 403 on #{name} and changes nothing" do
        before = glossary_state
        verb, path, params = write_request(name)

        public_send(verb, path, params: params)

        expect(response).to have_http_status(:forbidden)
        expect(glossary_state).to eq(before)
      end
    end

    it 'does not count the people right' do
      sign_in member_with(role_with('people:view_people', 'people:manage_people'))

      get organisation_glossary_terms_path(organisation)
      expect(response).to have_http_status(:forbidden)
    end

    it 'shows no menu entry in the sidebar and on the mobile "more" page' do
      get organisation_root_path(organisation)
      follow_redirect! while response.redirect?
      expect(response.body).to include(I18n.t('navigation.all_organisations'))
      expect(response.body).not_to include(organisation_glossary_terms_path(organisation))

      get organisation_mobile_more_path(organisation)
      expect(response.body).to include(I18n.t('mobile.more'))
      expect(response.body).not_to include(organisation_glossary_terms_path(organisation))
    end
  end

  describe 'with view_glossary only' do
    before { sign_in viewer }

    it 'lists the terms with category, heard forms, speaker and project, proposals first' do
      get organisation_glossary_terms_path(organisation)

      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body).to include('Lalabase', I18n.t('views.organisations.glossary.categories.product'))
      expect(body).to include('lala bass', 'la la base', 'Erika Beispiel')
      # E3: the project's name also where the reader cannot read the project.
      expect(body).to include('Projekt Ahorn', 'Projekt Birke')
      expect(body.index('Zirbelholz')).to be < body.index('Lalabase')
      expect(body).to include(I18n.t('views.organisations.glossary.statuses.proposed'))
    end

    it 'shows no write controls' do
      get organisation_glossary_terms_path(organisation, term_id: term.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(new_organisation_glossary_term_path(organisation))
      expect(response.body).not_to include(edit_organisation_glossary_term_path(organisation, term))
      expect(response.body).not_to include(confirm_organisation_glossary_term_path(organisation, proposal))
      expect(response.body).not_to include(merge_organisation_glossary_term_path(organisation, term))
      expect(response.body).not_to include(correction_organisation_glossary_term_path(organisation, term, correction_id: open_correction.id))
      expect(response.body).to include(I18n.t('views.organisations.glossary.show.read_only'))
    end

    it 'shows a term in the lane frame' do
      get organisation_glossary_term_path(organisation, term), headers: frame_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(<turbo-frame id="#{Organisations::GlossaryController::DETAIL_FRAME_ID}">), 'Lalabase', 'lala bass')
    end

    it 'sends a full visit of a term to the index with the lane open' do
      get organisation_glossary_term_path(organisation, term)

      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, term_id: term.id))
    end

    write_names.each do |name|
      it "is refused #{name} with 403 and nothing changes" do
        before = glossary_state
        verb, path, params = write_request(name)

        public_send(verb, path, params: params)

        expect(response).to have_http_status(:forbidden)
        expect(glossary_state).to eq(before)
      end
    end

    %w[new edit].each do |name|
      it "is refused the #{name} form with 403" do
        get frame_path(name), headers: frame_headers

        expect(response).to have_http_status(:forbidden)
      end
    end

    it 'shows the menu entry in the sidebar and on the mobile "more" page' do
      get organisation_root_path(organisation)
      follow_redirect! while response.redirect?
      expect(response.body).to include(%(href="#{organisation_glossary_terms_path(organisation)}"), I18n.t('navigation.glossary'))

      get organisation_mobile_more_path(organisation)
      expect(response.body).to include(%(href="#{organisation_glossary_terms_path(organisation)}"))
    end
  end

  # E3: the title and the link of a meeting need read access to that meeting.
  describe 'meetings in the lane' do
    def lane_for(user)
      sign_in user
      get organisation_glossary_term_path(organisation, term), headers: frame_headers
      response.body
    end

    it 'shows no meeting title to a reader without access to any project, only the project names' do
      body = lane_for(viewer)

      expect(body).to include('Projekt Ahorn', 'Projekt Birke', 'lala bass', 'la la base')
      expect(body).not_to include('Abstimmung Ahorn', 'Geheimrunde Birke')
      expect(body).not_to include("meeting_id=#{open_meeting.id}", "meeting_id=#{closed_meeting.id}")
    end

    it 'shows the title and the link of a meeting the reader may read, and no other' do
      create(:project_permission, user: viewer, project: open_project, meetings_access: :read_only)

      body = lane_for(viewer)

      expect(body).to include('Abstimmung Ahorn', organisation_meetings_path(organisation, meeting_id: open_meeting.id))
      expect(body).not_to include('Geheimrunde Birke', "meeting_id=#{closed_meeting.id}")
    end

    it 'shows every meeting title to an account admin' do
      expect(lane_for(admin)).to include('Abstimmung Ahorn', 'Geheimrunde Birke')
    end

    it 'keeps a heard form of a deleted meeting, without a meeting' do
      open_meeting.destroy!

      body = lane_for(admin)

      expect(body).to include('lala bass', 'Projekt Ahorn')
      expect(body).not_to include('Abstimmung Ahorn')
    end
  end

  # E3: speakers are shown as a name; the link to the person needs view_people.
  describe 'speakers in the lane' do
    def lane_for(user)
      sign_in user
      get organisation_glossary_term_path(organisation, term), headers: frame_headers
      Nokogiri::HTML(response.body)
    end

    it 'names the speaker without a link for a reader without view_people' do
      page = lane_for(viewer)

      expect(page.text).to include('Erika Beispiel')
      expect(page.css(%(a[href*="person_id=#{speaker.id}"]))).to be_empty
    end

    it 'links the speaker for a reader with view_people' do
      page = lane_for(member_with(role_with('view_glossary', 'people:view_people')))

      expect(page.css(%(a[href="#{organisation_people_path(organisation, person_id: speaker.id)}"])).text).to eq('Erika Beispiel')
    end

    it 'names a member speaker through the name display, linked to the member' do
      member = member_with(role_with)
      create(:term_correction, organisation: organisation, glossary_term: term, heard: 'lalabeis', user: member)

      page = lane_for(admin)

      expect(page.css(%(a[href="#{organisation_people_path(organisation, member_id: member.id)}"]))).to be_present
    end
  end

  describe 'filters' do
    before { sign_in viewer }

    let!(:other_term) do
      create(:glossary_term, organisation: organisation, term: 'Ahornsirup', category: 'person').tap do |found|
        create(:term_correction, organisation: organisation, glossary_term: found, heard: 'ahorn sirup', project: open_project)
      end
    end

    def listed
      Nokogiri::HTML(response.body).css('[data-glossary-row] .people-row__name').map(&:text)
    end

    it 'filters by the project a heard form came from' do
      get organisation_glossary_terms_path(organisation, project_id: closed_project.id)

      expect(listed).to eq(['Lalabase'])
    end

    it 'filters by category' do
      get organisation_glossary_terms_path(organisation, category: 'person')

      expect(listed).to eq(['Ahornsirup'])
    end

    it 'filters by status' do
      get organisation_glossary_terms_path(organisation, status: 'proposed')

      expect(listed).to eq(['Zirbelholz'])
    end

    it 'ignores a filter value it does not know' do
      get organisation_glossary_terms_path(organisation, status: 'maybe', category: 'planet', project_id: SecureRandom.uuid)

      expect(listed).to contain_exactly('Zirbelholz', 'Ahornsirup', 'Lalabase')
    end

    it 'offers only the projects heard forms came from' do
      unused = create(:project, organisation: organisation, name: 'Projekt Eibe')

      get organisation_glossary_terms_path(organisation)

      options = Nokogiri::HTML(response.body).css('#glossary-project-filter option').map(&:text)
      expect(options).to include('Projekt Ahorn', 'Projekt Birke')
      expect(options).not_to include(unused.name)
    end
  end

  shared_examples 'may keep the glossary' do
    it 'creates a confirmed term and lands on the list with it open' do
      expect { post organisation_glossary_terms_path(organisation), params: valid_params.merge(status: 'proposed') }
        .to change(GlossaryTerm, :count).by(1)

      created = GlossaryTerm.find_by!(term: 'Wortmarke')
      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, status: 'proposed', term_id: created.id))
      expect([created.status, created.category, created.created_by_id]).to eq(['confirmed', 'company', writer.id])
    end

    it 'refuses a spelling already in the glossary with the form and its message' do
      expect { post organisation_glossary_terms_path(organisation), params: { glossary_term: { term: 'LALABASE' } } }
        .not_to change(GlossaryTerm, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(ERB::Util.html_escape(I18n.t('activerecord.errors.models.glossary_term.attributes.term.taken')))
      expect(response.body).to include('id="glossary_term_term"')
    end

    it 'changes spelling and category' do
      patch organisation_glossary_term_path(organisation, term), params: { glossary_term: { term: 'LalaBase', category: 'domain' } }

      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, term_id: term.id))
      expect([term.reload.term, term.category]).to eq(%w[LalaBase domain])
    end

    it 'confirms and rejects a proposal' do
      patch confirm_organisation_glossary_term_path(organisation, proposal)
      expect(proposal.reload.status).to eq('confirmed')
      expect(response).to redirect_to(organisation_glossary_terms_path(organisation))

      patch reject_organisation_glossary_term_path(organisation, proposal), params: { term_id: proposal.id }
      expect(proposal.reload.status).to eq('rejected')
      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, term_id: proposal.id))
    end

    it 'deletes a term with its heard forms' do
      delete organisation_glossary_term_path(organisation, term)

      expect(response).to redirect_to(organisation_glossary_terms_path(organisation))
      expect(GlossaryTerm.where(id: term.id)).not_to exist
      expect(TermCorrection.where(id: [open_correction.id, closed_correction.id])).not_to exist
    end

    it 'merges a term into another, the heard forms move along' do
      post merge_organisation_glossary_term_path(organisation, term), params: { target_id: proposal.id }

      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, term_id: proposal.id))
      expect(GlossaryTerm.where(id: term.id)).not_to exist
      expect(proposal.term_corrections.reload).to contain_exactly(open_correction, closed_correction)
    end

    it 'refuses to merge a term into itself and changes nothing' do
      before = glossary_state
      post merge_organisation_glossary_term_path(organisation, term), params: { target_id: term.id }

      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, term_id: term.id))
      expect(flash[:alert]).to eq(I18n.t('controllers.glossary.merge.same_term'))
      expect(glossary_state).to eq(before)
    end

    it 'treats a target of another organisation as no target' do
      foreign = ActsAsTenant.with_tenant(other_organisation) { create(:glossary_term, organisation: other_organisation) }
      before = glossary_state

      post merge_organisation_glossary_term_path(organisation, term), params: { target_id: foreign.id }

      expect(flash[:alert]).to eq(I18n.t('controllers.glossary.merge.no_target'))
      expect(glossary_state).to eq(before)
    end

    it 'deletes one heard form and keeps the term' do
      delete correction_organisation_glossary_term_path(organisation, term, correction_id: open_correction.id)

      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, term_id: term.id))
      expect(TermCorrection.where(id: open_correction.id)).not_to exist
      expect(TermCorrection.where(id: closed_correction.id)).to exist
    end

    it 'answers 404 for a heard form of another term' do
      delete correction_organisation_glossary_term_path(organisation, proposal, correction_id: open_correction.id)

      expect(response).to have_http_status(:not_found)
      expect(TermCorrection.where(id: open_correction.id)).to exist
    end

    it 'opens the form in the lane, new and edit' do
      get new_organisation_glossary_term_path(organisation), headers: frame_headers
      expect(response.body).to include('id="glossary_term_term"')

      get edit_organisation_glossary_term_path(organisation, term), headers: frame_headers
      expect(response.body).to include('value="Lalabase"')
    end

    it 'shows confirm and reject on a proposal row, and the write controls in the lane' do
      get organisation_glossary_terms_path(organisation, term_id: term.id)

      expect(response.body).to include(confirm_organisation_glossary_term_path(organisation, proposal),
                                       reject_organisation_glossary_term_path(organisation, proposal),
                                       merge_organisation_glossary_term_path(organisation, term),
                                       correction_organisation_glossary_term_path(organisation, term, correction_id: open_correction.id))
    end
  end

  describe 'with manage_glossary' do
    let(:writer) { manager }

    before { sign_in writer }

    include_examples 'may keep the glossary'
  end

  describe 'with manage_glossary on a guest role (billable: false)' do
    let(:writer) { member_with(role_with('manage_glossary', billable: false)) }

    before { sign_in writer }

    include_examples 'may keep the glossary'
  end

  describe 'as an account admin without any row' do
    let(:writer) { admin }

    before { sign_in writer }

    it 'needs no permission row' do
      expect(Permission.where(category: 'glossary')).not_to exist
    end

    include_examples 'may keep the glossary'
  end

  describe 'a deactivated member who still holds the right' do
    it 'gets nothing of the glossary' do
      sign_in member_with(role_with('manage_glossary'), active: false)

      get organisation_glossary_terms_path(organisation)

      expect(response).to have_http_status(:redirect)
      expect(response.body).not_to include('Lalabase')
    end
  end

  describe 'another organisation' do
    let(:foreign_term) do
      ActsAsTenant.with_tenant(other_organisation) { create(:glossary_term, organisation: other_organisation, term: 'Fremdwort') }
    end

    before { sign_in admin }

    # One request per example: after a 404 the test session is signed out.
    it 'answers 404 for show of a term of another organisation' do
      get organisation_glossary_term_path(organisation, foreign_term), headers: frame_headers

      expect(response).to have_http_status(:not_found)
    end

    it 'answers 404 for update and leaves the term alone' do
      patch organisation_glossary_term_path(organisation, foreign_term), params: { glossary_term: { term: 'Gekapert' } }

      expect(response).to have_http_status(:not_found)
      expect(GlossaryTerm.unscoped.find(foreign_term.id).term).to eq('Fremdwort')
    end

    it 'answers 404 for destroy and keeps the term' do
      delete organisation_glossary_term_path(organisation, foreign_term)

      expect(response).to have_http_status(:not_found)
      expect(GlossaryTerm.unscoped.exists?(foreign_term.id)).to be(true)
    end

    it 'answers 404 for confirm, reject and merge of a term of another organisation' do
      patch reject_organisation_glossary_term_path(organisation, foreign_term)

      expect(response).to have_http_status(:not_found)
      expect(GlossaryTerm.unscoped.find(foreign_term.id).status).to eq('confirmed')
    end

    it 'sends the page of an organisation the user is not in to the organisation picker' do
      foreign_term
      get organisation_glossary_terms_path(other_organisation)

      expect(response).to redirect_to(select_organisation_path)
    end
  end

  describe 'the lane' do
    before { sign_in manager }

    it 'opens a term on a full visit with ?term_id=' do
      get organisation_glossary_terms_path(organisation, term_id: term.id)

      expect(response.body).to include('show-content', 'selected-row', 'lala bass')
    end

    it 'opens the form on a full visit with ?new=term' do
      get organisation_glossary_terms_path(organisation, new: 'term')

      expect(response.body).to include('id="glossary_term_term"')
    end

    it 'answers a lane request of the index with the lane alone' do
      get organisation_glossary_terms_path(organisation, term_id: term.id), headers: frame_headers

      expect(response.body).to start_with(%(<turbo-frame id="#{Organisations::GlossaryController::DETAIL_FRAME_ID}">))
      expect(response.body).not_to include('glossary-tools')
    end
  end

  # Prosopite watches every example: the list preloads heard forms, speakers
  # and projects, and asks the write right once, however many rows.
  describe 'queries' do
    # The fixtures are built in a loop; only the requests are watched.
    before do
      Prosopite.pause do
        3.times do |index|
          found = create(:glossary_term, :proposed, organisation: organisation, term: "Vorschlag #{index}")
          create(:term_correction, organisation: organisation, glossary_term: found, heard: "vor schlag #{index}",
                                   project: create(:project, organisation: organisation), user: member_with(role_with))
          create(:term_correction, organisation: organisation, glossary_term: found, heard: "vorschlak #{index}",
                                   person: create(:person, organisation: organisation), project: open_project)
        end
      end
    end

    it 'renders the list of many terms without an N+1' do
      sign_in manager

      get organisation_glossary_terms_path(organisation)

      expect(response).to have_http_status(:ok)
      expect(Nokogiri::HTML(response.body).css('[data-glossary-row]').size).to eq(5)
    end

    it 'renders a lane with many heard forms without an N+1' do
      sign_in member_with(role_with('manage_glossary', 'people:view_people'))
      target = GlossaryTerm.find_by!(term: 'Vorschlag 0')
      create(:term_correction, organisation: organisation, glossary_term: target, heard: 'vor schlag 0', meeting: open_meeting,
                               project: open_project, user: member_with(role_with))

      get organisation_glossary_term_path(organisation, target), headers: frame_headers

      expect(response).to have_http_status(:ok)
      expect(Nokogiri::HTML(response.body).css('.glossary-heard__row').size).to eq(3)
    end
  end

  %w[de en].each do |locale|
    it "renders the page and the lane in #{locale} without a missing text" do
      sign_in admin

      get organisation_glossary_terms_path(organisation, term_id: term.id, locale: locale)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('translation missing', 'Translation missing')
      I18n.with_locale(locale) do
        expect(response.body).to include(ERB::Util.html_escape(I18n.t('views.organisations.glossary.index.title')),
                                         ERB::Util.html_escape(I18n.t('views.organisations.glossary.show.heard_title')))
      end
    end
  end
end
