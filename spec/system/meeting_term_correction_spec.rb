# frozen_string_literal: true

require 'rails_helper'

# Correcting a misheard word in a meeting, clicked for real (K4b): only a browser shows
# that a mark in the transcript brings up "Korrigieren", that the server finds that mark in
# the stored transcript from what the page shows, that "replace everywhere" redraws the
# transcript and names the number, and that the glossary then holds the term with its heard
# form. In German and in English. The panel beside a ticket offers no correction.
# Invented words and names only.
RSpec.describe 'Correcting a term in a meeting', type: :system do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation, name: 'Projekt Ahorn') }
  let(:tc) { 'views.organisations.meetings.term_correction' }
  let(:transcript) { "Anna: Wir testen Lalabeis heute.\nBen: Lalabeis kann viel, sagt Anna.\nUnd Lalabeis-Konten auch." }

  before do
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
  end

  after do
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  def admin(locale)
    create(:user, first_name: 'Ada', last_name: 'Beispiel', language_preference: locale.to_s).tap do |user|
      create(:membership, user: user, organisation: organisation,
                          role: create(:role, organisation: organisation, title: Role::ACCOUNT_ADMIN_TITLE), active: true)
    end
  end

  def meeting_for(user)
    create(:meeting, organisation: organisation, project: project, creator: user, title: 'Abstimmung Ahorn',
                     transcript: transcript).tap do |meeting|
      create(:meeting_participant, meeting: meeting, display_name: 'Anna Ananas')
      create(:meeting_participant, meeting: meeting, display_name: 'Ben Birne')
    end
  end

  # Marks the nth place of `word` in the transcript the page shows, as a double click would.
  def mark_in_transcript(meeting, word, nth: 0)
    page.execute_script(<<~JS, "##{ActionView::RecordIdentifier.dom_id(meeting, :transcript)}", word, nth)
      const [selector, word, nth] = arguments
      const root = document.querySelector(selector).querySelector(".md-preview")
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT)
      let seen = 0
      let node
      while ((node = walker.nextNode())) {
        let index = node.data.indexOf(word)
        while (index !== -1) {
          if (seen === nth) {
            const range = document.createRange()
            range.setStart(node, index)
            range.setEnd(node, index + word.length)
            const selection = window.getSelection()
            selection.removeAllRanges()
            selection.addRange(range)
            return
          }
          seen += 1
          index = node.data.indexOf(word, index + 1)
        }
      }
      throw new Error(`no ${word} in the transcript`)
    JS
  end

  %i[de en].each do |locale|
    it "marks a word, replaces it everywhere and learns it for the glossary (#{locale})" do
      I18n.with_locale(locale) do
        user = admin(locale)
        meeting = meeting_for(user)
        sign_in user
        visit organisation_project_meetings_path(organisation, project, meeting_id: meeting.id)
        expect(page).to have_text('Ben: Lalabeis kann viel')

        mark_in_transcript(meeting, 'Lalabeis', nth: 1)
        trigger = find("#meeting-term-correction-trigger-#{meeting.id}", text: I18n.t("#{tc}.trigger"))
        trigger.click

        within('[role="dialog"]') do
          expect(page).to have_field(I18n.t("#{tc}.heard_label"), with: 'Lalabeis')
          expect(page).to have_select(I18n.t("#{tc}.speaker_label"), selected: 'Ben Birne')
          expect(page).to have_field(I18n.t("#{tc}.to_glossary_confirm"), checked: true)
          fill_in I18n.t("#{tc}.correct_label"), with: 'Lalabase'
          click_button I18n.t("#{tc}.everywhere", count: 3)
        end

        expect(page).to have_no_css('[role="dialog"]')
        expect(page).to have_text(I18n.t("#{tc}.flash.replaced", count: 3))
        expect(page).to have_text(I18n.t("#{tc}.flash.confirmed"))
        within("##{ActionView::RecordIdentifier.dom_id(meeting, :transcript)}") do
          expect(page).to have_text('Wir testen Lalabase heute.')
          expect(page).to have_text('Ben: Lalabase kann viel, sagt Anna.')
          expect(page).to have_text('Und Lalabase-Konten auch.')
          expect(page).to have_no_text('Lalabeis')
        end
        expect(meeting.reload.transcript).to include('Ben: Lalabase kann viel')

        visit organisation_glossary_terms_path(organisation)
        row = find('[data-glossary-row]', text: 'Lalabase')
        expect(row).to have_text(I18n.t('views.organisations.glossary.index.heard_as',
                                        forms: I18n.t('views.organisations.glossary.quoted', text: 'Lalabeis')))
      end
    end
  end

  it 'counts a changed heard form again, and replaces it only at the mark' do
    user = admin(:de)
    meeting = meeting_for(user)
    sign_in user
    visit organisation_project_meetings_path(organisation, project, meeting_id: meeting.id)
    expect(page).to have_text('Ben: Lalabeis kann viel')

    mark_in_transcript(meeting, 'Lalabeis', nth: 2)
    find("#meeting-term-correction-trigger-#{meeting.id}").click

    within('[role="dialog"]') do
      fill_in I18n.t("#{tc}.heard_label", locale: :de), with: 'Lalabeis-Konten'
      expect(page).to have_button(I18n.t("#{tc}.everywhere", count: 1, locale: :de))
      fill_in I18n.t("#{tc}.correct_label", locale: :de), with: 'Lalabase-Konten'
      click_button I18n.t("#{tc}.here", locale: :de)
    end

    expect(page).to have_text(I18n.t("#{tc}.flash.replaced", count: 1, locale: :de))
    expect(meeting.reload.transcript).to eq(
      "Anna: Wir testen Lalabeis heute.\nBen: Lalabeis kann viel, sagt Anna.\nUnd Lalabase-Konten auch."
    )
  end

  it 'offers no correction in the panel beside a ticket' do
    user = admin(:de)
    meeting = meeting_for(user)
    ticket = create(:ticket, project: project, title: 'Ticket neben dem Meeting', creator: user)
    meeting.outgoing_references.create!(organisation: organisation, target: ticket, target_title_snapshot: ticket.display_title)
    sign_in user
    page.driver.browser.manage.window.resize_to(1200, 900)
    visit organisation_project_tickets_path(organisation, project, ticket_id: ticket.id)

    within("#meeting-references-#{ticket.id}") { click_link 'Abstimmung Ahorn' }
    expect(page).to have_css('aside.column.panel', text: 'Lalabeis kann viel')

    within('aside.column.panel') do
      expect(page).to have_no_css('[data-controller~="transcript-selection"]')
      expect(page).to have_no_css("#meeting-term-correction-trigger-#{meeting.id}", visible: :all)
    end
  ensure
    page.driver.browser.manage.window.resize_to(1440, 900)
  end
end
