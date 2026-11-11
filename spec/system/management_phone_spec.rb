# frozen_string_literal: true

require 'rails_helper'

# What: the management area on a phone (doc/verwaltung_seitennavigation_plan.md §6, S4):
#       - the "Mehr" page lists the sections of the area, in the order and with the
#         addresses of the desktop sidebar's management list (a phone has no such
#         sidebar), and a tap leads into a section;
#       - the tab row of organisations/shared/_subnav stays ONE row and scrolls
#         sideways, and the open tab lies inside the row's visible box: on
#         "Protokoll", the sixth KI tab, opened by its address, and on every KI tab
#         tapped from there. Only the row moves, never the page. Once the reader
#         has swiped the row, it stays there when a tab changes size later;
#       - on a desk (md and wider) the row wraps as before and does not scroll;
#       - the mobile header names each management page by its own title
#         (MobileNavigationHelper::PAGE_TITLE_KEYS), never by the fallback "Mehr".
# Why:  until 2026-11-11 the row wrapped (flex-wrap): on a phone the six KI tabs
#       took two rows (tops 0 and 42 px, the bar 80 px high instead of 38). A row
#       that scrolls instead hides the tabs past its end, the open one too unless
#       something brings it in: "Protokoll" began at 485 px of a row 358 px wide.
#       Measured in a browser, because only the layout shows what fits.
RSpec.describe 'Management area on a phone', type: :system do
  let(:organisation) { create(:organisation, name: 'Beispiel GmbH', ai_enabled: true) }
  let(:admin) { create(:user, first_name: 'Anna', last_name: 'Beispiel') }
  let(:section) { I18n.t('settings.ai') }

  before do |example|
    Prosopite.pause
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation,
                          role: create(:admin_role, organisation: organisation), active: true)
    end
    sign_in admin
    # A phone for every example but the desk's.
    next if example.metadata[:desk]

    page.driver.browser.execute_cdp('Emulation.setDeviceMetricsOverride', width: 390, height: 844,
                                                                          deviceScaleFactor: 1, mobile: true)
  end

  # The browser outlives the example: without this every later spec runs on a phone.
  after do
    page.driver.browser.execute_cdp('Emulation.clearDeviceMetricsOverride')
    page.driver.browser.execute_cdp('Emulation.setTouchEmulationEnabled', enabled: false)
    Prosopite.resume
  end

  def mobile_title = find('.mobile-header h1').text

  describe 'the "Mehr" page' do
    it 'lists the sections of the management area and leads into them' do
      visit organisation_mobile_more_path(organisation)

      sections = NavigationHelper::SETTINGS_TABS.filter_map do |tab|
        next if tab[:gate] && !organisation.public_send(tab[:gate])

        [I18n.t(tab[:label_key]), public_send(tab[:path_helper], organisation)]
      end
      expect(page).to have_css('main h2', exact_text: I18n.t('navigation.management'))
      listed = all('main [data-management-nav] a').map { |link| [link.text.squish, URI(link[:href]).path] }
      expect(listed).to eq(sections)

      within('main [data-management-nav]') { click_link section }
      expect(page).to have_current_path(organisation_ai_overview_path(organisation))
      expect(mobile_title).to eq(section)
    end
  end

  describe 'the tab row' do
    # The six KI tabs in their order (NavigationHelper::AI_SECTION_TABS).
    let(:tab_labels) do
      %w[pages.overview pages.access usage.title pages.index pages.personas protocol.title]
        .map { |key| I18n.t("views.organisations.ai_overview.#{key}") }
    end

    # The row as the reader sees it once the web font has loaded and the page has
    # painted: the top of each tab in the row, whether the row wraps or scrolls and
    # how far, the open tab against the row's visible box (both from the row's left
    # edge), the row against main's content edge, and whether anything moved the
    # page. Overflow is measured against documentElement.clientWidth: under the
    # phone emulation window.innerWidth grows with a page that overflows and hides
    # what it measures.
    def row_geometry
      page.evaluate_async_script(<<~JS, section)
        const label = arguments[0], done = arguments[1]
        document.fonts.ready.then(() => requestAnimationFrame(() => requestAnimationFrame(() => {
          const row = document.querySelector(`main nav[aria-label="${CSS.escape(label)}"] ul`)
          const box = row.getBoundingClientRect(), computed = getComputedStyle(row)
          const open = row.querySelector('[aria-current]').getBoundingClientRect()
          const main = document.querySelector('main'), edge = main.getBoundingClientRect(), style = getComputedStyle(main)
          const round = value => Math.round(value * 10) / 10
          done({
            tops: Array.from(row.children, item => round(item.firstElementChild.getBoundingClientRect().top - box.top)),
            flex_wrap: computed.flexWrap, overflow_x: computed.overflowX,
            scroll_width: row.scrollWidth, client_width: row.clientWidth, scroll_left: round(row.scrollLeft),
            open_tab: [round(open.left - box.left), round(open.right - box.left)],
            row: [round(box.left), round(box.right)],
            content: [round(edge.left + parseFloat(style.paddingLeft)), round(edge.right - parseFloat(style.paddingRight))],
            page_overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth,
            page_scroll: [window.scrollX, window.scrollY]
          })
        })))
      JS
    end

    # Within a pixel counts as in view: the browser rounds the row's scroll width
    # to whole pixels, so the last tab can end a fraction past the row's end
    # (Protokoll at 390 px ends 0.2 px past it: 546.3 px of tabs, a scroll width of 546).
    def open_tab_in_view?(row)
      left, right = row['open_tab']
      left > -1 && right < row['client_width'] + 1
    end

    # Opened by its address, the page starts its Stimulus controllers after its
    # load event, so the row may still stand at its start when the page is there:
    # measured again until the open tab is in view or the wait is over, and the
    # expectations read the last measurement. A tab tapped in the row is a Turbo
    # visit: the new page's controllers connect as it is inserted, and the row
    # moves in the frame after; row_geometry measures two frames later.
    def settled_row
      deadline = Capybara::Helpers.monotonic_time + Capybara.default_max_wait_time
      loop do
        row = row_geometry
        return row if open_tab_in_view?(row) || Capybara::Helpers.monotonic_time > deadline

        sleep 0.1
      end
    end

    def expect_one_row_with_the_open_tab_in_view(name, row)
      expect(row['tops'].uniq.size).to eq(1), "#{name}: the tabs do not share one top, the row wrapped: #{row.inspect}"
      expect(open_tab_in_view?(row)).to be(true), "#{name}: the open tab lies outside the row's visible box: #{row.inspect}"
      expect(row['row'].first).to be >= row['content'].first - 0.5, "#{name}: the row starts left of main's content: #{row.inspect}"
      expect(row['row'].last).to be <= row['content'].last + 0.5, "#{name}: the row ends past main's content: #{row.inspect}"
      expect(row['page_overflow']).to be <= 0, "#{name}: the page scrolls sideways: #{row.inspect}"
      expect(row['page_scroll']).to eq([0, 0]), "#{name}: the page moved: #{row.inspect}"
    end

    it 'stays one row that scrolls sideways, with the open tab in view, also the sixth' do
      visit organisation_ai_protocol_path(organisation)
      expect(page).to have_css('main nav [aria-current="page"]', exact_text: tab_labels.last)

      row = settled_row
      expect(row['scroll_width']).to be > row['client_width'], "Protokoll: the row does not scroll: #{row.inspect}"
      expect_one_row_with_the_open_tab_in_view('Protokoll', row)
      expect(mobile_title).to eq(tab_labels.last)

      tab_labels.each do |label|
        within("main nav[aria-label='#{section}']") { click_link label }
        expect(page).to have_css('main nav [aria-current="page"]', exact_text: label)

        row = settled_row
        expect_one_row_with_the_open_tab_in_view(label, row)
        # The first tab keeps the row at its start: nothing moves a row whose open tab is in view.
        expect(row['scroll_left']).to eq(0), "#{label}: the row left its start: #{row.inspect}" if label == tab_labels.first
      end
    end

    # A finger on the row swipes it back to its start (touch emulation as in
    # mobile_shell_regressions_spec, switched off again in `after`).
    def swipe_row_to_its_start
      middle = page.evaluate_script(<<~JS, section)
        (function (label) {
          const box = document.querySelector(`main nav[aria-label="${CSS.escape(label)}"] ul`).getBoundingClientRect()
          return { x: Math.round(box.left + box.width / 2), y: Math.round(box.top + box.height / 2) }
        })(arguments[0])
      JS
      page.driver.browser.execute_cdp('Emulation.setTouchEmulationEnabled', enabled: true)
      page.driver.browser.execute_cdp('Input.synthesizeScrollGesture', x: middle['x'], y: middle['y'], xDistance: 400,
                                                                       yDistance: 0, speed: 800, gestureSourceType: 'touch')
    end

    # The phone turned to `width`, laid out and reported to the row's observer.
    def turn_phone_to(width)
      page.driver.browser.execute_cdp('Emulation.setDeviceMetricsOverride', width: width, height: 844,
                                                                            deviceScaleFactor: 1, mobile: true)
      page.evaluate_async_script('requestAnimationFrame(() => requestAnimationFrame(arguments[0]))')
    end

    # The reader's hand wins (review of S4A): a tab that changed size later, as with
    # a late web font (here: letter spacing on the first tab), pulled the swiped row
    # back to the open tab (the review measured 0 to 193, this example 0 to 187). A
    # turned phone does not pull it back either: the browser keeps the reader's
    # offset through the turn.
    it 'leaves the row where the reader swiped it when a tab changes size or the phone turns' do
      visit organisation_ai_protocol_path(organisation)
      expect(page).to have_css('main nav [aria-current="page"]', exact_text: tab_labels.last)
      expect(settled_row['scroll_left']).to be_positive

      swipe_row_to_its_start
      expect(row_geometry['scroll_left']).to eq(0)

      page.execute_script(<<~JS, section)
        document.querySelector(`main nav[aria-label="${CSS.escape(arguments[0])}"] li > :first-child`).style.letterSpacing = '1px'
      JS
      row = row_geometry
      expect(row['scroll_left']).to eq(0), "a tab changed size, and the row went back to the open tab: #{row.inspect}"

      turn_phone_to(844)
      turn_phone_to(390)
      row = row_geometry
      expect(row['scroll_left']).to eq(0), "the phone turned and back, and the row went back to the open tab: #{row.inspect}"
    end

    # The phone rule holds below md only: from md on the row wraps as it did before
    # and does not scroll. Measured at 1024 px, where the layout has its sidebar
    # again, without the phone's emulation (the `before` above reads :desk).
    context 'on a desk', :desk do
      let(:window) { page.driver.browser.manage.window }
      let!(:window_size) { window.size }

      before { window.resize_to(1024, 800) }
      after { window.resize_to(window_size.width, window_size.height) }

      it 'wraps as before and does not scroll, one line where the tabs fit' do
        visit organisation_ai_overview_path(organisation)
        expect(page).to have_css('main nav [aria-current="page"]', exact_text: tab_labels.first)

        row = row_geometry
        expect(row['flex_wrap']).to eq('wrap'), "the row does not wrap from md on: #{row.inspect}"
        expect(row['overflow_x']).to eq('visible'), "the row scrolls from md on: #{row.inspect}"
        expect(row['tops'].uniq.size).to eq(1), "the tabs do not share one top at 1024 px: #{row.inspect}"
      end
    end
  end

  describe 'the mobile header' do
    it 'names each management page by its own title, not the fallback' do
      fallback = I18n.t('mobile.more')

      {
        'Allgemein' => [organisation_settings_path(organisation), 'organisation_settings'],
        'Mitglieder' => [organisation_memberships_path(organisation), 'memberships'],
        'Zugriffsübersicht' => [organisation_access_matrix_index_path(organisation), 'access_matrix'],
        'Mitglied einladen' => [new_organisation_invitation_path(organisation), 'invitations'],
        'Rollen und Rechte' => [organisation_roles_path(organisation), 'roles'],
        'KI' => [organisation_ai_overview_path(organisation), 'ai_overviews']
      }.each do |name, (path, controller)|
        visit path
        expect(page).to have_current_path(path)

        title = mobile_title
        expect(title).not_to eq(fallback), "#{name}: the mobile header falls back to #{fallback.inspect}"
        expect(title).to eq(I18n.t(MobileNavigationHelper::PAGE_TITLE_KEYS.fetch(controller))), "#{name}: #{title.inspect}"
      end
    end
  end
end
