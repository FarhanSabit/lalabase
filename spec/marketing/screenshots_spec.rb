# frozen_string_literal: true

require 'rails_helper'

# The product screenshots for the project website.
#
# Not a test. Excluded from every normal run and from the CI; run it on purpose:
#
#   MARKETING_SCREENSHOTS=1 bundle exec rspec spec/marketing/screenshots_spec.rb
#
# It builds the Nordlicht fiction (Lalabase::Demo::World, the same world as the
# public demo) in the test database, freezes the clock and saves
# one picture per motif and language to tmp/screenshots/marketing/<locale>/. The
# website imports them from there; what its rows show also comes as <motif>_phone, a
# detail taken in the app's phone layout. The README shows four English ones, copied by hand
# to .github/readme/ (ticket_assistant, meeting_assistant, board, time, with dashes for
# underscores); copy them again after a new run, then redraw the framed tiles of the
# README's gallery with `bundle exec ruby script/readme_gallery`.
#
# It fails loudly when a screen changes shape (a selector it waits for is gone), which
# is the point: a stale picture on the website is worse than a red run.
module MarketingScreenshots
  # A Wednesday morning: the week columns of the time list show Monday to today.
  NOW = Time.zone.local(2026, 10, 14, 10, 30)
  # The assistant shows without a real model behind it: the answer in the pictures
  # is stored, and a key that is never called only switches the panel on.
  ORGANISATION = { ai_enabled: true, assistant_enabled: true, ai_provider: 'openai',
                   ai_access_token: 'sk-fiction-0000000000000000' }.freeze
  OUTPUT = Rails.root.join('tmp/screenshots/marketing')
  # Wide enough that the ticket list shows names and dates in full.
  WIDTH = 1600
  HEIGHT = 1000
  # The window for pictures that end up in a tile: the list fills less width.
  TILE_WIDTH = 1100
  # The window for the README pictures with the assistant open. GitHub shows a picture
  # about 840 px wide; from a 1600 px window its text came out too small to read.
  README_WIDTH = 1280
  # The screen for the pictures the website shows on a phone, where a desktop picture
  # shrinks to a fraction of its width and its text can no longer be read. A large
  # phone, emulated: Chrome keeps a window at least 500 px wide.
  PHONE_WIDTH = 430
  PHONE_HEIGHT = 932
  # A phone picture stands in a row of a long page and may not stretch it: at most
  # about four thirds of its width.
  PHONE_MAX_HEIGHT = 580
  CLIP_MARGIN = 16
  # The assistant's collapsed state hovers over the bottom of every page. A picture
  # ends above it.
  CAPSULE = '#assistant_panel input[placeholder]'
  # The visible column of the open assistant. #assistant_panel itself spans the page.
  PANEL = '#assistant_panel [data-assistant-panel-target="panel"]'

  def self.chrome_options
    options = Selenium::WebDriver::Chrome::Options.new
    options.add_argument('--headless=new')
    options.add_argument('--no-sandbox')
    options.add_argument('--disable-dev-shm-usage')
    options.add_argument('--disable-gpu')
    options.add_argument('--hide-scrollbars')
    options.add_argument("--window-size=#{WIDTH},#{HEIGHT}")
    # Twice the pixels, so the pictures stay sharp on a high-density screen.
    options.add_argument('--force-device-scale-factor=2')
    LocalChrome.apply_binary(options)
  end
end

Capybara.register_driver :marketing_chrome do |app|
  Capybara::Selenium::Driver.new(app, browser: :chrome, options: MarketingScreenshots.chrome_options)
end

# The phone pictures get a browser of their own that is a phone from the start. Chrome
# keeps a window at least 500 px wide, and a phone emulated in the browser of the other
# pictures would have to be taken down again after every one of them.
Capybara.register_driver :marketing_phone_chrome do |app|
  options = MarketingScreenshots.chrome_options
  options.add_emulation(device_metrics: { width: MarketingScreenshots::PHONE_WIDTH,
                                          height: MarketingScreenshots::PHONE_HEIGHT, pixelRatio: 2 })
  Capybara::Selenium::Driver.new(app, browser: :chrome, options:)
end

RSpec.describe 'Marketing screenshots', :marketing_screenshots, type: :system do
  include ActiveSupport::Testing::TimeHelpers

  before do
    driven_by :marketing_chrome
    # The browser outlives the example: without this, the narrower window of the
    # assistant picture stays for every picture after it.
    page.driver.browser.manage.window.resize_to(MarketingScreenshots::WIDTH, MarketingScreenshots::HEIGHT)
    Prosopite.pause
    travel_to MarketingScreenshots::NOW
    set_browser_clock
  end

  after { Prosopite.resume }

  # The server lives at NOW (travel_to), the browser would live today: the session
  # check compares the two and calls the session expired, and every "2 days ago"
  # rendered in the browser would be off. This sets the browser's clock to NOW on
  # every page before any script of the page runs.
  def set_browser_clock
    real_ms = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
    offset = (MarketingScreenshots::NOW.to_f * 1000).to_i - real_ms
    page.driver.browser.execute_cdp('Page.addScriptToEvaluateOnNewDocument', source: <<~JS)
      (() => {
        const RealDate = Date
        const offset = #{offset}
        class ShiftedDate extends RealDate {
          constructor(...args) { args.length ? super(...args) : super(RealDate.now() + offset) }
          static now() { return RealDate.now() + offset }
        }
        globalThis.Date = ShiftedDate
      })()
    JS
  end

  # Saves the window from the top down to `until_bottom_of` (plus a margin), or down
  # to the assistant capsule when no element is named. `clip_to` narrows the picture to
  # the left, right and top edge of one element, or of several taken together: a tile on the website is a third of the
  # page wide, and the whole window shrunk to that is unreadable. `from_left_of` cuts
  # away everything left of one element (the sidebar beside the assistant).
  def capture(locale, motif, until_bottom_of: nil, clip_to: nil, from_left_of: nil,
              margin: MarketingScreenshots::CLIP_MARGIN)
    save_picture(locale, motif) do |window_width, window_height|
      left, top, right = picture_columns(window_width, clip_to:, from_left_of:, margin:)
      [left, top, right, [picture_bottom(until_bottom_of), window_height].min]
    end
  end

  # A picture for a phone: the whole width of the window, from the top of `from` to the
  # bottom of `to`, so it begins and ends at a seam of the layout and never inside a
  # line of text. `above` and `below` are the room left around the two; a bar that
  # spans the window gets none above, or the edge of the bar over it shows as a stripe.
  # Fails when the picture would come out taller than PHONE_MAX_HEIGHT.
  def capture_phone(locale, motif, from:, to:, above: 0, below: 8)
    save_picture(locale, motif) do |window_width, window_height|
      top = box(from)['top'] - above
      bottom = box(to)['bottom'] + below
      expect(bottom - top).to be <= MarketingScreenshots::PHONE_MAX_HEIGHT
      expect(bottom).to be <= window_height
      [0, top, window_width, bottom]
    end
  end

  # Takes the window and keeps the area the block names as [left, top, right, bottom], in
  # CSS pixels; the block gets the window's width and height in the same unit. The
  # window is taken whole and cut with libvips, which the core already carries for
  # Active Storage.
  def save_picture(locale, motif)
    dir = MarketingScreenshots::OUTPUT.join(locale.to_s)
    FileUtils.mkdir_p(dir)
    window = dir.join("#{motif}.window.png")
    settle
    page.driver.browser.save_screenshot(window.to_s)

    image = Vips::Image.new_from_file(window.to_s)
    scale = image.width.to_f / page.evaluate_script('window.innerWidth')
    left, top, right, bottom = yield(image.width / scale, image.height / scale)
    area = [left, top, right - left, bottom - top].map { |value| (value * scale).round }
    image.crop(*area).write_to_file(dir.join("#{motif}.png").to_s)
  ensure
    FileUtils.rm_f(window) if window
  end

  def picture_columns(window_width, clip_to:, from_left_of:, margin:)
    return clip_area(clip_to, window_width, margin) if clip_to
    return [box(from_left_of)['left'], 0, window_width] if from_left_of

    [0, 0, window_width]
  end

  # The edges of the elements plus a margin, so text does not end flush at the cut.
  def clip_area(selectors, window_width, margin)
    boxes = Array(selectors).map { box(_1) }
    left = boxes.map { _1['left'] }.min
    top = boxes.map { _1['top'] }.min
    right = boxes.map { _1['right'] }.max
    [[left - margin, 0].max, [top - margin, 0].max, [right + margin, window_width].min]
  end

  def box(selector) = page.evaluate_script("document.querySelector(#{selector.to_json}).getBoundingClientRect().toJSON()")

  # Waits until no transition or animation runs (the assistant expands with one), so a
  # second run takes the same picture.
  def settle
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script('document.getAnimations().every((a) => a.playState !== "running")')
    end
    sleep 0.2
  end

  # The sources of the answer in the open panel, unfolded.
  def open_citations(count)
    find('#assistant_panel [data-testid="citation-list"] summary').click
    expect(page).to have_css('#assistant_panel [data-testid="citation-row"]', count: count)
  end

  def picture_bottom(selector)
    if selector
      box(selector)['bottom'] + 32
    else
      capsule = page.evaluate_script(<<~JS)
        (() => { const el = document.querySelector(#{MarketingScreenshots::CAPSULE.to_json}); return el && el.closest('form, div').getBoundingClientRect().top })()
      JS
      (capsule || page.evaluate_script('window.innerHeight')) - 16
    end
  end

  %i[de en].each do |locale|
    context "in #{locale}" do
      let(:world) do
        Lalabase::Demo::World.new(locale:, now: MarketingScreenshots::NOW,
                                  organisation: MarketingScreenshots::ORGANISATION).build
      end

      before do
        ActsAsTenant.current_tenant = world.organisation
        sign_in world.signed_in
      end

      it 'takes the ticket list' do
        visit organisation_project_tickets_path(world.organisation, world.project(:deichblick))
        expect(page).to have_text(Lalabase::Demo::Fiction::TICKETS.last.fetch(locale))
        capture(locale, :tickets)
      end

      # A narrower window and only the list, without the sidebar: the picture sits in
      # a tile on the website.
      it 'takes the time list' do
        page.driver.browser.manage.window.resize_to(MarketingScreenshots::TILE_WIDTH, MarketingScreenshots::HEIGHT)
        visit organisation_time_sessions_path(world.organisation, date_range: 'this_week')
        expect(page).to have_text(Lalabase::Demo::Fiction::TICKETS[3].fetch(locale))
        capture(locale, :time, clip_to: '#timeSessions')
      end

      # The note the assistant cites, open next to the list.
      it 'takes the knowledge list with an open note' do
        visit organisation_project_knowledge_index_path(world.organisation, world.project(:deichblick),
                                                        note_id: world.notes.first.id)
        content = Lalabase::Demo::Fiction::NOTES.first[:content].fetch(locale)
        last_line = Nokogiri::HTML.fragment(Lalabase::Demo::Fiction.dated(content, locale, MarketingScreenshots::NOW))
                                  .css('p').last.text
        expect(page).to have_text(last_line)
        expect(page).to have_no_css('.layout.hide-content')
        capture(locale, :knowledge, clip_to: 'main.column.content', until_bottom_of: '#note-header')
      end

      # The weekly call with Deichblick, open next to the list: who took part, the AI
      # summary with the tasks it found, the transcript under it. The detail column
      # only, down to the assistant capsule: on the website the picture stands in a row
      # beside its text, like the note above.
      it 'takes a meeting with its summary' do
        meeting = world.meetings.fetch(Lalabase::Demo::Fiction::MEETING_QUESTION[:meeting])
        visit organisation_project_meeting_path(world.organisation, meeting.project, meeting)
        expect(page).to have_css("##{ActionView::RecordIdentifier.dom_id(meeting)}_summary_section")
        expect(page).to have_text(meeting.title)
        expect(page).to have_no_css('.layout.hide-content')
        capture(locale, :meeting, clip_to: 'main.column.content')
      end

      # One ticket with its comments and the hours booked on it.
      it 'takes a ticket with its context' do
        ticket = world.ticket(Lalabase::Demo::Fiction::CHAT[:ticket])
        visit organisation_project_ticket_path(world.organisation, world.project(:deichblick), ticket)
        expect(page).to have_text(Lalabase::Demo::Fiction::COMMENTS.last.fetch(locale))
        capture(locale, :ticket)
      end

      # The tickets as a board: a setting per person and project, stored the way the
      # view switch stores it. The board alone, its first three columns: all four come
      # out too small to read at the width of the README.
      it 'takes the ticket board' do
        ViewConfiguration.for_user_project(world.signed_in, world.project(:deichblick), 'tickets')
                         .update!(view_mode: 'kanban')
        visit organisation_project_tickets_path(world.organisation, world.project(:deichblick))
        expect(page).to have_css('.kanban-board')
        expect(page).to have_text(Lalabase::Demo::Fiction::TICKETS[3].fetch(locale))
        columns = [1, 3].map { ".kanban-board > :nth-child(#{_1} of .kanban-column)" }
        capture(locale, :board, clip_to: columns, until_bottom_of: '.kanban-board')
      end

      # The assistant beside the object it was asked about, with the object as its
      # reference: the ticket of the detail motif, and the weekly call. In the README
      # window, from the panel to the right edge: the open panel reaches the bottom, and
      # the sidebar says nothing about the answer.
      it 'takes the assistant beside the ticket' do
        page.driver.browser.manage.window.resize_to(MarketingScreenshots::README_WIDTH, MarketingScreenshots::HEIGHT)
        ticket = world.ticket(Lalabase::Demo::Fiction::TICKET_QUESTION[:ticket])
        visit organisation_project_ticket_path(world.organisation, ticket.project, ticket,
                                               assistant_chat_id: world.ticket_question.id)
        # Three citations, two rows: the comment is listed under its ticket.
        open_citations(2)
        capture(locale, :ticket_assistant, until_bottom_of: 'body', from_left_of: MarketingScreenshots::PANEL)
      end

      it 'takes the assistant beside the meeting' do
        page.driver.browser.manage.window.resize_to(MarketingScreenshots::README_WIDTH, MarketingScreenshots::HEIGHT)
        meeting = world.meetings.fetch(Lalabase::Demo::Fiction::MEETING_QUESTION[:meeting])
        visit organisation_project_meeting_path(world.organisation, meeting.project, meeting,
                                                assistant_chat_id: world.meeting_question.id)
        open_citations(2)
        capture(locale, :meeting_assistant, until_bottom_of: 'body', from_left_of: MarketingScreenshots::PANEL)
      end

      it 'takes the assistant answer with its sources' do
        # Narrower than the other pictures: in full mode the answer runs across the
        # whole window, and at 1600 px the picture came out four times as wide as tall.
        page.driver.browser.manage.window.resize_to(1200, MarketingScreenshots::HEIGHT)
        visit organisation_root_path(organisation_id: world.organisation.id,
                                     assistant_chat_id: world.chat.id, assistant: 'full')
        find('#assistant_panel [data-testid="citation-list"] summary').click
        expect(page).to have_css('#assistant_panel [data-testid="citation-row"]', count: 3)
        # The conversation only: the answer is what the row on the website is about.
        # No margin: around it are the borders of the neighbouring columns.
        capture(locale, :assistant, clip_to: '#assistant_panel_body', margin: 0,
                                    until_bottom_of: '#assistant_panel [data-testid="citation-list"]')
      end

      # The motifs of the website's rows once more, for a phone and in the app's phone
      # layout. One detail each, across the whole screen, from one seam of the layout to
      # another.
      context 'on a phone' do
        before do
          driven_by :marketing_phone_chrome
          set_browser_clock
        end

        # The project's tabs, the saved filters and the first four tickets with status.
        it 'takes the ticket list for phones' do
          visit organisation_project_tickets_path(world.organisation, world.project(:deichblick), viewport: 'mobile')
          expect(page).to have_css('.mobile-tickets > .mobile-ticket-row', minimum: 4)
          capture_phone(locale, :tickets_phone, from: '.mobile-project-tabs',
                                                to: '.mobile-tickets > .mobile-ticket-row:nth-child(4)')
        end

        # The week's bookings per ticket with their durations, from the filter down to the
        # last one. The page's own title would repeat the bar above it.
        it 'takes the time list for phones' do
          visit organisation_time_sessions_path(world.organisation, date_range: 'this_week')
          expect(page).to have_text(Lalabase::Demo::Fiction::TICKETS[3].fetch(locale))
          capture_phone(locale, :time_phone, from: '#timeSessions [data-controller~="mobile-filter-drawer"]',
                                             to: '#timeSessions .md\\:hidden .space-y-6', above: 12)
        end

        # The note the assistant cites, whole, under the project's tabs.
        it 'takes the open note for phones' do
          visit organisation_project_knowledge_index_path(world.organisation, world.project(:deichblick),
                                                          note_id: world.notes.first.id, viewport: 'mobile')
          expect(page).to have_css('.note-content')
          capture_phone(locale, :knowledge_phone, from: '.mobile-project-tabs', to: '.note-content')
        end

        # The weekly call from its title down to the end of the AI summary.
        it 'takes the meeting for phones' do
          meeting = world.meetings.fetch(Lalabase::Demo::Fiction::MEETING_QUESTION[:meeting])
          visit organisation_project_meeting_path(world.organisation, meeting.project, meeting, viewport: 'mobile')
          summary = "##{ActionView::RecordIdentifier.dom_id(meeting)}_summary_section"
          expect(page).to have_css(summary)
          capture_phone(locale, :meeting_phone, from: '#meeting-header > h2', to: summary, above: 16)
        end

        # The open assistant: question, answer and its three sources.
        it 'takes the assistant answer for phones' do
          visit organisation_root_path(organisation_id: world.organisation.id,
                                       assistant_chat_id: world.chat.id, assistant: 'full')
          open_citations(3)
          capture_phone(locale, :assistant_phone, from: MarketingScreenshots::PANEL,
                                                  to: '#assistant_panel [data-testid="citation-list"]')
        end

        # The assistant on the ticket it was asked about, as in the README picture. On a
        # phone it covers the ticket.
        it 'takes the assistant on the ticket for phones' do
          ticket = world.ticket(Lalabase::Demo::Fiction::TICKET_QUESTION[:ticket])
          visit organisation_project_ticket_path(world.organisation, ticket.project, ticket,
                                                 assistant_chat_id: world.ticket_question.id, viewport: 'mobile')
          open_citations(2)
          capture_phone(locale, :ticket_assistant_phone, from: MarketingScreenshots::PANEL,
                                                         to: '#assistant_panel [data-testid="citation-list"]')
        end
      end
    end
  end
end
