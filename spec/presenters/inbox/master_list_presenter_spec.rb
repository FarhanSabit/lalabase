# frozen_string_literal: true

require 'rails_helper'

# Minimal Pagy host: the presenter calls pagy_helper.send(:pagy, ...).
class FakePagyHelper
  include Pagy::Backend

  def initialize(params = {})
    @params = params
  end

  attr_reader :params
end

RSpec.describe Inbox::MasterListPresenter do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:ticket_a) { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) } }
  let(:ticket_b) { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) } }

  let(:scope) { Notification.where(recipient: user, channel: 'in_app') }

  def notif(ticket, created_at:, state: 'queued')
    ActsAsTenant.with_tenant(organisation) do
      create(:notification,
             recipient: user, organisation: organisation, project: project,
             notifiable: ticket, channel: 'in_app', state: state,
             created_at: created_at, read_at: state == 'read' ? created_at : nil)
    end
  end

  before { ActsAsTenant.current_tenant = organisation }

  def build(params = {})
    described_class.new(
      pagy_helper: FakePagyHelper.new,
      scope: scope,
      params: { view_mode: 'grouped' }.merge(params)
    )
  end

  describe 'Bündelung im grouped-View' do
    it 'fasst mehrere Notifications eines Tickets zu EINER Zeile zusammen' do
      notif(ticket_a, created_at: 3.hours.ago)
      notif(ticket_a, created_at: 2.hours.ago)
      newest_a = notif(ticket_a, created_at: 1.hour.ago)
      notif(ticket_b, created_at: 90.minutes.ago)

      presenter = build

      # 2 tickets → 2 rows (not 4 notifications)
      expect(presenter.notifications.size).to eq(2)
      # The representative of ticket A is the NEWEST notification
      rep_a = presenter.notifications.find { |n| n.notifiable_id == ticket_a.id }
      expect(rep_a.id).to eq(newest_a.id)
    end

    it 'liefert group_total = Gesamtzahl der Notifications des Tickets' do
      notif(ticket_a, created_at: 3.hours.ago)
      notif(ticket_a, created_at: 2.hours.ago)
      notif(ticket_a, created_at: 1.hour.ago)

      presenter = build
      rep_a = presenter.notifications.first
      expect(presenter.group_total(rep_a)).to eq(3)
    end

    it 'liefert group_unread = Anzahl ungelesener des Tickets' do
      notif(ticket_a, created_at: 3.hours.ago, state: 'read')
      notif(ticket_a, created_at: 2.hours.ago)
      notif(ticket_a, created_at: 1.hour.ago)

      presenter = build
      rep_a = presenter.notifications.first
      expect(presenter.group_unread(rep_a)).to eq(2)
    end

    it 'zeigt ein tagesübergreifend aktives Ticket nur EINMAL, unter dem neuesten Zeitraum' do
      travel_to Time.zone.local(2026, 11, 11, 12) do # a Wednesday
        notif(ticket_a, created_at: 2.days.ago)
        notif(ticket_a, created_at: 1.hour.ago)

        presenter = build

        expect(presenter.notifications.size).to eq(1)
        expect(presenter.grouped_notifications.keys).to eq([:today])
      end
    end

    it 'ordnet die Zeilen den Zeiträumen Heute, Gestern, Diese Woche und Älter zu, in dieser Reihenfolge' do
      travel_to Time.zone.local(2026, 11, 11, 12) do # Wednesday; the week began on Monday the 9th
        ticket_c = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) }
        ticket_d = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) }
        notif(ticket_d, created_at: Time.zone.local(2026, 11, 8, 23)) # Sunday: last week
        notif(ticket_c, created_at: Time.zone.local(2026, 11, 9, 0, 30)) # Monday
        notif(ticket_b, created_at: Time.zone.local(2026, 11, 10, 9)) # yesterday
        notif(ticket_a, created_at: Time.zone.local(2026, 11, 11, 0, 5)) # today

        grouped = build.grouped_notifications

        expect(grouped.keys).to eq(%i[today yesterday this_week older])
        expect(grouped.transform_values { |reps| reps.map(&:notifiable_id) })
          .to eq(today: [ticket_a.id], yesterday: [ticket_b.id], this_week: [ticket_c.id], older: [ticket_d.id])
      end
    end

    it 'zählt gestern als gestern, auch wenn gestern in der Vorwoche lag' do
      travel_to Time.zone.local(2026, 11, 9, 12) do # Monday
        notif(ticket_a, created_at: Time.zone.local(2026, 11, 8, 12)) # Sunday

        expect(build.grouped_notifications.keys).to eq([:yesterday])
      end
    end
  end

  describe 'chronologischer View (kein Bündeln)' do
    it 'rendert jede Notification einzeln' do
      notif(ticket_a, created_at: 2.hours.ago)
      notif(ticket_a, created_at: 1.hour.ago)

      presenter = build(view_mode: 'chronological')
      expect(presenter.notifications.size).to eq(2)
    end
  end
end
