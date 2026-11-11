# frozen_string_literal: true

# What: GET /ai_settings/confirm_package — the KI-Pakete P4b consequence dialog
#   that now stands between a package card and a lane-moving switch.
# Type: Request spec.
# Why (philosophy): P4a made the switch customer-triggerable and metered while
#   the cards stayed shut; §9 named the one thing that had to exist before they
#   could open — a quota pre-check, because the gate fires ONCE at the provider
#   build and a run that starts inside the budget keeps going until the corpus is
#   done, taking chat AND semantic search down with it for the rest of the month.
#   These examples therefore assert the dialog's STATEMENTS, not its markup: what
#   changes legally, what it costs, whether the quota covers it, and what search
#   does meanwhile. A dialog that renders but omits one of those is the failure
#   mode this slice exists to prevent.
# Contract: the dialog appears only for a switch that actually moves the vector
#   space; it names both jurisdictions and the direction of the change; it quotes
#   an estimate and holds it against the remaining quota; and the only write it
#   offers is the same #select_package POST the card used to fire directly.

require 'rails_helper'

RSpec.describe 'Organisations::AiSettings package switch dialog (P4b)', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin) { create(:user) }
  let(:admin_role) { ActsAsTenant.with_tenant(organisation) { create(:admin_role, organisation: organisation) } }

  let!(:admin_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
    end
  end

  # Same reason as in ai_settings_package_selection_spec: without a resolvable
  # own lane the switch guard has no "before" triple and fails closed on every
  # pick, so a same-lane example would never be reachable.
  let!(:system_embedding_credential) do
    create(:ai_credential, provider: 'openai', active: true, region: 'eu', company_domicile: 'eu')
  end

  # dims 1536 is what the system credential derives — raising it is how an example
  # asks for a switch that genuinely moves the vector space.
  #
  # The jurisdiction travels through the CREDENTIAL's two axes, not through the
  # column alone: AiPackage#effective_jurisdiction recomputes the rung from them
  # (P2-B3), and the model refuses a stored claim its credentials contradict. So
  # an example that wants a non-EU package has to give it non-EU credentials.
  # Region and domicile come from the MATRIX, not from an eu_native/rest guess:
  # AiPackage validates the declared rung against the pair it derives from the
  # credential (§3, consistency check), so a crude binary mapping could only ever
  # build the two extreme rungs. `.key` answers nil for SELF_HOSTED, which is
  # exempt from that check by design (a third axis, AiPackage:66-68) — the
  # fallback pair is then never compared against anything.
  def publish_package(name:, jurisdiction: 'eu_native', dims: 1536, model: 'text-embedding-3-small')
    domicile_eu, region_eu = AiPackage::JURISDICTION_MATRIX.key(jurisdiction) || [false, false]
    credential = create(:ai_credential, region: region_eu ? 'eu' : 'us',
                                        company_domicile: domicile_eu ? 'eu' : 'non_eu')
    package = build(:ai_package, name: name, jurisdiction: jurisdiction, active: true,
                                 embedding_credential: credential,
                                 embedding_model: model, embedding_dims: dims)
    AiPackageTier::KEYS.each_with_index do |key, index|
      package.tiers << build(:ai_package_tier, ai_package: package, key: key,
                                               label: AiPackageTier::DEFAULT_LABELS.fetch(key),
                                               chat_credential: credential, position: index)
    end
    package.save!
    package
  end

  # A corpus of a known size, so the quoted estimate is a number the example can
  # reason about rather than whatever the factories happened to leave behind.
  # 4.000 characters = 1.000 tokens = exactly 1 credit at the DOCUMENT_INDEXING
  # tariff (see Embeddings::SwitchEstimate).
  def corpus_of(characters)
    ActsAsTenant.with_tenant(organisation) do
      project = create(:project, organisation: organisation)
      create(:project_capability, project: project, organisation: organisation,
                                  description: 'a' * characters)
    end
  end

  def t(key, **args)
    I18n.t("views.organisations.ai_settings.packages.switch.#{key}", **args)
  end

  # The org's CURRENT vector space, and the pointer at it. Without one, reads fall
  # back to the configured triple and a switch is HARD rather than staged — so this
  # is what "the normal case" looks like, and an example that wants the reassuring
  # search text has to build it. A plain create(:organisation) has no pointer, which
  # is why every dialog example rendered the hard variant until #437's blocker 2.
  def with_space_pointer
    space = ActsAsTenant.with_tenant(organisation) { create(:embedding_space, organisation: organisation) }
    organisation.update_column(:active_embedding_space_id, space.id)
    space
  end

  before { sign_in admin }

  describe 'a switch that moves the vector space' do
    let!(:other_space_package) { publish_package(name: 'Groß', dims: 3072, model: 'text-embedding-3-large') }

    before do
      corpus_of(4_000)
      # A budget the estimate cannot exhaust, so this example asserts the dialog's
      # STRUCTURE; the pre-check's own branches have their own describe below.
      organisation.update!(ai_quota_credits_override: 500, ai_quota_buffer_override: 5)
      with_space_pointer
    end

    it 'states the four consequences and offers the write behind them' do
      get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: other_space_package.id)

      expect(response).to have_http_status(:ok)
      # 1 — the legal side, both statements named rather than only the new one.
      expect(response.body).to include(t('legal_heading'))
      expect(response.body).to include(t('side_today'), t('side_after'))
      # 2 — the estimate, as an estimate.
      expect(response.body).to include(t('cost_estimate', records: '1', credits: '1'))
      expect(response.body).to include(t('cost_estimate_hint'))
      # 3 — the quota pre-check (§9 precondition 1); this org has budget left.
      expect(response.body).to include(t('quota_covered', remaining: '500'))
      # 4 — the rebuild and its time lag (E3).
      expect(response.body).to include(t('search_body'), t('search_gap'))
      # …and the button is the SAME write the card used to fire directly.
      expect(response.body).to include(select_package_organisation_ai_settings_path(organisation))
      expect(response.body).to include(%(value="#{other_space_package.id}"))
    end

    # The recipient line comes from Factory.routing_disclosure, so the dialog and
    # the chat page's Art. 13 notice cannot name different "today" recipients for
    # the same moment.
    it 'names who receives the search input today and afterwards' do
      get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: other_space_package.id)

      disclosure = Lalabase::Llm::Factory.routing_disclosure(organisation.reload)
      expect(response.body).to include(
        ERB::Util.html_escape(
          t('search_recipients', today: disclosure.embedding_provider_label,
                                 after: other_space_package.embedding_credential.display_label)
        )
      )
    end
  end

  # The whole point of the legal half: the customer has to be told which DIRECTION
  # the third-country question moves in, not merely that something changed.
  describe 'the jurisdiction verdict' do
    it 'says a third-country transfer ARISES when leaving an eu_native package' do
      current = publish_package(name: 'Europäisch')
      organisation.update!(ai_package: current, ai_package_tier_key: 'fast')
      target = publish_package(name: 'Global', jurisdiction: 'non_eu', dims: 3072)

      get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: target.id)

      expect(response.body).to include(t('jurisdiction_change.from_eu_native'))
      expect(response.body).not_to include(t('jurisdiction_change.to_eu_native'))
    end

    it 'says it CEASES on the way back to an eu_native package' do
      current = publish_package(name: 'Global', jurisdiction: 'non_eu')
      organisation.update!(ai_package: current, ai_package_tier_key: 'fast')
      target = publish_package(name: 'Europäisch', dims: 3072)

      get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: target.id)

      expect(response.body).to include(t('jurisdiction_change.to_eu_native'))
      expect(response.body).not_to include(t('jurisdiction_change.from_eu_native'))
    end

    # Two packages in the same legal rung on different vector spaces: the search
    # index moves, the jurisdiction does not. Saying otherwise would push a
    # customer to re-read a legal statement that did not change — and would let
    # the verdict collapse into "something happened" for every switch.
    it 'says the jurisdiction is untouched when both sides sit in the same rung' do
      current = publish_package(name: 'Europäisch')
      organisation.update!(ai_package: current, ai_package_tier_key: 'fast')
      target = publish_package(name: 'Europäisch Groß', dims: 3072)

      get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: target.id)

      expect(response.body).to include(t('jurisdiction_change.unchanged'))
      expect(response.body).not_to include(t('jurisdiction_change.changed'))
    end

    # Neither side is eu_native: something moved, but naming it an improvement or
    # a deterioration would be an invented claim. This case exists for it.
    #
    # Both sides are real MATRIX rungs — until the #437 review this example moved to
    # BLANK and still asserted `changed`, so its title ("between two non-eu_native
    # statements") described a setup it did not build, and the case it claimed to
    # cover stayed untested.
    it 'reports a move between two non-eu_native statements as a plain change' do
      current = publish_package(name: 'Global', jurisdiction: 'non_eu', dims: 3072)
      organisation.update!(ai_package: current, ai_package_tier_key: 'fast')
      target = publish_package(name: 'EU-Region', jurisdiction: 'eu_region_foreign_provider')

      get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: target.id)

      expect(response.body).to include(t('jurisdiction_change.changed'))
      expect(response.body).not_to include(t('jurisdiction_change.from_eu_native'))
      expect(response.body).not_to include(t('jurisdiction_change.to_eu_native'))
    end

    # "Eigene Konfiguration" claims no jurisdiction at all. Reporting that as a
    # deterioration invents a legal statement; reporting it as unchanged hides one.
    # It is its own case (AiSettingsController#jurisdiction_change).
    #
    # ⚠️ This example USED TO ASSERT THE DEFECT (#437 review): its title and comment
    # said "neither better nor worse" while the assertion demanded `from_eu_native`
    # — the deterioration. Green, and therefore read as a guard while cementing
    # exactly the statement it names as wrong. Kept as a reminder: a title and an
    # assertion that disagree prove nothing, and this is the most-travelled path
    # (every way back to "Eigene Konfiguration" lands here).
    it 'reports a move to an unstated jurisdiction as neither better nor worse' do
      # dims 3072 so that DROPPING this package really moves the lane back onto
      # the org's own 1536 one — otherwise the way back is a same-lane pick and
      # never reaches the dialog at all.
      current = publish_package(name: 'Europäisch', dims: 3072)
      organisation.update!(ai_package: current, ai_package_tier_key: 'fast')

      get confirm_package_organisation_ai_settings_path(organisation)

      expect(response.body).to include(t('jurisdiction_change.unstated'))
      expect(response.body).not_to include(t('jurisdiction_change.from_eu_native'))
      expect(response.body).to include(t('jurisdiction_unstated'))
      # The way back has no package credential to name, so the recipient line
      # says what actually decides then: the org's own provider form.
      expect(response.body).to include(ERB::Util.html_escape(t('recipient_custom')))
    end

    # The THIRD axis (AiPackage:66-68), and the sharper half of the same defect: a
    # binary "== EU_NATIVE" made this the INVERSION of the truth. Moving to a
    # self-hosted server announced that a third-country transfer ARISES — for the
    # option that has none at all, and arguably the strictest one on offer.
    it 'claims no third-country change when moving to a self-hosted package' do
      current = publish_package(name: 'Europäisch', dims: 3072)
      organisation.update!(ai_package: current, ai_package_tier_key: 'fast')
      target = publish_package(name: 'Eigener Server', jurisdiction: AiPackage::SELF_HOSTED)

      get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: target.id)

      expect(response.body).to include(t('jurisdiction_change.self_hosted_target'))
      expect(response.body).not_to include(t('jurisdiction_change.from_eu_native'))
      # NOT "cannot be derived" either: self_hosted makes a real statement, and the
      # badge two lines above already names it (#437 review, finding 6).
      expect(response.body).not_to include(t('jurisdiction_change.unstated'))
    end

    # The mirror direction, which the same binary test got wrong the other way:
    # it announced that a transfer CEASES that never existed.
    it 'claims none on the way back from a self-hosted package either' do
      current = publish_package(name: 'Eigener Server', jurisdiction: AiPackage::SELF_HOSTED, dims: 3072)
      organisation.update!(ai_package: current, ai_package_tier_key: 'fast')
      target = publish_package(name: 'Europäisch')

      get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: target.id)

      expect(response.body).to include(t('jurisdiction_change.self_hosted_source'))
      expect(response.body).not_to include(t('jurisdiction_change.to_eu_native'))
    end

    # The self_hosted texts NAME an external provider ("geht an einen externen
    # Anbieter" / "findet danach nicht mehr statt"). Both claims are about the OTHER
    # side — so when that side states nothing, they are invented, exactly like the
    # binary == EU_NATIVE test was one branch earlier. "Eigene Konfiguration" is the
    # target of every way back, and the same page says two lines above that no
    # jurisdiction is recorded for it.
    it 'claims nothing about a provider when leaving self_hosted for an unstated target' do
      current = publish_package(name: 'Eigener Server', jurisdiction: AiPackage::SELF_HOSTED, dims: 3072)
      organisation.update!(ai_package: current, ai_package_tier_key: 'fast')

      get confirm_package_organisation_ai_settings_path(organisation)

      expect(response.body).to include(t('jurisdiction_change.unstated'))
      expect(response.body).not_to include(t('jurisdiction_change.self_hosted_source'))
    end

    # The mirror: "eine Übermittlung findet danach NICHT MEHR statt" asserts that one
    # existed before — about a side that never said so.
    it 'claims nothing about a previous transfer when arriving at self_hosted from an unstated source' do
      target = publish_package(name: 'Eigener Server', jurisdiction: AiPackage::SELF_HOSTED, dims: 3072)

      get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: target.id)

      expect(response.body).to include(t('jurisdiction_change.unstated'))
      expect(response.body).not_to include(t('jurisdiction_change.self_hosted_target'))
    end
  end

  # T7 (doc/ki_vertragsdaten_plan.md). Until now the dialog only compared the
  # jurisdiction, even though it is built explicitly "to compare in the same
  # words in which the customer chose the package". Anyone who had chosen because
  # of "kein Training" therefore switched without warning to a provider that
  # trains. This very line is the purpose of the slice.
  describe 'the training verdict (T7)' do
    def assess(package, training:, retention: AiCredentialContract::RETENTION_UNSPECIFIED, days: nil)
      create(:ai_credential_contract, ai_credential: package.embedding_credential,
                                      training_usage: training, retention_policy: retention,
                                      retention_days: days)
    end

    def switch(from:, to:)
      organisation.update!(ai_package: from, ai_package_tier_key: 'fast')
      get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: to.id)
    end

    # THE line T7 exists for.
    it 'warns when the new provider trains and the old one contractually did not' do
      current = publish_package(name: 'Zurückhaltend')
      target = publish_package(name: 'Trainiert', dims: 3072)
      assess(current, training: AiCredentialContract::TRAINING_EXCLUDED)
      assess(target, training: AiCredentialContract::TRAINING_USED)

      switch(from: current, to: target)

      expect(response.body).to include(t('training_change.to_used'))
      expect(response.body).not_to include(t('training_change.to_excluded'))
    end

    it 'names the improvement on the way back' do
      current = publish_package(name: 'Trainiert')
      target = publish_package(name: 'Zurückhaltend', dims: 3072)
      assess(current, training: AiCredentialContract::TRAINING_USED)
      assess(target, training: AiCredentialContract::TRAINING_EXCLUDED)

      switch(from: current, to: target)

      expect(response.body).to include(t('training_change.to_excluded'))
      expect(response.body).not_to include(t('training_change.to_used'))
    end

    it 'says nothing changed when both sides carry the same assurance' do
      current = publish_package(name: 'Zurückhaltend A')
      target = publish_package(name: 'Zurückhaltend B', dims: 3072)
      assess(current, training: AiCredentialContract::TRAINING_EXCLUDED)
      assess(target, training: AiCredentialContract::TRAINING_EXCLUDED)

      switch(from: current, to: target)

      expect(response.body).to include(t('training_change.unchanged'))
      expect(response.body).not_to include(t('training_change.to_used'))
    end

    # "Nicht zugesichert" is no commitment you can compare against. Claiming
    # neither improvement nor deterioration is the only honest answer
    # here; either one would be invented.
    it 'refuses to call it better or worse when one side assures nothing' do
      current = publish_package(name: 'Zurückhaltend')
      target = publish_package(name: 'Ungeprüft', dims: 3072)
      assess(current, training: AiCredentialContract::TRAINING_EXCLUDED)

      switch(from: current, to: target)

      expect(response.body).to include(t('training_change.not_comparable'))
      expect(response.body).not_to include(t('training_change.to_used'))
      expect(response.body).not_to include(t('training_change.to_excluded'))
    end

    # The most expensive case, and the reason for the order in the controller: for
    # self_hosted the question is MOOT, not open. Each of the four sentences
    # would claim something here about a side that states nothing at all: exactly
    # the defect the #437 review pulled out of the neighbouring method four times.
    # The jurisdiction line already carries the case.
    it 'renders NO training verdict at all when the target is self-hosted' do
      current = publish_package(name: 'Zurückhaltend')
      target = publish_package(name: 'Eigener Server', jurisdiction: AiPackage::SELF_HOSTED, dims: 3072)
      assess(current, training: AiCredentialContract::TRAINING_EXCLUDED)

      switch(from: current, to: target)

      %w[unchanged to_used to_excluded not_comparable].each do |verdict|
        expect(response.body).not_to include(t("training_change.#{verdict}"))
      end
      expect(response.body).to include(t('jurisdiction_change.self_hosted_target'))
    end

    # The same emptiness from the other direction: "Eigene Konfiguration" is not a
    # package at all, so there is no commitment from before. No sentence may appear here either.
    it 'renders NO training verdict when the org has no package to compare against' do
      target = publish_package(name: 'Trainiert', dims: 3072)
      assess(target, training: AiCredentialContract::TRAINING_USED)

      organisation.update!(ai_package: nil)
      get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: target.id)

      %w[unchanged to_used to_excluded not_comparable].each do |verdict|
        expect(response.body).not_to include(t("training_change.#{verdict}"))
      end
    end

    # The comparison must be readable in the same words as the card. Otherwise
    # the warning only stands in the verdict and not where customers check it against
    # their original choice.
    it 'shows each side its own badge and addendum, like the card does' do
      current = publish_package(name: 'Zurückhaltend')
      target = publish_package(name: 'Trainiert', dims: 3072)
      assess(current, training: AiCredentialContract::TRAINING_EXCLUDED,
                      retention: AiCredentialContract::RETENTION_NONE)
      assess(target, training: AiCredentialContract::TRAINING_USED,
                     retention: AiCredentialContract::RETENTION_LIMITED, days: 30)

      switch(from: current, to: target)

      packages = 'views.organisations.ai_settings.packages'
      expect(response.body).to include(I18n.t("#{packages}.training_usages.excluded"))
      expect(response.body).to include(I18n.t("#{packages}.training_usages.used"))
      expect(response.body).to include(I18n.t("#{packages}.training_notes.used"))
      expect(response.body).to include(I18n.t("#{packages}.retention_notes.none"))
      expect(response.body).to include(I18n.t("#{packages}.retention_notes.limited", count: 30))
    end
  end

  # The card asks the EMBEDDING question before the rung question, so a package
  # that is both lane-moving and unselectable now renders as a link in here. Before
  # P4b that ordering was inert (the first branch was a disabled button); opening
  # the door turned it into a dead end that quotes a price and offers a button the
  # Actor answers with :tier_not_offered / :tier_credential_unusable.
  #
  # Added after the #437 review's finding 2 — and note WHY it is here: the guard
  # itself was written first and no example covered it, so removing it changed
  # nothing that was measured. A guard nobody can fail is not a guard.
  describe 'a package that is lane-moving AND unselectable' do
    it 'turns away at the dialog instead of quoting a price for a dead end' do
      target = publish_package(name: 'Kaputte Stufe', dims: 3072)
      # Same refusal the Actor reaches, via the purpose rather than `enabled`:
      # #usable_for?(:chat) is enabled? && serves_lane?(:chat) && endpoint_resolvable?,
      # and a credential a package references cannot be disabled at all (the P1
      # reference guard) — which is itself worth knowing when building this state.
      target.tiers.each { |tier| tier.chat_credential.update!(purpose: 'embedding') }

      get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: target.id)

      expect(response).to redirect_to(organisation_ai_settings_path(organisation))
      expect(flash[:alert]).to eq(t('tier_unusable'))
    end
  end

  # §9's first hard precondition, and the reason the card doors could not open
  # before this slice.
  # #437 review, blocker 2. The reassuring "search keeps serving from the existing
  # index" only holds for an org that HAS a space pointer. Without one,
  # Factory.embedding_space_for(:active) falls back to the CONFIGURED triple, so the
  # reads jump onto the new, empty space the moment the write lands — search and RAG
  # chat return nothing until the rebuild finishes. Reachable because the column is
  # nullable and #431's backfill is fail-soft.
  describe 'an organisation without a vector-space pointer' do
    let!(:target) { publish_package(name: 'Groß', dims: 3072, model: 'text-embedding-3-large') }

    it 'says the search goes DARK instead of promising continuity' do
      corpus_of(4_000)
      expect(organisation.active_embedding_space_id).to be_nil

      get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: target.id)

      expect(response.body).to include(t('search_body_hard'))
      expect(response.body).not_to include(t('search_body'))
    end

    it 'keeps the reassuring wording once a pointer exists' do
      corpus_of(4_000)
      with_space_pointer

      get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: target.id)

      expect(response.body).to include(t('search_body'))
      expect(response.body).not_to include(t('search_body_hard'))
    end
  end

  describe 'the quota pre-check' do
    let!(:target) { publish_package(name: 'Groß', dims: 3072, model: 'text-embedding-3-large') }

    it 'warns when the estimate overshoots what is left of the budget' do
      corpus_of(8_000) # 2.000 tokens ⇒ 2 credits, ×1.3 margin ⇒ 3
      organisation.update!(ai_quota_credits_override: 1, ai_quota_buffer_override: 5)

      get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: target.id)

      expect(response.body).to include(t('quota_short_title'))
      # The three numbers on the page reconcile: planned (3) − remaining (1) = 2.
      # They did not before — the warning used the margined figure while the cost
      # line showed the raw one, so "2 credits" against "1 left" claimed "2 above".
      expect(response.body).to include(
        t('quota_short_body', remaining: '1', planned: '3', shortfall: '2')
      )
      expect(response.body).not_to include(t('quota_covered', remaining: '1'))
    end

    # The margin (#437 review, finding 3). SwitchEstimate is a ±30 % rule of thumb
    # and only ONE of its two error sources points downwards — the skip logic does,
    # the characters/4 token approximation does not, and CodeSymbol signatures are
    # code, which tokenises denser. An estimate that lands exactly on the remaining
    # budget is a coin flip, and the losing side costs the customer chat and search
    # for the rest of the month. Without the margin this org would read "covered".
    it 'refuses to call an estimate covered when it only just fits' do
      corpus_of(8_000) # 2 credits
      organisation.update!(ai_quota_credits_override: 2, ai_quota_buffer_override: 5)

      get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: target.id)

      expect(response.body).to include(t('quota_short_title'))
      expect(response.body).not_to include(t('quota_covered', remaining: '2'))
    end

    # #437 review, blocker 1 — the counterweight with the most teeth. The gate that
    # actually stops a run asks the CREDENTIAL of the target lane
    # (`ensure_within_quota!` returns early unless `included_in_quota?`), and that
    # column defaults to false. Reading the ledger unconditionally made all three
    # branches describe a block that cannot fire: red announcing "the rebuild starts
    # next month" for a run that starts immediately, green reassuring about credits
    # nobody books. For an unflagged lane the dialog must say NOTHING about quota.
    it 'says nothing about quota when the target lane is not metered at all' do
      corpus_of(8_000)
      organisation.update!(ai_quota_credits_override: 1, ai_quota_buffer_override: 5)
      # ONLY the target package's own credential. A blanket
      # AiCredential.update_all — which is what this example did first — flips the
      # provider's active row too, so it cannot tell WHICH credential the branch
      # reads. That blind spot is precisely what let the wrong-credential defect
      # through the first review (#437, second round).
      target.embedding_credential.update!(included_in_quota: false)

      get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: target.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(t('cost_estimate', records: '1', credits: '2'))
      expect(response.body).not_to include(t('quota_short_title'), t('quota_exhausted_title'))
      expect(response.body).not_to include(t('quota_covered', remaining: '1'))
    end

    # The mirror, and the expensive direction: the package's credential IS metered
    # while the provider's `active` row is not. A name-based lookup answers off the
    # active row and stays silent — the customer starts, the month's budget goes,
    # chat and search are gone until it rolls over.
    #
    # Both rows exist here on purpose: AiCredential.active_for_provider returns the
    # single active: true row per provider name, and a curated package references an
    # ENABLED row instead (Factory#resolve_embedding_credentials). With two
    # openai_compatible rows side by side — the normal case for the EU packages —
    # those are simply different credentials.
    it 'judges the PACKAGE credential, not the provider default' do
      corpus_of(8_000)
      organisation.update!(ai_quota_credits_override: 1, ai_quota_buffer_override: 5)
      system_embedding_credential.update!(included_in_quota: false)
      target.embedding_credential.update!(included_in_quota: true, active: false)

      get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: target.id)

      expect(response.body).to include(t('quota_short_title'))
    end

    # The counterweight — without it the warning could simply always render and
    # both halves of the check would still look asserted.
    it 'confirms coverage when the budget is comfortably above the estimate' do
      corpus_of(4_000) # 1 credit
      organisation.update!(ai_quota_credits_override: 500, ai_quota_buffer_override: 5)

      get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: target.id)

      expect(response.body).to include(t('quota_covered', remaining: '500'))
      expect(response.body).not_to include(t('quota_short_title'))
    end

    # A different fault with a different answer: an already exhausted quota does
    # not overshoot, it prevents the run from starting at all. That is a PAUSE —
    # ReindexOrganisationJob logs "switch paused" and P4d's watcher resumes it
    # next month — so the copy must not read like the overshoot warning.
    it 'tells an exhausted org the rebuild starts next month, not that it overshoots' do
      corpus_of(4_000)
      with_space_pointer
      organisation.update!(ai_quota_credits_override: 0, ai_quota_buffer_override: 0)

      get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: target.id)

      expect(organisation.reload.ai_quota_ledger.state).to eq(:exhausted)
      expect(response.body).to include(t('quota_exhausted_title'), t('quota_exhausted_body'))
      expect(response.body).not_to include(t('quota_short_title'))
    end
  end

  # ONE sentence about search per page, derived from BOTH facts that decide it.
  #
  # The two blocks used to answer this question independently — the quota box carried
  # its own "bis dahin durchsucht die Suche unverändert den bisherigen Index" while the
  # search box branched on the pointer alone. They disagreed in two of the four
  # combinations, and the worst one told a customer their search stays served while the
  # truth was: empty, and empty until the month rolls over.
  #
  # Written as a MATRIX rather than as three examples plus a special case, because the
  # defect was precisely that the rule was enforced twice by hand.
  describe 'what the page says about search (pointer × quota)' do
    let!(:target) { publish_package(name: 'Groß', dims: 3072, model: 'text-embedding-3-large') }

    [
      { pointer: true,  exhausted: false, key: 'search_body' },
      { pointer: false, exhausted: false, key: 'search_body_hard' },
      { pointer: true,  exhausted: true,  key: 'search_body_paused' },
      { pointer: false, exhausted: true,  key: 'search_body_hard_paused' }
    ].each do |combination|
      it "says exactly one thing with pointer=#{combination[:pointer]} " \
         "exhausted=#{combination[:exhausted]}" do
        corpus_of(4_000)
        with_space_pointer if combination[:pointer]
        if combination[:exhausted]
          organisation.update!(ai_quota_credits_override: 0, ai_quota_buffer_override: 0)
        else
          organisation.update!(ai_quota_credits_override: 500, ai_quota_buffer_override: 5)
        end

        get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: target.id)

        expect(response.body).to include(t(combination[:key]))
        # …and NONE of the other three. This is the half that catches a second
        # statement creeping back into the quota box.
        (%w[search_body search_body_hard search_body_paused search_body_hard_paused] -
          [combination[:key]]).each do |other|
          expect(response.body).not_to include(t(other))
        end
      end
    end
  end

  # organisations.ai_enabled defaults to FALSE in the database while the factory
  # sets true, so this is the production-common case the suite is otherwise blind
  # to. Actors::SelectAiPackage#enqueue_jobs returns early for such an org: no
  # reindex, no credits, no transmission. Quoting a price would describe events
  # that cannot happen.
  describe 'an organisation without the AI opt-in' do
    it 'drops the estimate, the quota check and the rebuild notice' do
      organisation.update!(ai_enabled: false)
      target = publish_package(name: 'Groß', dims: 3072, model: 'text-embedding-3-large')
      corpus_of(4_000)

      get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: target.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(t('ai_disabled_note'))
      expect(response.body).not_to include(t('cost_estimate_hint'))
      expect(response.body).not_to include(t('search_body'))
      # The legal half still applies — the package decides where data WOULD go.
      expect(response.body).to include(t('legal_heading'))
    end
  end

  describe 'targets that need no dialog' do
    # A same-lane pick re-embeds nothing and costs nothing; the card offers the
    # direct button for it. A dialog here would ask the customer to confirm
    # consequences that do not exist.
    it 'sends a same-lane pick straight back to the settings page' do
      same_lane = publish_package(name: 'Europäisch')
      expect(same_lane.embedding_switch_for?(organisation)).to be(false)

      get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: same_lane.id)

      expect(response).to redirect_to(organisation_ai_settings_path(organisation))
      expect(flash[:alert]).to be_blank
      # Not an error, but not silent either (#437 review, finding 6): a customer
      # who saved this URL — or whose catalogue went stale between render and
      # click — otherwise lands back on the settings page with no idea why.
      expect(flash[:notice]).to eq(t('same_lane'))
    end

    # Only reachable by hand-built URL — a withdrawn package has no card. The
    # published catalogue is the authority, so there is no second copy of the
    # Actor's refusal codes on this page.
    it 'turns away a package the catalogue would not offer' do
      withdrawn = publish_package(name: 'Zurückgezogen', dims: 3072)
      withdrawn.update!(active: false)

      get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: withdrawn.id)

      expect(response).to redirect_to(organisation_ai_settings_path(organisation))
      expect(flash[:alert]).to eq(t('unavailable'))
    end
  end

  # A page below the Zugang tab (doc/verwaltung_seitennavigation_plan.md §5, S3): the
  # head of the AI section with Zugang marked as its parent, and the crumb as the one
  # way back. It leads where "Abbrechen" led until 2026-11-11: onto the pane the card
  # was rendered in, which the card hands over as package_mode. The only button left
  # on the page is the write.
  describe 'the way back' do
    let!(:target) { publish_package(name: 'Groß', dims: 3072, model: 'text-embedding-3-large') }
    let(:access) { I18n.t('views.organisations.ai_overview.pages.access') }

    def dialog(**params)
      get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: target.id, **params)
      expect(response).to have_http_status(:ok)
      Nokogiri::HTML(response.body)
    end

    it 'is the crumb to Zugang, onto the pane the dialog was opened from' do
      doc = dialog(package_mode: 'custom')

      marked = doc.css('main nav:not([data-section-crumb]) [aria-current]')
      expect(marked.map { |tab| [tab.text.squish, tab['aria-current']] }).to eq([[access, 'true']])
      back = doc.at_css('main [data-section-crumb] a')
      expect(back['href']).to eq(organisation_ai_settings_path(organisation, package_mode: 'custom'))
      expect(back.text.delete('‹').squish).to eq(access)
      expect(doc.css('main [aria-current="page"]').map { |item| item.text.squish })
        .to eq([I18n.t('views.organisations.ai_overview.pages.switch')])

      # Nothing else on the page leads back to Zugang: no "Abbrechen" beside the write.
      settings = organisation_ai_settings_path(organisation)
      other_ways_back = doc.css('main a[href]').select { |link| link['href'].start_with?(settings) }
                           .reject { |link| link.ancestors('nav').any? }
      expect(other_ways_back).to be_empty
    end

    # A hand-built URL carries no pane; the settings page then opens its own default.
    it 'leads to Zugang without a pane when the dialog was opened without one' do
      expect(dialog.at_css('main [data-section-crumb] a')['href']).to eq(organisation_ai_settings_path(organisation))
    end
  end

  # The dialog is the first half of a write, so it carries the write's
  # authorisation — a member who may not switch the package has no business
  # reading its price either.
  describe 'as a plain member' do
    let(:member) { create(:user) }
    let(:member_role) { ActsAsTenant.with_tenant(organisation) { create(:role, organisation: organisation) } }

    let!(:member_membership) do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: member, organisation: organisation, role: member_role, active: true)
      end
    end

    it 'cannot open the dialog' do
      target = publish_package(name: 'Groß', dims: 3072, model: 'text-embedding-3-large')
      sign_in member

      get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: target.id)

      expect(response).not_to have_http_status(:ok)
    end

    # AiSettingsPolicy answers show? and update? with the SAME predicate today, so
    # the example above is turned away by the page-level before_action and says
    # nothing about the write right this action asks for on its own. Loosening
    # only the read half is what makes that second check provable — and it is the
    # check that matters, because the dialog is the first half of a metered write
    # (same reasoning as #select_package, which carries the same explicit call).
    it 'still refuses when only the read right is granted' do
      target = publish_package(name: 'Groß', dims: 3072, model: 'text-embedding-3-large')
      allow_any_instance_of(AiSettingsPolicy).to receive(:show?).and_return(true)
      allow_any_instance_of(AiSettingsPolicy).to receive(:update?).and_return(false)
      sign_in member

      get confirm_package_organisation_ai_settings_path(organisation, ai_package_id: target.id)

      expect(response).not_to have_http_status(:ok)
    end
  end
end
