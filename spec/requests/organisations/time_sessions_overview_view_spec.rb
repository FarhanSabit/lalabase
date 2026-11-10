# frozen_string_literal: true

require 'rails_helper'

# What: The time list has two views, switched top right: the LIST (default)
#       and the OVERVIEW, the status table of all time per project (billed,
#       in billing, without billing, total). The overview replaces the list
#       instead of floating above it; a number in it opens the list with that
#       project and status set and a trail back to the overview.
# Type: Request spec over the rendered index.
# Why:  The status table used to be a tab inside the filter header, above the
#       list; with thirty projects that is a screen, not a header. The switch
#       and the overview are gated like the table was (TimeSessionStatisticsPolicy).
RSpec.describe 'Time list: overview view', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role)   { create(:admin_role, organisation: organisation) }
  let(:member_role)  { create(:role, organisation: organisation) }
  let(:admin)        { create(:user) }
  let(:project)      { with_tenant { create(:project, organisation: organisation, name: 'WebApp2') } }

  let(:times_path)    { organisation_time_sessions_path(organisation) }
  let(:overview_path) { organisation_time_sessions_path(organisation, view: 'overview') }
  # The footnote names the period the table is showing (S5): without a
  # date_range in the address that is the table's own default, "alles".
  let(:footnote) do
    ERB::Util.html_escape(
      I18n.t('views.organisations.time_sessions.billing_overview_panel.footnote',
             period: TimeSessions::ListPeriod.label(TimeSessions::ListPeriod::TABLE_DEFAULT))
    )
  end
  let(:switch_label) { I18n.t('views.organisations.time_sessions.index.view_switch_label') }

  before do
    ActsAsTenant.current_tenant = organisation
    with_tenant { create(:membership, user: admin, organisation: organisation, role: admin_role, active: true) }
    Prosopite.pause
  end

  after do
    Prosopite.resume
    ActsAsTenant.current_tenant = nil
  end

  def with_tenant(&block)
    ActsAsTenant.with_tenant(organisation, &block)
  end

  # One booking in each billing state, so every column of the table has a number.
  #
  # The date is PINNED, and pinned in the past. The factory's own
  # `sequence(:occurred_on) { |n| Time.current + n.hours }` dates a session in
  # the FUTURE, at a distance that depends on the GLOBAL FactoryBot counter. A
  # bounded period then excludes these rows by accident rather than by age, and
  # which way it falls depends on the run order and on the time of day: the
  # "letzte 30 Tage" example below passed in a full-file run (counter high
  # enough to push the sessions past midnight) and failed on its own (counter
  # at 1, sessions still today). A caller that needs a specific distance from
  # today says so itself; the default only has to be in the past.
  def book_all_states(occurred_on: 2.days.ago)
    with_tenant do
      billed_group = create(:time_session_group, :billed, organisation: organisation)
      open_group   = create(:time_session_group, organisation: organisation)
      create(:time_session, organisation: organisation, project: project, creator: admin, duration: 10,
                            billed: true, time_session_group: billed_group, occurred_on: occurred_on)
      create(:time_session, organisation: organisation, project: project, creator: admin, duration: 20,
                            time_session_group: open_group, occurred_on: occurred_on)
      create(:time_session, organisation: organisation, project: project, creator: admin, duration: 30,
                            occurred_on: occurred_on)
    end
  end

  def doc
    Nokogiri::HTML(response.body)
  end

  def switch_links
    doc.css("nav[aria-label='#{switch_label}'] a").map { |a| [CGI.unescapeHTML(a['href']), a['aria-current']] }
  end

  def hrefs
    response.body.scan(/href="([^"]+)"/).flatten.map { |h| CGI.unescapeHTML(h) }
  end

  def trail
    doc.css('[data-overview-trail]').first
  end

  context 'as account admin' do
    before do
      book_all_states
      sign_in admin
    end

    it 'defaults to the list: filter box, no status table, no in-page tabs, switch marks "Liste"' do
      get times_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-controller="query-toggle"')
      expect(response.body).not_to include(footnote)
      expect(response.body).not_to include('data-tab-id=')
      expect(switch_links).to contain_exactly([times_path, 'page'], [overview_path, nil])
      # The statistics are the overview's; the list does not compute them.
      expect(assigns(:project_statistics)).to be_nil
    end

    # One view switch on every page (user, 2026-11-11): the tickets' icon pair,
    # the list first; in the head the switch, then help, the main action
    # outermost. Until then the time list wore a groove between "+" and "?",
    # and a 40 px "?" to match it.
    it 'heads the page like the tickets: the switch (list first), help, the main action outermost' do
      get times_path

      switch = doc.at_css("nav[aria-label='#{switch_label}']")
      expect(switch.css('a').map { |a| a['title'] })
        .to eq(%w[view_list view_overview].map { |key| I18n.t("views.organisations.time_sessions.index.#{key}") })
      expect(switch.css('a svg').size).to eq(2)
      expect(switch['class']).not_to include('bg-selected')

      row = switch.parent.element_children
      expect(row.first).to eq(switch)
      expect(row[1].at_css("[title='#{I18n.t('components.contextual_help.label')}']")['class']).to include('h-8')
      expect(row.last['title']).to eq(I18n.t('views.organisations.time_sessions.index.record_button'))
      expect(row.last['class']).to include('bg-btn-primary')
    end

    it 'shows the status table INSTEAD of the list in the overview view' do
      get overview_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(footnote)
      expect(response.body).to include('WebApp2')
      expect(response.body).not_to include('time_sessions_list_frame')
      expect(response.body).not_to include('data-controller="query-toggle"')
      expect(switch_links).to contain_exactly([times_path, nil], [overview_path, 'page'])
      expect(assigns(:project_statistics).map { |s| s[:project] }).to eq([project])
    end

    it 'links every number to the list with project, status, the neutral params and the overview as origin' do
      get overview_path

      open_link = hrefs.find { |h| h.include?('status_filters%5B%5D=without_billing') && !h.include?('billed&') && !h.include?('in_billing') }
      expect(open_link).to be_present, 'no link for the "without billing" number'
      expect(open_link).to include("project_id_filter=#{project.id}")
      expect(open_link).to include('date_range=all')
      expect(open_link).to include('from=overview')

      total_link = hrefs.find do |h|
        h.include?("project_id_filter=#{project.id}") &&
          TimeSession::BILLING_STATUS_FILTERS.all? { |b| h.include?("status_filters%5B%5D=#{b}") }
      end
      expect(total_link).to be_present, 'no total link with all three buckets'
      expect(total_link).to include('date_range=all')
      expect(total_link).to include('from=overview')
    end

    it 'shows the trail on the list after a click: a way back and the filters as chips' do
      get overview_path
      open_link = hrefs.find { |h| h.include?('status_filters%5B%5D=without_billing') && !h.include?('in_billing') }

      get open_link
      expect(response).to have_http_status(:ok)
      expect(trail).to be_present, 'no trail above the list'
      # The way back carries the period the table was showing (S5). A cell of a
      # table on its default sends "alles" out, so "alles" is what comes home;
      # that the period travels AT ALL is pinned in the drill-down spec.
      back_path = organisation_time_sessions_path(
        organisation, view: 'overview', date_range: TimeSessions::ListPeriod::TABLE_DEFAULT
      )
      expect(trail.css('a').map { |a| CGI.unescapeHTML(a['href']) }).to include(back_path)
      expect(trail.text).to include('WebApp2')
      expect(trail.text).to include(I18n.t('views.time_sessions.billing_status.without_billing'))
      # The list itself is filtered the same way: 30 minutes, not 60.
      expect(assigns(:total_filtered_duration)).to eq(30)
    end

    it 'names all statuses with one chip when the total column was clicked' do
      get overview_path
      total_link = hrefs.find do |h|
        h.include?("project_id_filter=#{project.id}") &&
          TimeSession::BILLING_STATUS_FILTERS.all? { |b| h.include?("status_filters%5B%5D=#{b}") }
      end

      get total_link
      expect(trail.text).to include(I18n.t('views.organisations.time_sessions.index.overview_trail_all'))
      expect(assigns(:total_filtered_duration)).to eq(60)
    end

    it 'shows no trail on a plain list' do
      get times_path

      expect(trail).to be_nil
    end
  end

  # S5b: the table's craft (F8). The oracle is not "looks nice" but the four
  # things the design review named as costing trust: magnitudes that cannot be
  # compared, a colour on every number that therefore says nothing, the action
  # colour on a row nobody can act on, and rows of "--:--" between the rows that
  # matter.
  context 'the table itself' do
    let(:quiet_project) { with_tenant { create(:project, organisation: organisation, name: 'Ruhiges Projekt') } }

    before do
      book_all_states
      quiet_project
      sign_in admin
    end

    def cells
      doc.css('td[data-overview-cell]')
    end

    it 'right-aligns every number and sets it tabular, so magnitudes line up' do
      get overview_path

      expect(cells).not_to be_empty
      cells.each do |cell|
        expect(cell['class']).to include('text-right'), "#{cell['data-overview-cell']} is not right-aligned"
        expect(cell['class']).to include('tabular-nums'), "#{cell['data-overview-cell']} is not tabular"
      end
    end

    # The header has to follow the body, or the column label sits over the wrong
    # edge of its own numbers.
    it 'right-aligns the number column headers with them' do
      get overview_path

      headers = doc.css('table thead th')
      expect(headers.first['class']).to include('text-left')
      headers.drop(1).each { |th| expect(th['class']).to include('text-right') }
    end

    it 'gives the numbers no link colour of their own' do
      get overview_path

      links = cells.css('a')
      expect(links).not_to be_empty
      links.each do |link|
        # Any colour utility, not the two the old markup happened to use: the
        # intent is "no colour of its own", and text-indigo-600 would pass a
        # deny-list of cobalt and blue just as quietly.
        expect(link['class'].to_s)
          .not_to match(/(^|\s)(hover:|focus:|focus-visible:)?text-(?!(xs|sm|base|lg|xl|left|right|center)\b)/),
                  'a number still carries a link colour'
      end
    end

    it 'paints neither the totals row nor a row hover in the action colour' do
      get overview_path

      table = doc.at_css('table').to_html
      expect(table).not_to include('lime'), 'lime is the action colour and belongs to buttons'
      expect(doc.at_css('tfoot tr')['class']).to include('font-bold')
      expect(doc.at_css('tfoot')['class']).to include('border-t-2')
    end

    it 'tints the cell under the pointer, not the whole row' do
      get overview_path

      filled = cells.find { |cell| cell.at_css('a') }
      expect(filled['class']).to include('hover:bg-cream-100')
      expect(filled['class']).to include('focus-within:bg-cream-100')
      expect(doc.at_css('tbody tr')['class'].to_s).not_to include('hover:')

      # And NOT on an empty cell: "--:--" is nothing to open, so nothing lights
      # up. Without this, a tint on every cell survives.
      empty = cells.find { |cell| cell.at_css('a').nil? }
      expect(empty).to be_present
      expect(empty['class']).not_to include('hover:')
      expect(empty['class']).not_to include('focus-within:')
    end

    it 'uses the page palette, not the cold slate one' do
      get overview_path

      expect(doc.at_css('table').to_html).not_to include('slate-')
    end

    # Folding, and the reason it is safe: a folded row is all zeros, so the foot
    # is the same number whether it is shown or not.
    it 'folds the projects without hours away and says how many there are' do
      get overview_path

      folded = doc.css('tr[data-more-item]')
      expect(folded.size).to eq(1)
      expect(folded.first['class']).to include('hidden')
      expect(folded.first.text).to include('Ruhiges Projekt')

      # The other half, and the one the fold exists FOR. Nothing else in this
      # file looks at a row that is MEANT to be visible, so without this the
      # partial could render EVERY row hidden, the whole table gone, and every
      # example here would stay green.
      visible = doc.css('tbody tr:not([data-more-item])')
      expect(visible.size).to eq(1)
      expect(visible.first['class'].to_s).not_to include('hidden')
      # And in this order: the projects with hours first, the folded ones behind.
      expect(doc.css('tr[data-overview-row]').first.text).to include('WebApp2')

      # Scoped: the sidebar's project list carries its own reveal-more trigger
      # ("mehr …"), which is the same controller on a different surface.
      trigger = doc.at_css('button[data-overview-reveal]')
      expect(trigger).to be_present, 'no way to unfold the empty projects'
      expect(trigger.text.strip).to eq(
        I18n.t('views.organisations.time_sessions.billing_overview_panel.reveal_empty_projects', count: 1)
      )

      # A trigger is worth exactly its wiring. Asserting only that the button
      # EXISTS leaves the dead-button case green, and that case is silent:
      # without JavaScript the rows stay folded BY DESIGN, so nothing else on
      # the page complains and the folded projects are unreachable for good.
      #
      # Walked UPWARD from the trigger rather than looked up over the document:
      # the sidebar carries its own reveal-more and comes first, so at_css
      # finds the navigation and says nothing about this table. The folded rows
      # have to hang under the SAME element as the trigger, because that
      # element is the one reveal_more_controller queries.
      panel = trigger.ancestors('[data-controller~="reveal-more"]').first
      expect(panel).to be_present, 'the trigger sits under no reveal-more controller'
      expect(trigger['data-action']).to eq('click->reveal-more#reveal')
      expect(panel.css('tr[data-more-item]').size).to eq(folded.size)
    end

    it 'renders a folded row as four "--:--" cells without links, under the same handles' do
      get overview_path

      folded_cells = doc.at_css('tr[data-more-item]').css('td[data-overview-cell]')
      expect(folded_cells.map { |cell| cell['data-overview-cell'] }).to eq(TimeSession::BILLING_OVERVIEW_COLUMNS)
      folded_cells.each do |cell|
        expect(cell.at_css('a')).to be_nil, "#{cell['data-overview-cell']} of an empty project is a link"
        expect(cell.text.strip).to eq('--:--')
      end
    end

    it 'says how many projects are folded when there is more than one' do
      with_tenant { create(:project, organisation: organisation, name: 'Zweites ruhiges Projekt') }

      get overview_path

      expect(doc.css('tr[data-more-item]').size).to eq(2)
      trigger = doc.at_css('button[data-overview-reveal]')
      expect(trigger.text.strip).to eq(
        I18n.t('views.organisations.time_sessions.billing_overview_panel.reveal_empty_projects', count: 2)
      )
      expect(trigger.text).to include('2')
    end

    # The foot counts the folded rows into nothing (they are all zeros), so it
    # is the sum either way; and it lines up with the body, or the total sits
    # under the wrong edge of the column it sums.
    it 'sums every column in the foot, right-aligned like the body' do
      get overview_path

      foot = doc.css('tfoot td')
      expect(foot.map { |td| td.text.strip }).to eq([30, 20, 10, 60].map { |m| TimeSession.format_duration(m) })
      foot.each do |td|
        expect(td['class']).to include('text-right')
        expect(td['class']).to include('tabular-nums')
      end
    end

    it 'offers no unfold trigger when every project has hours' do
      quiet_project.destroy!

      get overview_path

      expect(doc.css('tr[data-more-item]')).to be_empty
      expect(doc.at_css('button[data-overview-reveal]')).to be_nil
    end
  end

  # Two different emptinesses. Before S5b both said "Keine Statistik-Daten
  # verfügbar", which is not what a reader who just picked "diese Woche" needs
  # to hear.
  context 'when the table is empty' do
    let(:scope) { 'views.organisations.time_sessions.billing_overview_panel' }
    let(:nothing_booked) { ERB::Util.html_escape(I18n.t("#{scope}.no_data")) }
    let(:reset) { organisation_time_sessions_path(organisation, view: 'overview', date_range: 'all') }

    before { sign_in admin }

    def period_emptied(period)
      ERB::Util.html_escape(I18n.t("#{scope}.empty_period", period: TimeSessions::ListPeriod.label(period)))
    end

    # The period control, or nil while its wrapper is hidden. The wrapper is
    # what carries `hidden`, so the select is asked through it.
    def period_select
      doc.at_css('div:not([hidden]) > form select[name="date_range"]')
    end

    it 'says nothing is booked yet when the period is "alles"' do
      project

      get overview_path

      expect(response.body).to include(nothing_booked)
      # And not the other sentence: two `if`s instead of an `elsif` would say both.
      expect(response.body).not_to include(period_emptied('all'))
      expect(hrefs).not_to include(reset)
      # No period to pick over nothing: the list hides its filters on first use too.
      expect(period_select).to be_nil
    end

    # The second sentence promises a way back. On an organisation without a
    # single booking there is nothing to come back to, so the period is not the
    # reason and must not be blamed: the reader would follow the link and find
    # the same empty page under "alles".
    it 'says nothing is booked yet under a bounded period too, when there is nothing to come back to' do
      project

      get organisation_time_sessions_path(organisation, view: 'overview', date_range: '30_days')

      expect(assigns(:table_period)).to eq('30_days')
      expect(response.body).to include(nothing_booked)
      expect(response.body).not_to include(period_emptied('30_days'))
      expect(hrefs).not_to include(reset)
      expect(period_select).to be_nil
    end

    it 'names the period that emptied it, and offers the way back to "alles"' do
      # Booked well outside the 30 days the request below picks, so the period is
      # what empties the table. See book_all_states for why the date must not be
      # left to the factory.
      book_all_states(occurred_on: 200.days.ago)

      get organisation_time_sessions_path(organisation, view: 'overview', date_range: '30_days')

      expect(assigns(:table_period)).to eq('30_days')
      expect(response.body).to include(period_emptied('30_days'))
      expect(response.body).not_to include(nothing_booked)
      expect(hrefs).to include(reset)
      # There IS something to pick a period over, so the control stays.
      expect(period_select).to be_present

      # The oracle of a reset link is what it leads to, not its address: the
      # sentence promises rows under "alles", so the example goes and looks.
      get reset

      expect(assigns(:table_period)).to eq('all')
      expect(doc.css('tbody tr[data-overview-row]:not([data-more-item])').size).to eq(1)
      expect(response.body).not_to include(period_emptied('all'))
    end
  end

  context 'as a member who sees time but has no statistics right' do
    let(:viewer) { create(:user) }

    before do
      book_all_states
      with_tenant do
        create(:membership, user: viewer, organisation: organisation, role: member_role, active: true)
        create(:time_session_permission, user: viewer, project: project, can_view_own: true)
        # One own booking, so the list is past first use and renders its filter box.
        create(:time_session, organisation: organisation, project: project, creator: viewer, duration: 5)
      end
      sign_in viewer
    end

    it 'gets no switch, and view=overview falls back to the list' do
      get overview_path

      expect(response).to have_http_status(:ok)
      expect(doc.css("nav[aria-label='#{switch_label}']")).to be_empty
      expect(response.body).not_to include(footnote)
      expect(response.body).to include('data-controller="query-toggle"')
    end
  end
end
