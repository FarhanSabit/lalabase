# frozen_string_literal: true

require 'rails_helper'

# What the glossary did to a transcript before it arrived (K4d), on the meeting page:
# one line with the sums under the transcript heading, the rows behind it. The term
# leads into the glossary only for a reader of it; the panel beside a ticket shows
# nothing of it; a meeting without the list shows no line. Invented words only.
RSpec.describe 'Organisations::Meetings glossary applied', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:project) { create(:project, organisation: organisation) }
  let(:creator) { reader }
  let(:meeting) do
    create(:meeting, organisation: organisation, project: project, creator: creator, title: 'Abstimmung',
                     transcript: 'Anna: Lalabase kann viel.')
  end
  let(:term) { create(:glossary_term, organisation: organisation, term: 'Lalabase') }
  let(:ga) { 'views.organisations.meetings.glossary_applied' }

  def role_with(*glossary_actions)
    role = create(:role, organisation: organisation)
    glossary_actions.each { |action| create(:permission, role: role, category: 'glossary', action: action, allowed: true) }
    role
  end

  def reader(*glossary_actions)
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: role_with(*glossary_actions), active: true)
    create(:project_permission, user: user, project: project, meetings_access: :read_only)
    user
  end

  def applied(heard, count:, term_record: term)
    create(:term_application, organisation: organisation, meeting: meeting, glossary_term: term_record, heard: heard,
                              replaced_count: count)
  end

  def page_for(user)
    sign_in user
    get organisation_project_meeting_path(organisation, project, meeting)
    response.body
  end

  it 'sums the places and the terms, lists each spelling with its count, and marks a righted spelling' do
    applied('lala bass', count: 3)
    applied('lalabase', count: 2)
    applied('zirbel holz', count: 1, term_record: create(:glossary_term, organisation: organisation, term: 'Zirbelholz'))

    body = page_for(reader)

    expect(body).to include(I18n.t("#{ga}.summary", places: I18n.t("#{ga}.places", count: 6), terms: I18n.t("#{ga}.terms", count: 2)))
    expect(body).to include('lala bass', 'zirbel holz', I18n.t("#{ga}.times", count: 3))
    expect(body.scan(I18n.t("#{ga}.spelling")).size).to eq(1)
  end

  it 'links the term into the glossary only for a reader of the glossary, and only while the term exists' do
    applied('lala bass', count: 1)
    gone = applied('zirbel holz', count: 1, term_record: create(:glossary_term, organisation: organisation, term: 'Zirbelholz'))
    gone.glossary_term.destroy!

    without = page_for(reader)
    expect(without).to include('Lalabase', 'Zirbelholz')
    expect(without).not_to include(organisation_glossary_term_path(organisation, term))

    with = page_for(reader('view_glossary'))
    expect(with).to include(organisation_glossary_term_path(organisation, term))
    expect(with.scan('/glossary/').size).to eq(1), 'the term that is gone is text'
  end

  it 'shows no line for a meeting without the list' do
    expect(page_for(reader)).not_to include('transcript-glossary')
  end

  it 'shows nothing of it in the panel beside a ticket' do
    applied('lala bass', count: 3)
    ticket = create(:ticket, organisation: organisation, project: project)
    user = reader
    sign_in user

    get organisation_project_ticket_meeting_panel_path(organisation, project, ticket, meeting_id: meeting.id),
        headers: { 'Turbo-Frame' => 'ticket-meeting-panel' }

    expect(response.body).to include('Lalabase kann viel')
    expect(response.body).not_to include('transcript-glossary')
  end
end
