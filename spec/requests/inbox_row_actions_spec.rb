# frozen_string_literal: true

require 'rails_helper'

# What: the actions on one notification, in words, in two places: the head of
#       the lane ("Als gelesen"/"Als ungelesen", "Archivieren") and a "···" menu
#       on every row of the list, so that a notification can be read or archived
#       without opening it. One set of words, the inbox's own (the status views
#       say "Archiviert", the bulk bar "Als gelesen" and "Archivieren").
# Why:  until 2026-11-10 the lane showed an envelope (its meaning only in a
#       tooltip, and showing the state it would switch TO) and "Erledigt" for
#       archiving; the list offered nothing per row.
#       A row action answers with the same stream as the lane, so the stream
#       must keep the notification the lane SHOWS, not the one acted on: it
#       used to take the acted one for the open one and swap the lane's
#       buttons to it.
#       One ticket is one row: an action on a row acts on every notification
#       of that ticket. The single routes did; the bulk ones (ids[]) and the
#       way back out of the archive did not, so a bundled row stayed.
RSpec.describe 'Inbox row actions', type: :request do
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
  let(:ticket_a) { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, title: 'Ticket A') } }
  let(:ticket_b) { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, title: 'Ticket B') } }

  def notification_for(ticket, state: :delivered, created_at: 1.hour.ago)
    ActsAsTenant.with_tenant(organisation) do
      create(:notification,
             recipient: user, organisation: organisation, project: project,
             notifiable: ticket, event_type: 'ticket_commented', channel: 'in_app', state: state,
             read_at: %i[read archived].include?(state) ? created_at : nil,
             archived_at: state == :archived ? created_at : nil,
             created_at: created_at)
    end
  end

  let!(:a_new) { notification_for(ticket_a, created_at: 1.hour.ago) }
  let!(:a_old) { notification_for(ticket_a, created_at: 2.hours.ago) }
  let!(:b_one) { notification_for(ticket_b, created_at: 3.hours.ago) }

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
  end

  after { ActsAsTenant.current_tenant = nil }

  def words(key)
    I18n.t("views.organisations.notifications.actions.#{key}")
  end

  def page_for(**params)
    get organisation_notifications_path(organisation, **params)
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  def stream_patch(path, referer:)
    patch path, headers: { 'Accept' => 'text/vnd.turbo-stream.html', 'Referer' => referer }
    expect(response).to have_http_status(:ok)
  end

  def inbox_url(**params)
    "http://www.example.com#{organisation_notifications_path(organisation, **params)}"
  end

  describe 'the head of the lane' do
    it 'names both actions in words, and archiving is "Archivieren"' do
      pills = page_for(notification: b_one.id, state_filters: ['unread']).at_css('#inbox_pane_status_pills')

      expect(pills.css('button').map { |button| button.text.squish })
        .to eq([words(:mark_read), words(:archive)])
      expect(pills.text).not_to include('Erledigt')
      expect(pills.css('.bi-envelope, .bi-envelope-open')).to be_empty
    end

    it 'offers "Als ungelesen" once the notification is read' do
      b_one.update!(state: :read, read_at: Time.current)
      pills = page_for(notification: b_one.id, state_filters: %w[read unread]).at_css('#inbox_pane_status_pills')

      expect(pills.css('button').map { |button| button.text.squish })
        .to eq([words(:mark_unread), words(:archive)])
    end

    it 'gives both buttons one form (F40: one height, one edge)' do
      pills = page_for(notification: b_one.id, state_filters: ['unread']).at_css('#inbox_pane_status_pills')

      expect(pills.css('button').map { |button| button['class'] }.uniq).to eq(['inbox-lane-actions__button'])
    end
  end

  describe 'the menu of a row' do
    def menu_of(doc, notification)
      doc.at_css("[data-notification-id='#{notification.id}'] .inbox-row__menu")
    end

    it 'offers reading and archiving for an unread row, without opening it' do
      menu = menu_of(page_for(state_filters: ['unread']), b_one)

      expect(menu).to be_present
      expect(menu.at_css('summary')['aria-label']).to include('Ticket B')
      actions = menu.css('form').map { |form| [form['action'], form.at_css('button').text.squish] }
      expect(actions).to eq([
                              [mark_read_organisation_notification_path(organisation, b_one), words(:mark_read)],
                              [archive_organisation_notification_path(organisation, b_one), words(:archive)]
                            ])
    end

    it 'offers "Als ungelesen" for a read row' do
      b_one.update!(state: :read, read_at: Time.current)
      menu = menu_of(page_for(state_filters: %w[read unread]), b_one)

      expect(menu.css('button').map { |button| button.text.squish }).to eq([words(:mark_unread), words(:archive)])
    end

    it 'offers the way back in the archive' do
      b_one.update!(state: :archived, read_at: Time.current, archived_at: Time.current)
      menu = menu_of(page_for(state_filters: ['archived']), b_one)

      expect(menu.css('form').map { |form| form['action'] })
        .to eq([unarchive_organisation_notification_path(organisation, b_one)])
      expect(menu.at_css('button').text.squish).to eq(words(:unarchive))
    end
  end

  describe 'a row action while another notification is open in the lane' do
    it 'leaves the lane and its selected row with the open one' do
      stream_patch archive_organisation_notification_path(organisation, b_one),
                   referer: inbox_url(notification: a_new.id, state_filters: ['unread'])

      expect(b_one.reload).to be_state_archived
      expect(response.body).not_to include('target="inbox_pane_status_pills"')
      list = Nokogiri::HTML(response.body.scan(%r{<template>(.*?)</template>}m).flatten.join)
      expect(list.css('.selected-row').map { |row| row['data-notification-id'] }).to eq([a_new.id])
    end

    it 'still swaps the lane buttons when the action is on the open one' do
      stream_patch mark_read_organisation_notification_path(organisation, a_new),
                   referer: inbox_url(notification: a_new.id, state_filters: %w[read unread])

      expect(response.body).to include('target="inbox_pane_status_pills"')
    end
  end

  describe 'one ticket is one row' do
    it 'archives every notification of a selected ticket in bulk' do
      patch archive_all_organisation_notifications_path(organisation),
            params: { ids: [a_new.id], selection: '1' }, headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect([a_new, a_old].map { |n| n.reload.state }).to eq(%w[archived archived])
      expect(b_one.reload.state).to eq('delivered')
    end

    it 'reads every notification of a selected ticket in bulk' do
      patch mark_all_read_organisation_notifications_path(organisation),
            params: { ids: [a_new.id], selection: '1' }, headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect([a_new, a_old].map { |n| n.reload.state }).to eq(%w[read read])
      expect(b_one.reload.state).to eq('delivered')
    end

    it 'brings the whole ticket back out of the archive' do
      [a_new, b_one].each { |n| n.update!(state: :archived, read_at: Time.current, archived_at: Time.current) }
      # The bulk bar archives unread ones too: archived, never read.
      a_old.update!(state: :archived, read_at: nil, archived_at: Time.current)
      expect(a_old.reload.read_at).to be_nil # the case under test

      stream_patch unarchive_organisation_notification_path(organisation, a_new),
                   referer: inbox_url(state_filters: ['archived'])

      expect([a_new, a_old].map { |n| n.reload.state }).to eq(%w[read read])
      expect([a_new, a_old].map(&:archived_at)).to eq([nil, nil])
      expect(a_old.read_at).to be_present
      expect(b_one.reload.state).to eq('archived')
    end
  end
end
