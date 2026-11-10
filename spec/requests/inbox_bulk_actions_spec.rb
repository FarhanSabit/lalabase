# frozen_string_literal: true

require 'rails_helper'

# Bulk actions in the inbox (Gmail-style): mark_all_read and archive_all
# both accept an optional ids[] parameter to affect only the selected
# notifications instead of everything in the org.
#
# See doc/inbox_v1_plan.md PR-2/C3 and doc/inbox_feature_spec.md
# implementation steps V1 (multi-select pulled forward from V1.1).
RSpec.describe 'Inbox bulk actions with ids[] filter', type: :request do
  # Pre-existing N+1 in organisations/notifications#mark_all_read and
  # #archive_all (response render iterates notifications and accesses
  # .organisation per item). Plus N+1 when creating 4 notifications
  # in the let!. NOT in scope of this PR — separate performance PR. Here
  # we only test the new bulk-IDs filter logic.
  #
  # IMPORTANT: Prosopite.pause MUST be in a `before`, not in an
  # `around` — the support-config `before(:each)` calls Prosopite.scan and
  # would override our pause if around runs before it.
  before { Prosopite.pause }
  after  { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:role, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership,
             user: user, organisation: organisation,
             role: role, active: true)
    end
  end

  let!(:notifications) do
    ActsAsTenant.with_tenant(organisation) do
      Array.new(4) do |i|
        create(:notification,
               recipient: user,
               organisation: organisation,
               channel: 'in_app',
               state: :delivered,
               created_at: i.hours.ago)
      end
    end
  end

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
  end

  # Convenience wrapper, keeps the notation explicit. Prosopite is paused
  # in the around hook (see above).
  def bulk_patch(path, **opts)
    patch(path, **opts)
  end

  describe 'PATCH mark_all_read with ids[]' do
    it 'marks only the selected notifications as read' do
      selected = notifications.first(2)
      bulk_patch mark_all_read_organisation_notifications_path(organisation),
                 params: { ids: selected.map(&:id) }

      selected.each { |n| expect(n.reload.state).to eq('read') }
      notifications.last(2).each { |n| expect(n.reload.state).to eq('delivered') }
    end

    it 'is idempotent on already-read notifications' do
      notifications.first.update!(state: 'read', read_at: 1.minute.ago)
      expect do
        bulk_patch mark_all_read_organisation_notifications_path(organisation),
                   params: { ids: [notifications.first.id] }
      end.not_to(change { notifications.first.reload.read_at })
    end

    it 'ignores empty ids array and marks all unread (original behavior)' do
      bulk_patch mark_all_read_organisation_notifications_path(organisation),
                 params: { ids: [] }
      notifications.each { |n| expect(n.reload.state).to eq('read') }
    end

    it 'ignores blank ids in the array (Stimulus may send empty strings)' do
      bulk_patch mark_all_read_organisation_notifications_path(organisation),
                 params: { ids: ['', notifications.first.id, ''] }
      expect(notifications.first.reload.state).to eq('read')
      notifications.last(3).each { |n| expect(n.reload.state).to eq('delivered') }
    end

    it 'cannot mark notifications outside the org (multi-tenancy)' do
      other_org = create(:organisation)
      other_user = create(:user)
      foreign_notification = ActsAsTenant.with_tenant(other_org) do
        create(:notification, recipient: other_user, organisation: other_org,
                              channel: 'in_app', state: :delivered)
      end

      bulk_patch mark_all_read_organisation_notifications_path(organisation),
                 params: { ids: [foreign_notification.id] }

      expect(foreign_notification.reload.state).to eq('delivered')
    end
  end

  describe 'PATCH archive_all with ids[]' do
    it 'archives the selected notifications regardless of read state' do
      selected = notifications.first(2)
      # For archive_all without ids, only :read is archived. With ids: also :delivered.
      bulk_patch archive_all_organisation_notifications_path(organisation),
                 params: { ids: selected.map(&:id) }

      selected.each { |n| expect(n.reload.state).to eq('archived') }
      notifications.last(2).each { |n| expect(n.reload.state).to eq('delivered') }
    end

    it 'archives ungelesene Notifications wenn explizit selektiert (Gmail-Verhalten)' do
      # Default behavior without ids: only read notifications are archived.
      # With ids: all selected ones, including unread.
      bulk_patch archive_all_organisation_notifications_path(organisation),
                 params: { ids: [notifications.first.id] }
      expect(notifications.first.reload.state).to eq('archived')
    end
  end

  # User-reported test case: filter=unread, select items, bulk
  # "Mark as read" → items must disappear from the list (now read,
  # no longer match the unread filter). We check the turbo_stream
  # response: inbox_master_list must NOT contain the marked items
  # anymore. state_filters come from the referrer (the bulk-form URL does
  # not carry them).
  # The bulk bar of the inbox names its requests (selection=1). Without ids
  # such a request would be the whole-inbox action the bar never offers (the
  # buttons are disabled, but Turbo re-enables a submitter after a failed
  # request), so the routes refuse it and change nothing. The header dropdown
  # keeps asking for the whole inbox without the marker (the example above).
  describe 'a request of the bulk bar without ids' do
    let(:turbo) { { 'Accept' => 'text/vnd.turbo-stream.html' } }

    it 'mark_all_read refuses it and marks nothing' do
      bulk_patch mark_all_read_organisation_notifications_path(organisation),
                 params: { selection: '1', ids: [''] }, headers: turbo

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('flash.notifications.nothing_selected'))
      notifications.each { |n| expect(n.reload.state).to eq('delivered') }
    end

    it 'archive_all refuses it and archives nothing' do
      notifications.first.update!(state: 'read', read_at: 1.minute.ago)
      bulk_patch archive_all_organisation_notifications_path(organisation),
                 params: { selection: '1' }, headers: turbo

      expect(response).to have_http_status(:unprocessable_content)
      expect(notifications.first.reload.state).to eq('read')
    end

    it 'answers the plain form with a redirect and the reason' do
      bulk_patch archive_all_organisation_notifications_path(organisation), params: { selection: '1' }

      expect(response).to redirect_to(organisation_notifications_path(organisation))
      expect(flash[:alert]).to eq(I18n.t('flash.notifications.nothing_selected'))
    end

    it 'still acts on the named ids when the bar sends them' do
      bulk_patch mark_all_read_organisation_notifications_path(organisation),
                 params: { selection: '1', ids: [notifications.first.id] }, headers: turbo

      expect(response).to have_http_status(:ok)
      expect(notifications.first.reload.state).to eq('read')
      notifications.last(3).each { |n| expect(n.reload.state).to eq('delivered') }
    end
  end

  describe 'Bulk-Action refresht Liste filter-korrekt (turbo_stream)' do
    let(:unread_referrer) do
      organisation_notifications_path(organisation, state_filters: ['unread'])
    end

    it 'mark_all_read mit ids entfernt Items aus der Ungelesen-gefilterten Liste' do
      selected = notifications.first(2)
      patch mark_all_read_organisation_notifications_path(organisation),
            params: { ids: selected.map(&:id) },
            headers: { 'Referer' => unread_referrer,
                       'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)
      # The marked (now read) items must no longer appear in the
      # rendered master.
      selected.each do |n|
        expect(response.body).not_to include("notification_#{n.id}")
      end
      # The unmarked unread ones stay in.
      notifications.last(2).each do |n|
        expect(response.body).to include("notification_#{n.id}")
      end
    end

    it 'archive_all mit ids entfernt Items aus der Ungelesen-gefilterten Liste' do
      selected = notifications.first(2)
      patch archive_all_organisation_notifications_path(organisation),
            params: { ids: selected.map(&:id) },
            headers: { 'Referer' => unread_referrer,
                       'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)
      selected.each do |n|
        expect(response.body).not_to include("notification_#{n.id}")
        expect(n.reload.state).to eq('archived')
      end
      notifications.last(2).each do |n|
        expect(response.body).to include("notification_#{n.id}")
      end
    end
  end
end
