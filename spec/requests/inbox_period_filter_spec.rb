# frozen_string_literal: true

require 'rails_helper'

# What: a period filter in the inbox, like the time list's (user, 2026-11-10),
#       "gesamter Zeitraum" chosen by default. The periods are the time
#       area's (TimeSessions::ListPeriod: the eight presets, their order,
#       labels and bounds), not a second list; a notification counts by the
#       day it arrived in the reader's time zone.
#       The period narrows like search and project: it travels with every
#       link of the list, survives the streams of a row action, and the empty
#       list's reset drops it.
RSpec.describe 'Inbox period filter', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before { Prosopite.pause } # pre-existing N+1 in the render path
  after  { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, timezone: 'Berlin') }
  let(:role) { create(:admin_role, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  def notification_for(title, created_at:)
    ticket = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, title: title) }
    ActsAsTenant.with_tenant(organisation) do
      create(:notification,
             recipient: user, organisation: organisation, project: project, notifiable: ticket,
             event_type: 'ticket_commented', channel: 'in_app', state: :delivered, created_at: created_at)
    end
  end

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
  end

  after { ActsAsTenant.current_tenant = nil }

  def shown_ids
    controller.instance_variable_get(:@notifications).map(&:id)
  end

  def list_page(**params)
    get organisation_notifications_path(organisation, state_filters: %w[read unread], **params)
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  describe 'the select' do
    it 'offers the eight periods of the time area, "Gesamter Zeitraum" chosen' do
      select = list_page.at_css('select[name="period"]')

      expect(select).to be_present
      expect(select.css('option').map { |option| option['value'] }).to eq(TimeSessions::ListPeriod::KEYS)
      expect(select.css('option').map(&:text)).to eq(TimeSessions::ListPeriod::KEYS.map { |key|
        TimeSessions::ListPeriod.label(key).upcase_first
      })
      expect(select.at_css('option[selected]')['value']).to eq('all')
    end

    it 'marks the chosen period, and the search form carries it' do
      doc = list_page(period: 'this_month')

      expect(doc.at_css('select[name="period"] option[selected]')['value']).to eq('this_month')
      expect(doc.at_css('form.inbox-search input[type="hidden"][name="period"]')['value']).to eq('this_month')
    end
  end

  describe 'the rows' do
    # Monday 2026-11-09, 00:30 in Berlin = Sunday 23:30 UTC.
    around { |example| travel_to(Time.utc(2026, 11, 8, 23, 30)) { example.run } }

    let!(:this_week) { notification_for('Diese Woche', created_at: Time.utc(2026, 11, 8, 23, 10)) }
    let!(:last_month) { notification_for('Letzter Monat', created_at: Time.utc(2026, 10, 2, 12)) }
    let!(:years_ago) { notification_for('Vor Jahren', created_at: Time.utc(2024, 3, 1, 12)) }

    it 'shows every notification by default' do
      list_page

      expect(shown_ids).to contain_exactly(this_week.id, last_month.id, years_ago.id)
    end

    it "counts a notification by its day in the reader's time zone" do
      # 23:10 UTC on Sunday is 00:10 on Monday in Berlin: this week there.
      list_page(period: 'this_week')

      expect(shown_ids).to eq([this_week.id])
    end

    it 'narrows to the last 90 days' do
      list_page(period: '90_days')

      expect(shown_ids).to contain_exactly(this_week.id, last_month.id)
    end

    it 'takes an unknown period for the whole time' do
      list_page(period: 'gestern')

      expect(shown_ids).to contain_exactly(this_week.id, last_month.id, years_ago.id)
    end

    it 'keeps the period when a row action redraws the list' do
      patch mark_read_organisation_notification_path(organisation, last_month),
            headers: { 'Accept' => 'text/vnd.turbo-stream.html',
                       'Referer' => "http://www.example.com#{organisation_notifications_path(organisation, state_filters: %w[read unread], period: 'this_week')}" }

      list = Nokogiri::HTML(response.body.scan(%r{<template>(.*?)</template>}m).flatten.join)
      titles = list.css('.inbox-row__title').map { |title| title.text.strip }
      expect(titles).to eq(['Diese Woche'])
    end

    it 'counts as narrowing: a list empty by the period alone offers to drop it' do
      this_week.destroy!
      doc = list_page(period: 'this_week')

      expect(controller.instance_variable_get(:@presenter).empty_reason).to eq(:no_match)
      reset = doc.at_css('.inbox-empty a')['href']
      expect(reset).not_to include('period')
      expect(reset).not_to include('search')
    end
  end
end
