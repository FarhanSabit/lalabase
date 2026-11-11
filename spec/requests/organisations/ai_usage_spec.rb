# frozen_string_literal: true

require 'rails_helper'

# What: Request spec for "Verbrauch", the AI area's consumption page
#   (doc/ki_bereich_navigation_plan.md S6, gap L8).
# Type: Request spec — authorization, the numbers, and the MOVE itself.
# Why (philosophy): the quota bar, the six-month Nachweis-Historie and the 30-day token
#   statistic used to share the settings page with the package catalogue and the provider
#   form, which is why the hub's "Verbrauch" card linked to the same URL as its "Zugang"
#   card. The examples below therefore assert on both ends of the move: the new page shows
#   the real values, and the old page no longer does. A spec that only checked the new
#   page would stay green if the content had merely been COPIED.
#   The consumption examples (bar, 80% warning, Kulanz, exhausted banner) come verbatim
#   from spec/requests/organisations/ai_settings_quota_spec.rb (S3 KI-Kontingent UI,
#   test 25) — moved with their subject rather than deleted.
# Contract: account_admin only; credits before tokens; ONE QuotaLedger per request.
RSpec.describe 'Organisations::AiUsages', type: :request do
  include ActionView::Helpers::NumberHelper

  # budget 10 + buffer 5 → hard limit 15.
  let(:organisation) { create(:organisation, ai_quota_credits_override: 10, ai_quota_buffer_override: 5) }
  let!(:credential) { create(:ai_credential, :active, provider: 'openai', included_in_quota: true) }
  let(:admin_role) { ActsAsTenant.with_tenant(organisation) { create(:admin_role, organisation: organisation) } }
  let(:user) { create(:user) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    end
  end

  before do
    Rails.cache.clear
    sign_in user
  end

  def book(credits, tokens: 0)
    AiUsage.create!(organisation: organisation, provider: 'openai', ai_credential: credential,
                    credits_used: credits, tokens_used: tokens, used_at: Time.current)
  end

  # The section's tab row (doc/verwaltung_seitennavigation_plan.md S3): the title names
  # the section on every tab, "Verbrauch" is the open tab, and the way to the hub is its
  # tab "Übersicht". Until then a crumb "‹ KI" stood over every page of the area.
  def section_tabs(body)
    tabs = Nokogiri::HTML(body).at_css("main nav[aria-label='#{I18n.t('settings.ai')}']")
    expect(tabs).not_to be_nil, 'no tab row in main named after the section'
    tabs
  end

  it 'heads the page with the section, its own tab open and the hub one tab away' do
    get organisation_ai_usage_path(organisation)

    expect(Nokogiri::HTML(response.body).at_css('main h1').text.squish).to eq(I18n.t('settings.ai'))
    tabs = section_tabs(response.body)
    expect(tabs.at_css('[aria-current="page"]').text.squish).to eq(I18n.t('views.organisations.ai_overview.usage.title'))
    overview = tabs.css('a').find { |link| link.text.squish == I18n.t('views.organisations.ai_overview.pages.overview') }
    expect(overview&.attr('href')).to eq(organisation_ai_overview_path(organisation))
  end

  describe 'the credit figures (moved from the settings page, S3 test 25)' do
    it 'shows the consumption bar with the real used/budget/percent values' do
      book(5)
      get organisation_ai_usage_path(organisation)
      expect(response.body).to include(
        I18n.t('shared.ai.quota.used_of', used: 5, budget: 10, percent: 50)
      )
    end

    it 'shows the 80% pre-warning while still within budget' do
      book(9) # 90% of budget 10
      get organisation_ai_usage_path(organisation)
      expect(response.body).to include(I18n.t('shared.ai.quota.warn_80'))
    end

    it 'shows the Kulanz banner in the grace zone' do
      book(12) # over budget 10, under hard limit 15
      get organisation_ai_usage_path(organisation)
      expect(response.body).to include(I18n.t('shared.ai.quota.grace_banner'))
      expect(response.body).not_to include(I18n.t('shared.ai.quota.exhausted_title'))
    end

    it 'shows the 3-way exhausted banner at the hard limit' do
      book(15)
      get organisation_ai_usage_path(organisation)
      expect(response.body).to include(I18n.t('shared.ai.quota.exhausted_title'))
      expect(response.body).to include(I18n.t('shared.ai.quota.exhausted_byok'))
      expect(response.body).to include(I18n.t('shared.ai.quota.exhausted_reset'))
    end

    # The plan calls the six-month history a Nachweis-PFLICHT, not an ornament: it is
    # what has to exist before a hard gate may bite. Losing it in the move would be the
    # one regression nobody notices, because the page would still look complete.
    it 'shows the six-month Nachweis history with the consumed credits' do
      book(7)
      get organisation_ai_usage_path(organisation)
      expect(response.body).to include(I18n.t('shared.ai.quota.history_heading'))
      expect(response.body).to include(I18n.t('shared.ai.quota.history_detail_toggle'))
    end
  end

  # L8 is an ORDER, not a set: "Fußzeile priorisiert die falsche Zahl". Both numbers may
  # be on the page; the credits have to come first, and the tokens have to say what they
  # are for. Asserting on the byte offsets is the only way to pin that.
  describe 'credits before tokens (L8)' do
    before { book(5, tokens: 4_200) }

    it 'renders the token statistic BELOW the credit bar, with its explanation' do
      get organisation_ai_usage_path(organisation)

      credits_at = response.body.index(I18n.t('shared.ai.quota.heading'))
      tokens_at = response.body.index(I18n.t('views.organisations.ai_overview.usage.tokens_heading'))

      expect(credits_at).to be_present
      expect(tokens_at).to be_present
      expect(credits_at).to be < tokens_at
      expect(response.body).to include(I18n.t('views.organisations.ai_overview.usage.tokens_hint'))
      expect(response.body).to include(
        I18n.t('views.organisations.ai_overview.usage.tokens_value', formatted: number_with_delimiter(4_200))
      )
    end
  end

  # QuotaLedger memoises #used, #budget and #buffer PER INSTANCE, and this page asks all
  # three repeatedly (bar, banners, percentage, history). Two instances therefore mean a
  # second consumption SUM plus another pair of uncached SystemSetting reads — which is
  # exactly what happens if either partial stops being handed the controller's ledger.
  it 'builds exactly one QuotaLedger for the whole page' do
    book(5)
    allow(Lalabase::Llm::QuotaLedger).to receive(:for).and_call_original

    get organisation_ai_usage_path(organisation)

    expect(Lalabase::Llm::QuotaLedger).to have_received(:for).once
  end

  describe 'with AI switched off' do
    let(:organisation) do
      create(:organisation, :ai_disabled, ai_quota_credits_override: 10, ai_quota_buffer_override: 5)
    end

    # The hub locks the card, but the route stays reachable by URL. An empty page there
    # reads as a defect rather than as a state.
    it 'names the state instead of rendering a blank page' do
      get organisation_ai_usage_path(organisation)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('views.organisations.ai_overview.disabled_notice.title'))
      # To the OVERVIEW since doc/ki_zugang_umbau_plan.md D4: the box points at whichever
      # page carries the switch, and that is no longer "Zugang". Read off the box's own
      # link: the tab row and the sidebar lead to the overview as well.
      notice_link = Nokogiri::HTML(response.body).css('main a').find do |link|
        link.text.squish == I18n.t('views.organisations.ai_overview.disabled_notice.action')
      end
      expect(notice_link&.attr('href')).to eq(organisation_ai_overview_path(organisation))
    end

    # Opened by its URL while AI is off: the tab is locked as on every other page of the
    # section, and still marked as the open one, so the reader sees where they are.
    it 'marks its own tab as the open one, locked and without a link' do
      get organisation_ai_usage_path(organisation)
      open_tab = section_tabs(response.body).at_css('[aria-current="page"]')

      expect(open_tab.name).to eq('span')
      expect(open_tab.text.squish).to start_with(I18n.t('views.organisations.ai_overview.usage.title'))
      expect(open_tab.at_css('i.bi-lock')).to be_present
    end

    # Calls that already happened are not unmade by flipping the switch, and hiding them
    # loses the answer to "wofür ging das Kontingent drauf" exactly when it is asked.
    it 'keeps showing tokens already consumed' do
      book(3, tokens: 1_234)

      get organisation_ai_usage_path(organisation)

      expect(response.body).to include(I18n.t('views.organisations.ai_overview.usage.tokens_heading'))
    end
  end

  # The other end of the move. Without these the content could have been copied instead
  # of moved, and the hub would still have two cards pointing at one page.
  describe 'the settings page it came from' do
    before { book(5, tokens: 4_200) }

    it 'no longer carries the quota bar, the history or the token statistic' do
      get organisation_ai_settings_path(organisation)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(I18n.t('shared.ai.quota.heading'))
      expect(response.body).not_to include(I18n.t('shared.ai.quota.history_heading'))
      expect(response.body).not_to include(I18n.t('views.organisations.ai_overview.usage.tokens_heading'))
    end
  end

  # The card is why this slice exists: it linked to the settings page, so the hub offered
  # two cards to one URL and the user noticed.
  describe 'the hub card that points here' do
    # The row's own link: the tab row above the rows leads to the usage page as well.
    it 'sends "Verbrauch" to the usage page, not to the settings page' do
      get organisation_ai_overview_path(organisation)
      row = Nokogiri::HTML(response.body).css('#ai_overview_rows a').find do |link|
        link.text.squish.start_with?(I18n.t('views.organisations.ai_overview.rows.usage.title'))
      end

      expect(row&.attr('href')).to eq(organisation_ai_usage_path(organisation))
    end
  end

  describe 'authorization' do
    let(:member) { create(:user) }
    let(:member_role) { ActsAsTenant.with_tenant(organisation) { create(:role, organisation: organisation) } }
    let!(:member_membership) do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: member, organisation: organisation, role: member_role, active: true)
      end
    end

    # Same gate as every other page of the area (§2.4). Consumption per action is the
    # "wer hat wann was ausgelöst" record the opt-in text promises only admins can read.
    it 'denies a plain member and says so' do
      sign_in member

      get organisation_ai_usage_path(organisation)

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to be_present
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

      # The priming request puts the outsider's OWN org into the session. Without a
      # session tenant, BaseController#set_current_membership runs before the org is
      # resolved, finds nothing and redirects to the picker — a 302 that would let the
      # example pass for a reason unrelated to the membership-scoped lookup.
      before do
        sign_in outsider
        get organisation_ai_usage_path(organisation_id: outsider_org.id)
      end

      it 'gets 404 (membership-scoped lookup, no existence leak)' do
        get organisation_ai_usage_path(organisation)

        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
