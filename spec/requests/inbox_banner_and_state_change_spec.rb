# frozen_string_literal: true

require 'rails_helper'

# Supplementary QA-matrix cases (round 2, extended):
# - H2: state-change when item still matches the filter → stays visible
# - H5: completely empty inbox → up_to_date text instead of try_different_filters
# - H6: banner visibility across filters (bug #8 regression guard)
RSpec.describe 'Inbox banner + state-change matrix', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:admin_role, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end
  let!(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end
  let!(:ticket) do
    ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) }
  end

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
    Prosopite.pause
  end
  after { Prosopite.resume }

  def presenter
    controller.instance_variable_get(:@presenter)
  end

  describe 'H6: die Status-Ansicht der Pillen (Ungelesen, Alle, Archiviert)' do
    {
      [''] => 'all',
      ['unread'] => 'unread',
      %w[read unread] => 'all',
      ['archived'] => 'archived',
      ['read'] => nil
    }.each do |filters, view|
      it "nennt fuer state_filters #{filters.inspect} die Ansicht #{view.inspect}" do
        get organisation_notifications_path(organisation), params: { state_filters: filters }
        expect(presenter.status_view).to eq(view)
      end
    end

    it 'markiert genau die aktive Pille' do
      get organisation_notifications_path(organisation), params: { state_filters: ['archived'] }
      expect(response.body.scan('aria-current="true"').size).to eq(2) # the pill and the view mode cell
      expect(response.body).to match(/people-pill--active"[^>]*>\s*#{I18n.t('views.organisations.notifications.filter.views.archived')}/)
    end
  end

  describe 'H5: Empty-State-Texte' do
    it 'sagt "Alles gelesen." statt eines Fehlers, wenn die Ungelesen-Ansicht leer ist' do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation,
                              channel: 'in_app', state: :read, read_at: 1.hour.ago, notifiable: ticket, project: project)
      end
      get organisation_notifications_path(organisation), params: { state_filters: ['unread'] }
      expect(presenter.empty_reason).to eq(:all_read)
      expect(response.body).to include(I18n.t('views.organisations.notifications.master_list.empty.all_read.title'))
      expect(response.body).not_to include(I18n.t('views.organisations.notifications.master_list.empty.no_match.title'))
    end

    it 'bietet bei einer Suche ohne Treffer an, Suche und Projekt zurueckzusetzen, und behaelt die Ansicht' do
      get organisation_notifications_path(organisation), params: { state_filters: ['unread'], search: 'nichts' }
      expect(presenter.empty_reason).to eq(:no_match)
      reset = Nokogiri::HTML(response.body).at_css('.inbox-empty a')
      expect(reset['href']).to include('state_filters')
      expect(reset['href']).not_to include('search')
    end

    it 'nennt die leere Archiv- und Alle-Ansicht ohne Fehlerton' do
      get organisation_notifications_path(organisation), params: { state_filters: ['archived'] }
      expect(presenter.empty_reason).to eq(:nothing_archived)
      get organisation_notifications_path(organisation), params: { state_filters: %w[read unread] }
      expect(presenter.empty_reason).to eq(:nothing_yet)
    end
  end

  describe 'H2: State-Change wenn Item weiter zum Filter passt' do
    let!(:notification) do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation,
                              notifiable: ticket, project: project,
                              channel: 'in_app', state: :delivered)
      end
    end

    it 'unread→read bleibt in der Liste wenn Filter unread+read umfasst' do
      # mark_read from the pane, referrer has unread+read filter
      patch mark_read_organisation_notification_path(organisation, notification),
            headers: { 'Referer' => organisation_notifications_path(organisation, state_filters: %w[unread read]) }
      # Notification is now read, but read is in the filter → stays visible.
      # We check the filter-match logic in the controller.
      still_in = controller.send(:notification_matches_state_filters?,
                                 notification.reload, %w[unread read])
      expect(still_in).to be true
    end

    it 'unread→read verschwindet wenn Filter NUR unread umfasst' do
      patch mark_read_organisation_notification_path(organisation, notification),
            headers: { 'Referer' => organisation_notifications_path(organisation, state_filters: %w[unread]) }
      still_in = controller.send(:notification_matches_state_filters?,
                                 notification.reload, %w[unread])
      expect(still_in).to be false
    end
  end
end
