# frozen_string_literal: true

# What: Request spec for "Eigene Konfiguration" — the setup screen behind the
#   catalogue's own-configuration card (doc/ki_bereich_navigation_plan.md S7, E6-A).
# Type: Request spec — authorization, the per-provider form, and the three writes.
# Why (philosophy): The screen replaces a form that carried five of the plan's thirteen
#   gaps, and four of them are only observable at the request level: which FIELDS a
#   provider gets (L7), that "prüfen" runs after the save rather than before it (L5/E3),
#   that a save never removes a key while an explicit action does (L3/E2), and that the
#   verdict outlives the flash (L10). A "renders successfully" test would pass for a
#   screen with none of that.
# Contract: account_admin only; fields are rendered per provider and the ones that do
#   not apply are neither shown nor submitted; PATCH writes through the Actor and
#   optionally probes; DELETE is the only way a key leaves.

require 'rails_helper'

RSpec.describe 'Organisations::AiConfigurations', type: :request do
  let(:organisation) { create(:organisation, :ai_disabled) }
  let(:admin) { create(:user) }
  let(:member) { create(:user) }
  let(:openai_key) { "sk-#{'x' * 30}" }

  let(:admin_role) { ActsAsTenant.with_tenant(organisation) { create(:admin_role, organisation: organisation) } }
  let(:member_role) { ActsAsTenant.with_tenant(organisation) { create(:role, organisation: organisation) } }

  let!(:admin_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
    end
  end
  let!(:member_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: member, organisation: organisation, role: member_role, active: true)
    end
  end

  def stub_probe(answer)
    probe = instance_double(Lalabase::Llm::OpenAiProvider)
    allow(probe).to receive(:connectivity_check) { answer.is_a?(Exception) ? raise(answer) : answer }
    allow(Lalabase::Llm::Factory).to receive(:chat_probe).and_return(probe)
  end

  describe 'as account_admin' do
    before { sign_in admin }

    describe 'GET #show — the per-provider fields (L7)' do
      # ai_api_base and preferred_chat_model had ZERO occurrences in app/views before
      # S7 while the Factory read both. Their presence is the whole of L7, so it is
      # asserted by name rather than by "the form renders".
      it 'renders the endpoint and model fields an openai_compatible access needs' do
        organisation.update!(ai_provider: 'openai_compatible')

        get organisation_ai_configuration_path(organisation)

        expect(response.body).to include('name="ai_api_base"')
        expect(response.body).to include('name="preferred_chat_model"')
      end

      # The DISABLED half is what decides what gets SUBMITTED — a hidden field still
      # posts. Without it, switching to OpenAI would keep re-submitting the endpoint the
      # form no longer shows, and that is precisely where the key would keep going.
      it 'disables the endpoint fields for a provider that has no endpoint' do
        organisation.update!(ai_provider: 'openai')

        get organisation_ai_configuration_path(organisation)

        expect(response.body).to match(/id="ai_api_base_field"[^>]*disabled|disabled[^>]*id="ai_api_base_field"/)
      end

      # A password field with an "sk-…" placeholder is the wrong widget for Vertex: it
      # takes a multi-line service-account JSON, and an API key there would silently use
      # the GLOBAL endpoint and void EU data residency.
      it 'offers a textarea rather than a key field for google' do
        organisation.update!(ai_provider: 'google')

        get organisation_ai_configuration_path(organisation)

        expect(response.body).to include('<textarea')
        expect(response.body).to include('id="ai_access_token_json"')
      end

      # The third occurrence of the "AI is off" box, and the reason it became a partial
      # with ONE string set. Deliberately NOT a blocker here: "erst konfigurieren, dann
      # anschalten" is the natural order, so the screen states the fact and stays usable.
      it 'names the switched-off state with the shared notice, without blocking the form' do
        get organisation_ai_configuration_path(organisation)

        expect(response.body).to include(I18n.t('views.organisations.ai_overview.disabled_notice.title'))
        expect(response.body).to include('id="ai_configuration_form"')
      end

      # Same regression as on the hub card, on the page the check date is FOR: L10
      # persists the verdict so that its age can be judged, and `time.formats.short`
      # ("%d %b %H:%M") drops the one component that makes an age readable. Asserts the
      # year literally rather than re-deriving the view's own `format:`, which would
      # follow the view into any format and prove nothing.
      it 'names the year of the stored check, so an old verdict cannot read as today' do
        organisation.update!(ai_provider: 'openai', ai_access_token: openai_key,
                             ai_connection_status: Organisation::AI_CONNECTION_OK,
                             ai_connection_checked_at: Time.zone.local(2024, 3, 5, 14, 32))

        get organisation_ai_configuration_path(organisation)

        expect(response.body).to include('2024')
      end

      it 'never echoes the stored key back, not even masked into an input' do
        organisation.update!(ai_provider: 'openai', ai_access_token: openai_key)

        get organisation_ai_configuration_path(organisation)

        expect(response.body).not_to include(openai_key)
        expect(response.body).to include(%(value="" autocomplete="off"))
      end
    end

    # A page below the Zugang tab (doc/verwaltung_seitennavigation_plan.md §5, S3): the
    # head names the AI section and marks Zugang as the parent of the page, and the
    # crumb leads back to Zugang and names the page. Zugang is the parent because the
    # door to this screen is on it; the hub only lists it.
    describe 'GET #show: its place in the AI section' do
      it 'keeps the head of the AI section, Zugang marked as its parent, and leads back to Zugang' do
        access = I18n.t('views.organisations.ai_overview.pages.access')

        get organisation_ai_configuration_path(organisation)

        doc = Nokogiri::HTML(response.body)
        expect(doc.css('main h1').map { |h1| h1.text.squish }).to eq([I18n.t('settings.ai')])
        marked = doc.css('main nav:not([data-section-crumb]) [aria-current]')
        expect(marked.map { |tab| [tab.text.squish, tab['aria-current']] }).to eq([[access, 'true']])
        back = doc.at_css('main [data-section-crumb] a')
        expect(back['href']).to eq(organisation_ai_settings_path(organisation))
        expect(back.text.delete('‹').squish).to eq(access)
        expect(doc.css('main [aria-current="page"]').map { |item| item.text.squish })
          .to eq([I18n.t('views.organisations.ai_overview.configuration.title')])
      end
    end

    describe 'PATCH #update' do
      it 'stores an own access through the Actor' do
        patch organisation_ai_configuration_path(organisation),
              params: { ai_provider: 'openai', ai_access_token: openai_key, ai_organization_id: 'org-1' }

        expect(response).to redirect_to(organisation_ai_configuration_path(organisation))
        expect(organisation.reload).to have_attributes(ai_provider: 'openai', ai_organization_id: 'org-1')
      end

      # L13's last third: this write is the third and final site of the AI protocol, and
      # it was the one that left no trace at all before S7.
      it 'leaves a protocol row' do
        expect do
          patch organisation_ai_configuration_path(organisation),
                params: { ai_provider: 'openai', ai_access_token: openai_key }
        end.to change {
          ActsAsTenant.with_tenant(organisation) { Activity.where(action: AiConfigurationAudit::ACTION).count }
        }.by(1)
      end

      # L3/E2: the defect the old #update carried — one click on "system credentials"
      # and a key most providers never show again was gone, silently.
      it 'keeps the stored key when the form leaves the field empty' do
        organisation.update!(ai_provider: 'openai', ai_access_token: openai_key)

        patch organisation_ai_configuration_path(organisation),
              params: { ai_provider: 'openai', ai_access_token: '', ai_organization_id: 'org-2' }

        expect(organisation.reload.ai_access_token).to eq(openai_key)
        expect(organisation.ai_organization_id).to eq('org-2')
      end

      # ⚠️ The hidden-blank mechanism, measured through the browser's eyes: the form
      # posts an empty ai_api_base BEFORE the real field, and only the enabled field
      # overwrites it. Without that, a column the form no longer shows for the selected
      # provider keeps whatever an earlier provider left behind — and for ai_api_base
      # that leftover is where the key would keep being sent, invisibly, since the
      # OpenAI form has no endpoint field to reveal it.
      it 'clears a field the selected provider does not use' do
        organisation.update!(ai_provider: 'openai_compatible', ai_access_token: 'key-123',
                             ai_api_base: 'https://old.example/v1', preferred_chat_model: 'm')

        # Exactly what the rendered OpenAI form submits: the three blank defaults, with
        # only ai_organization_id overwritten by its visible field.
        patch organisation_ai_configuration_path(organisation),
              params: { ai_provider: 'openai', ai_access_token: openai_key,
                        ai_organization_id: 'org-1', ai_api_base: '', preferred_chat_model: '' }

        expect(organisation.reload).to have_attributes(ai_api_base: nil, preferred_chat_model: nil)
      end

      it 'renders the blank defaults that make that clearing possible' do
        organisation.update!(ai_provider: 'openai')

        get organisation_ai_configuration_path(organisation)

        %w[ai_api_base preferred_chat_model ai_organization_id].each do |field|
          expect(response.body).to include(%(type="hidden" name="#{field}" value=""))
        end
      end

      it 're-renders with the message when the Actor refuses' do
        patch organisation_ai_configuration_path(organisation),
              params: { ai_provider: 'openai_compatible', ai_access_token: 'key-123' }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include('Endpunkt-URL')
        expect(organisation.reload.ai_provider).not_to eq('openai_compatible')
      end
    end

    describe 'PATCH #update with "Speichern und prüfen" (E3-A)' do
      # THE ordering assertion of the slice. L5's complaint was that the probe read the
      # STORED configuration while the button sat under a freshly typed key — so it
      # tested the old one and reported success. Saving first is what makes the two the
      # same thing, and the probe's argument is the record after the write.
      it 'probes the configuration it has just written, not the one before it' do
        seen = nil
        allow(Lalabase::Llm::Factory).to receive(:chat_probe) do |org|
          seen = org.ai_organization_id
          instance_double(Lalabase::Llm::OpenAiProvider, connectivity_check: true)
        end

        patch organisation_ai_configuration_path(organisation),
              params: { ai_provider: 'openai', ai_access_token: openai_key,
                        ai_organization_id: 'org-new', check: '1' }

        expect(seen).to eq('org-new')
      end

      it 'reports the probe in the flash and records its verdict' do
        stub_probe(true)

        patch organisation_ai_configuration_path(organisation),
              params: { ai_provider: 'openai', ai_access_token: openai_key, check: '1' }

        expect(flash[:notice]).to eq(I18n.t('flash.ai_settings.connection_success', provider: 'OpenAI (GPT)'))
        expect(organisation.reload.ai_connection_ok?).to be(true)
      end

      it 'saves the access even when the probe fails' do
        stub_probe(Lalabase::Llm::Provider::AuthError.new('401'))

        patch organisation_ai_configuration_path(organisation),
              params: { ai_provider: 'openai', ai_access_token: openai_key, check: '1' }

        expect(flash[:alert]).to be_present
        expect(organisation.reload.ai_access_token).to eq(openai_key)
        expect(organisation.ai_connection_failed?).to be(true)
      end

      # The plain save must NOT reach the network: a save that depends on whether a
      # stranger's endpoint feels like answering is not a save.
      it 'does not probe without the flag' do
        allow(Lalabase::Llm::Factory).to receive(:chat_probe)

        patch organisation_ai_configuration_path(organisation),
              params: { ai_provider: 'openai', ai_access_token: openai_key }

        expect(Lalabase::Llm::Factory).not_to have_received(:chat_probe)
      end
    end

    describe 'DELETE #destroy — "Zugang entfernen" (E2a)' do
      before { organisation.update!(ai_provider: 'openai', ai_access_token: openai_key) }

      it 'is the way a key leaves, and it works' do
        delete organisation_ai_configuration_path(organisation)

        expect(response).to redirect_to(organisation_ai_configuration_path(organisation))
        expect(flash[:notice]).to eq(I18n.t('flash.ai_configurations.removed'))
        expect(organisation.reload.ai_access_token).to be_nil
      end

      # ── The failure path, which the action did not have. Forced rather than provoked
      # on purpose: in dev/test BaseActor RE-RAISES unexpected errors, so a real defect
      # here shows up as a crash in the suite and as a plain failure Result in
      # production — the one environment where the difference matters is the one no
      # example runs in. Stubbing the Result is what puts the production shape under
      # test.
      #
      # Measured before the fix: success flash, no alert, token still stored. On an
      # action whose dialog promises the removal cannot be undone, that is the lie that
      # makes the admin stop looking.
      it 'says so instead of claiming success when the Actor fails' do
        allow(Actors::RemoveAiConfiguration).to receive(:call)
          .and_return(Actors::BaseActor::Result.new(success: false, errors: ['Entfernen fehlgeschlagen.']))

        delete organisation_ai_configuration_path(organisation)

        expect(flash[:notice]).to be_blank
        expect(flash[:alert]).to eq('Entfernen fehlgeschlagen.')
        expect(organisation.reload.ai_access_token).to eq(openai_key)
      end

      # The button must not exist where there is nothing to remove — a destructive
      # action in an empty state is an invitation to find out what it does.
      it 'is offered only once there is an access to remove' do
        get organisation_ai_configuration_path(organisation)
        expect(response.body).to include(I18n.t('views.organisations.ai_overview.configuration.remove_button'))

        organisation.update!(ai_access_token: nil)
        get organisation_ai_configuration_path(organisation)
        expect(response.body).not_to include(I18n.t('views.organisations.ai_overview.configuration.remove_button'))
      end
    end
  end

  describe 'as regular member (not account_admin)' do
    before { sign_in member }

    # Stricter than the read-only pages of the area have to be: this screen shows the
    # masked key and writes the columns every AI call routes on.
    it 'is denied the screen' do
      get organisation_ai_configuration_path(organisation)

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to be_present
    end

    it 'is denied the write' do
      patch organisation_ai_configuration_path(organisation),
            params: { ai_provider: 'openai', ai_access_token: openai_key }

      expect(organisation.reload.ai_access_token).to be_nil
    end

    it 'is denied the removal' do
      organisation.update!(ai_provider: 'openai', ai_access_token: openai_key)

      delete organisation_ai_configuration_path(organisation)

      expect(organisation.reload.ai_access_token).to eq(openai_key)
    end
  end

  # The door the custom pane opens. Without it the screen exists but is unreachable,
  # which is the state §3.4 describes as "die Wahl ohne die Einrichtung dahinter".
  describe 'reachability from the package catalogue' do
    before { sign_in admin }

    # ?package_mode=custom opens the pane the door lives in since
    # doc/ki_zugang_umbau_plan.md D6 — the page shows one way at a time now.
    it 'is linked from the own-configuration pane' do
      get organisation_ai_settings_path(organisation, package_mode: 'custom')

      expect(response.body).to include(organisation_ai_configuration_path(organisation))
    end

    # E6-A: "danach gibt es EINE Tür". Proved POSITIVELY rather than assumed from the
    # absence of a form — the route was the unguarded write path, and a route left
    # behind by accident answers hand-built POSTs long after its form is gone.
    #
    # Asked of the ROUTER rather than by sending a request: this environment renders
    # routing failures as a 404 page instead of raising, and a 404 is also what a
    # membership check answers — the two would be indistinguishable, so the example
    # would pass whether or not the route still existed.
    it 'no longer answers the old write route on the settings page' do
      settings_path = organisation_ai_settings_path(organisation)

      expect { Rails.application.routes.recognize_path(settings_path, method: :patch) }
        .to raise_error(ActionController::RoutingError)
      # The counter-proof: the page itself is still reachable, so the expectation above
      # is about the WRITE and not about a path that stopped existing altogether.
      expect(Rails.application.routes.recognize_path(settings_path, method: :get))
        .to include(controller: 'organisations/ai_settings', action: 'show')
    end
  end
end
