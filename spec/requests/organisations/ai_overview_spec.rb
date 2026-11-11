# frozen_string_literal: true

# What: Request spec for the AI area's hub (doc/ki_bereich_navigation_plan.md S2; the row
#   list of doc/ki_uebersicht_zeilenliste_plan.md).
# Type: Request spec — authorization + the three STATEMENTS the hub exists for.
# Why (philosophy): N1 decided the hub is not a dispatcher but an answer: "muss ich
#   etwas tun?" in three seconds, most visits ending here without a click. The page
#   answers in three places — one sentence about the switch, one main action for the
#   first open setup step, a dot on exactly the rows where something needs doing — and
#   those three are what this spec pins. A row whose dot never moves, or a lime button
#   that stays after its job is done, would satisfy a "renders successfully" test and
#   defeat the design.
# Contract: account_admin only; five rows; a dot only for attention (amber) or alert
#   (red), none while AI is off; one main action or none; with AI off the locked rows
#   render no link (§3.2, "zwei Gesichter"); every value ends on the same right edge; the
#   hub is the first tab of the section's tab row, inside the page root under the head.

require 'rails_helper'

RSpec.describe 'Organisations::AiOverviews', type: :request do
  include ActionView::Helpers::SanitizeHelper

  # Quota fixed to 10 + 5 so the usage row's figures are numbers this file can name.
  let(:organisation) do
    create(:organisation, :ai_disabled, ai_quota_credits_override: 10, ai_quota_buffer_override: 5)
  end
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

  def hub_t(key, **)
    I18n.t("views.organisations.ai_overview.#{key}", **)
  end

  def hub_body
    get organisation_ai_overview_path(organisation)
    response.body
  end

  # The values carry a <span> around every figure (mono), so a sentence like
  # "5 von 10 Credits" never appears verbatim in the markup. Read the page as text.
  def hub_text
    strip_tags(hub_body).squish
  end

  # data-row-state is rendered for exactly the rows that CLAIM something. Asserting on
  # it rather than on colour classes keeps the spec about the decision, not the styling.
  def row_states
    hub_body.scan(/data-row-state="(\w+)"/).flatten
  end

  # The links of the rows alone. Since the section has a tab row
  # (doc/verwaltung_seitennavigation_plan.md S3) the tabs above the rows lead to the same
  # pages, so a path found anywhere on the page says nothing about a row any more.
  def row_links(body)
    Nokogiri::HTML(body).css('#ai_overview_rows a').map { |link| link['href'] }
  end

  let(:chevron) { '<path d="M9 6l6 6-6 6" />' }
  let(:value_cell) { 'class="min-w-[148px] shrink-0 text-right"' }

  def write_protocol_entry(action, created_at:)
    ActsAsTenant.with_tenant(organisation) do
      Activity.create!(organisation: organisation, actor: admin, trackable: organisation, action: action,
                       parameters: {}, created_at: created_at, skip_notifications: true)
    end
  end

  describe 'as account_admin' do
    before { sign_in admin }

    # Head and tab row are one block. The layout's content column puts gap-4/lg:gap-6
    # between its direct children, so a tab row outside the page's root element would
    # stand a gap away from its head. The hub is the section's first tab, "Übersicht".
    it 'keeps the tab row of the section inside the page root, right under the head' do
      document = Nokogiri::HTML(hub_body)
      navigation = document.at_css("main nav[aria-label='#{I18n.t('settings.ai')}']")

      expect(navigation).to be_present
      page_layout_gaps = navigation.parent['class'].to_s.split & %w[gap-4 lg:gap-6]
      expect(page_layout_gaps).to be_empty
      expect(navigation.previous_element.at_css('h1').text.squish).to eq(I18n.t('settings.ai'))
      expect(navigation.at_css('[aria-current="page"]').text.squish).to eq(hub_t('pages.overview'))
    end

    it 'renders the hub with a link to every page of the area' do
      organisation.update!(ai_enabled: true)

      body = hub_body

      expect(response).to have_http_status(:ok)
      expect(row_links(body)).to contain_exactly(
        organisation_ai_settings_path(organisation), organisation_ai_usage_path(organisation),
        organisation_ai_sync_status_path(organisation), organisation_prompt_personas_path(organisation),
        organisation_ai_protocol_path(organisation)
      )
    end

    # Five values on one right edge is the point of the form: five cells of the fixed
    # width, and a chevron on every row that is a way. A locked row keeps a blank of
    # the chevron's width instead, so the count of cells does not move with the lock.
    it 'ends every value on the same edge: five value cells, five chevrons' do
      organisation.update!(ai_enabled: true)

      body = hub_body

      expect(body.scan(value_cell).size).to eq(5)
      expect(body.scan(chevron).size).to eq(5)
    end

    describe 'with AI off (the second face of §3.2)' do
      # The lock is not a styling detail, it is the mechanism: a locked row renders no
      # link_to at all, so the page cannot be clicked into an area that is switched off.
      # "Zugang" stays a way (preparing the access first is the intended order, D3 of
      # the Zugang plan) and so does "Protokoll" (the trail outlives the switch).
      it 'locks three rows into place rather than only greying them' do
        body = hub_body

        expect(row_links(body)).to contain_exactly(organisation_ai_settings_path(organisation),
                                                   organisation_ai_protocol_path(organisation))
        # Page-wide on purpose: neither a row nor the tab row above them leads into a
        # locked page (the tabs lock the same three, NavigationHelper#ai_section_tabs).
        expect(body).not_to include(organisation_ai_usage_path(organisation))
        expect(body).not_to include(organisation_ai_sync_status_path(organisation))
        expect(body).not_to include(organisation_prompt_personas_path(organisation))
        expect(body.scan(chevron).size).to eq(2)
        expect(body.scan(value_cell).size).to eq(5)
      end

      # Nothing is missing while nothing runs: the sentence says "ausgeschaltet" once,
      # and no row carries a dot — not even Zugang, whose access is not chosen here.
      it 'says so in one sentence and gives no row a dot' do
        expect(hub_body).to include(hub_t('status.inactive'))
        expect(row_states).to be_empty
      end

      # ⚠️ NOT the shared "KI ist nicht aktiviert" box of the other pages
      # (doc/ki_zugang_umbau_plan.md D1/D4). That box exists to point somewhere; here it
      # would point at itself, so this page carries the switch — with the consent copy,
      # because the decision is made here and the text belongs at the decision.
      it 'carries the switch itself, with the consent copy, rather than the box that points at it' do
        body = hub_body

        expect(body).not_to include(hub_t('disabled_notice.title'))
        expect(body).to include(activate_organisation_ai_settings_path(organisation))
        expect(body).to include(hub_t('activation.explanation'))
      end

      # The main-action rule: the first open step of the setup. With nothing chosen
      # that is the access; switching on stays reachable as text, since the order is a
      # recommendation, not a gate.
      it 'makes "Zugang einrichten" the main action while nothing is chosen, and keeps switching on as text' do
        body = hub_body

        expect(body).to include(hub_t('actions.set_up_access'))
        expect(body).to include(hub_t('actions.switch_on'))
      end

      it 'makes switching on the main action once the access is chosen' do
        package = create(:ai_package, :with_tiers, active: true)
        organisation.update!(ai_package: package)

        body = hub_body

        expect(body).to include(hub_t('actions.switch_on'))
        expect(body).not_to include(hub_t('actions.set_up_access'))
      end
    end

    describe 'with AI on' do
      before { organisation.update!(ai_enabled: true) }

      it 'drops the consent copy and the activate action, and offers switching off as text' do
        body = hub_body

        expect(body).not_to include(hub_t('activation.explanation'))
        expect(body).not_to include(activate_organisation_ai_settings_path(organisation))
        expect(body).to include(deactivate_organisation_ai_settings_path(organisation))
        expect(body).to include(hub_t('actions.switch_off'))
      end

      # D6 of the plan: "nothing works" keys on the gate every AI button asks
      # (ai_available?), which includes the operator's credential — NOT on the setup
      # state. The two examples below hold the two facts apart on one page.
      describe 'the sentence' do
        it 'says nothing works while no usable access exists' do
          body = hub_body

          expect(body).to include(hub_t('status.active_without_access'))
          expect(body).not_to include(hub_t('status.active'))
        end

        it 'says active once the operator credential serves the organisation, while the access row still asks for a choice' do
          create(:ai_credential, :active, provider: 'openai')

          body = hub_body

          expect(body).to include(hub_t('status.active'))
          expect(body).not_to include(hub_t('status.active_without_access'))
          expect(row_states).to eq(%w[attention])
        end
      end

      describe 'the dots, which are the point of the hub' do
        # ONE dot on a fresh organisation that is switched on, and it sits on Zugang:
        # choosing who processes the content is the open step. Usage at zero, an empty
        # index and no personas claim nothing. Counting matters here: the whole point
        # of the list is that a glance lands on the rows that actually claim something.
        it 'gives the access row one amber dot while nothing is chosen, and no other row any' do
          body = hub_body

          expect(row_states).to eq(%w[attention])
          expect(body).to include(hub_t('rows.access.state_missing'))
        end

        it 'drops the dot once a package is chosen' do
          package = create(:ai_package, :with_tiers, name: 'Europäisch', active: true)
          organisation.update!(ai_package: package)

          expect(row_states).to be_empty
          expect(hub_body).to include('Europäisch')
        end

        it 'drops the dot once own credentials are stored' do
          organisation.update!(ai_package: nil, ai_provider: nil, ai_access_token: 'sk-live-key')

          expect(row_states).to be_empty
          expect(hub_body).to include(hub_t('rows.access.value_custom'))
        end

        # ⚠️ Asserts the YEAR literally, not "the same format the view happens to use" —
        # mirroring the view's own `format:` would follow it into any format and prove
        # nothing. `time.formats.short` is "%d %b %H:%M": a verdict from two years back
        # rendered "05 Mär 14:32" and read like this afternoon, on the row whose entire
        # job is to say how old the bad news is.
        it 'turns the access row red once a connection check failed, and names the year' do
          organisation.update!(ai_connection_status: Organisation::AI_CONNECTION_FAILED,
                               ai_connection_checked_at: Time.zone.local(2024, 3, 5, 14, 32))

          expect(row_states).to eq(%w[alert])
          expect(hub_body).to include('2024')
        end

        # ORDER, not just presence. Both statements are true at once here, and only one
        # is a reason to act — a switch running on an access that does not answer is
        # going to fail anyway, so red has to win. Asserted because "which of the two"
        # is exactly the kind of decision an `elsif` chain loses silently when reordered.
        it 'lets a failed access outrank a running switch' do
          allow(Embeddings::SwitchProgress).to receive(:call)
            .and_return(Embeddings::SwitchProgress::Result.new(state: :building, remaining: 5, total: 10))
          organisation.update!(ai_connection_status: Organisation::AI_CONNECTION_FAILED,
                               ai_connection_checked_at: 2.hours.ago)

          expect(row_states).to eq(%w[alert])
          expect(hub_body).to include(
            hub_t('rows.access.description_check_failed',
                  date: I18n.l(organisation.reload.ai_connection_checked_at, format: :long))
          )
        end

        # A running switch is the normal case: it gets its sentence, not a colour.
        it 'gives a running switch no dot, only its sentence' do
          package = create(:ai_package, :with_tiers, active: true)
          organisation.update!(ai_package: package)
          allow(Embeddings::SwitchProgress).to receive(:call)
            .and_return(Embeddings::SwitchProgress::Result.new(state: :building, remaining: 5, total: 10))

          expect(row_states).to be_empty
          expect(hub_body).to include(hub_t('rows.access.description_switching'))
        end

        describe 'on the usage row' do
          let!(:credential) { create(:ai_credential, :active, provider: 'openai', included_in_quota: true) }

          def book(credits)
            AiUsage.create!(organisation: organisation, provider: 'openai', ai_credential: credential,
                            credits_used: credits, tokens_used: 0, used_at: Time.current)
          end

          it 'turns red once the hard limit blocks new calls' do
            book(15)

            expect(row_states).to include('alert')
            expect(hub_body).to include(hub_t('rows.usage.state_exhausted'))
          end

          it 'turns amber from 80 percent on' do
            book(8)

            expect(row_states).to include('attention')
            expect(hub_body).to include(hub_t('rows.usage.state_nearly'))
          end

          it 'claims nothing while the share is small' do
            book(2)

            expect(hub_body).not_to include(hub_t('rows.usage.state_nearly'))
            expect(hub_body).not_to include(hub_t('rows.usage.state_exhausted'))
          end
        end

        describe 'on the indexing row' do
          let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

          it 'turns red when content failed to embed' do
            ActsAsTenant.with_tenant(organisation) do
              create(:note, project: project, organisation: organisation,
                            create_embeddings: true, embedding_creation_error: 'boom')
            end

            expect(row_states).to include('alert')
            expect(hub_body).to include(hub_t('rows.index.state_failed'))
          end

          # Outstanding work is the normal case and gets no colour — the failure mode
          # this guards is a backlog dressed up as an alert.
          it 'gives outstanding work no dot' do
            package = create(:ai_package, :with_tiers, active: true)
            organisation.update!(ai_package: package)
            ActsAsTenant.with_tenant(organisation) do
              create(:note, project: project, organisation: organisation,
                            create_embeddings: true, embeddings_creation_flag: nil)
            end

            expect(row_states).to be_empty
          end
        end
      end

      describe 'the values, right-aligned in one column' do
        let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

        it 'shows the credits used against the budget, with a bar of the same share' do
          credential = create(:ai_credential, :active, provider: 'openai', included_in_quota: true)
          AiUsage.create!(organisation: organisation, provider: 'openai', ai_credential: credential,
                          credits_used: 5, tokens_used: 0, used_at: Time.current)

          expect(hub_text).to include(strip_tags(hub_t('rows.usage.value_html', used: 5, budget: 10)))
          expect(hub_body).to include('style="width: 50%"')
        end

        # Nachtrag 2 of the plan: a figure is never cut, because half a number is wrong.
        # The value column has a minimum width and no truncation; the word "Credits"
        # lives in the description so the value is nothing but numbers.
        it 'never cuts a number: a budget of ten million renders in full, the name gives way' do
          organisation.update!(ai_quota_credits_override: 10_000_000)

          body = hub_body
          expect(strip_tags(body).squish).to include(strip_tags(hub_t('rows.usage.value_html', used: 0, budget: '10.000.000')))
          expect(body).to include('class="whitespace-nowrap text-[13px] text-body"')
          expect(body).not_to match(/class="[^"]*truncate[^"]*"[^>]*>\s*<span class="font-mono/)
        end

        # An empty bar is a statement too: the groove renders, the fill has no width.
        it 'leaves the bar empty at zero' do
          expect(hub_body).to include('style="width: 0%"')
        end

        it 'names failures before the backlog, and the backlog in the description' do
          ActsAsTenant.with_tenant(organisation) do
            create(:note, project: project, organisation: organisation,
                          create_embeddings: true, embedding_creation_error: 'boom')
            create(:note, project: project, organisation: organisation,
                          create_embeddings: true, embeddings_creation_flag: nil)
          end

          text = hub_text
          expect(text).to include(strip_tags(hub_t('rows.index.value_failed_html', failed: 1)))
          expect(text).to include(hub_t('rows.index.description_failed_pending', pending: 1))
        end

        it 'reads "nichts ausstehend" when the index is clear' do
          expect(hub_body).to include(hub_t('rows.index.value_clear'))
        end

        it 'counts own personas, in words when there are none' do
          expect(hub_body).to include(hub_t('rows.personas.value_html', count: 0, number: 0))

          ActsAsTenant.with_tenant(organisation) { create_list(:prompt_persona, 2, organisation: organisation) }

          expect(hub_text).to include(strip_tags(hub_t('rows.personas.value_html', count: 2, number: 2)))
        end

        # The oldest entry, not the newest: the row says since WHEN the trail exists.
        it 'dates the protocol from its oldest entry' do
          write_protocol_entry('ai_activated', created_at: 3.days.ago)
          write_protocol_entry('ai_deactivated', created_at: 1.hour.ago)

          expect(hub_text).to include(
            strip_tags(hub_t('rows.protocol.value_since_html', date: I18n.l(3.days.ago.to_date)))
          )
        end

        it 'says the protocol is still empty for a fresh organisation' do
          expect(hub_body).to include(hub_t('rows.protocol.value_empty'))
        end

        # doc/ki_zugang_umbau_plan.md D7: the same three states the access page
        # distinguishes, on the row that summarises it. "Nothing chosen" must never read
        # like a choice made — asserted with the absence of the neighbouring copy, since a
        # positive-only assertion would stay green on a row that lost the branch.
        it 'says nothing is set up when neither a package nor credentials exist' do
          organisation.update!(ai_package: nil, ai_access_token: nil)

          body = hub_body
          expect(body).to include(hub_t('rows.access.description_none'))
          # Asserted on the value paragraph, not on the page: the description names
          # "eigene Zugangsdaten" as an option, which is a different sentence.
          value_cell = 'class="whitespace-nowrap text-[13px] text-body">'
          expect(body).to include("#{value_cell}#{hub_t('rows.access.value_none')}<")
          expect(body).not_to include("#{value_cell}#{hub_t('rows.access.value_custom')}<")
        end
      end

      describe 'the main action' do
        it 'is "Zugang einrichten" while nothing is chosen' do
          body = hub_body

          expect(body).to include(hub_t('actions.set_up_access'))
          expect(body).not_to include(hub_t('actions.switch_on'))
        end

        # A main action that has nothing left to do must not stay lime. Both labels
        # are asserted absent, so a page that fell back to the wrong branch fails too.
        it 'is gone once the access is chosen' do
          package = create(:ai_package, :with_tiers, active: true)
          organisation.update!(ai_package: package)

          body = hub_body

          expect(body).not_to include(hub_t('actions.set_up_access'))
          expect(body).not_to include(hub_t('actions.switch_on'))
        end
      end
    end
  end

  describe 'as regular member (not account_admin)' do
    before { sign_in member }

    # The hub NAMES what is behind it — package, jurisdiction, quota, backlog — even
    # where it does not link. A weaker gate here than on the pages themselves would be
    # the one hole in the wall §2.4 of the plan checked before cutting the area.
    it 'is denied and told so, rather than silently shown an empty page' do
      get organisation_ai_overview_path(organisation)

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to be_present
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

    # The priming request is NOT decoration: it puts the outsider's OWN organisation into
    # the session. Without a session tenant, Organisations::BaseController#set_current_
    # membership runs before #set_organisation has resolved anything, finds no membership
    # and redirects to the org picker — a 302, so the example below would pass or fail for
    # a reason that has nothing to do with the membership-scoped lookup it is about.
    before do
      sign_in outsider
      get organisation_ai_overview_path(organisation_id: outsider_org.id)
    end

    it 'gets 404 (membership-scoped lookup, no existence leak)' do
      get organisation_ai_overview_path(organisation)

      expect(response).to have_http_status(:not_found)
    end
  end
end
