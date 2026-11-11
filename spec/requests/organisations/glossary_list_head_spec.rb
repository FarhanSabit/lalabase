# frozen_string_literal: true

require 'rails_helper'

# What: the head of the glossary wears the bar of the ticket list, as the
#       inbox and Personen do (user, 2026-11-11):
#       - the statuses of the list as its tabs (F10, the same classes), each
#         with its count: of a term on the terms, of a proposal in the review
#         list;
#       - at the right end project and category as the bar's selects, tinted
#         while they narrow the list;
#       - outermost the way to the other list, "Prüfliste" from the terms and
#         "Zurück zu den Begriffen" from the review list, in one place;
#       - the organisation's name under the title.
# Why:  until then the glossary had the people page's old head: pills, a
#       review pill among them and boxed selects.
RSpec.describe 'Glossary list head', type: :request do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:manager) do
    role = create(:role, organisation: organisation)
    create(:permission, role: role, category: 'glossary', action: 'manage_glossary', allowed: true)
    user = create(:user, first_name: 'Anna', last_name: 'Beispiel')
    create(:membership, user: user, organisation: organisation, role: role)
    user
  end
  let(:project) { create(:project, organisation: organisation, name: 'Projekt Ahorn') }

  before do
    create(:glossary_term, organisation: organisation, term: 'Zorbelstein')
    create(:glossary_term, :proposed, organisation: organisation, term: 'Quarnix')
    create(:glossary_proposal, organisation: organisation, term: 'Wub')
    sign_in manager
  end

  def doc_for(**params)
    get organisation_glossary_terms_path(organisation, **params)
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  def tab_words(bar) = bar.css('[role="tablist"] a[role="tab"]').map { |tab| tab.children.find { |node| node.text? && node.text.strip.present? }.text.strip }

  describe 'on the terms' do
    it 'draws the statuses as the ticket list draws its tabs, each with its count' do
      bar = doc_for(status: 'proposed').at_css('.people-tools')
      tabs = bar.css('[role="tablist"] a[role="tab"]')

      expect(bar['class'].split).to include('list-tab-bar')
      expect(tab_words(bar)).to eq(%w[all proposed confirmed rejected].map { |key| I18n.t("views.organisations.glossary.index.status_filter.#{key}") })
      expect(tabs.map { |tab| tab.at_css('.people-pill__count').text }).to eq(%w[2 1 1 0])
      expect(tabs.map { |tab| tab['aria-selected'] }).to eq(%w[false true false false])
      expect(tabs[1]['class']).to eq(NeoFilterBarComponent.tab_classes(true))
      expect([tabs[0], *tabs[2..]].map { |tab| tab['class'] }).to all(eq(NeoFilterBarComponent.tab_classes(false)))
      expect(bar.css('.people-pill--active, .people-filters')).to be_empty
    end

    it 'puts project and category among the tools, tinted while they narrow, and the review list outermost' do
      project
      tools = doc_for(category: 'product').at_css('.people-tools .list-tab-bar__tools')

      selects = tools.css('select')
      expect(selects.map { |select| select['name'] }).to eq(%w[project_id category])
      expect(selects.map { |select| select['class'].split }).to all(include('list-tab-bar__select'))
      expect(selects.map { |select| select['class'].include?('list-tab-bar__select--active') }).to eq([false, true])
      expect(tools.element_children.last['data-glossary-review-link']).to be_present
      expect(tools.element_children.last.at_css('.people-pill__count').text).to eq('1')
    end

    it 'keeps project and category in the tabs and the way to the review list, and leaves the status behind there' do
      doc = doc_for(status: 'confirmed', category: 'product')

      hrefs = doc.css('[role="tablist"] a[role="tab"]').map { |tab| tab['href'] }
      expect(hrefs).to all(include('category=product'))
      review = doc.at_css('a[data-glossary-review-link]')['href']
      expect(review).to eq(organisation_glossary_terms_path(organisation, category: 'product', view: 'proposals'))
    end
  end

  describe 'in the review list' do
    it 'draws the statuses of a proposal as tabs and the way back outermost' do
      bar = doc_for(view: 'proposals').at_css('.people-tools')

      expect(tab_words(bar)).to eq(GlossaryProposal::STATUSES.map { |status| I18n.t("views.organisations.glossary.proposals.statuses.#{status}") })
      expect(bar.css('[role="tablist"] a[aria-selected="true"]').map { |tab| tab['data-glossary-proposal-status'] }).to eq(['open'])
      last = bar.at_css('.list-tab-bar__tools').element_children.last
      expect(last['data-glossary-terms-link']).to be_present
      expect(bar.at_css('a[data-glossary-review-link]')).to be_nil
    end
  end

  it 'names the organisation under the title, as "Alle Meetings", the inbox and Personen do' do
    expect(doc_for.at_css('.people-head').text).to include(organisation.name)
  end
end
