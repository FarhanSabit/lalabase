# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NeoInboxMasterItemComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:ticket) { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) } }
  let(:notification) do
    ActsAsTenant.with_tenant(organisation) do
      create(:notification, recipient: user, organisation: organisation,
                            project: project, notifiable: ticket, channel: 'in_app')
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    # link_url calls helpers.current_organisation (controller method) — stub it
    # in the isolated component test.
    allow_any_instance_of(ApplicationController).to receive(:current_organisation).and_return(organisation)
  end

  it 'zeigt den Ticket-Titel vorn und darunter wer, was und wo' do
    render_inline(described_class.new(notification: notification))
    expect(page).to have_css('.inbox-row__title', text: ticket.title)
    expect(page).to have_css('.inbox-row__meta-text', text: project.name)
  end

  it 'zeigt "N neu" ab zwei ungelesenen Meldungen eines gebündelten Tickets' do
    render_inline(described_class.new(notification: notification, group_count: 5, group_unread: 3))
    expect(page).to have_css('.inbox-row__new', text: I18n.t('views.organisations.notifications.item.new_count', count: 3))
  end

  it 'zeigt KEIN "neu" bei einer einzigen ungelesenen Meldung (Punkt und fetter Titel genuegen)' do
    render_inline(described_class.new(notification: notification, group_count: 5, group_unread: 1))
    expect(page).not_to have_css('.inbox-row__new')
    expect(page).to have_css('.inbox-row--unread')
  end

  it 'markiert die Zeile als ungelesen, wenn group_unread > 0' do
    notification.update!(state: 'read', read_at: 1.hour.ago)
    render_inline(described_class.new(notification: notification, group_count: 2, group_unread: 1))
    # The app-wide unread dot (Neo::UnreadMarkerComponent), the same as in the ticket rows
    expect(page).to have_css('[data-unread-marker="dot"]')
  end

  it 'markiert die Zeile als gelesen, wenn group_unread == 0, und behaelt das Auswahlkaestchen' do
    render_inline(described_class.new(notification: notification, group_count: 2, group_unread: 0))
    expect(page).to have_css('.inbox-row:not(.inbox-row--unread)')
    expect(page).not_to have_css('[data-unread-marker]')
    expect(page).to have_css('input.inbox-row__check[data-inbox-bulk-select-target="checkbox"]')
  end
end
