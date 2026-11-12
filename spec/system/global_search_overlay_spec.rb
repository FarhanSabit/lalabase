# frozen_string_literal: true

require 'rails_helper'

# Stage 1 interaction: the labelled "Suche" nav item opens a body-level overlay; the close
# button, Escape, and the Cmd/Ctrl+K shortcut all drive it via search_overlay_controller.
#
# NOTE: the default system driver disables CSS, so we assert on the `hidden` class
# (toggled by the controller) instead of Capybara visibility — same approach as
# time_sessions_modal_spec.
RSpec.describe 'Global search overlay', type: :system do
  before { Prosopite.pause }
  after  { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
    # Search lives in the app sidebar; Appearance has the management sidebar.
    visit organisation_root_path(organisation)
  end

  def overlay
    page.find('[data-search-overlay-target="overlay"]', visible: :all)
  end

  it 'starts closed and opens when clicking the "Suche" nav item' do
    expect(overlay[:class]).to include('hidden')
    find('[data-action="search-overlay#open"]').click
    expect(overlay[:class]).not_to include('hidden')
  end

  it 'closes the overlay via the close button' do
    find('[data-action="search-overlay#open"]').click
    expect(overlay[:class]).not_to include('hidden')
    find('[data-action="click->search-overlay#close"]').click
    expect(overlay[:class]).to include('hidden')
  end

  it 'closes the overlay on Escape' do
    find('[data-action="search-overlay#open"]').click
    expect(overlay[:class]).not_to include('hidden')
    find('body').send_keys(:escape)
    expect(overlay[:class]).to include('hidden')
  end

  it 'closes the overlay when the backdrop (not the panel) is clicked' do
    find('[data-action="search-overlay#open"]').click
    expect(overlay[:class]).not_to include('hidden')

    # Click inside the panel -> closeOnBackdrop must NOT close (panel containment guard).
    page.execute_script(%{document.querySelector('[data-search-overlay-target="panel"]').click()})
    expect(overlay[:class]).not_to include('hidden')

    # Click the overlay backdrop (container outside the panel) -> closes.
    page.execute_script(%{document.querySelector('[data-search-overlay-target="overlay"]').click()})
    expect(overlay[:class]).to include('hidden')
  end

  it 'toggles the overlay open and shut via the Cmd/Ctrl+K shortcut' do
    # Find the trigger first so the controller is connected (the keydown listener is
    # attached in connect()) before we dispatch the synthetic event — avoids a flake
    # where the event fires before mount.
    find('[data-action="search-overlay#open"]')
    expect(overlay[:class]).to include('hidden')

    cmd_k = %{document.dispatchEvent(new KeyboardEvent('keydown', { key: 'k', metaKey: true }))}
    page.execute_script(cmd_k)
    expect(overlay[:class]).not_to include('hidden')

    page.execute_script(cmd_k) # press again -> toggle shut
    expect(overlay[:class]).to include('hidden')
  end

  context 'when search is pinned (Stage 2b)' do
    before do
      user.sidebar_pins.pin_global!(organisation, 'search')
      visit organisation_root_path(organisation)
    end

    it 'renders the persistent inline search bar' do
      expect(page).to have_css('#global-search-inline-bar', visible: :all)
    end

    it 'focuses the inline bar text input instead of opening the overlay on the "Suche" item' do
      find('[data-action="search-overlay#open"]').click

      expect(overlay[:class]).to include('hidden')
      # Assert the focused element IS the inline bar's text input — not merely "somewhere
      # in the bar" (which a loose closest() check would also accept for the select/button).
      focused_text_input = page.evaluate_script(
        %{!!(document.activeElement && document.activeElement.matches('#global-search-inline-bar input[type="text"]'))}
      )
      expect(focused_text_input).to be true
    end
  end
end
