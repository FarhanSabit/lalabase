# frozen_string_literal: true

# What: Request spec for the GDPR org-level AI opt-in (audit 2026-07-03, 1.2).
# Type: Request spec — authorization + activation bookkeeping.
# Why (philosophy): The opt-in is the LEGAL basis documentation for every AI
#   transfer: activation must be admin-only and must record who activated when.
#   Deactivation keeps that history (audit trail); re-activation overwrites it
#   so the record always documents the LATEST activation. Non-admin members
#   must not be able to flip the switch (app convention: Pundit denial →
#   redirect with not_authorized flash, never a silent success).
# Contract: POST activate/deactivate on /org/:id/ai_settings is account_admin
#   only; activate stamps ai_activated_at + ai_activated_by, deactivate only
#   clears ai_enabled.

require 'rails_helper'

RSpec.describe 'Organisations::AiSettings activation (GDPR AI opt-in)', type: :request do
  let(:organisation) { create(:organisation, :ai_disabled) }
  let(:admin) { create(:user) }
  let(:member) { create(:user) }

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

  describe 'as account_admin' do
    before { sign_in admin }

    it 'activates AI and records timestamp + acting admin' do
      post activate_organisation_ai_settings_path(organisation)

      expect(response).to redirect_to(organisation_ai_overview_path(organisation))
      organisation.reload
      expect(organisation.ai_enabled).to be(true)
      expect(organisation.ai_activated_at).to be_present
      expect(organisation.ai_activated_by).to eq(admin)
    end

    it 'deactivates AI but keeps the activation history' do
      organisation.update!(ai_enabled: true, ai_activated_at: 2.days.ago, ai_activated_by: admin)

      post deactivate_organisation_ai_settings_path(organisation)

      expect(response).to redirect_to(organisation_ai_overview_path(organisation))
      organisation.reload
      expect(organisation.ai_enabled).to be(false)
      expect(organisation.ai_activated_at).to be_present
      expect(organisation.ai_activated_by).to eq(admin)
    end

    # D2 decision: activation triggers the backfill automatically — content
    # skipped while disabled must not stay invisible to RAG/search until an
    # admin happens to find the sync page. The WHAT (revive filter, flag-
    # filtered embeddings) is unit-tested in embeddings/activation_backfill_spec;
    # this request test pins the WHEN: activate — and only activate — runs it.
    it 'runs the activation backfill exactly on activate' do
      allow(Embeddings::ActivationBackfill).to receive(:call)

      post activate_organisation_ai_settings_path(organisation)

      expect(Embeddings::ActivationBackfill).to have_received(:call).with(organisation)
    end

    it 'does NOT run the backfill on deactivate' do
      organisation.update!(ai_enabled: true, ai_activated_at: Time.current, ai_activated_by: admin)
      allow(Embeddings::ActivationBackfill).to receive(:call)

      post deactivate_organisation_ai_settings_path(organisation)

      expect(Embeddings::ActivationBackfill).not_to have_received(:call)
    end

    it 're-activation overwrites the previous activation record' do
      previous_admin = create(:user)
      old_time = 3.weeks.ago
      organisation.update!(ai_enabled: false, ai_activated_at: old_time, ai_activated_by: previous_admin)

      post activate_organisation_ai_settings_path(organisation)

      organisation.reload
      expect(organisation.ai_activated_by).to eq(admin)
      expect(organisation.ai_activated_at).to be > old_time
    end

    # S0 of doc/ki_bereich_navigation_plan.md (E5/L13). The switch writes with
    # update_columns and Organisation is not trackable, so no callback produces this
    # row — it exists only because the action writes it explicitly. And it is the only
    # lasting trace: ai_activated_at/_by hold the LATEST activation, so without these
    # rows every earlier one is overwritten and gone.
    describe 'the opt-in protocol' do
      # Deliberately tenant-SCOPED, not Activity.unscoped: the row landing in the right
      # mandant is one of the things #log_ai_switch's with_tenant exists to guarantee,
      # and an unscoped lookup would find a misfiled row just as happily as a correct
      # one — the assertion could never fail for the reason it was written.
      def last_activity(action)
        ActsAsTenant.with_tenant(organisation) { Activity.where(action: action).order(:created_at).last }
      end

      # Both models are tenant-scoped, and a request spec sets no ambient tenant — a
      # bare change(Activity, :count) raises NoTenantSet rather than counting.
      def activity_count
        ActsAsTenant.with_tenant(organisation) { Activity.count }
      end

      def outbox_event_count
        ActsAsTenant.with_tenant(organisation) { OutboxEvent.count }
      end

      it 'records who switched AI on, against the organisation' do
        expect { post activate_organisation_ai_settings_path(organisation) }
          .to change { activity_count }.by(1)

        expect(last_activity('ai_activated')).to have_attributes(
          actor_id: admin.id, trackable: organisation, organisation_id: organisation.id,
          key: 'organisation.ai_activated'
        )
      end

      # Its own verb, not a shared "ai_switched" with a flag in the parameters: the
      # off-switch is the one entry a data-protection question actually looks for, and
      # it must be findable by action alone.
      it 'records the off-switch under its own verb' do
        organisation.update!(ai_enabled: true, ai_activated_at: 2.days.ago, ai_activated_by: admin)

        expect { post deactivate_organisation_ai_settings_path(organisation) }
          .to change { activity_count }.by(1)

        expect(last_activity('ai_deactivated')).to have_attributes(
          actor_id: admin.id, trackable: organisation, key: 'organisation.ai_deactivated'
        )
      end

      # ⚠️ THE reason skip_notifications is set (measured for the package verbs in P4e,
      # same trap here). An Activity is not a quiet audit row: after_create_commit
      # reaches OutboxEvent → OutboxConsumeJob → FanoutService, and this key derives no
      # known event type, so derive_event_type falls back to SYSTEM_MESSAGE rather than
      # nil. Without the flag the compliance off-switch would mail the whole org.
      it 'notifies nobody when AI is switched off' do
        organisation.update!(ai_enabled: true)

        expect { post deactivate_organisation_ai_settings_path(organisation) }
          .not_to(change { outbox_event_count })
      end

      it 'would notify without the flag, which is what the flag is for' do
        expect do
          ActsAsTenant.with_tenant(organisation) do
            Activity.create!(organisation: organisation, actor: admin, trackable: organisation,
                             action: 'ai_deactivated')
          end
        end.to change { outbox_event_count }.by(1)
      end

      # Both locales, read off the backend rather than through I18n.exists?, which
      # answers true for :en via the en→de fallback. Worth pinning because BOTH render
      # paths swallow a miss: Activity#message rescues MissingInterpolationArgument and
      # #action_text carries a humanised default — a missing key would show up as
      # plausible-looking text, not as an error.
      %w[de en].each do |locale|
        it "renders both verbs in #{locale} instead of falling back silently" do
          %w[ai_activated ai_deactivated].each do |verb|
            expect(I18n.backend.translations.dig(locale.to_sym, :activities, :messages, :organisation,
                                                 verb.to_sym)).to be_present
            expect(I18n.backend.translations.dig(locale.to_sym, :activities, :organisation,
                                                 verb.to_sym)).to be_present
          end
        end
      end

      # A switch that did not move must not appear to have moved. Both doors render the
      # current state, so these are stale tabs and hand-built POSTs — but the row they
      # would write is indistinguishable from a real one afterwards, and the public
      # doc sells the four verbs as the complete trail.
      it 'writes nothing when activate is repeated on an already-active organisation' do
        post activate_organisation_ai_settings_path(organisation)

        expect { post activate_organisation_ai_settings_path(organisation) }
          .not_to(change { activity_count })
      end

      # The settings page renders ai_activated_at/_by as "aktiviert am X von Y". If the
      # audit row is conditional but the stamp is not, a repeat click credits the
      # activation to somebody who switched nothing — and since the row is skipped,
      # nothing in the trail contradicts it. The two have to move together.
      it 'leaves the rendered activation credit with the admin who actually switched it on' do
        post activate_organisation_ai_settings_path(organisation)
        original = organisation.reload.ai_activated_at

        second_admin = create(:user)
        ActsAsTenant.with_tenant(organisation) do
          create(:membership, user: second_admin, organisation: organisation, role: admin_role, active: true)
        end
        sign_in second_admin
        post activate_organisation_ai_settings_path(organisation)

        organisation.reload
        expect(organisation.ai_activated_by).to eq(admin)
        expect(organisation.ai_activated_at).to eq(original)
      end

      it 'writes nothing when deactivate hits an organisation that is already off' do
        expect { post deactivate_organisation_ai_settings_path(organisation) }
          .not_to(change { activity_count })
        expect(organisation.reload.ai_enabled).to be(false)
      end

      # The other half of the pair above: the guard must not swallow the real thing.
      it 'still records the second activation after a genuine off-switch in between' do
        post activate_organisation_ai_settings_path(organisation)
        post deactivate_organisation_ai_settings_path(organisation)

        expect { post activate_organisation_ai_settings_path(organisation) }
          .to change { activity_count }.by(1)
        expect(ActsAsTenant.with_tenant(organisation) { Activity.where(action: 'ai_activated').count }).to eq(2)
      end

      # Ordering, not decoration: the backfill is the part of #activate that can raise
      # (its own first half rescues, the two steps after it do not — see the controller
      # comment). Writing the audit row afterwards would lose exactly the entry that
      # says AI was switched on, in the one case where the admin needs it most.
      it 'has written the audit row even when the backfill blows up (production)' do
        allow(Rails.env).to receive(:local?).and_return(false)
        allow(Embeddings::ActivationBackfill).to receive(:call).and_raise(ActiveRecord::StatementInvalid, 'boom')

        expect { post activate_organisation_ai_settings_path(organisation) }
          .to change { activity_count }.by(1)

        expect(response).to redirect_to(organisation_ai_overview_path(organisation))
        expect(organisation.reload.ai_enabled).to be(true)
      end

      # The other half of that split. Without it the rescue around the backfill would be
      # a strictly worse version of the unprotected call it replaced: that one at least
      # failed loudly on a developer's machine.
      it 'lets a broken backfill raise in dev and test' do
        allow(Embeddings::ActivationBackfill).to receive(:call).and_raise(ActiveRecord::StatementInvalid, 'boom')

        expect { post activate_organisation_ai_settings_path(organisation) }
          .to raise_error(ActiveRecord::StatementInvalid)
      end

      # The dev/test half of the fail-soft split, which the production example below
      # stubs away. Without this one, deleting `raise if Rails.env.local?` would leave
      # the whole suite green and turn every local audit failure silent.
      it 'raises loudly in dev and test instead of swallowing the failure' do
        allow(Activity).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'boom')

        expect { post activate_organisation_ai_settings_path(organisation) }
          .to raise_error(ActiveRecord::StatementInvalid)
      end

      it 'names the acting admin in the rendered message' do
        post activate_organisation_ai_settings_path(organisation)

        expect(last_activity('ai_activated').message).to include(admin.full_name)
      end

      # The off-switch is the compliance one and "has to work unconditionally" (see
      # the controller comment on #activate). A DB-level failure of the audit write
      # must therefore not undo it or answer an applied request with a 500 — in
      # production. Dev and test raise instead, which is why Rails.env is stubbed here
      # rather than the behaviour being asserted for the test environment.
      it 'keeps the switch applied when the audit row cannot be written (production)' do
        organisation.update!(ai_enabled: true)
        allow(Rails.env).to receive(:local?).and_return(false)
        allow(Activity).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'boom')

        post deactivate_organisation_ai_settings_path(organisation)

        expect(response).to redirect_to(organisation_ai_overview_path(organisation))
        expect(organisation.reload.ai_enabled).to be(false)
      end
    end

    # ⚠️ INVERTED by S7 (L6), and that inversion is the point. This example used to
    # assert that the probe REFUSES while AI is off, because it ran through the gated
    # seam and answered AiDisabledError. But "erst konfigurieren, dann anschalten" is
    # the natural order, so the one moment the button was most useful was the one moment
    # it declined — and the hub card could never reach "Verbindung fehlerhaft" for an
    # organisation that had not switched on yet.
    #
    # connectivity_check lists models; it sends no content and spends no tokens, which
    # is why Factory.chat_probe may bypass the opt-in gate where nothing else may.
    it 'answers the connection test while AI is disabled instead of refusing it' do
      post test_connection_organisation_ai_settings_path(organisation)

      expect(flash[:alert]).not_to eq(I18n.t('shared.ai.disabled_admin_hint'))
      # No system credential in this example, so the honest answer is "no access", not
      # "AI is off" — a statement about the ACCESS, which is what the button asks about.
      expect(flash[:alert]).to eq(I18n.t('flash.ai_settings.no_client', provider: 'OpenAI (GPT)'))
    end

    # L10: the verdict outlives the flash now. Without this the hub card is decoration —
    # it renders a state nothing ever writes.
    it 'records the failed verdict on the organisation, not just in the flash' do
      post test_connection_organisation_ai_settings_path(organisation)

      expect(organisation.reload.ai_connection_failed?).to be(true)
      expect(organisation.ai_connection_checked_at).to be_present
    end

    # ⚠️ The switch is rendered on the HUB since doc/ki_zugang_umbau_plan.md D1, not on
    # this controller's own page. Both surfaces are pinned here rather than split across
    # two files: the point of the move is that exactly ONE of them carries the buttons,
    # and that is a statement about the pair.
    describe 'where the switch is rendered' do
      it 'offers the activate action on the hub while AI is off, and no deactivate' do
        get organisation_ai_overview_path(organisation)

        expect(response.body).to include(activate_organisation_ai_settings_path(organisation))
        expect(response.body).not_to include(deactivate_organisation_ai_settings_path(organisation))
        expect(response.body).to include(I18n.t('views.organisations.ai_overview.status.inactive'))
        # The consent long-text belongs AT the decision (D2) — this is the one screen
        # that carries it, so its absence anywhere else means something.
        expect(response.body).to include(
          I18n.t('views.organisations.ai_overview.activation.explanation')
        )
      end

      it 'shows the status sentence plus deactivate on the hub while AI is on' do
        organisation.update!(ai_enabled: true, ai_activated_at: Time.zone.parse('2026-06-01 10:00'),
                             ai_activated_by: admin)

        get organisation_ai_overview_path(organisation)

        expect(response.body).to include(deactivate_organisation_ai_settings_path(organisation))
        expect(response.body).not_to include(activate_organisation_ai_settings_path(organisation))
        # No date on the hub any more (doc/ki_uebersicht_zeilenliste_plan.md D4): the
        # Protokoll page is the audit record, the hub only says whether AI runs.
        expect(response.body).not_to include(I18n.l(organisation.ai_activated_at, format: :long))
        # No consent briefing on the way OUT (D2). Paired with the positive assertion
        # above, so this absence cannot pass by rendering nothing at all.
        expect(response.body).not_to include(
          I18n.t('views.organisations.ai_overview.activation.explanation')
        )
      end

      it 'still renders the hub when the activating admin was deleted (FK nullified)' do
        # Orgs whose activating admin left are exactly the ones that must not 500.
        organisation.update!(ai_enabled: true, ai_activated_at: Time.zone.parse('2026-06-01 10:00'),
                             ai_activated_by: nil)

        get organisation_ai_overview_path(organisation)

        expect(response).to have_http_status(:ok)
      end

      # D5: what is LEFT on "Zugang" is one line, and the mutation this pins is the one
      # that would undo the move — a switch quietly rendered on both pages.
      describe 'and where it is not: the access page' do
        # The rendered line carries an <a> where %{link} sits, so the whole translation
        # never appears verbatim. Assert the part BEFORE the link, taken from the
        # translation itself rather than retyped — a retyped sentence stops matching the
        # moment the copy is edited, and then the example silently pins nothing.
        def status_line_lead(state)
          I18n.t("views.organisations.ai_settings.show.status_line_#{state}_html", link: '@@LINK@@')
              .split('@@LINK@@').first
        end

        it 'carries a status line and neither switch action while AI is off' do
          get organisation_ai_settings_path(organisation)

          expect(response.body).not_to include(activate_organisation_ai_settings_path(organisation))
          expect(response.body).not_to include(deactivate_organisation_ai_settings_path(organisation))
          expect(response.body).to include(status_line_lead('inactive'))
          # The way onwards is named, not implied. Read off the line's own link: the
          # section's tab row (whose first tab has the same word) and the sidebar lead to
          # the overview as well.
          line = Nokogiri::HTML(response.body).css('main p').find do |paragraph|
            paragraph.text.squish.include?(status_line_lead('inactive').squish)
          end
          expect(line&.at_css('a')&.attr('href')).to eq(organisation_ai_overview_path(organisation))
        end

        it 'carries the active status line and still no switch action while AI is on' do
          organisation.update!(ai_enabled: true, ai_activated_at: Time.current, ai_activated_by: admin)

          get organisation_ai_settings_path(organisation)

          expect(response.body).not_to include(activate_organisation_ai_settings_path(organisation))
          expect(response.body).not_to include(deactivate_organisation_ai_settings_path(organisation))
          # No second truth about the switch: the date and the name live on the hub.
          expect(response.body).not_to include(I18n.l(organisation.ai_activated_at, format: :long))
        end

        # The connection test is deliberately NOT among the actions that left with the
        # switch: the probe is gate-free since S7 (L6), and setting the access up before
        # activating is the intended order. Pinned positively rather than dropped.
        it 'keeps the connection test reachable in both states (the probe is gate-free)' do
          get organisation_ai_settings_path(organisation)
          expect(response.body).to include(test_connection_organisation_ai_settings_path(organisation))

          organisation.update!(ai_enabled: true)
          get organisation_ai_settings_path(organisation)
          expect(response.body).to include(test_connection_organisation_ai_settings_path(organisation))
        end

        # The section's head (doc/verwaltung_seitennavigation_plan.md S3): the help and the
        # connection test stand right of the title, as every page's tools do. Once each on
        # the page and that once in the head, so no row of tools is left under the tab row.
        it 'puts the help and the connection test into the head' do
          get organisation_ai_settings_path(organisation)
          doc = Nokogiri::HTML(response.body)
          tabs = doc.at_css("main nav[aria-label='#{I18n.t('settings.ai')}']")
          expect(tabs).not_to be_nil, 'no tab row in main named after the section'
          head = tabs.previous_element
          help = "[data-controller='dropdown'] > [title='#{I18n.t('components.contextual_help.label')}']"
          test = "form[action='#{test_connection_organisation_ai_settings_path(organisation)}']"

          expect(head.at_css('h1').text.squish).to eq(I18n.t('settings.ai'))
          expect(head.css(help).size).to eq(1)
          expect(doc.css("main #{help}").size).to eq(1)
          expect(head.css(test).size).to eq(1)
          expect(doc.css("main #{test}").size).to eq(1)
        end
      end
    end
  end

  # What the admin is TOLD, which until now was "activated" over every outcome.
  #
  # `ai_enabled` is the GDPR opt-in, not a statement that an embedding lane exists, and
  # the two failed independently. An organisation activated without embedding access got a
  # green notice, its content never entered the index at all (EmbeddingProcessingService
  # writes the fragment only after the embedding call returns), and the first symptom was
  # a search missing content days later, with the banner blaming "AI ranking".
  #
  # The activation itself must survive every branch below: the opt-in is a compliance act
  # and may never be blocked by a technical state — only described honestly.
  describe 'what activation reports back' do
    before { sign_in admin }

    def flash_after_activate
      post activate_organisation_ai_settings_path(organisation)
      flash
    end

    context 'without a usable embedding lane' do
      it 'warns instead of reporting plain success' do
        expect(flash_after_activate[:alert])
          .to eq(I18n.t('flash.ai_settings.activated_without_embedding_access'))
      end

      it 'still switches AI on — the opt-in is never blocked by the warning' do
        post activate_organisation_ai_settings_path(organisation)

        expect(organisation.reload.ai_enabled).to be(true)
      end

      it 'does not also claim success' do
        expect(flash_after_activate[:notice]).to be_nil
      end
    end

    context 'with a usable embedding lane' do
      before { create(:ai_credential, provider: 'openai', active: true, enabled: true, purpose: 'both') }

      it 'reports plain success' do
        expect(flash_after_activate[:notice]).to eq(I18n.t('flash.ai_settings.activated'))
        expect(flash_after_activate[:alert]).to be_nil
      end

      # The gate is asked about the lane this organisation actually resolves to. Asked
      # bare it defaults to openai, so an organisation whose own embedding lane points
      # somewhere unconfigured would be judged against a provider it does not use — and
      # told everything was fine.
      it 'judges the ORGANISATION lane, not the openai default' do
        organisation.update!(embedding_provider: 'google')

        expect(flash_after_activate[:alert])
          .to eq(I18n.t('flash.ai_settings.activated_without_embedding_access'))
      end

      it 'names the reason when the catch-up itself refuses' do
        allow(Embeddings::ActivationBackfill).to receive(:call)
          .and_return({ success: false, total_jobs: 0, error: 'AI quota exhausted' })

        expect(flash_after_activate[:alert])
          .to eq(I18n.t('flash.ai_settings.activated_backfill_failed', error: 'AI quota exhausted'))
      end

      # nil is the shape the controller's own rescue leaves behind, and that failure is
      # already an error in the log. Inventing a reason we do not have would be worse
      # than the plain notice.
      it 'falls back to the plain notice when the catch-up reported nothing at all' do
        allow(Embeddings::ActivationBackfill).to receive(:call).and_return(nil)

        expect(flash_after_activate[:notice]).to eq(I18n.t('flash.ai_settings.activated'))
      end
    end
  end

  describe 'as regular member (not account_admin)' do
    before { sign_in member }

    it 'cannot activate AI (Pundit denial → redirect, flag untouched)' do
      post activate_organisation_ai_settings_path(organisation)

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to be_present
      expect(organisation.reload.ai_enabled).to be(false)
    end

    it 'cannot deactivate AI either' do
      organisation.update!(ai_enabled: true, ai_activated_at: Time.current, ai_activated_by: admin)

      post deactivate_organisation_ai_settings_path(organisation)

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to be_present
      expect(organisation.reload.ai_enabled).to be(true)
    end
  end

  describe 'as non-member' do
    let(:outsider) { create(:user) }
    let(:outsider_org) { create(:organisation) }
    let(:outsider_role) { ActsAsTenant.with_tenant(outsider_org) { create(:admin_role, organisation: outsider_org) } }
    let!(:outsider_membership) do
      ActsAsTenant.with_tenant(outsider_org) do
        create(:membership, user: outsider, organisation: outsider_org, role: outsider_role, active: true)
      end
    end

    before do
      sign_in outsider
      # Prime the session with the outsider's OWN org — without a current org
      # the request is redirected to /select_organisation before reaching the
      # controller (see ai_settings_controller_spec for the full rationale).
      get organisation_ai_settings_path(organisation_id: outsider_org.id)
    end

    it 'gets 404 (membership-scoped lookup, no existence leak)' do
      post activate_organisation_ai_settings_path(organisation)
      expect(response).to have_http_status(:not_found)
      expect(organisation.reload.ai_enabled).to be(false)
    end
  end
end
