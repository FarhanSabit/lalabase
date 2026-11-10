# frozen_string_literal: true

require 'rails_helper'

# Status filter of the inbox (Controller#index). The list head offers one
# view at a time (Inbox::MasterListPresenter::STATUS_VIEWS, rendered by
# organisations/notifications/_list_head), the controller still accepts a
# union. Behavior:
#
# - No selection      → default inbox view: everything EXCEPT archived.
# - state_filters[]=unread      → only unread (queued/sent/delivered).
# - state_filters[]=read        → only read.
# - state_filters[]=archived    → only archived.
# - Several together  → union.
# - Legacy ?state=unread (single value) → falls back to state_filters.
RSpec.describe 'Inbox status filter (multi-select)', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:role, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership,
             user: user, organisation: organisation, role: role, active: true)
    end
  end

  let!(:unread_n) do
    ActsAsTenant.with_tenant(organisation) do
      create(:notification, recipient: user, organisation: organisation,
                            channel: 'in_app', state: :delivered)
    end
  end
  let!(:read_n) do
    ActsAsTenant.with_tenant(organisation) do
      create(:notification, recipient: user, organisation: organisation,
                            channel: 'in_app', state: :read, read_at: 1.hour.ago)
    end
  end
  let!(:archived_n) do
    ActsAsTenant.with_tenant(organisation) do
      create(:notification, recipient: user, organisation: organisation,
                            channel: 'in_app', state: :archived,
                            archived_at: 1.hour.ago)
    end
  end

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
    Prosopite.pause
  end
  after { Prosopite.resume }

  def visible_notifications
    # Helper: we test the controller logic directly via the @notifications
    # instance variable after the request. Simplifies writing assertions.
    controller.instance_variable_get(:@notifications)
  end

  describe 'Default (keine state_filters)' do
    it 'redirected nackten /inbox-Aufruf auf state_filters[]=unread' do
      get organisation_notifications_path(organisation)
      expect(response).to redirect_to(
        organisation_notifications_path(organisation, state_filters: ['unread'])
      )
    end

    it 'mit leerem aber existierendem Query-String (z.B. ?state_filters[]=) zeigt ALLE nicht-archivierten' do
      # Explicit user choice "no state filter" is respected — no
      # automatic redirect-to-unread.
      get organisation_notifications_path(organisation), params: { state_filters: [''] }
      ids = visible_notifications.map(&:id)
      expect(ids).to include(unread_n.id, read_n.id)
      expect(ids).not_to include(archived_n.id)
    end
  end

  describe 'state_filters[]=unread' do
    it 'shows only unread' do
      get organisation_notifications_path(organisation), params: { state_filters: ['unread'] }
      ids = visible_notifications.map(&:id)
      expect(ids).to eq([unread_n.id])
    end
  end

  describe 'state_filters[]=read' do
    it 'shows only read' do
      get organisation_notifications_path(organisation), params: { state_filters: ['read'] }
      ids = visible_notifications.map(&:id)
      expect(ids).to eq([read_n.id])
    end
  end

  describe 'state_filters[]=archived' do
    it 'shows only archived' do
      get organisation_notifications_path(organisation), params: { state_filters: ['archived'] }
      ids = visible_notifications.map(&:id)
      expect(ids).to eq([archived_n.id])
    end
  end

  describe 'state_filters[] mit mehreren Werten' do
    it 'shows union of unread + archived' do
      get organisation_notifications_path(organisation),
          params: { state_filters: %w[unread archived] }
      ids = visible_notifications.map(&:id)
      expect(ids).to include(unread_n.id, archived_n.id)
      expect(ids).not_to include(read_n.id)
    end

    it 'shows all 3 when all 3 are active' do
      get organisation_notifications_path(organisation),
          params: { state_filters: %w[unread read archived] }
      ids = visible_notifications.map(&:id)
      expect(ids).to include(unread_n.id, read_n.id, archived_n.id)
    end
  end

  describe 'Backward-Compat: ?state=unread (Single-Value)' do
    it 'fällt auf state_filters-Logik zurück (zeigt nur unread)' do
      get organisation_notifications_path(organisation), params: { state: 'unread' }
      ids = visible_notifications.map(&:id)
      expect(ids).to eq([unread_n.id])
    end

    it '?state=archived zeigt nur archivierte (Legacy-Verhalten erhalten)' do
      get organisation_notifications_path(organisation), params: { state: 'archived' }
      ids = visible_notifications.map(&:id)
      expect(ids).to eq([archived_n.id])
    end
  end

  describe 'Robust gegenüber Blank-Werten' do
    it 'ignores blank entries in state_filters[]' do
      get organisation_notifications_path(organisation),
          params: { state_filters: ['', 'unread', ''] }
      ids = visible_notifications.map(&:id)
      expect(ids).to eq([unread_n.id])
    end

    it 'ignores leeres Array → Default-View (nicht archiviert)' do
      get organisation_notifications_path(organisation), params: { state_filters: [] }
      ids = visible_notifications.map(&:id)
      expect(ids).to include(unread_n.id, read_n.id)
      expect(ids).not_to include(archived_n.id)
    end
  end
end
