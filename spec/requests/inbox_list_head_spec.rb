# frozen_string_literal: true

require 'rails_helper'

# What: the head of the inbox list (user, 2026-11-10).
#       - The inbox opens on "Alle" (unread and read), not on "Ungelesen".
#       - The status views read "Alle, Ungelesen, Gelesen, Archiviert", in that
#         order; "Gelesen" is new.
#       - The search answers while typing: the form debounces (auto-submit) and
#         reloads only the list frame, so the field keeps its focus and every
#         letter typed meanwhile. What depends on the search and stands outside
#         the frame (the status links, the project form, the type chip: they
#         carry the search in their addresses) rides along as a <turbo-stream>
#         INSIDE the frame answer, the time list's FRAME_DEPENDENT_REGIONS idiom.
# Why:  nobody found out that the search wanted Enter; and a status link drawn
#       before the search would drop it on the next click.
RSpec.describe 'Inbox list head', type: :request do
  before { Prosopite.pause } # pre-existing N+1 in the render path
  after  { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:admin_role, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  def notification_for(title, state:)
    ticket = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, title: title) }
    ActsAsTenant.with_tenant(organisation) do
      create(:notification,
             recipient: user, organisation: organisation, project: project, notifiable: ticket,
             event_type: 'ticket_commented', channel: 'in_app', state: state,
             read_at: %i[read archived].include?(state) ? 1.hour.ago : nil,
             archived_at: state == :archived ? 1.hour.ago : nil)
    end
  end

  let!(:unread_one) { notification_for('Rechnungslauf', state: :delivered) }
  let!(:read_one) { notification_for('Exportfehler', state: :read) }
  let!(:archived_one) { notification_for('Startseite', state: :archived) }

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
  end

  after { ActsAsTenant.current_tenant = nil }

  def doc_for(**params)
    get organisation_notifications_path(organisation, **params)
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  def view_word(key)
    I18n.t("views.organisations.notifications.filter.views.#{key}")
  end

  it 'opens on "Alle": unread and read, not archived' do
    get organisation_notifications_path(organisation)

    expect(response).to redirect_to(organisation_notifications_path(organisation, state_filters: %w[read unread]))
    follow_redirect!
    ids = controller.instance_variable_get(:@notifications).map(&:id)
    expect(ids).to contain_exactly(unread_one.id, read_one.id)
  end

  it 'names the status views Alle, Ungelesen, Gelesen, Archiviert, in that order' do
    pills = doc_for(state_filters: %w[read unread]).css('nav.people-filters a.people-pill')

    expect(pills.map { |pill| pill.children.find(&:text?)&.text.to_s.squish })
      .to eq(%w[all unread read archived].map { |key| view_word(key) })
    expect(pills.first['aria-current']).to eq('true')
  end

  it 'shows only the read ones under "Gelesen", and marks it' do
    doc = doc_for(state_filters: %w[read])

    ids = controller.instance_variable_get(:@notifications).map(&:id)
    expect(ids).to eq([read_one.id])
    active = doc.at_css('nav.people-filters a[aria-current="true"]')
    expect(active.text).to include(view_word(:read))
  end

  it 'says so when nothing is read yet' do
    read_one.update!(state: :archived, archived_at: Time.current)
    doc = doc_for(state_filters: %w[read])

    expect(doc.text).to include(I18n.t('views.organisations.notifications.master_list.empty.nothing_read.title'))
  end

  describe 'the search' do
    it 'submits while typing, into the list frame, replacing the address' do
      form = doc_for(state_filters: %w[read unread]).at_css('form.inbox-search')

      expect(form['data-controller']).to eq('auto-submit')
      expect(form['data-turbo-frame']).to eq('notifications_list_frame')
      expect(form['data-turbo-action']).to eq('replace')
    end

    it 'keeps the open notification in the address' do
      form = doc_for(state_filters: %w[read unread], notification: read_one.id).at_css('form.inbox-search')

      expect(form.at_css('input[type="hidden"][name="notification"]')['value']).to eq(read_one.id)
    end

    it 'filters the list frame and redraws the status links with the search' do
      get organisation_notifications_path(organisation, state_filters: %w[read unread], search: 'Export'),
          headers: { 'Turbo-Frame' => 'notifications_list_frame' }

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      frame = doc.at_css('turbo-frame#notifications_list_frame')
      expect(frame.text).to include('Exportfehler')
      expect(frame.text).not_to include('Rechnungslauf')

      stream = frame.at_css('turbo-stream[action="replace"][target="inbox_list_tools"]')
      expect(stream).to be_present, 'the tools ride inside the frame, or Turbo drops them'
      links = Nokogiri::HTML(stream.at_css('template').inner_html).css('a.people-pill').map { |a| a['href'] }
      expect(links).to all(include('search=Export'))
    end

    it 'shows the whole view again once the field is empty' do
      get organisation_notifications_path(organisation, state_filters: %w[read unread], search: ''),
          headers: { 'Turbo-Frame' => 'notifications_list_frame' }

      frame = Nokogiri::HTML(response.body).at_css('turbo-frame#notifications_list_frame')
      expect(frame.text).to include('Exportfehler', 'Rechnungslauf')
    end

    it 'sends no tools stream on a full page' do
      doc = doc_for(state_filters: %w[read unread])

      expect(doc.at_css('turbo-stream[target="inbox_list_tools"]')).to be_nil
      expect(doc.at_css('#inbox_list_tools')).to be_present
    end
  end
end
