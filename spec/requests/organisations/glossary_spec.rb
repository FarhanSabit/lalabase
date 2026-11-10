# frozen_string_literal: true

require 'rails_helper'

# The glossary page and its writes (K4a). Every action against the right
# (GlossaryPolicy, E2): 403 without it, view_glossary reads but never writes,
# manage_glossary writes (a guest role too), an account admin needs no row,
# and a term of another organisation answers 404. What a reader sees (E3):
# heard forms with their project from every project, but a meeting's title
# only with read access to that meeting, a speaker's name only when the
# reader may see that speaker on the members or the people page, and a link
# to a speaker only with view_people as well. Invented words and names only.
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
    %w[create update destroy confirm reject merge destroy_heard_form confirm_heard_form reject_heard_form]
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
      'destroy_heard_form' => [:delete, heard_form_organisation_glossary_term_path(organisation, target, correction_id: open_correction.id), {}],
      'confirm_heard_form' => [:patch, confirm_heard_form_organisation_glossary_term_path(organisation, target, correction_id: open_correction.id), {}],
      'reject_heard_form' => [:delete, reject_heard_form_organisation_glossary_term_path(organisation, target, correction_id: open_correction.id), {}]
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
    [GlossaryTerm.order(:id).pluck(:id, :term, :status, :category), TermCorrection.order(:id).pluck(:id, :glossary_term_id, :status)]
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
      expect(body).to include('lala bass', 'la la base')
      # A row of the people directory is a name only with view_people (review
      # round 4 of #113).
      expect(body).to include(I18n.t('views.organisations.glossary.speaker_hidden'))
      expect(body).not_to include('Erika Beispiel')
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
      expect(response.body).not_to include(heard_form_organisation_glossary_term_path(organisation, term, correction_id: open_correction.id))
      expect(response.body).to include(I18n.t('views.organisations.glossary.show.read_only'))
      page = Nokogiri::HTML(response.body)
      expect(page.css('input[name="_method"][value="delete"]')).to be_empty
      expect(page.text).not_to include(I18n.t('views.organisations.glossary.show.delete'))
      expect(page.css('.glossary-heard__group')).to be_present
    end

    it 'opens no form with ?new=term on a full visit' do
      get organisation_glossary_terms_path(organisation, new: 'term')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Lalabase')
      expect(response.body).not_to include('id="glossary_term_term"')
    end

    it 'names ?new=term as unresolved when it opens no form' do
      get organisation_glossary_terms_path(organisation, new: 'term')

      data = Nokogiri::HTML(response.body).at_css('.glossary-page')['data-layout-toggle-unresolved-selection-value']
      expect(JSON.parse(data)).to eq('new' => 'term')
    end

    it 'opens no form with ?new=term in the lane frame' do
      get organisation_glossary_terms_path(organisation, new: 'term'), headers: frame_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('glossary-term-placeholder')
      expect(response.body).not_to include('id="glossary_term_term"')
    end

    # The write right comes before the heard form is looked up: 403, not 404.
    it 'is refused deleting a heard form of another term with 403' do
      delete heard_form_organisation_glossary_term_path(organisation, proposal, correction_id: open_correction.id)

      expect(response).to have_http_status(:forbidden)
      expect(TermCorrection.where(id: open_correction.id)).to exist
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

    # The glossary has no menu entry (user, 04.11.2026): it is reached from
    # the head of the meetings pages, see 'the way in from the meetings pages'.
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

  # The glossary belongs to the meetings area (user, 04.11.2026): the "···"
  # of "Alle Meetings" and of a project's meetings page holds the way in, for
  # those with the glossary right only; on the glossary page the sidebar
  # keeps "Alle Meetings" lit, and that entry is the way back.
  describe 'the way in from the meetings pages' do
    def meetings_reader(*rights)
      member_with(role_with(*rights)).tap do |user|
        create(:project_permission, user: user, project: open_project, meetings_access: 'read_only')
      end
    end

    def glossary_link
      %(href="#{organisation_glossary_terms_path(organisation)}")
    end

    def meetings_pages
      [organisation_meetings_path(organisation), organisation_project_meetings_path(organisation, open_project)]
    end

    it 'shows the link on both meetings pages with the glossary right' do
      sign_in meetings_reader('view_glossary')

      meetings_pages.each do |path|
        get path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include('data-meetings-glossary-link', glossary_link), "no glossary link on #{path}"
        expect(response.body).to include(I18n.t('navigation.glossary'))
      end
    end

    # Until 2026-11-10 the link was a word in cobalt in the head, the one
    # of its kind there (user: blue links are not what the heads hold); before
    # that a framed button. The heads hold the page's action, "···" and "?".
    it 'is an item of the "···" in the head, not a word or a button of its own' do
      sign_in meetings_reader('view_glossary')

      meetings_pages.each do |path|
        get path
        link = Nokogiri::HTML(response.body).at_css('a[data-meetings-glossary-link]')
        expect(link).to be_present, "no glossary item on #{path}"
        menu = link.ancestors('[data-dropdown-target="menu"]').first
        expect(menu).to be_present, "not in a menu on #{path}"
        trigger = menu.parent.at_css("[title='#{I18n.t('components.overflow_menu.label')}']")
        expect(trigger).to be_present, "not behind the \"···\" on #{path}"
        expect(link['class'].to_s.split).not_to include('text-info')
        expect(link.text.squish).to eq(I18n.t('navigation.glossary'))
        expect(link['data-turbo-frame']).to eq('_top')
      end
    end

    it 'shows no link on either meetings page without the glossary right' do
      sign_in meetings_reader

      meetings_pages.each do |path|
        get path
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include('data-meetings-glossary-link')
        expect(response.body).not_to include(glossary_link)
      end
    end

    # No back button in the head since 2026-11-10: the lit sidebar entry is
    # the way back, so it is the one link to "Alle Meetings" on the page.
    it 'keeps "Alle Meetings" lit in the sidebar as the way back, with no back button in the head' do
      sign_in meetings_reader('view_glossary')

      get organisation_glossary_terms_path(organisation)

      expect(response).to have_http_status(:ok)
      page = Nokogiri::HTML(response.body)
      to_meetings = page.css('a').select { |link| link['href'] == organisation_meetings_path(organisation) }
      expect(to_meetings.size).to eq(1)
      expect(to_meetings.first['class']).to include('sidebar-row--active')
      expect(page.at_css(%(.people-head a[href="#{organisation_meetings_path(organisation)}"]))).to be_nil
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

  # K4d: where a device applied a form, under the form; the spelling at the head; a form
  # without corrections left keeps its applications as a group of its own.
  describe 'applications in the lane' do
    let(:ga) { 'views.organisations.glossary.show' }

    def lane_for(user)
      sign_in user
      get organisation_glossary_term_path(organisation, term), headers: frame_headers
      response.body
    end

    def applied(heard, meeting, count: 1, glossary_term: term)
      create(:term_application, organisation: organisation, glossary_term: glossary_term, meeting: meeting, project: meeting.project,
                                heard: heard, replaced_count: count)
    end

    it 'lists an application under its heard form with project, date and count, the meeting only for its reader' do
      applied('Lala Bass', open_meeting, count: 3)
      applied('la la base', closed_meeting)

      body = lane_for(viewer)
      expect(body).to include(I18n.t("#{ga}.applied_row"), I18n.t("#{ga}.replaced", count: 3))
      expect(body.scan(I18n.t("#{ga}.applied_row")).size).to eq(2)
      expect(body).not_to include('Abstimmung Ahorn', "meeting_id=#{open_meeting.id}")

      create(:project_permission, user: viewer, project: open_project, meetings_access: :read_only)
      body = lane_for(viewer)
      expect(body).to include('Abstimmung Ahorn', organisation_meetings_path(organisation, meeting_id: open_meeting.id))
      expect(body).not_to include('Geheimrunde Birke')
    end

    it 'names a righted spelling at the head, not as a heard form' do
      applied('lalabase', open_meeting, count: 4)
      applied('LALABASE', closed_meeting, count: 1)

      body = lane_for(admin)

      expect(body).to include(I18n.t("#{ga}.spelling_applied", times: I18n.t("#{ga}.times", count: 5),
                                                               meetings: I18n.t("#{ga}.in_meetings", count: 2)))
      expect(body).not_to include(I18n.t('views.organisations.glossary.quoted', text: 'lalabase'))
    end

    it 'keeps historical spelling counts at the head after the term is renamed' do
      applied('lalabase', open_meeting, count: 4)
      applied('LALABASE', closed_meeting)
      sign_in manager

      patch organisation_glossary_term_path(organisation, term), params: { glossary_term: { term: 'Lala Base' } }

      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, term_id: term.id))
      page = Nokogiri::HTML(lane_for(admin))
      expect(page.at_css('.people-identity__name').text).to eq('Lala Base')
      expect(page.css('.glossary-detail__spelling').text.squish)
        .to eq(I18n.t("#{ga}.spelling_applied", times: I18n.t("#{ga}.times", count: 5),
                                                meetings: I18n.t("#{ga}.in_meetings", count: 2)))
      expect(page.css('.glossary-heard__row--applied')).to be_empty
      expect(page.css('.glossary-heard__form').text).not_to include(I18n.t('views.organisations.glossary.quoted', text: 'lalabase'))
    end

    it 'keeps an application under its heard form when the term is renamed to that form' do
      applied('lala bass', open_meeting, count: 3)
      sign_in manager

      patch organisation_glossary_term_path(organisation, term), params: { glossary_term: { term: 'Lala Bass' } }

      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, term_id: term.id))
      page = Nokogiri::HTML(lane_for(admin))
      expect(page.at_css('.people-identity__name').text).to eq('Lala Bass')
      expect(page.css('.glossary-detail__spelling')).to be_empty
      group = page.css('.glossary-heard__group').find { |node| node.text.include?('lala bass') }
      rows = group.css('.glossary-heard__row--applied')
      expect(rows.size).to eq(1)
      expect(rows.text).to include(I18n.t("#{ga}.replaced", count: 3))
      expect(rows.css('a').pluck('href')).to eq([organisation_meetings_path(organisation, meeting_id: open_meeting.id)])
    end

    it 'keeps an application and its meeting link after its corrections are deleted and the term is renamed to its heard form' do
      applied('lala bass', open_meeting, count: 2)
      sign_in manager
      delete heard_form_organisation_glossary_term_path(organisation, term, correction_id: open_correction.id)

      patch organisation_glossary_term_path(organisation, term), params: { glossary_term: { term: 'Lala Bass' } }

      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, term_id: term.id))
      page = Nokogiri::HTML(lane_for(admin))
      expect(page.css('.glossary-detail__spelling')).to be_empty
      group = page.css('.glossary-heard__group').find { |node| node.text.include?('lala bass') }
      expect(group).to be_present
      expect(group.text).to include(I18n.t("#{ga}.applied_only"))
      rows = group.css('.glossary-heard__row--applied')
      expect(rows.size).to eq(1)
      expect(rows.text).to include(I18n.t("#{ga}.replaced", count: 2))
      expect(rows.css('a').pluck('href')).to eq([organisation_meetings_path(organisation, meeting_id: open_meeting.id)])
    end

    it 'separates spelling from other applications with the same heard form and different stored terms after a merge' do
      source = create(:glossary_term, organisation: organisation, term: 'Lala Base')
      historical = applied('lalabase', open_meeting, count: 3, glossary_term: source)
      applied('lala base', open_meeting, count: 4, glossary_term: source)
      applied('LALABASE', closed_meeting)
      sign_in manager

      post merge_organisation_glossary_term_path(organisation, source), params: { target_id: term.id }

      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, term_id: term.id))
      expect(GlossaryTerm.where(id: source.id)).not_to exist
      expect(historical.reload).to have_attributes(glossary_term_id: term.id, term: 'Lala Base')
      page = Nokogiri::HTML(lane_for(admin))
      expect(page.css('.glossary-detail__spelling').text.squish)
        .to eq(I18n.t("#{ga}.spelling_applied", times: I18n.t("#{ga}.times", count: 5),
                                                meetings: I18n.t("#{ga}.in_meetings", count: 2)))
      rows = page.css('.glossary-heard__row--applied')
      expect(rows.size).to eq(1)
      expect(rows.text).to include(I18n.t("#{ga}.replaced", count: 3))
      expect(rows.css('a').pluck('href')).to eq([organisation_meetings_path(organisation, meeting_id: open_meeting.id)])
      group = page.css('.glossary-heard__group').find { |node| node.text.include?('lalabase') }
      expect(group.text).to include(I18n.t("#{ga}.applied_only"))
      expect(group.css('.glossary-heard__row--applied').size).to eq(1)
    end

    it 'keeps the applications of a form whose corrections were deleted, as a group of its own' do
      applied('lala bass', open_meeting, count: 2)
      sign_in manager
      delete heard_form_organisation_glossary_term_path(organisation, term, correction_id: open_correction.id)

      body = lane_for(admin)

      expect(body).to include(I18n.t('views.organisations.glossary.quoted', text: 'lala bass'), I18n.t("#{ga}.applied_only"),
                              I18n.t("#{ga}.replaced", count: 2))
      expect(body).not_to include(I18n.t("#{ga}.delete_heard", heard: 'lala bass'))
    end

    it 'shows the empty line only when neither corrections nor applications exist' do
      term.term_corrections.delete_all
      expect(lane_for(admin)).to include(I18n.t("#{ga}.no_heard"))

      applied('lala bass', open_meeting)
      expect(lane_for(admin)).not_to include(I18n.t("#{ga}.no_heard"))
    end

    it 'goes with its meeting' do
      row = applied('lala bass', open_meeting)
      open_meeting.destroy!

      expect(TermApplication.where(id: row.id)).not_to exist
    end
  end

  # E3: speakers are shown as a name; the link to the person needs view_people.
  describe 'speakers in the lane' do
    def lane_for(user)
      sign_in user
      get organisation_glossary_term_path(organisation, term), headers: frame_headers
      Nokogiri::HTML(response.body)
    end

    def speakers(page)
      page.css('.glossary-heard__speaker').map { |node| node.text.strip }
    end

    let(:hidden) { I18n.t('views.organisations.glossary.speaker_hidden') }

    # Review round 4 of #113 (decided): a speaker's name follows what the
    # reader may see on the people page; without view_people that page shows
    # no row of the directory.
    it 'shows a row of the directory as a neutral word to a reader without view_people' do
      page = lane_for(viewer)

      expect(speakers(page)).to include(hidden)
      expect(page.text).not_to include('Erika Beispiel')
      expect(page.css(%(a[href*="person_id=#{speaker.id}"]))).to be_empty
    end

    it 'links the speaker for a reader with view_people' do
      page = lane_for(member_with(role_with('view_glossary', 'people:view_people')))

      expect(page.css(%(a[href="#{organisation_people_path(organisation, person_id: speaker.id)}"])).text).to eq('Erika Beispiel')
    end

    # Review round 1 of #113: the link needs view_people, also for a member
    # speaker (whom MembershipPolicy::Scope shows without it), and only to a
    # row or member the reader may see on the people page.
    it 'does not link a member speaker for a reader without view_people' do
      # The reader would see the speaker on the members page (a shared project),
      # so only view_people can keep the link away.
      speaker_member = member_with(role_with)
      create(:project_permission, user: viewer, project: open_project, tickets_access: :read_only)
      create(:project_permission, user: speaker_member, project: open_project, tickets_access: :read_only)
      create(:term_correction, organisation: organisation, glossary_term: term, heard: 'lalabeis', user: speaker_member)

      page = lane_for(viewer)

      expect(speakers(page)).to include(speaker_member.display_name)
      expect(page.css(%(a[href*="member_id=#{speaker_member.id}"]))).to be_empty
    end

    # Review round 4 of #113 (decided): MembershipPolicy::Scope keeps the
    # names of other projects' members from a guest of one project, so the
    # glossary does too, in the lane and in the list.
    describe 'a guest of one project (billable: false) with view_glossary' do
      let(:guest) { member_with(role_with('view_glossary', billable: false)) }
      let(:colleague) { member_with(role_with) }
      let(:stranger) { member_with(role_with) }

      before do
        create(:project_permission, user: guest, project: open_project, tickets_access: :read_only)
        create(:project_permission, user: colleague, project: open_project, tickets_access: :read_only)
        create(:project_permission, user: stranger, project: closed_project, tickets_access: :read_only)
        create(:term_correction, organisation: organisation, glossary_term: term, heard: 'lalabeis', user: colleague,
                                 project: open_project)
        create(:term_correction, organisation: organisation, glossary_term: term, heard: 'lalabais', user: stranger,
                                 project: closed_project)
      end

      it 'sees the name of a member of its project, not of a member of another project' do
        page = lane_for(guest)

        expect(speakers(page)).to include(colleague.display_name, hidden)
        expect(page.text).not_to include(stranger.display_name)
        expect(page.css('.glossary-heard__speaker a')).to be_empty
      end

      it 'sees the same names in the list' do
        sign_in guest
        get organisation_glossary_terms_path(organisation)

        origin = Nokogiri::HTML(response.body).css('.glossary-row__origin').map(&:text).join
        expect(origin).to include(colleague.display_name, hidden, 'Projekt Birke')
        expect(origin).not_to include(stranger.display_name)
      end
    end

    describe 'with view_people but without any project' do
      let(:reader) { member_with(role_with('view_glossary', 'people:view_people')) }
      let(:hidden_member) { member_with(role_with) }

      it 'shows a member it may not see on the members page as a neutral word, without a link' do
        create(:term_correction, organisation: organisation, glossary_term: term, heard: 'lalabeis', user: hidden_member)

        page = lane_for(reader)

        expect(speakers(page)).to include(hidden)
        expect(page.text).not_to include(hidden_member.display_name)
        expect(page.css(%(a[href*="member_id=#{hidden_member.id}"]))).to be_empty
      end

      it 'shows the row of a member it may not see as a neutral word, without a link' do
        row = create(:person, organisation: organisation, user: hidden_member, name: 'Paula Platzhalter')
        create(:term_correction, organisation: organisation, glossary_term: term, heard: 'lalabeis', person: row)

        page = lane_for(reader)

        expect(speakers(page)).to include(hidden)
        expect(page.text).not_to include('Paula Platzhalter')
        expect(page.css(%(a[href*="person_id=#{row.id}"]))).to be_empty
      end

      it 'links a member it may see on the people page (a shared project)' do
        create(:project_permission, user: reader, project: open_project, tickets_access: :read_only)
        create(:project_permission, user: hidden_member, project: open_project, tickets_access: :read_only)
        create(:term_correction, organisation: organisation, glossary_term: term, heard: 'lalabeis', user: hidden_member)

        page = lane_for(reader)

        expect(page.css(%(a[href="#{organisation_people_path(organisation, member_id: hidden_member.id)}"]))).to be_present
      end
    end

    it 'names a member speaker through the name display, linked to the member' do
      member = member_with(role_with)
      create(:term_correction, organisation: organisation, glossary_term: term, heard: 'lalabeis', user: member)

      page = lane_for(admin)

      expect(page.css(%(a[href="#{organisation_people_path(organisation, member_id: member.id)}"]))).to be_present
    end

    # Review round 4 of #113: the people page lists active members only, so a
    # link to a deactivated one opened an empty lane. The members page still
    # lists them, so the name stays.
    it 'names a deactivated member without a link' do
      member = member_with(role_with, active: false)
      create(:term_correction, organisation: organisation, glossary_term: term, heard: 'lalabeis', user: member)

      page = lane_for(admin)

      expect(speakers(page)).to include(member.display_name)
      expect(page.css(%(a[href*="member_id=#{member.id}"]))).to be_empty
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

    # Review round 2 of #113: a heard form learnt wrong goes with every
    # correction of it at this term, not one correction at a time.
    it 'deletes one heard form with all its corrections and keeps the term and its other forms' do
      heard_again = create(:term_correction, organisation: organisation, glossary_term: term, heard: 'Lala Bass')

      delete heard_form_organisation_glossary_term_path(organisation, term, correction_id: open_correction.id)

      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, term_id: term.id))
      expect(flash[:notice]).to eq(I18n.t('controllers.glossary.heard_form.destroy.success'))
      expect(TermCorrection.where(id: [open_correction.id, heard_again.id])).not_to exist
      expect(TermCorrection.where(id: closed_correction.id)).to exist
      expect(GlossaryTerm.where(id: term.id)).to exist
    end

    it 'offers the delete once per heard form, and asks with the number of its corrections' do
      create(:term_correction, organisation: organisation, glossary_term: term, heard: 'Lala Bass')

      get organisation_glossary_term_path(organisation, term), headers: frame_headers

      page = Nokogiri::HTML(response.body)
      forms = page.css('.glossary-heard__group form[action*="/heard/"]')
      expect(forms.size).to eq(2)
      expect(forms.map { |form| form['data-turbo-confirm'] }).to include(
        I18n.t('views.organisations.glossary.show.delete_heard_confirm', heard: 'Lala Bass', term: 'Lalabase', count: 2)
      )
      expect(page.css('.glossary-heard__row form')).to be_empty
    end

    it 'counts heard forms, not corrections, when it asks before deleting the term' do
      create(:term_correction, organisation: organisation, glossary_term: term, heard: 'Lala Bass')

      get organisation_glossary_term_path(organisation, term), headers: frame_headers

      confirm = Nokogiri::HTML(response.body).css("form[action=\"#{organisation_glossary_term_path(organisation, term)}\"]")
                        .filter_map { |form| form['data-turbo-confirm'] }
      expect(confirm).to eq([I18n.t('views.organisations.glossary.show.delete_confirm', term: 'Lalabase', count: 2)])
    end

    it 'answers 404 for a heard form of another term' do
      delete heard_form_organisation_glossary_term_path(organisation, proposal, correction_id: open_correction.id)

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
                                       heard_form_organisation_glossary_term_path(organisation, term, correction_id: open_correction.id))
    end

    # Review round 4 of #113 (optional): a screen reader heard "Bestätigen"
    # once per proposal without its term, and the row held a div in a span.
    it 'names the term in the buttons of a proposal row, inside valid markup' do
      get organisation_glossary_terms_path(organisation)

      page = Nokogiri::HTML(response.body)
      row = page.css('[data-glossary-row]').find { |node| node.text.include?('Zirbelholz') }
      expect(row.css('button').map { |button| button.text.squish })
        .to eq([I18n.t('views.organisations.glossary.show.confirm'), I18n.t('views.organisations.glossary.show.reject')]
                 .map { |word| "#{word} #{I18n.t('views.organisations.glossary.quoted', text: 'Zirbelholz')}" })
      expect(page.css('[data-glossary-row] span div, [data-glossary-row] span form')).to be_empty
    end
  end

  describe 'with manage_glossary' do
    let(:writer) { manager }

    before { sign_in writer }

    include_examples 'may keep the glossary'

    # Review round 4 of #113: a form opened before another change wrote the
    # old spelling back.
    it 'shows the current values and the stale message when someone else saved first' do
      opened_with = term.lock_version
      term.update!(term: 'Lala Base')

      patch organisation_glossary_term_path(organisation, term),
            params: { glossary_term: { term: 'Lalabase', category: 'company', lock_version: opened_with } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(CGI.escapeHTML(I18n.t('controllers.glossary.update.stale')))
      form = Nokogiri::HTML(response.body)
      expect(form.css('#glossary_term_term').first['value']).to eq('Lala Base')
      expect(form.css('input[name="glossary_term[lock_version]"]').first['value']).to eq(term.reload.lock_version.to_s)
      expect([term.term, term.category]).to eq(['Lala Base', 'product'])
    end

    it 'sends the lock_version along with the form of a saved term, none with a new one' do
      get edit_organisation_glossary_term_path(organisation, term), headers: frame_headers
      expect(Nokogiri::HTML(response.body).css('input[name="glossary_term[lock_version]"]').map { |input| input['value'] })
        .to eq([term.lock_version.to_s])

      get new_organisation_glossary_term_path(organisation), headers: frame_headers
      expect(response.body).not_to include('glossary_term[lock_version]')
    end

    # Review round 4 of #113 (optional): require.permit crashed on a string.
    it 'answers a form that is no form with 400, not an error' do
      patch organisation_glossary_term_path(organisation, term), params: { glossary_term: 'Lalabase' }

      expect(response).to have_http_status(:bad_request)
      expect(term.reload.term).to eq('Lalabase')
    end
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

  # The base controller sends a deactivated member away before any glossary
  # action runs; that the policy refuses them as well is pinned in
  # glossary_policy_spec.rb and inactive_membership_scope_guard_spec.rb.
  describe 'a deactivated member who still holds the right' do
    it 'is sent to the organisation picker before the glossary' do
      sign_in member_with(role_with('manage_glossary'), active: false)

      get organisation_glossary_terms_path(organisation)

      expect(response).to redirect_to(select_organisation_path)
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

    it 'answers 404 for confirm of a term of another organisation' do
      ActsAsTenant.with_tenant(other_organisation) { foreign_term.update!(status: 'proposed') }

      patch confirm_organisation_glossary_term_path(organisation, foreign_term)

      expect(response).to have_http_status(:not_found)
      expect(GlossaryTerm.unscoped.find(foreign_term.id).status).to eq('proposed')
    end

    it 'answers 404 for reject of a term of another organisation' do
      patch reject_organisation_glossary_term_path(organisation, foreign_term)

      expect(response).to have_http_status(:not_found)
      expect(GlossaryTerm.unscoped.find(foreign_term.id).status).to eq('confirmed')
    end

    it 'answers 404 for merging a term of another organisation into this glossary' do
      post merge_organisation_glossary_term_path(organisation, foreign_term), params: { target_id: term.id }

      expect(response).to have_http_status(:not_found)
      expect(GlossaryTerm.unscoped.exists?(foreign_term.id)).to be(true)
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

    # The lane parameters the server did not open go to layout-toggle, which
    # takes them out of the address (review round 2 of #113).
    it 'names an unknown term_id as unresolved, and none for an opened term' do
      unknown = SecureRandom.uuid
      get organisation_glossary_terms_path(organisation, term_id: unknown)

      data = Nokogiri::HTML(response.body).at_css('.glossary-page')['data-layout-toggle-unresolved-selection-value']
      expect(JSON.parse(data)).to eq('term_id' => unknown)

      get organisation_glossary_terms_path(organisation, term_id: term.id)

      expect(Nokogiri::HTML(response.body).at_css('.glossary-page')['data-layout-toggle-unresolved-selection-value']).to be_nil
    end

    it 'keeps the phone view through a refused save' do
      post organisation_glossary_terms_path(organisation), params: { glossary_term: { term: 'LALABASE' }, viewport: 'mobile' }

      expect(response).to have_http_status(:unprocessable_content)
      page = Nokogiri::HTML(response.body)
      expect(page.css('.people-mobile-grid')).to be_present
      expect(page.css('form.people-form input[type="hidden"][name="viewport"][value="mobile"]')).to be_present
    end

    it 'keeps the phone view through a write' do
      patch confirm_organisation_glossary_term_path(organisation, proposal), params: { viewport: 'mobile' }

      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, viewport: 'mobile'))
    end

    it 'answers a lane request of the index with the lane alone' do
      get organisation_glossary_terms_path(organisation, term_id: term.id), headers: frame_headers

      expect(response.body).to start_with(%(<turbo-frame id="#{Organisations::GlossaryController::DETAIL_FRAME_ID}">))
      expect(response.body).not_to include('glossary-tools')
    end
  end

  # K4b (E3): a correction in a meeting without manage_glossary leaves an open
  # heard form, also at a confirmed term. The page shows it as open, and only
  # manage_glossary confirms it (it works from then on) or rejects it (its
  # proposals go, a confirmed correction of the same form stays).
  describe 'open heard forms' do
    let!(:open_form) do
      create(:term_correction, organisation: organisation, glossary_term: term, heard: 'lala beis', status: 'proposed',
                               project: open_project)
    end
    let(:gs) { 'views.organisations.glossary' }

    def lane_markup
      get organisation_glossary_term_path(organisation, term), headers: frame_headers
      Nokogiri::HTML(response.body)
    end

    def open_group(page)
      page.css('.glossary-heard__group').find { |group| group.text.include?('lala beis') }
    end

    it 'marks a term with open forms in the list, also for a reader' do
      sign_in viewer
      get organisation_glossary_terms_path(organisation)

      row = Nokogiri::HTML(response.body).css('[data-glossary-row]').find { |node| node.text.include?('Lalabase') }
      expect(row.text).to include(I18n.t("#{gs}.index.open_forms", count: 1))
    end

    # Review round 2 of #121: the badge counts forms, not their proposals.
    it 'counts open forms, not the proposals in them' do
      create(:term_correction, organisation: organisation, glossary_term: term, heard: 'Lala Beis', status: 'proposed')
      create(:term_correction, organisation: organisation, glossary_term: term, heard: 'lala bese', status: 'proposed')
      sign_in viewer
      get organisation_glossary_terms_path(organisation)

      row = Nokogiri::HTML(response.body).css('[data-glossary-row]').find { |node| node.text.include?('Lalabase') }
      expect(row.text).to include(I18n.t("#{gs}.index.open_forms", count: 2))
      expect(row.text).not_to include(I18n.t("#{gs}.index.open_forms", count: 3))
    end

    it 'shows the open form as a proposal in the lane, without buttons for a reader' do
      sign_in viewer
      group = open_group(lane_markup)

      expect(group.text).to include(I18n.t("#{gs}.show.open_form"))
      expect(group.css('form')).to be_empty
      closed = lane_markup.css('.glossary-heard__group').find { |node| node.text.include?('la la base') }
      expect(closed.text).not_to include(I18n.t("#{gs}.show.open_form"))
    end

    it 'offers confirm and reject of the open form with manage_glossary' do
      sign_in manager
      group = open_group(lane_markup)

      actions = group.css('form').pluck('action')
      expect(actions).to include(confirm_heard_form_organisation_glossary_term_path(organisation, term, correction_id: open_form.id),
                                 reject_heard_form_organisation_glossary_term_path(organisation, term, correction_id: open_form.id))
    end

    it 'confirms the form, which works from then on' do
      sign_in manager
      patch confirm_heard_form_organisation_glossary_term_path(organisation, term, correction_id: open_form.id)

      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, term_id: term.id))
      expect(flash[:notice]).to eq(I18n.t('controllers.glossary.heard_form.confirm.success'))
      expect(TermCorrection.effective.where(id: open_form.id)).to exist
    end

    it 'rejects the form: its proposals go, its confirmed corrections stay' do
      kept = create(:term_correction, organisation: organisation, glossary_term: term, heard: 'Lala Beis')
      sign_in manager

      delete reject_heard_form_organisation_glossary_term_path(organisation, term, correction_id: open_form.id)

      expect(flash[:notice]).to eq(I18n.t('controllers.glossary.heard_form.reject.success'))
      expect(TermCorrection.where(id: open_form.id)).not_to exist
      expect(TermCorrection.where(id: kept.id)).to exist
    end

    it 'says so when nothing of the form is open any more' do
      sign_in manager
      open_form.update!(status: 'confirmed')

      patch confirm_heard_form_organisation_glossary_term_path(organisation, term, correction_id: open_form.id)

      expect(flash[:alert]).to eq(I18n.t('controllers.glossary.heard_form.not_open'))
    end

    it 'answers 404 for a heard form of another term or another organisation, and changes nothing' do
      foreign = ActsAsTenant.with_tenant(other_organisation) do
        create(:term_correction, organisation: other_organisation, status: 'proposed')
      end
      user = manager
      before = glossary_state

      # One sign-in per request: a 404 of the exceptions app writes no session.
      sign_in user
      patch confirm_heard_form_organisation_glossary_term_path(organisation, proposal, correction_id: open_form.id)
      expect(response).to have_http_status(:not_found)
      sign_in user
      delete reject_heard_form_organisation_glossary_term_path(organisation, term, correction_id: foreign.id)
      expect(response).to have_http_status(:not_found)
      sign_in user
      patch confirm_heard_form_organisation_glossary_term_path(organisation, foreign.glossary_term_id, correction_id: foreign.id)
      expect(response).to have_http_status(:not_found)
      expect(glossary_state).to eq(before)
      expect(ActsAsTenant.without_tenant { foreign.reload.status }).to eq('proposed')
    end

    it 'confirms the open forms of a proposed term with the term' do
      proposed_form = create(:term_correction, organisation: organisation, glossary_term: proposal, heard: 'zirbel holz',
                                               status: 'proposed')
      sign_in manager

      patch confirm_organisation_glossary_term_path(organisation, proposal)

      expect(proposal.reload).to be_confirmed
      expect(proposed_form.reload).to be_confirmed
      expect(open_form.reload).to be_proposed
    end
  end

  # K5b: a heard form from the glossary extraction or from an import says so
  # after its project. It has no meeting, so it never stands where a meeting
  # would, and a form from a meeting stays as it was.
  describe 'the origin of a heard form in the lane' do
    def origin_of(heard)
      get organisation_glossary_term_path(organisation, term), headers: frame_headers
      group = Nokogiri::HTML(response.body).css('.glossary-heard__group').find { |node| node.at_css('.glossary-heard__form').text.include?(heard) }
      group.at_css('.glossary-heard__origin').text.squish
    end

    let(:origins) { 'views.organisations.glossary.heard_origins' }

    before do
      create(:term_correction, organisation: organisation, glossary_term: term, heard: 'lalabeis', project: open_project,
                               origin: 'extraction')
      create(:term_correction, organisation: organisation, glossary_term: term, heard: 'lalabais', origin: 'import')
    end

    it 'names the extraction and an import after the project, for every reader' do
      sign_in viewer

      expect(origin_of('lalabeis')).to eq("Projekt Ahorn · #{I18n.t("#{origins}.extraction")}")
      expect(origin_of('lalabais')).to eq("#{I18n.t('views.organisations.glossary.show.no_project')} · #{I18n.t("#{origins}.import")}")
      expect(origin_of('lala bass')).to eq('Projekt Ahorn')
    end

    it 'keeps the meeting of a form from a meeting, and names none for the others' do
      sign_in admin

      expect(origin_of('lala bass')).to eq('Projekt Ahorn · Abstimmung Ahorn')
      get organisation_glossary_term_path(organisation, term), headers: frame_headers
      page = Nokogiri::HTML(response.body)
      expect(page.css('.glossary-heard__origin a').map(&:text)).to contain_exactly('Abstimmung Ahorn', 'Geheimrunde Birke')
    end

    %w[de en].each do |locale|
      it "names the origins in #{locale}" do
        admin.update!(language_preference: locale)
        sign_in admin

        I18n.with_locale(locale) do
          expect(origin_of('lalabeis')).to end_with(I18n.t("#{origins}.extraction"))
        end
        expect(response.body).not_to include('translation missing', 'Translation missing')
      end
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
                                   person: create(:person, organisation: organisation), project: open_project,
                                   status: 'proposed')
        end
      end
    end

    it 'renders the list of many terms without an N+1' do
      sign_in manager

      get organisation_glossary_terms_path(organisation)

      expect(response).to have_http_status(:ok)
      page = Nokogiri::HTML(response.body)
      expect(page.css('[data-glossary-row]').size).to eq(5)
      expect(page.text.scan(I18n.t('views.organisations.glossary.index.open_forms', count: 1)).size).to eq(3)
    end

    it 'renders a lane with many heard forms without an N+1' do
      sign_in member_with(role_with('manage_glossary', 'people:view_people'))
      target = GlossaryTerm.find_by!(term: 'Vorschlag 0')
      create(:term_correction, organisation: organisation, glossary_term: target, heard: 'vor schlag 0', meeting: open_meeting,
                               project: open_project, user: member_with(role_with))

      get organisation_glossary_term_path(organisation, target), headers: frame_headers

      expect(response).to have_http_status(:ok)
      page = Nokogiri::HTML(response.body)
      expect(page.css('.glossary-heard__row').size).to eq(3)
      expect(page.css('.glossary-heard__decide form').size).to eq(2)
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
