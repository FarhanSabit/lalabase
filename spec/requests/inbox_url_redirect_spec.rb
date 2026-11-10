# frozen_string_literal: true

require 'rails_helper'

# Ensures that after the URL rename:
#   1. All old /org/:id/notifications(/...) paths 301-redirect to /inbox
#      (bookmarks, old email notification links stay functional).
#   2. The new /inbox paths are actually reachable.
#   3. Technical routes (API v1, unsubscribe) are NOT affected.
#   4. i18n labels resolve to "Inbox" in both locales.
#
# See doc/inbox_feature_spec.md chapter 5 + doc/inbox_v1_plan.md PR-1.
RSpec.describe 'Inbox URL rename', type: :request do
  let(:organisation) { create(:organisation) }

  describe 'Legacy /notifications → /inbox 301-Redirects' do
    it 'redirects the collection root' do
      get "/org/#{organisation.id}/notifications"
      expect(response).to have_http_status(:moved_permanently)
      expect(response).to redirect_to("/org/#{organisation.id}/inbox")
    end

    it 'redirects collection sub-paths (e.g. preferences)' do
      get "/org/#{organisation.id}/notifications/preferences"
      expect(response).to have_http_status(:moved_permanently)
      expect(response).to redirect_to("/org/#{organisation.id}/inbox/preferences")
    end

    it 'redirects member-level paths (e.g. specific notification show)' do
      notification_id = SecureRandom.uuid
      get "/org/#{organisation.id}/notifications/#{notification_id}"
      expect(response).to have_http_status(:moved_permanently)
      expect(response).to redirect_to("/org/#{organisation.id}/inbox/#{notification_id}")
    end

    it 'redirects member sub-paths (e.g. /:id/open deep link)' do
      notification_id = SecureRandom.uuid
      get "/org/#{organisation.id}/notifications/#{notification_id}/open"
      expect(response).to have_http_status(:moved_permanently)
      expect(response).to redirect_to(
        "/org/#{organisation.id}/inbox/#{notification_id}/open"
      )
    end

    it 'preserves query strings across the redirect' do
      get "/org/#{organisation.id}/notifications?filter=unread&project=abc"
      expect(response).to have_http_status(:moved_permanently)
      expect(response.location).to include(
        "/org/#{organisation.id}/inbox"
      )
      expect(response.location).to include('filter=unread')
      expect(response.location).to include('project=abc')
    end

    it 'preserves URL-encoded query values (e.g. spaces, special chars)' do
      get "/org/#{organisation.id}/notifications?q=foo%20bar%26baz"
      expect(response.location).to include('q=foo%20bar%26baz')
    end

    it 'preserves multi-value query parameters (?tag=a&tag=b)' do
      get "/org/#{organisation.id}/notifications?tag=a&tag=b"
      expect(response.location).to include('tag=a')
      expect(response.location).to include('tag=b')
    end

    # Documented behavior: only GETs are redirected. Other HTTP methods
    # on legacy /notifications paths → 404. DELIBERATE choice because:
    # (a) 301 would turn POST→GET (browser standard) and lose the mutation
    #     intent.
    # (b) Mutations come exclusively from our own forms via route helpers —
    #     those automatically point to /inbox. External bookmarks are GET.
    it 'does NOT redirect non-GET methods on legacy paths (returns 404)' do
      notification_id = SecureRandom.uuid
      patch "/org/#{organisation.id}/notifications/#{notification_id}/mark_read"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'Technical routes that must NOT change' do
    it 'routes /unsubscribe/notifications to NotificationUnsubscribesController (unchanged)' do
      route = Rails.application.routes.recognize_path(
        '/unsubscribe/notifications', method: :get
      )
      expect(route[:controller]).to eq('notification_unsubscribes')
      expect(route[:action]).to eq('show')
    end

    it 'routes /api/v1/notifications to api/v1 controller (unchanged)' do
      route = Rails.application.routes.recognize_path(
        '/api/v1/notifications', method: :get
      )
      expect(route[:controller]).to eq('api/v1/notifications')
      expect(route[:action]).to eq('index')
    end
  end

  describe 'New /inbox routes are mounted' do
    let(:helpers) { Rails.application.routes.url_helpers }
    let(:notification_id) { SecureRandom.uuid }

    # Parametrized: all bulk and member action helpers must point to /inbox,
    # not to /notifications. Helper names stay unchanged
    # (`path:` only changes the URL, not the helper name).
    {
      organisation_notifications_path: '',
      mark_all_read_organisation_notifications_path: '/mark_all_read',
      archive_all_organisation_notifications_path: '/archive_all',
      preferences_organisation_notifications_path: '/preferences',
      ticket_exceptions_organisation_notifications_path: '/ticket_exceptions',
      stats_organisation_notifications_path: '/stats'
    }.each do |helper, suffix|
      it "#{helper} → /inbox#{suffix}" do
        path = helpers.send(helper, organisation_id: organisation.id)
        expect(path).to eq("/org/#{organisation.id}/inbox#{suffix}")
      end
    end

    {
      mark_read_organisation_notification_path: '/mark_read',
      mark_unread_organisation_notification_path: '/mark_unread',
      archive_organisation_notification_path: '/archive',
      open_organisation_notification_path: '/open',
      mark_group_read_organisation_notification_path: '/mark_group_read',
      activities_organisation_notification_path: '/activities',
      organisation_notification_path: ''
    }.each do |helper, suffix|
      it "#{helper} → /inbox/:id#{suffix}" do
        path = helpers.send(helper, organisation_id: organisation.id,
                                    id: notification_id)
        expect(path).to eq("/org/#{organisation.id}/inbox/#{notification_id}#{suffix}")
      end
    end
  end

  describe 'i18n: navigation label is "Inbox" in both locales' do
    %i[de en].each do |locale|
      it "resolves navigation.notifications → \"Inbox\" in #{locale.upcase}" do
        expect(I18n.t('navigation.notifications', locale: locale)).to eq('Inbox')
      end

      it "resolves notifications_label static plural forms → \"Inbox\" in #{locale.upcase}" do
        %i[zero one other].each do |form|
          expect(I18n.t("navigation.notifications_label.#{form}", locale: locale))
            .to eq('Inbox')
        end
      end

      # Actual usage in app/helpers/application_helper.rb:475 is
      # I18n.t('navigation.notifications_label', count: count). Here all
      # realistic count values must return "Inbox" (not the
      # earlier plural-form mix "Benachrichtigung"/"Benachrichtigungen").
      it "resolves notifications_label with count parameter → \"Inbox\" in #{locale.upcase}" do
        [0, 1, 2, 5, 100].each do |count|
          expect(
            I18n.t('navigation.notifications_label', count: count, locale: locale)
          ).to eq('Inbox')
        end
      end

      it "resolves inbox index page title → \"Inbox\" in #{locale.upcase}" do
        expect(
          I18n.t('views.organisations.notifications.index.title', locale: locale)
        ).to eq('Inbox')
      end
    end
  end

  # Ensures the new /inbox URL actually dispatches to the
  # notifications controller — i.e. the URL renaming did not accidentally
  # break the controller wiring. A full page render
  # is not practical here (asset precompile needed); the recognize_path
  # check guarantees routing correctness for every action, though.
  describe '/inbox dispatches to notifications controller' do
    {
      '' => 'index',
      '/preferences' => 'preferences',
      '/stats' => 'stats',
      '/ticket_exceptions' => 'ticket_exceptions'
    }.each do |suffix, expected_action|
      it "GET /inbox#{suffix} → notifications##{expected_action}" do
        route = Rails.application.routes.recognize_path(
          "/org/#{organisation.id}/inbox#{suffix}", method: :get
        )
        expect(route[:controller]).to eq('organisations/notifications')
        expect(route[:action]).to eq(expected_action)
      end
    end

    it 'GET /inbox/:id → notifications#show' do
      route = Rails.application.routes.recognize_path(
        "/org/#{organisation.id}/inbox/#{SecureRandom.uuid}", method: :get
      )
      expect(route[:controller]).to eq('organisations/notifications')
      expect(route[:action]).to eq('show')
    end

    it 'PATCH /inbox/:id/mark_read → notifications#mark_read (mutation route works on new URL)' do
      route = Rails.application.routes.recognize_path(
        "/org/#{organisation.id}/inbox/#{SecureRandom.uuid}/mark_read",
        method: :patch
      )
      expect(route[:controller]).to eq('organisations/notifications')
      expect(route[:action]).to eq('mark_read')
    end
  end

  # i18n for the inbox pane (empty state, missing, unauthorized, "Open in
  # ticket" link). All keys must exist in DE+EN and be non-empty.
  describe 'i18n: inbox pane strings exist in both locales' do
    %i[de en].each do |locale|
      %w[empty_title
         missing_title missing_subtitle
         unauthorized_title unauthorized_subtitle
         non_ticket_title non_ticket_subtitle
         open_full_view].each do |key|
        it "views.organisations.notifications.pane.#{key} (#{locale.upcase})" do
          value = I18n.t("views.organisations.notifications.pane.#{key}",
                         locale: locale, default: nil)
          expect(value).to be_present, "Missing pane.#{key} in #{locale}"
        end
      end
      # The actions moved out of pane.* (2026-11-10): the lane and the "···"
      # of a row share them.
      %w[mark_read mark_unread archive unarchive].each do |key|
        it "views.organisations.notifications.actions.#{key} (#{locale.upcase})" do
          value = I18n.t("views.organisations.notifications.actions.#{key}",
                         locale: locale, default: nil)
          expect(value).to be_present, "Missing actions.#{key} in #{locale}"
        end
      end
    end
  end

  # Regression guard: the briefing-page notifications lane is preserved per
  # spec 3.6 (position B) — and its section title remains
  # "Benachrichtigungen", not "Inbox". This could easily have been
  # accidentally overwritten during the locale sweep.
  describe 'Briefing-Page section title NOT renamed (Spec 3.6, Position B)' do
    it 'keeps "Benachrichtigungen" for briefing notifications lane in DE' do
      expect(
        I18n.t('dashboard.briefing.sections.notifications.title', locale: :de)
      ).to eq('Benachrichtigungen')
    end

    it 'keeps "Notifications" for briefing notifications lane in EN' do
      expect(
        I18n.t('dashboard.briefing.sections.notifications.title', locale: :en)
      ).to eq('Notifications')
    end
  end
end
