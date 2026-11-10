# frozen_string_literal: true

require 'rails_helper'

# What: the page title (h1) stands at the same place on every list page:
#       the same distance from the left edge and from the top of the main
#       column as on "Alle Meetings". The list below starts at the same left
#       edge as the title.
# Why:  until 2026-11-10 the pages built on the people head (Personen, Inbox,
#       Glossar) indented head, tools and list by another 24 px and the head
#       by 20 px from the top, on top of the main column's own padding: their
#       title stood 24 px further right and 20 px lower than everywhere else.
#       Measured in a browser, because the offset is a sum of paddings in
#       several places that no single file shows.
RSpec.describe 'Page title edge', type: :system do
  before { Prosopite.pause }
  after  { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:admin_role, organisation: organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      create(:person, organisation: organisation)
    end
    login_as(user, scope: :user)
    page.driver.browser.manage.window.resize_to(1400, 800)
  end

  # Title and first list edge relative to <main>, in whole pixels.
  def edges(path, list_selector)
    visit path
    expect(page).to have_css('main h1')
    page.evaluate_script(<<~JS)
      (function () {
        var main = document.querySelector('main').getBoundingClientRect();
        var title = document.querySelector('main h1').getBoundingClientRect();
        var list = document.querySelector(#{list_selector.to_json});
        return { title_left: Math.round(title.left - main.left),
                 title_top: Math.round(title.top - main.top),
                 list_left: list && Math.round(list.getBoundingClientRect().left - main.left) };
      })()
    JS
  end

  it 'puts the title of Personen, Inbox and Glossar where "Alle Meetings" puts it' do
    reference = edges(organisation_meetings_path(organisation), 'main h1')

    {
      'Personen' => [organisation_people_path(organisation), '.people-tools > :first-child'],
      'Inbox' => [organisation_notifications_path(organisation, state_filters: %w[read unread]), '.people-list'],
      'Glossar' => [organisation_glossary_terms_path(organisation), '.people-tools > :first-child']
    }.each do |name, (path, list_selector)|
      measured = edges(path, list_selector)

      expect([measured['title_left'], measured['title_top']])
        .to eq([reference['title_left'], reference['title_top']]), "title of #{name}: #{measured.inspect}"
      expect(measured['list_left']).to eq(measured['title_left']), "#{list_selector} of #{name}: #{measured.inspect}"
    end
  end
end
