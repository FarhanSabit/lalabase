# frozen_string_literal: true

require 'rails_helper'

# Integration tests for the inbox pane flow (spec 4.4 / 4.8 / 4.6).
# Tests the controller logic end-to-end (notification loading,
# Pundit auth, mark-as-read, pane-state selection), not the full
# UI rendering — for that there is a dedicated test per pane state that
# checks the controller instance variables.
RSpec.describe 'Inbox pane flow', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:admin_role, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership,
             user: user, organisation: organisation, role: role, active: true)
    end
  end

  let!(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  let!(:ticket) do
    ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) }
  end

  let!(:ticket_notification) do
    ActsAsTenant.with_tenant(organisation) do
      create(:notification,
             recipient: user, organisation: organisation, project: project,
             notifiable: ticket, channel: 'in_app', state: :delivered)
    end
  end

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
    Prosopite.pause # Pre-existing N+1 in the render path, separate cleanup PR.
  end
  after { Prosopite.resume }

  describe 'GET /inbox ohne ?notification (Default-View)' do
    it 'sets pane_state to nil (Empty-State im Pane)' do
      # Bare URL → redirect to default filter, then follow.
      get organisation_notifications_path(organisation, state_filters: ['unread'])
      expect(response).to have_http_status(:ok)
      expect(controller.instance_variable_get(:@pane_state)).to be_nil
      expect(controller.instance_variable_get(:@selected_notification)).to be_nil
    end
  end

  describe 'GET /inbox?notification=:id mit gültiger Ticket-Notification' do
    it 'lädt Ticket + Project in den Pane-Kontext' do
      get organisation_notifications_path(organisation),
          params: { notification: ticket_notification.id }
      expect(controller.instance_variable_get(:@pane_state)).to eq(:ticket)
      expect(controller.instance_variable_get(:@ticket)).to eq(ticket)
      expect(controller.instance_variable_get(:@project)).to eq(project)
      expect(controller.instance_variable_get(:@selected_notification)).to eq(ticket_notification)
    end

    it 'markiert die Notification NICHT sofort als gelesen — Mark-as-read passiert verzögert' do
      # Immediate mark_as_read would turn preview clicks (user only takes a
      # quick look) into read commits. Instead: Stimulus fires a
      # PATCH /mark_read from the pane after 5s.
      expect do
        get organisation_notifications_path(organisation),
            params: { notification: ticket_notification.id }
      end.not_to(change { ticket_notification.reload.state })
    end

    it 'lässt bereits-gelesene Notifications unverändert (read_at bleibt)' do
      ticket_notification.update!(state: 'read', read_at: 1.hour.ago)
      original_read_at = ticket_notification.read_at
      get organisation_notifications_path(organisation),
          params: { notification: ticket_notification.id }
      expect(ticket_notification.reload.read_at.to_i).to eq(original_read_at.to_i)
    end
  end

  describe 'GET /inbox?notification=:id mit nicht-existierender ID' do
    it 'setzt pane_state auf :missing' do
      get organisation_notifications_path(organisation),
          params: { notification: SecureRandom.uuid }
      expect(controller.instance_variable_get(:@pane_state)).to eq(:missing)
    end
  end

  describe 'GET /inbox?notification=:id mit Non-Ticket-Notifiable' do
    let!(:doc_notification) do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification,
               recipient: user, organisation: organisation, project: project,
               notifiable: project, # Project as a stand-in for non-ticket
               channel: 'in_app', state: :delivered)
      end
    end

    it 'setzt pane_state auf :non_ticket und markiert NICHT als gelesen' do
      get organisation_notifications_path(organisation),
          params: { notification: doc_notification.id }
      expect(controller.instance_variable_get(:@pane_state)).to eq(:non_ticket)
      expect(doc_notification.reload.state).to eq('delivered')
    end
  end

  describe 'GET /inbox?notification=:id ohne Ticket-Zugriff (Pundit)' do
    let(:other_user) { create(:user) }
    let!(:other_membership) do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: other_user, organisation: organisation,
                            role: role, active: true)
      end
    end
    # A notification for other_user that guido should not be able to see.
    let!(:foreign_notification) do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification,
               recipient: other_user, organisation: organisation, project: project,
               notifiable: ticket, channel: 'in_app', state: :delivered)
      end
    end

    it 'findet die Notification nicht (gehört einem anderen User) → :missing' do
      get organisation_notifications_path(organisation),
          params: { notification: foreign_notification.id }
      expect(controller.instance_variable_get(:@pane_state)).to eq(:missing)
    end
  end

  describe 'GET /inbox?notification=:id als Turbo-Frame-Request' do
    it 'rendert nur das Pane-Partial (kein Full-Page-Render)' do
      get organisation_notifications_path(organisation),
          params: { notification: ticket_notification.id },
          headers: { 'Turbo-Frame' => 'ticket_pane' }
      expect(response).to have_http_status(:ok)
      # On frame request: no <html> / no layout
      expect(response.body).not_to include('<html')
      # Pane partial rendered (project eyebrow at top left)
      expect(response.body).to include('ticket_pane')
    end
  end

  # The pane is a quick look at ONE notification: its head names that ticket, so a link to
  # another ticket leaves the pane instead of swapping only the part below the head. The
  # timeline loads apart and cannot know where it sits, hence a controller here, not a target
  # on each link. It sits inside the frame: a frame load does not copy the frame's attributes.
  describe 'links to other tickets from the pane' do
    it 'wires the controller that sends them out, inside the pane' do
      get organisation_notifications_path(organisation),
          params: { notification: ticket_notification.id },
          headers: { 'Turbo-Frame' => 'ticket_pane' }

      expect(response).to have_http_status(:ok)
      document = Nokogiri::HTML(response.body)
      wrapper = document.at_css("turbo-frame#ticket_pane [data-controller~='ticket-pane-links']")
      expect(wrapper).to be_present
      expect(wrapper['data-action']).to include('click->ticket-pane-links#leave')
      expect(wrapper.at_css('turbo-frame#ticket_display_frame')).to be_present
    end
  end

  describe 'editing a ticket from the pane' do
    # The pane carries ticket_display_frame like the standalone ticket view
    # (_index_desktop.html.erb): the status pills and inline edits target it, and
    # Turbo shows "Content missing" when a targeted frame is absent.
    it 'rendert <turbo-frame id="ticket_display_frame"> im Pane' do
      get organisation_notifications_path(organisation),
          params: { notification: ticket_notification.id },
          headers: { 'Turbo-Frame' => 'ticket_pane' }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="ticket_display_frame"')
    end

    # Since the writing surface (Paket 3, #587/#588) "Edit" opens the ticket in
    # turbo-frame#writing_surface, which the application layout owns, so every page has
    # it, the inbox included. Until 10.09.2026 this block still asked tickets#edit for
    # the earlier turbo stream into ticket_display_frame. No link requests that any more,
    # and tickets#edit has no turbo_stream template, so the example answered 500.
    it 'points the edit link at the writing surface the inbox page provides' do
      get organisation_notifications_path(organisation), params: { notification: ticket_notification.id }
      document = Nokogiri::HTML(response.body)
      edit_path = edit_organisation_project_ticket_path(organisation, project, ticket)

      edit_links = document.css(%(a[href="#{edit_path}"]))

      expect(document.at_css('turbo-frame#writing_surface')).to be_present
      # Every one of them: the title (designer round 8a) and the pencil in the action bar.
      expect(edit_links).not_to be_empty
      expect(edit_links.map { |link| link['data-turbo-frame'] }).to all(eq('writing_surface'))
    end

    it 'answers the edit click with the writing surface for that frame' do
      get edit_organisation_project_ticket_path(organisation, project, ticket),
          headers: { 'Turbo-Frame' => 'writing_surface' }

      expect(response).to have_http_status(:ok)
      expect(Nokogiri::HTML(response.body).at_css('turbo-frame#writing_surface form')).to be_present
    end
  end

  describe 'Bündelung: Kaskade auf Ticket-Geschwister' do
    # Three notifications for the same ticket — bundling shows one row,
    # actions should hit all three.
    let!(:older1) do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation, project: project,
                              notifiable: ticket, channel: 'in_app', state: 'delivered',
                              created_at: 3.hours.ago)
      end
    end
    let!(:older2) do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation, project: project,
                              notifiable: ticket, channel: 'in_app', state: 'delivered',
                              created_at: 2.hours.ago)
      end
    end
    # ticket_notification (defined above) is the third/newest.

    it 'mark_read kaskadiert auf ALLE ungelesenen Notifications des Tickets' do
      patch mark_read_organisation_notification_path(organisation, ticket_notification)
      expect(older1.reload.state).to eq('read')
      expect(older2.reload.state).to eq('read')
      expect(ticket_notification.reload.state).to eq('read')
    end

    it 'archive kaskadiert auf ALLE Notifications des Tickets' do
      patch archive_organisation_notification_path(organisation, ticket_notification)
      expect(older1.reload.state).to eq('archived')
      expect(older2.reload.state).to eq('archived')
      expect(ticket_notification.reload.state).to eq('archived')
    end

    it 'mark_unread flippt NUR die Ziel-Notification (keine Kaskade)' do
      [older1, older2, ticket_notification].each { |n| n.update!(state: 'read', read_at: 1.hour.ago) }
      patch mark_unread_organisation_notification_path(organisation, ticket_notification)
      expect(ticket_notification.reload.unread?).to be(true)
      expect(older1.reload.state).to eq('read')
      expect(older2.reload.state).to eq('read')
    end
  end

  describe 'Pane: "Was war neu"-Block' do
    let!(:older1) do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation, project: project,
                              notifiable: ticket, channel: 'in_app', state: 'delivered',
                              created_at: 2.hours.ago)
      end
    end

    it 'lädt @new_activities mit den ungelesenen Notifications des Tickets' do
      get organisation_notifications_path(organisation),
          params: { notification: ticket_notification.id }
      new_activities = controller.instance_variable_get(:@new_activities)
      expect(new_activities.map(&:id)).to match_array([older1.id, ticket_notification.id])
    end

    it 'rendert den Block (Aktivitäts-Zeilen mit Randlinie) im Pane-Frame' do
      get organisation_notifications_path(organisation),
          params: { notification: ticket_notification.id },
          headers: { 'Turbo-Frame' => 'ticket_pane' }
      # A list with one row per unread activity, marked by its edge line,
      # without a heading.
      expect(response.body).to include('inbox-new-activity__item')
      expect(response.body).to include(I18n.t('views.organisations.notifications.event_short.system_message'))
    end
  end

  describe 'URL-Persistenz' do
    it 'rendert die volle Inbox-Page bei direktem Aufruf mit ?notification=' do
      get organisation_notifications_path(organisation),
          params: { notification: ticket_notification.id }
      # Full page (no frame request) → layout + pane rendered
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('ticket_pane')
    end
  end
end
