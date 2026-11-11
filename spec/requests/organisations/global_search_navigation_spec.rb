# frozen_string_literal: true

require 'rails_helper'

# Stage 1 of the global-search redesign: the search entry point moved from a tiny icon
# beside the logo into a LABELLED "Suche" item in the org navigation that opens a
# body-level overlay (search_overlay_controller). This request spec pins the server-rendered
# wiring without JS:
#   - the labelled nav button is present and wired to the overlay controller's #open
#   - the search-overlay controller is mounted on <body> (common ancestor of trigger + overlay)
#   - the overlay is rendered ONCE at body level with the shared search form
#   - the OLD logo icon trigger (sidebar-search) is gone -> regression guard against re-adding it
#
# Access follows the search feature gate: policy(Project).index? || policy(TimeSession).index?.
RSpec.describe 'Global search navigation (Stage 1)', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
  end

  # Parse the rendered layout so assertions can target the exact element, not a bare
  # substring — the label "Suche"/"Search" also appears elsewhere in the chrome.
  def nav_doc
    Nokogiri::HTML(response.body)
  end

  context 'user with project/time access (account admin)' do
    let(:role) { create(:admin_role, organisation: organisation) }
    let!(:membership) do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user, organisation: organisation, role: role, active: true)
      end
    end

    # An app page: on a page of the management area the sidebar lists its sections
    # instead of the app's entries since 2026-11-11 (common/_navigation_management),
    # where the search would be missing for everybody.
    before { get organisation_notifications_path(organisation, state_filters: %w[read unread]) }

    it 'renders the labelled "Suche" nav button wired to the overlay controller' do
      expect(response).to have_http_status(:ok)
      button = nav_doc.at_css('li#global-search-nav button[data-action="search-overlay#open"]')
      expect(button).to be_present
      # The visible LABEL (not just an icon) is the whole point of the redesign — assert it
      # lives INSIDE the button, so a stray "Suche" elsewhere in the chrome can't pass this.
      expect(button.text).to include(I18n.t('navigation.search'))
    end

    it 'renders the pin toggle as a PATCH form to the search-pin path' do
      # button_to renders <form method="post"> + a hidden _method=patch. Pin the method
      # and target path so a regression to GET / the wrong route fails here, not silently
      # in the (behaviour-only) system spec which seeds pins directly.
      form = nav_doc.at_css(
        %(li#global-search-nav form[action="#{organisation_search_pin_path(organisation_id: organisation.id)}"])
      )
      expect(form).to be_present
      expect(form.at_css('input[name="_method"]')[:value]).to eq('patch')
    end

    it 'mounts the search-overlay controller on <body>' do
      expect(response.body).to match(/<body[^>]*data-controller="[^"]*search-overlay/)
    end

    it 'renders the overlay once at body level with the shared search form' do
      expect(response.body).to include('data-search-overlay-target="overlay"')
      expect(response.body.scan('data-search-overlay-target="overlay"').size).to eq(1)
      expect(response.body).to include('name="power_search_query"')
      expect(response.body).to include(organisation_power_search_path(organisation_id: organisation.id))
    end

    it 'titles the overlay with the organisation name to signal org-wide scope' do
      heading = nav_doc.at_css('[data-search-overlay-target="overlay"] h2')
      expect(heading).to be_present
      expect(heading.text).to include(organisation.name)
    end

    it 'no longer renders the old logo search icon (regression guard)' do
      expect(response.body).not_to include('sidebar-search')
    end
  end

  context 'user without project/time access' do
    let(:role) { create(:role, organisation: organisation, title: 'no_access') }
    let!(:membership) do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user, organisation: organisation, role: role, active: true)
      end
    end

    # An app page: on a page of the management area the sidebar lists its sections
    # instead of the app's entries since 2026-11-11 (common/_navigation_management),
    # where the search would be missing for everybody.
    before { get organisation_notifications_path(organisation, state_filters: %w[read unread]) }

    it 'does not render the search nav button' do
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('data-action="search-overlay#open"')
    end

    it 'does not render the overlay' do
      expect(response.body).not_to include('data-search-overlay-target="overlay"')
    end
  end
end
