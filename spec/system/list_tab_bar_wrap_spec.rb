# frozen_string_literal: true

require 'rails_helper'

# What: the bar of the inbox, Personen and Glossar (.list-tab-bar) keeps one
#       row while its tools fit beside the tabs; where they do not, the tools
#       move to a line above the tabs, and the tabs stay whole on the divider.
# Why:  until 2026-11-11 the row never wrapped: on a phone the inbox's two
#       selects took the room and cut its tabs down to "Alle Ung", and the
#       glossary's would have done the same. Measured in a browser, because
#       only the layout shows what fits.
RSpec.describe 'List tab bar on a narrow row', type: :system do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, first_name: 'Anna', last_name: 'Beispiel') }

  before do
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
    role = create(:role, organisation: organisation, title: Role::ACCOUNT_ADMIN_TITLE)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    create(:person, organisation: organisation, name: 'Berta Erste')
    create(:glossary_term, organisation: organisation, term: 'Zorbelstein')
    sign_in user
  end

  after do
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  # Where the tab strip and the tools stand in the bar, in whole pixels, and
  # how much of the strip is cut (its scroll width beyond its own width).
  def geometry
    expect(page).to have_css('.list-tab-bar [role="tablist"]')
    page.evaluate_script(<<~JS)
      (function () {
        var bar = document.querySelector('.list-tab-bar');
        var tabs = bar.querySelector('[role="tablist"]');
        var tools = bar.querySelector('.list-tab-bar__tools') || bar.querySelector('[data-fb-search]');
        var b = bar.getBoundingClientRect(), t = tabs.getBoundingClientRect(), o = tools.getBoundingClientRect();
        return { cut: tabs.scrollWidth - tabs.clientWidth,
                 tabs_top: Math.round(t.top), tabs_bottom: Math.round(t.bottom),
                 tools_top: Math.round(o.top), tools_bottom: Math.round(o.bottom), bar_bottom: Math.round(b.bottom) };
      })()
    JS
  end

  def expect_tools_above_whole_tabs(name)
    measured = geometry
    expect(measured['cut']).to be <= 0, "#{name}: the tabs are cut: #{measured.inspect}"
    expect(measured['tools_bottom']).to be <= measured['tabs_top'], "#{name}: the tools do not stand above the tabs: #{measured.inspect}"
    expect((measured['bar_bottom'] - measured['tabs_bottom']).abs).to be <= 1, "#{name}: the tabs left the divider: #{measured.inspect}"
  end

  it 'moves the tools above whole tabs on a phone: the inbox and the glossary' do
    page.driver.browser.manage.window.resize_to(400, 844)

    visit organisation_notifications_path(organisation, viewport: 'mobile')
    expect_tools_above_whole_tabs('Inbox')

    visit organisation_glossary_terms_path(organisation, viewport: 'mobile')
    expect_tools_above_whole_tabs('Glossar')
  end

  it 'keeps one row where the tools fit: the glossary and Personen on a desk' do
    page.driver.browser.manage.window.resize_to(1400, 900)

    [organisation_glossary_terms_path(organisation), organisation_people_path(organisation)].each do |path|
      visit path
      measured = geometry
      expect(measured['tools_bottom']).to be > measured['tabs_top'], "#{path}: the tools left the tabs' row: #{measured.inspect}"
      expect(measured['cut']).to be <= 0, "#{path}: the tabs are cut: #{measured.inspect}"
    end
  end
end
