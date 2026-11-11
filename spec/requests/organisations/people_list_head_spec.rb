# frozen_string_literal: true

require 'rails_helper'

# What: the head of the people list wears the bar of the ticket list, as the
#       inbox does (user, 2026-11-11):
#       - the three views (Alle, Mitglieder, Kontakte) as its tabs (F10, the
#         same classes), each with its count, keeping the search and the person
#         open now;
#       - the search the last thing in the row, a magnifier that grows into the
#         field (F35, NeoListSearchComponent, shared with the inbox), open while
#         a term stands in it;
#       - the search answers while typing: it reloads only the list frame, and
#         the tabs, whose links carry the search, ride along as a
#         <turbo-stream> INSIDE the frame answer.
# Why:  until then the page had a wide search field on the left and pills, the
#       form of the inbox before PR #139; the user expected it to look like
#       "Alle Meetings". A tab drawn before the search would drop it on the
#       next click.
RSpec.describe 'People list head', type: :request do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:admin) do
    user = create(:user, first_name: 'Anna', last_name: 'Beispiel')
    role = create(:role, organisation: organisation, title: Role::ACCOUNT_ADMIN_TITLE)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    user
  end
  let!(:doris) { create(:person, organisation: organisation, name: 'Doris Dienstleister') }
  let!(:emil) { create(:person, organisation: organisation, name: 'Emil Extern') }
  let(:frame_id) { Organisations::PeopleController::LIST_FRAME_ID }

  before { sign_in admin }

  def doc_for(**params)
    get organisation_people_path(organisation, **params)
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  def frame_answer(**params)
    get organisation_people_path(organisation, **params), headers: { 'Turbo-Frame' => frame_id }
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body).at_css("turbo-frame##{frame_id}")
  end

  def kind_word(kind) = I18n.t("views.organisations.people.index.kinds.#{kind}")

  def tab_word(tab) = tab.children.find { |node| node.text? && node.text.strip.present? }.text.strip

  def query_of(href) = Rack::Utils.parse_nested_query(URI(CGI.unescapeHTML(href)).query)

  describe 'the tabs' do
    it 'draws the views as the ticket list draws its tabs, the active one marked' do
      tabs = doc_for(kind: 'contacts').css('.people-tools [role="tablist"] a[role="tab"]')

      expect(tabs.map { |tab| tab_word(tab) }).to eq(%w[all members contacts].map { |kind| kind_word(kind) })
      expect(tabs.map { |tab| tab['aria-selected'] }).to eq(%w[false false true])
      expect(tabs.last['class']).to eq(NeoFilterBarComponent.tab_classes(true))
      expect(tabs.first(2).map { |tab| tab['class'] }).to all(eq(NeoFilterBarComponent.tab_classes(false)))
    end

    it 'marks "Alle" without a view in the address' do
      tabs = doc_for.css('[role="tablist"] a[role="tab"]')

      expect(tabs.map { |tab| tab['aria-selected'] }).to eq(%w[true false false])
    end

    it 'keeps the search and the person open now, and leaves the pills behind' do
      doc = doc_for(q: 'dienst', sort: 'last')
      tabs = doc.css('[role="tablist"] a[role="tab"]')

      expect(tabs.map { |tab| query_of(tab['href'])['q'] }).to all(eq('dienst'))
      expect(tabs.map { |tab| query_of(tab['href'])['sort'] }).to all(eq('last'))
      expect(tabs.map { |tab| query_of(tab['href'])['kind'] }).to eq([nil, 'members', 'contacts'])
      expect(tabs.map { |tab| tab['data-lane-keep'] }).to all(eq('true'))
      expect(doc.css('.people-pill, .people-filters, .people-search__field')).to be_empty
    end
  end

  describe 'the search' do
    it 'is the last thing in the bar, a magnifier while empty' do
      bar = doc_for.at_css('.people-tools')
      search = bar.at_css('[data-fb-search]')

      expect(bar['class'].split).to include('list-tab-bar', 'filter-bar')
      expect(bar.element_children.last).to eq(search)
      expect(search['data-controller']).to eq('search-disclosure')
      expect(search.key?('data-fb-search-open')).to be(false)
      expect(search.at_css('button[data-fb-search-open-button]')['aria-label'])
        .to eq(I18n.t('views.organisations.people.index.search_label'))
    end

    it 'stands open while a term is typed' do
      search = doc_for(q: 'dienst').at_css('[data-fb-search]')

      expect(search.key?('data-fb-search-open')).to be(true)
      expect(search.at_css('input#people-search[name="q"]')['value']).to eq('dienst')
    end

    # No turbo action: layout-toggle follows the list frame into the address
    # and keeps the person open there (people_page_data); the form carries the
    # list state alone, the person stays out of it (a row click changes the
    # person in the address only, after the form was drawn).
    it 'submits while typing into the list frame, keeping the view and the order' do
      form = doc_for(kind: 'contacts', sort: 'last', person_id: doris.id).at_css('form.people-search')

      expect(form['data-controller']).to eq('auto-submit')
      expect(form['data-turbo-frame']).to eq(frame_id)
      expect(form['data-turbo-action']).to be_nil
      hidden = form.css('input[type="hidden"]').to_h { |input| [input['name'], input['value']] }
      expect(hidden).to eq('kind' => 'contacts', 'sort' => 'last')
    end

    it 'filters the list frame and redraws the tabs with the search' do
      frame = frame_answer(q: 'dienst')

      expect(frame.text).to include('Doris Dienstleister')
      expect(frame.text).not_to include('Emil Extern')
      stream = frame.at_css('turbo-stream[action="replace"][target="people_list_tabs"]')
      expect(stream).to be_present, 'the tabs ride inside the frame, or Turbo drops them'
      tabs = Nokogiri::HTML(stream.at_css('template').inner_html).css('#people_list_tabs a[role="tab"]')
      expect(tabs.size).to eq(3)
      expect(tabs.map { |tab| query_of(tab['href'])['q'] }).to all(eq('dienst'))
    end

    it 'shows the whole view again once the field is empty' do
      frame = frame_answer(q: '')

      expect(frame.text).to include('Doris Dienstleister', 'Emil Extern')
    end

    it 'marks the row of the person the search carries' do
      frame = frame_answer(q: 'dienst', person_id: doris.id)

      expect(frame.at_css(".people-row.selected-row[data-list-row-id-value='#{doris.id}']")).to be_present
    end

    it 'sends no tabs stream on a full page' do
      doc = doc_for(q: 'dienst')

      expect(doc.at_css('turbo-stream[target="people_list_tabs"]')).to be_nil
      expect(doc.css('#people_list_tabs').size).to eq(1)
    end
  end

  it 'names the organisation under the title, as "Alle Meetings" and the inbox do' do
    head = doc_for.at_css('.people-head')

    expect(head.text).to include(organisation.name)
  end
end
