# frozen_string_literal: true

# What: Request spec for the AI area's protocol page
#   (doc/ki_bereich_navigation_plan.md S5, L13/E5).
# Type: Request spec — authorization, tenant separation, the selection of rows and the
#   ceiling that keeps the page from growing with the organisation's age.
# Why (philosophy): The value of this page is completeness and correctness of ATTRIBUTION,
#   not that it renders. A page that shows three of four verbs, or one that shows a
#   neighbour's trail, looks exactly as healthy as a correct one — there is no error, no
#   blank, nothing a screenshot would reveal. So the examples below are about WHICH rows
#   appear and WHOSE, and every one of them is written so it fails if that selection
#   slips.
# Contract: account_admin only; the four protocol verbs and nothing else; rows of the
#   CURRENT tenant only; newest first; at most PAGE_SIZE rows per page and never more
#   than MAX_PAGE_SIZE however the request asks.

require 'rails_helper'

RSpec.describe 'Organisations::AiProtocols', type: :request do
  let(:organisation) { create(:organisation, ai_enabled: true) }
  let(:admin) { create(:user, first_name: 'Ada', last_name: 'Adminson') }
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

  # Written the way the two production write sites write it (Actors::SelectAiPackage
  # #log_choice, Organisations::AiSettingsController#log_ai_switch): inside with_tenant,
  # with both skip flags. Not a stylistic echo — an Activity without them fans out
  # notifications, so a spec that omitted them would exercise a row this feature never
  # produces AND make the suite send mail.
  def write_entry(org, action, actor:, parameters: {}, created_at: Time.current)
    ActsAsTenant.with_tenant(org) do
      Activity.create!(organisation: org, actor: actor, trackable: org, action: action,
                       parameters: parameters, created_at: created_at,
                       skip_notifications: true)
    end
  end

  describe 'as account_admin' do
    before { sign_in admin }

    it 'names when, who and what for every one of the four verbs' do
      write_entry(organisation, 'ai_activated', actor: admin, created_at: 3.days.ago)
      write_entry(organisation, 'ai_package_selected', actor: admin, created_at: 2.days.ago,
                                                       parameters: { 'from_package' => 'Eigene Konfiguration',
                                                                     'to_package' => 'PAKET-EIGEN',
                                                                     'from_jurisdiction' => nil,
                                                                     'to_jurisdiction' => 'eu_native' })
      write_entry(organisation, 'ai_tier_selected', actor: admin, created_at: 1.day.ago,
                                                    parameters: { 'from_tier_key' => 'balanced', 'to_tier_key' => 'thorough' })
      write_entry(organisation, 'ai_deactivated', actor: admin, created_at: 1.hour.ago)

      get organisation_ai_protocol_path(organisation)

      expect(response).to have_http_status(:ok)
      # WAS: the four verbs, each with its own wording rather than a generic "changed".
      expect(response.body).to include(I18n.t('activities.organisation.ai_activated'))
      expect(response.body).to include(I18n.t('activities.organisation.ai_deactivated'))
      expect(response.body).to include(I18n.t('activities.organisation.ai_package_selected'))
      expect(response.body).to include(I18n.t('activities.organisation.ai_tier_selected'))
      # WER: the sentence carries the actor. This is the half a timestamp cannot supply,
      # and Activity#message degrades silently when it is missing.
      expect(response.body).to include('Ada Adminson')
      # WAS, concretely: the package the organisation moved to.
      expect(response.body).to include('PAKET-EIGEN')
      # WANN: rendered as a date, not as an ISO blob or a relative "vor 2 Tagen" that
      # stops being evidence the moment it is read.
      expect(response.body).to include(I18n.l(2.days.ago.to_date, format: :long))
    end

    # The filter, asserted from the other side. Every model in the app writes activities;
    # without the action filter this page would be a general org feed with an audit
    # page's title — and would leak ticket titles to an audience the ticket policies
    # never approved.
    it 'shows only the AI protocol verbs, not the organisation activity feed' do
      write_entry(organisation, 'ai_activated', actor: admin)
      ActsAsTenant.with_tenant(organisation) do
        project = create(:project, organisation: organisation)
        ticket = create(:ticket, project: project, organisation: organisation, title: 'GEHEIMES-TICKET')
        Activity.create!(organisation: organisation, actor: admin, trackable: ticket,
                         action: 'created', key: 'ticket.created',
                         skip_notifications: true)
      end

      get organisation_ai_protocol_path(organisation)

      expect(response.body).to include(I18n.t('activities.organisation.ai_activated'))
      expect(response.body).not_to include('GEHEIMES-TICKET')
    end

    # Tenant separation proved with a SECOND organisation that has entries of its own,
    # not with an empty one: an empty neighbour makes "no foreign rows" true for the
    # wrong reason and the example would stay green with the scoping removed.
    it 'never shows another organisation\'s trail' do
      other_org = create(:organisation, ai_enabled: true)
      other_admin = create(:user, first_name: 'Bob', last_name: 'Fremdfirma')
      write_entry(other_org, 'ai_package_selected', actor: other_admin,
                                                    parameters: { 'from_package' => 'Eigene Konfiguration',
                                                                  'to_package' => 'PAKET-FREMD' })
      write_entry(organisation, 'ai_package_selected', actor: admin,
                                                       parameters: { 'from_package' => 'Eigene Konfiguration',
                                                                     'to_package' => 'PAKET-EIGEN' })

      get organisation_ai_protocol_path(organisation)

      expect(response.body).to include('PAKET-EIGEN')
      expect(response.body).not_to include('PAKET-FREMD')
      expect(response.body).not_to include('Bob Fremdfirma')
    end

    # Newest first, and asserted on POSITION rather than on presence: both rows are on
    # the page either way, so an order that flipped would pass any "renders both" check.
    it 'puts the newest entry first' do
      # Labels that appear on ONE row each. The obvious version — old row ends at
      # "PAKET-ALT", new row starts from it — measures nothing: the newest row names the
      # package it came FROM, so the older label appears first on a correctly ordered
      # page too.
      write_entry(organisation, 'ai_package_selected', actor: admin, created_at: 5.days.ago,
                                                       parameters: { 'from_package' => 'ZEILE-ALT-VON',
                                                                     'to_package' => 'ZEILE-ALT-NACH' })
      write_entry(organisation, 'ai_package_selected', actor: admin, created_at: 1.day.ago,
                                                       parameters: { 'from_package' => 'ZEILE-NEU-VON',
                                                                     'to_package' => 'ZEILE-NEU-NACH' })

      get organisation_ai_protocol_path(organisation)

      expect(response.body.index('ZEILE-NEU-NACH')).to be < response.body.index('ZEILE-ALT-NACH')
    end

    # ⚠️ The rung must read like it reads everywhere else. The writer stores the two
    # packages as LABELS but the two tiers as KEYS, so without the reader-side override
    # this line said 'von "fast" auf "thorough"' on the one page sold as an AVV record.
    # Asserted on the LABEL and against the raw key, because a sentence containing both
    # would satisfy a presence-only check.
    it 'names the rung the way the rest of the app names it, not by its raw key' do
      write_entry(organisation, 'ai_tier_selected', actor: admin,
                                                    parameters: { 'from_tier_key' => 'fast',
                                                                  'to_tier_key' => 'thorough' })

      get organisation_ai_protocol_path(organisation)

      expect(response.body).to include(AiPackageTier::DEFAULT_LABELS['thorough'])
      expect(response.body).not_to match(/"fast"|"thorough"/)
    end

    # The jurisdiction is the field the whole chapter exists for, and it is shown only
    # when it MOVED — a row repeating the same value on both sides trains the reader to
    # skip the one line they came for.
    describe 'the jurisdiction line' do
      it 'states the move when the processing location changed' do
        write_entry(organisation, 'ai_package_selected', actor: admin,
                                                         parameters: { 'from_package' => 'A', 'to_package' => 'B',
                                                                       'from_jurisdiction' => 'eu_native',
                                                                       'to_jurisdiction' => 'non_eu' })

        get organisation_ai_protocol_path(organisation)

        expect(response.body).to include(
          I18n.t('views.organisations.ai_overview.protocol.jurisdiction_change',
                 from: I18n.t('views.organisations.ai_settings.packages.jurisdictions.eu_native'),
                 to: I18n.t('views.organisations.ai_settings.packages.jurisdictions.non_eu'))
        )
      end

      # ⚠️ The direction that matters most for the AVV question, and the one the first
      # version was silent about. Actors::SelectAiPackage writes to_jurisdiction from
      # `package&.effective_jurisdiction`, and the "Eigene Konfiguration" card posts a
      # BLANK package id — so LEAVING a non-EU package stores to: nil. A condition asking
      # `to_jurisdiction.present?` renders nothing for exactly that row. "When did
      # processing abroad END" is not reconstructible from anywhere else.
      it 'states the move when an organisation LEAVES a jurisdiction for its own configuration' do
        write_entry(organisation, 'ai_package_selected', actor: admin,
                                                         parameters: { 'from_package' => 'A',
                                                                       'to_package' => 'Eigene Konfiguration',
                                                                       'from_jurisdiction' => 'non_eu',
                                                                       'to_jurisdiction' => nil })

        get organisation_ai_protocol_path(organisation)

        expect(response.body).to include(
          I18n.t('views.organisations.ai_overview.protocol.jurisdiction_change',
                 from: I18n.t('views.organisations.ai_settings.packages.jurisdictions.non_eu'),
                 to: I18n.t('views.organisations.ai_settings.packages.jurisdictions.blank'))
        )
      end

      it 'stays silent when the processing location did not move' do
        write_entry(organisation, 'ai_tier_selected', actor: admin,
                                                      parameters: { 'from_tier_key' => 'balanced', 'to_tier_key' => 'thorough',
                                                                    'from_jurisdiction' => 'eu_native',
                                                                    'to_jurisdiction' => 'eu_native' })

        get organisation_ai_protocol_path(organisation)

        expect(response.body).to include(I18n.t('activities.organisation.ai_tier_selected'))
        # The jurisdiction LABEL is what must be absent, not the template around it: a
        # row that printed "Verarbeitung: Europäisch → Europäisch" would satisfy any
        # assertion about the sentence still being correct.
        expect(response.body).not_to include(I18n.t('views.organisations.ai_settings.packages.jurisdictions.eu_native'))
      end
    end

    # An empty trail is a statement, and the page has to make the right one: entries from
    # before P4e/S0 do not exist and cannot be reconstructed, so "no entries" must not
    # read as "nothing ever happened".
    it 'explains an empty protocol instead of rendering a bare page' do
      get organisation_ai_protocol_path(organisation)

      expect(response.body).to include(I18n.t('views.organisations.ai_overview.protocol.empty_title'))
      expect(response.body).to include(I18n.t('views.organisations.ai_overview.protocol.empty_body').squish)
    end

    describe 'the ceiling, which is what keeps this page from ageing badly' do
      # One marker per rendered row — the page's own data attribute, so the count is of
      # ENTRIES and not of some layout element that happens to repeat.
      def rendered_rows
        response.body.scan(/data-protocol-action=/).size
      end

      # MORE than the ceiling, not merely more than a page. With 25 rows the "?items=1000"
      # example below would be vacuum-green: an uncapped request would render all 25 and
      # still satisfy "at most 50". The trail has to be longer than the ceiling for the
      # ceiling to be measurable at all.
      entry_count = Organisations::AiProtocolsController::MAX_PAGE_SIZE + 5

      before do
        entry_count.times do |i|
          write_entry(organisation, 'ai_activated', actor: admin, created_at: i.hours.ago)
        end
      end

      it 'renders one page worth of entries, not the whole trail' do
        get organisation_ai_protocol_path(organisation)

        expect(rendered_rows).to eq(Organisations::AiProtocolsController::PAGE_SIZE)
      end

      # The last page, not the second: a second page full of rows would look the same
      # whether the trail ends there or is silently cut off, while the remainder proves
      # every entry is actually reachable.
      it 'reaches the rest through the pages behind it' do
        last_page = (entry_count.to_f / Organisations::AiProtocolsController::PAGE_SIZE).ceil

        get organisation_ai_protocol_path(organisation, page: last_page)

        expect(response).to have_http_status(:ok)
        expect(rendered_rows).to eq(entry_count % Organisations::AiProtocolsController::PAGE_SIZE)
      end

      # `?items=` reaches this page only from the URL — the stored-preference injection
      # in Organisations::BaseController#ensure_items_parameter needs a Turbo-Frame header
      # and this page has no frame. The cap matters regardless: the trail grows without
      # bound, and nothing else stops a hand-typed number from loading all of it.
      it 'caps a request that asks for more' do
        get organisation_ai_protocol_path(organisation, items: 1000)

        # Exactly the ceiling, not "at most": there are more entries than that, so a
        # request that got what it asked for renders more, and the equality is what
        # fails once the cap is gone.
        expect(rendered_rows).to eq(Organisations::AiProtocolsController::MAX_PAGE_SIZE)
      end

      # The other half of the same rule, and the reason the cap is a clamp rather than a
      # fixed size: a ceiling that also ignored SMALLER values would leave the selector
      # in the pagination footer offering choices that do nothing.
      it 'honours a request that asks for less' do
        get organisation_ai_protocol_path(organisation, items: 10)

        expect(rendered_rows).to eq(10)
      end
    end

    # A page size alone does not bound the cost. Every row renders Activity#message,
    # which reads the actor AND, through #trackable_display_name, the trackable — one
    # query each per row without the preloads. That is invisible on the two-row page a
    # developer looks at and is twenty times as expensive on a full one, which is the
    # normal state of an audit trail. Counted rather than asserted through a matcher, so
    # the example says what it measures.
    describe 'the cost per row' do
      def count_queries
        count = 0
        subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
          count += 1 unless payload[:name].to_s.match?(/SCHEMA|TRANSACTION|CACHE/)
        end
        yield
        count
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      it 'does not grow with the number of entries on the page' do
        2.times { |i| write_entry(organisation, 'ai_activated', actor: admin, created_at: i.hours.ago) }
        get organisation_ai_protocol_path(organisation) # warm up: first-request lookups belong to no page
        few = count_queries { get organisation_ai_protocol_path(organisation) }

        # Distinct actors on purpose: a per-row actor query is invisible when every row
        # shares one, because Rails answers the repeats from the query cache.
        18.times do |i|
          write_entry(organisation, 'ai_activated', actor: create(:user), created_at: (i + 3).hours.ago)
        end

        expect(count_queries { get organisation_ai_protocol_path(organisation) }).to eq(few)
      end
    end
  end

  # The trail names who changed the AI configuration and when — personal data about
  # colleagues, and the organisation's jurisdiction history. It is evidence for the AVV,
  # not a team feed, so it takes the same gate as every other page of the area (§2.4).
  describe 'as regular member (not account_admin)' do
    before { sign_in member }

    it 'is denied and told so, rather than silently shown an empty page' do
      write_entry(organisation, 'ai_activated', actor: admin)

      get organisation_ai_protocol_path(organisation)

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to be_present
      expect(response.body).not_to include('Ada Adminson')
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

    # The priming request puts the outsider's OWN organisation into the session; without
    # it Organisations::BaseController#set_current_membership redirects to the org picker
    # and the example below would pass for a reason unrelated to the lookup it is about.
    before do
      sign_in outsider
      get organisation_ai_protocol_path(organisation_id: outsider_org.id)
    end

    it 'gets 404 (membership-scoped lookup, no existence leak)' do
      get organisation_ai_protocol_path(organisation)

      expect(response).to have_http_status(:not_found)
    end
  end

  # The hub's fifth card. Two things about it differ from its neighbours on purpose, and
  # both are decisions rather than styling.
  describe 'the card on the hub' do
    before { sign_in admin }

    # The rows' own links: the section's tab row above them leads to the protocol as well
    # (doc/verwaltung_seitennavigation_plan.md S3), so the page as a whole proves nothing.
    def hub_row_links
      Nokogiri::HTML(response.body).css('#ai_overview_rows a').map { |link| link['href'] }
    end

    it 'links to the protocol' do
      get organisation_ai_overview_path(organisation)

      expect(hub_row_links).to include(organisation_ai_protocol_path(organisation))
    end

    # Every other card is locked while AI is off. This one is not: it leads to the record
    # of the switch that was just thrown, and locking it would hide the evidence of a
    # deactivation at exactly the moment somebody goes looking for it.
    it 'stays reachable while AI is switched off' do
      organisation.update!(ai_enabled: false)

      get organisation_ai_overview_path(organisation)

      expect(hub_row_links).to include(organisation_ai_protocol_path(organisation))
    end
  end
end
