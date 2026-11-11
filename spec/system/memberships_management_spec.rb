# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Membership management browser interactions', type: :system do
  before do
    @previous_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    driven_by :selenium_chrome_headless_full
    page.driver.browser.execute_cdp('Emulation.clearDeviceMetricsOverride')
    page.current_window.resize_to(1440, 1100)
    @organisation = create(:organisation, name: 'UX Demo Agentur')
    @admin = create(:user, first_name: 'Guido', last_name: 'Boyke', email: 'guido@example.com')
    ActsAsTenant.with_tenant(@organisation) do
      @role = create(:role, organisation: @organisation, title: 'Standard-Benutzer')
      @other_role = create(:role, organisation: @organisation, title: 'Projektleitung')
      create(:membership, organisation: @organisation, user: @admin, role: create(:admin_role, organisation: @organisation))
      @member = create(:user, first_name: 'Anna', last_name: 'Berg', email: 'anna@example.com')
      @membership = create(:membership, organisation: @organisation, user: @member, role: @role)
      %w[Klein Roth Weiss Schulz].each_with_index do |name, index|
        create(:membership, organisation: @organisation, role: @role, active: index != 2,
                            user: create(:user, first_name: %w[Ben Carla David Eva][index], last_name: name))
      end
      @invitation = create(:invitation, organisation: @organisation, inviter: @admin, email: 'einladung@example.com', sent_at: Time.current)
    end
    login_as(@admin, scope: :user)
  end

  after { ActiveJob::Base.queue_adapter = @previous_queue_adapter }

  it 'changes roles and access in place, keeps context and supports keyboard close and browser back' do
    visit organisation_memberships_path(@organisation)
    page.execute_script("localStorage.setItem('lb-theme', 'light')")
    page.refresh
    expect(page).to have_css('.members-row', count: 6)
    capture_memberships('list')
    within("#membership_#{@membership.id}") { select 'Projektleitung' }
    expect(page).to have_css('[role="status"]', text: 'Mitgliedschaft')
    expect(@membership.reload.role_id).to eq(@other_role.id)
    expect(page).not_to have_css('.members-panel')

    find("#membership_#{@membership.id} [data-member-link]").click
    expect(page).to have_css('.members-panel', text: 'Anna Berg')
    expect(page).to have_current_path(/membership_id=#{@membership.id}/)
    expect(page).to have_css('.members-row--selected', count: 1)
    expect(page.evaluate_script("getComputedStyle(document.querySelector('.members-row--selected')).backgroundColor")).not_to eq(page.evaluate_script("getComputedStyle(document.querySelector('.members-row:not(.members-row--selected)')).backgroundColor"))
    capture_memberships('panel')
    within('.members-panel') { select 'gesperrt', from: 'Zugang' }
    expect(page).to have_css('.members-row--selected', text: 'gesperrt')
    expect(@membership.reload).not_to be_active
    within('.members-panel') { click_link 'Fertig' }
    expect(page).not_to have_css('.members-panel')
    expect(page).to have_current_path(%r{/memberships(?:\?items=20)?\z})
    page.go_back
    expect(page).to have_current_path(/membership_id=#{@membership.id}/)
    expect(page).to have_css('.members-panel', text: 'Anna Berg')
    find('.members-panel a[aria-label="Mitgliedschaft schließen"]').send_keys(:escape)
    expect(page).not_to have_css('.members-panel')

    page.current_window.resize_to(390, 844)
    page.driver.browser.execute_cdp('Emulation.setDeviceMetricsOverride', width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    find("#membership_#{@membership.id} [data-member-link]").click
    expect(page).to have_css('.members-panel', text: 'Anna Berg')
    capture_memberships('mobile')
    expect(page.evaluate_script('document.documentElement.scrollWidth <= window.innerWidth')).to be true
  end

  it 'keeps initials when an avatar fails and closes action menus with Escape' do
    @member.avatar.attach(io: Rails.root.join('spec/fixtures/files/test_avatar.png').open, filename: 'avatar.png', content_type: 'image/png')
    visit organisation_memberships_path(@organisation)
    row = "#membership_#{@membership.id}"
    expect(page).to have_css("#{row} .neo-user-avatar img")
    page.execute_script("document.querySelector(arguments[0]).dispatchEvent(new Event('error'))", "#{row} img")
    expect(page).to have_css("#{row} [data-avatar-fallback-target='initials']", text: 'AB')
    expect(page).not_to have_css("#{row} img")
    find("#{row} summary").click
    expect(page).to have_link('Aktivität ansehen')
    find("#{row} summary").send_keys(:escape)
    expect(page).not_to have_link('Aktivität ansehen')
    expect(page).not_to have_css('.members-panel')
  end

  it 'copies an invitation on demand and confirms resending and withdrawing separately' do
    visit organisation_memberships_path(@organisation)
    # Capture the browser clipboard write without requiring OS clipboard permission.
    page.execute_script(<<~JS)
      window.invitationClipboard = null;
      Object.defineProperty(navigator, 'clipboard', { configurable: true, value: {
        write: async (items) => { window.invitationClipboard = await (await items[0].getType('text/plain')).text(); }
      }});
    JS
    within('#pending-invitations') do
      find('summary').click
      click_button 'Link kopieren'
      expect(page).to have_button('kopiert')
      expect(page.evaluate_script('window.invitationClipboard')).to include(@invitation.token)
      expect(page).not_to have_text(@invitation.token)
      dismiss_confirm { click_button 'Erneut senden' }
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs).to be_empty
      accept_confirm { click_button 'Erneut senden' }
    end
    expect(page).to have_css('[role="status"]', text: 'Einladung')
    # Ask for the delivery job instead of naming the Rails class: since 19.09.2026
    # the mails run through MailDeliveryJob (keeps tokens out of the log),
    # and a comparison against ActionMailer::MailDeliveryJob then counted zero.
    expect(ActiveJob::Base.queue_adapter.enqueued_jobs.count { |job| job[:job] == ActionMailer::Base.delivery_job }).to eq(1)
    within('#pending-invitations') do
      find('summary').click
      accept_confirm { click_button 'Einladung zurückziehen …' }
    end
    expect(page).not_to have_css('#pending-invitations')
  end

  it 'removes a membership from the lane and keeps reload on the member list' do
    visit organisation_memberships_path(@organisation, membership_id: @membership.id)
    expect(page).to have_css('#members_count', text: '6', exact_text: true)
    within('.members-panel') do
      accept_confirm(/Zuweisungen bleiben bestehen/) { click_button 'Aus der Organisation entfernen …' }
    end
    expect(page).not_to have_css("#membership_#{@membership.id}")
    expect(page).to have_current_path(organisation_memberships_path(@organisation))
    expect(page).to have_css('#members_count', text: '5', exact_text: true)
    page.refresh
    expect(page).to have_css('.members-row', count: 5)
    expect(page).not_to have_css('.members-panel')
  end

  def capture_memberships(view)
    # Review artifacts for this UI change, including the responsive lane.
    page.save_screenshot(Rails.root.join("tmp/memberships-#{view}.png")) # rubocop:disable Lint/Debugger
  end
end
