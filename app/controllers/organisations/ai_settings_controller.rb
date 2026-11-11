# frozen_string_literal: true

module Organisations
  class AiSettingsController < BaseController
    include AiConnectionCheckable

    before_action :set_organisation
    before_action :authorize_ai_settings

    # The two rungs of each §7.1 filter. Both default to the STRICT value: the
    # customer sees the narrowest catalogue first and has to widen it on purpose
    # ("EU ist Standard, US die bewusste Abweichung").
    FILTER_EU = 'eu'
    FILTER_ANY = 'any'

    # The two answers to the either/or of doc/ki_zugang_umbau_plan.md D6, and the ONLY
    # two values #show accepts for `package_mode`. Anything else falls back to the
    # default, so a hand-built or stale URL cannot render a third thing.
    #
    # The param is called `package_mode` and not `mode` on purpose: it sits next to
    # provider_scope and processing_scope, and a generic name is the one a future param
    # collides with.
    MODE_PACKAGES = 'packages'
    MODE_CUSTOM = 'custom'

    # The two verbs of the opt-in protocol (S0 of doc/ki_bereich_navigation_plan.md,
    # E5/L13). Deliberately NOT the package verbs of Actors::SelectAiPackage: the
    # switch is the customer's legal-basis decision, a package choice is a decision
    # about processors. An audit filing both under one verb would blur exactly the
    # line the protocol exists to document.
    ACTIVITY_ACTIVATED = 'ai_activated'
    ACTIVITY_DEACTIVATED = 'ai_deactivated'

    # [has a vector-space pointer?, quota exhausted?] => the ONE sentence the P4b
    # dialog says about search in that state. See #search_outcome for why this is
    # data rather than two branches in two different blocks.
    SEARCH_OUTCOMES = {
      [true, false] => :search_body,
      [false, false] => :search_body_hard,
      [true, true] => :search_body_paused,
      [false, true] => :search_body_hard_paused
    }.freeze

    # ⚠️ #update is gone since S7 (E6-A), and so is its route. It was a bare
    # `@organisation.update` that wrote four columns, deleted a key as a side effect
    # (L3) and left no trace — the third and last unprotected write site of the AI
    # protocol. Its form moved to Organisations::AiConfigurationsController and its
    # write to Actors::SaveAiConfiguration.
    #
    # Its one non-obvious note travels with it, because it is still true there
    # (S3, decision 5A): NO quota-resume hook belongs on that write. It sets CHAT
    # credentials, while the quota-paused work is EMBEDDINGS, gated on the embedding
    # columns. The effective resume triggers are the admin budget increase
    # (Admin::OrganisationsController#update) and the monthly reset
    # (AiQuotaMonthlyResumeJob).
    def show
      load_package_catalogue
      @package_mode = resolve_package_mode
    end

    # POST /ai_settings/activate
    #
    # GDPR org-level AI opt-in (audit 2026-07-03, item 1.2): records WHO enabled
    # AI features and WHEN. Re-activation overwrites both fields on purpose —
    # the record always documents the latest activation.
    #
    # ⚠️ No longer a trivial single-model write since S0 — it is a column write, an
    # audit row and a backfill that enqueues jobs, which by the project seam rule
    # (CLAUDE.md) is Actor territory. It stays in the controller anyway, and on
    # purpose: the whole reason both actions use update_columns is that this switch
    # must not be wrapped in anything that could block it, and Actors::BaseActor#call
    # wraps its body in a transaction. Moving it becomes right with S7, where #update
    # turns into an Actor and the three write paths get one shape — not before.
    #
    # update_columns on purpose (both actions): the switch writes ONLY its own
    # three columns, and it must never be blocked by an unrelated validation
    # failure on the organisation — deactivate especially is the compliance
    # off-switch and has to work unconditionally. This also removes the
    # practically unreachable "update returned false" branches no test could
    # exercise.
    def activate
      authorize @organisation, :activate?, policy_class: AiSettingsPolicy

      # Read BEFORE the write: the audit row must describe a switch that actually
      # moved. Clicking activate on an already-active org (stale tab, hand-built POST)
      # still refreshes the two history columns, but nothing was switched on — and
      # "nothing happened" in an audit trail is worse than a gap, because a reader
      # cannot tell the two apart afterwards. Same rule the package side applies in
      # Actors::SelectAiPackage#log_choice, for the same reason.
      was_enabled = @organisation.ai_enabled?

      # deliberate, see comment above. The two HISTORY columns move with the audit row,
      # not with the request: they are what the settings page renders as "aktiviert am X
      # von Y", so stamping them on a click that switched nothing would credit the
      # activation to somebody who never made it — and since S0 no audit row would be
      # written to contradict that. Before S0 the two were consistent because both were
      # unconditional; the guard has to cover both or neither.
      history = was_enabled ? {} : { ai_activated_at: Time.current, ai_activated_by_id: current_user.id }
      @organisation.update_columns(ai_enabled: true, updated_at: Time.current, **history)
      Rails.logger.info "AI features activated for organisation #{@organisation.id} by user #{current_user.id}"
      # Before the backfill on purpose: the audit row is the cheap, immediate part of
      # this request, and it must not depend on how the enqueueing half goes.
      log_ai_switch(ACTIVITY_ACTIVATED) unless was_enabled

      # Catch up on everything the pipelines skipped while AI was off — see
      # Embeddings::ActivationBackfill for its halves and their rationale.
      # Synchronous on purpose: apart from two small writes it only counts and
      # enqueues (same pattern as the AI sync page); the heavy work runs in jobs.
      # Those writes are the org's vector-space row and its pointer at that space,
      # which have to exist before a later package change can be a STAGED switch
      # rather than a hard one.
      #
      # ⚠️ Wrapped, because "fail-soft" was only ever true of its FIRST half.
      # ActivationBackfill#ensure_active_space_pointer rescues itself, but the two
      # steps after it do not: EmbeddingReprocessingService hangs its rescue on the
      # with_tenant BLOCK, so the Factory lookup and Gate.exhausted? above it run
      # unprotected — and the gate reads an `encrypts`-backed token, which raises on
      # an undecryptable value. Unwrapped, the admin got a 500 on a request that had
      # already switched AI ON, with no flash telling them so.
      backfill = nil
      begin
        backfill = Embeddings::ActivationBackfill.call(@organisation)
      rescue StandardError => e
        # Same split as #log_ai_switch, and for the same reason: a broken backfill is a
        # defect, and a defect must shout where shouting is free. Swallowing it in dev
        # and test would make this rescue worse than the unprotected call it replaced —
        # that one at least failed loudly on the developer's machine.
        raise if Rails.env.local?

        Rails.logger.error('[AiSettings] activation backfill failed for organisation ' \
                           "#{@organisation.id}: #{e.class}: #{e.message}")
      end

      # Back to the HUB, not to this controller's own page: the buttons that post here
      # live on the overview since doc/ki_zugang_umbau_plan.md D1. The actions stayed
      # behind on purpose (the update_columns hardening above is the reason), so the
      # redirect target is the only thing about them that moved.
      redirect_to organisation_ai_overview_path(@organisation), **activation_flash(backfill)
    end

    # POST /ai_settings/deactivate
    #
    # Only flips the switch — ai_activated_at/_by stay as activation history.
    def deactivate
      authorize @organisation, :deactivate?, policy_class: AiSettingsPolicy

      # See #activate: only a switch that MOVED gets an audit row.
      was_enabled = @organisation.ai_enabled?

      # deliberate, see #activate comment
      @organisation.update_columns(ai_enabled: false, updated_at: Time.current)
      Rails.logger.info "AI features deactivated for organisation #{@organisation.id} by user #{current_user.id}"
      log_ai_switch(ACTIVITY_DEACTIVATED) if was_enabled
      # See #activate: the switch is operated from the hub, so that is where it answers.
      redirect_to organisation_ai_overview_path(@organisation), notice: t('flash.ai_settings.deactivated')
    end

    # POST /ai_settings/select_package
    #
    # KI-Pakete P2 (§7): the org picks a curated package card — or the "Eigene
    # Konfiguration" card, which posts a BLANK id and is the very same write
    # (E1-C: custom is a package kind, not an absence of one).
    #
    # Non-trivial write (switch protocol columns + the embedding-space
    # consequences behind them) → Actor, not an inline update (project seam rule).
    # `update?` is the authorisation: this changes the org's AI configuration,
    # exactly like #update does, and a second policy method for the same right
    # would be a place for the two to drift apart.
    #
    # ONE action for both axes (P3): the card posts a package, the rung switcher
    # inside the chosen card posts the SAME package with a different tier_key.
    # Key name matches the Actor's and the column's (ai_package_tier_key), not a
    # shorter alias: a mismatch here would not fail, it would silently drop the
    # rung and answer with the package flash.
    def select_package
      authorize @organisation, :update?, policy_class: AiSettingsPolicy

      result = Actors::SelectAiPackage.call(
        organisation: @organisation,
        params: { ai_package_id: params[:ai_package_id].presence,
                  ai_package_tier_key: params[:ai_package_tier_key].presence },
        current_user: current_user
      )

      if result.success?
        # Did the PACKAGE move, or only the rung? The two get different copy
        # (§2: the customer made one of two very different decisions), and the
        # answer comes from the record the Actor wrote, never from an id read
        # before the call.
        #
        # A pre-call read speaks about a row this request may no longer be
        # writing: Actors::SelectAiPackage#perform takes a row lock and RELOADS.
        # Two admins racing — B moves the org to Q, A's stale tab posts P — left
        # the old reading comparing P against P and announcing "Leistungsstufe …
        # Rechtsraum und Suchindex bleiben unverändert" for a write that had just
        # moved the jurisdiction back from Q to P. saved_changes are computed
        # after the lock, so they describe the write that actually happened.
        #
        # Asked HERE and not inside the notice helper: that one reloads, and
        # ActiveRecord::AttributeMethods::Dirty#reload drops saved_changes.
        package_changed = result.resource.saved_change_to_ai_package_id?
        # ⚠️ The pane travels with the redirect, and it is derived from the RECORD that
        # was just written, never from the request. Without it #show re-derives the mode
        # from state — and the one write that lands in Z3 is "Eigene Konfiguration
        # nutzen" without credentials, which re-derives to MODE_PACKAGES. The customer
        # would click the custom button, read a success flash, and land on the package
        # catalogue: the same "surface contradicts the decision" class D7 exists to end,
        # on the other foot.
        redirect_to organisation_ai_settings_path(@organisation, package_mode: mode_for(result.resource)),
                    notice: package_selection_notice(package_changed)
      else
        # The Actor's ActorError texts are the customer-facing explanation
        # (including the "switch is blocked until the guided migration" one) —
        # rendering them verbatim keeps ONE wording for both doors, the greyed-out
        # card and the direct POST.
        # The REQUEST's pane here, not the record's: nothing was written, so the customer
        # should be looking at what they were looking at. A refused switch that also
        # closed the pane would answer one rejection with two surprises.
        redirect_to organisation_ai_settings_path(@organisation, package_mode: permitted_package_mode),
                    alert: result.errors.join(' ')
      end
    end

    # GET /ai_settings/confirm_package
    #
    # KI-Pakete P4b (doc/ki_pakete_p4_plan.md §4): the consequence dialog. Since
    # P4a the Actor no longer refuses a lane-moving switch, it STARTS one — a
    # full, quota-metered re-embedding of the org's corpus onto a possibly
    # different jurisdiction. §9's first hard precondition is that nobody reaches
    # that from a bare button, so the cards route here first.
    #
    # `update?` and not `show?`: this page is the first half of a write, and a
    # plain member who may not perform it has no business seeing its price either.
    #
    # Everything the page states is computed HERE and once (E7) — the four
    # aggregate queries behind the estimate must never land on #show, which every
    # visit to the settings page renders.
    def confirm_package
      authorize @organisation, :update?, policy_class: AiSettingsPolicy

      # The pane the customer came from, carried through the detour so the way back (the
      # crumb "‹ Zugang" of the dialog) puts them back where they were. nil drops the param
      # and #show falls back to its own default, which is the right answer for a hand-built URL.
      @package_mode = permitted_package_mode

      # Blank id = back to "Eigene Konfiguration", the Actor's own convention
      # (E1-C), so the dialog speaks about the same two cases the write does.
      target_id = params[:ai_package_id].presence
      @target_package = target_id && published_package(target_id)
      # Only reachable by hand-built URL: a withdrawn or unknown package has no
      # card to click. The published catalogue is the authority on what may be
      # offered, so there is no second copy of the Actor's refusal codes here.
      if target_id.present? && @target_package.nil?
        return redirect_to(organisation_ai_settings_path(@organisation, package_mode: @package_mode),
                           alert: t('views.organisations.ai_settings.packages.switch.unavailable'))
      end

      # The card asks the embedding question BEFORE the rung question (its two
      # branches are ordered that way), so a package that moves the lane AND has an
      # unusable default rung now renders as a link into this dialog — where it
      # would quote a price and offer a button that Actors::SelectAiPackage refuses
      # with :tier_not_offered / :tier_credential_unusable. Before P4b that ordering
      # was inert because the first branch was a disabled button; opening the door
      # turned it into a dead end that names a cost first. Same predicate the Actor
      # resolves, so the two cannot disagree about which rung a blank request means.
      if @target_package&.selection_tier_unusable?
        return redirect_to(organisation_ai_settings_path(@organisation),
                           alert: t('views.organisations.ai_settings.packages.switch.tier_unusable'))
      end

      # Nothing to consent to when the lane does not move — the switch is a plain
      # write then, and the settings page is where it belongs. Said out loud rather
      # than bounced silently: a customer who saved this URL, or whose catalogue
      # went stale between render and click, otherwise lands back on the settings
      # page with no idea why.
      unless switch_moves_lane?
        return redirect_to(organisation_ai_settings_path(@organisation),
                           notice: t('views.organisations.ai_settings.packages.switch.same_lane'))
      end

      load_switch_consequences
    end

    # Tests the org's ACTUAL chat configuration — package, BYOK or system credential,
    # whichever governs. Since S7 that statement is finally true without a caveat:
    # there is no form on this page any more whose contents the probe could disagree
    # with (L5), and it runs through the GATE-FREE seam (L6), so an organisation that
    # has not switched AI on yet — the normal state while setting up — gets an answer
    # about its access instead of AiDisabledError.
    #
    # The eight-line rescue chain that used to live here is gone with the gates: two of
    # its branches were the gates themselves, and the remaining four are the four
    # outcomes Lalabase::Llm::ConnectionCheck names. The result is now also PERSISTED
    # (L10) and feeds the hub card, instead of living exactly as long as this flash.
    def test_connection
      authorize @organisation, :test_connection?, policy_class: AiSettingsPolicy

      redirect_back(fallback_location: organisation_ai_settings_path(@organisation),
                    **ai_connection_check_flash(@organisation))
    end

    private

    # Membership-scoped lookup (overrides BaseController#set_organisation).
    # `current_user.organisations.find(...)` raises RecordNotFound for non-
    # members → 404, instead of loading a foreign org. Additionally resets the
    # tenant: the policy checks `account_admin?` against
    # ActsAsTenant.current_tenant — without this reset the tenant would remain
    # the attacker's org from the session, and the check would falsely pass.
    def set_organisation
      @organisation = current_user.organisations.find(params[:organisation_id])
      @current_organisation = @organisation
      ActsAsTenant.current_tenant = @organisation
    end

    def authorize_ai_settings
      authorize @organisation, :show?, policy_class: AiSettingsPolicy
    end

    # The flash of an activation that always SUCCEEDS as a legal act but does not always
    # WORK. Until now this was an unconditional success notice, and it was wrong in the
    # single most likely case: `ai_enabled` is the GDPR opt-in, not a statement that an
    # embedding credential exists. An org activated without one is told everything is
    # fine while its new content gets no vector at all, so AI chat and the semantic half
    # of search stay blind to it, and the first symptom is a search that misses things
    # days later.
    #
    # ⚠️ This used to say "its content never reaches the index at all", which was true
    # and is not any more: since the fragment/embedding split the fragment is written
    # BEFORE the embedding call, so full-text search keeps working through a missing
    # credential. The warning is still right, its reason is narrower — say the narrower
    # thing, here and in the flash text itself.
    #
    # Order matters and is not alphabetical: a missing credential is reported FIRST
    # because it is the cause, and the backfill result below is downstream of it — with
    # no credential the catch-up still reports success, having enqueued jobs that each
    # die individually in the background. Reporting the enqueue first would name the
    # symptom and bury the cause.
    #
    # It never BLOCKS the activation. The opt-in is the compliance act and has to land
    # whatever the technical state is; this only decides which sentence the admin reads.
    def activation_flash(backfill)
      return { alert: t('flash.ai_settings.activated_without_embedding_access') } unless embedding_access_usable?

      # `false`, not falsy: a backfill the rescue above swallowed leaves nil here, and
      # that case is already in the log as an error — claiming a specific failure reason
      # we do not have would be worse than the plain notice.
      reported_failure = backfill.is_a?(Hash) && backfill[:success] == false
      return { alert: t('flash.ai_settings.activated_backfill_failed', error: backfill[:error]) } if reported_failure

      { notice: t('flash.ai_settings.activated') }
    end

    # :content_indexing, through the registry — NOT has_valid_embedding_configuration?
    # directly. The first draft of this method called that predicate and the R5 Guard C
    # spec rejected it, correctly: the predicate answers about a provider NAME, so every
    # caller built on it re-derives the gate the registry owns, and each one picks its own
    # provider to ask about. The registry resolves the lane itself, which is also what
    # makes this right for an org on a curated package or its own Vertex lane.
    #
    # :content_indexing rather than :semantic_search, though both ride the same lane: what
    # breaks here is the WRITE path (EmbeddingProcessingService is that feature's seam),
    # and the write is what decides whether content ever enters the index at all. Search
    # is the surface where an admin NOTICES it, days later.
    #
    # Rescues TOWARDS the warning on purpose. This runs after the switch has already been
    # written, so raising here would 500 a request that did activate AI (the exact shape
    # the backfill comment above describes). A warning that turns out to be unnecessary
    # costs a sentence; a green notice over a broken lane costs the whole index.
    def embedding_access_usable?
      @organisation.ai_available_for?(:content_indexing).available?
    rescue StandardError => e
      Rails.logger.warn('[AiSettings] embedding access unverifiable for organisation ' \
                        "#{@organisation.id}: #{e.class}: #{e.message}")
      false
    end

    # S0 of doc/ki_bereich_navigation_plan.md (E5/L13): the opt-in switch leaves a
    # trace. Both actions write with update_columns and therefore fire no callbacks —
    # Organisation is not trackable to begin with — so the row is written HERE,
    # explicitly, or it is never written at all. That is the whole point: the columns
    # ai_activated_at/_by hold only the LATEST activation, so every earlier one is
    # gone the moment somebody flips the switch again, and what was not written then
    # cannot be reconstructed now.
    #
    # ⚠️ skip_notifications, for the reason P4e measured in Actors::SelectAiPackage
    # #log_choice: an Activity is not a quiet audit row. after_create_commit hangs
    # OutboxEvent.create_from_activity! on it, which reaches the
    # full FanoutService through OutboxConsumeJob — and derive_event_type does not fall
    # back to nil for an unknown key but to SYSTEM_MESSAGE. Unthrottled, the compliance
    # off-switch would fan a generic system notification, e-mails included, across the
    # whole organisation.
    #
    # with_tenant rather than `organisation:` alone, same reason as P4e: acts_as_tenant
    # OVERWRITES the passed organisation from ActsAsTenant.current_tenant in a
    # before_validation on :create. #set_organisation happens to set the same org — but
    # that is a fact about today's caller, not a property of this write, and an audit
    # row whose mandant depends on ambient state is not an audit row.
    def log_ai_switch(action)
      ActsAsTenant.with_tenant(@organisation) do
        # ⚠️ The rescue sits on the CREATE, not on the method. Today both would catch
        # the same errors, because no transaction encloses this action and
        # after_create_commit therefore fires inside the call. That stops being true
        # the moment this write moves into an Actor (S7): Actors::BaseActor#call wraps
        # its body in a transaction, the commit callbacks run when the OUTERMOST
        # transaction commits, and a method-level rescue would no longer be on the
        # stack for them. Scoped here, the protection does not depend on the caller.
        Activity.create!(organisation: @organisation, actor: current_user,
                         trackable: @organisation, action: action,
                         skip_notifications: true)
      rescue StandardError => e
        # The switch has already happened at this point and must stay happened: activate
        # is the GDPR opt-in, deactivate the compliance off-switch that "has to work
        # unconditionally" (see #activate). A missing audit row is a defect worth
        # shouting about where shouting is free, but it is not a reason to answer an
        # applied request with a 500 and leave the admin unsure whether AI is off.
        #
        # ⚠️ `local?` is dev and test ONLY — staging takes the production branch, so a
        # failure there is a log line nobody is watching (there is no error tracker in
        # this app, and the log rotates after 7 days). Until there is one, a silent
        # audit gap is possible in exactly the environment that rehearses production.
        raise if Rails.env.local?

        Rails.logger.error(
          "[AiSettings] audit row for #{action} failed on organisation #{@organisation.id}: #{e.class}: #{e.message}"
        )
      end
    end

    # Reads the OUTCOME rather than trusting the request: the flash names the
    # package the organisation now actually carries, so a request that was
    # partially ignored can never be announced as a clean switch.
    def package_selection_notice(package_changed)
      package = @organisation.reload.ai_package
      return t('flash.ai_settings.package_cleared') if package.nil?
      # The package column did not move ⇒ the customer changed the RUNG, not the
      # package. Announcing a package switch there would report a jurisdiction
      # decision they did not make — the one confusion §2's two axes exist to
      # prevent.
      return t('flash.ai_settings.package_tier_selected', tier: current_tier_label(package)) unless package_changed

      t('flash.ai_settings.package_selected', package: package.name)
    end

    # The rung's operator-maintained label, falling back to its key: the column
    # is free text per row (AiPackageTier::DEFAULT_LABELS is only a prefill), so
    # a rung the customer just picked must never leave the flash empty.
    def current_tier_label(package)
      key = @organisation.ai_package_tier_key
      # Through AiPackage#tier_for, the shared "which row does key X mean"
      # lookup — a hand-written detect here would be a fourth copy of it.
      package.tier_for(key)&.label.presence || key
    end

    # The catalogue's own rule about what may be offered — `published` is
    # `active: true, kind: curated`, i.e. exactly the rows #load_package_catalogue
    # renders cards for. Anything else reaching #confirm_package came from a
    # hand-built URL and is turned away rather than explained.
    def published_package(id)
      AiPackage.published.with_customer_claims.find_by(id: id)
    end

    # Does this target actually move the search lane? The SAME helper the cards,
    # the "Eigene Konfiguration" card and Actors::SelectAiPackage ask — one rule,
    # four callers. A same-lane pick has no consequences to confirm: nothing is
    # re-embedded, nothing is charged, and the card offers a direct button for it.
    def switch_moves_lane?
      ::Lalabase::Llm::Factory.embedding_switch?(@organisation, package: @target_package)
    end

    # Everything the P4b dialog states, gathered ONCE per opening (E7) — the four
    # aggregate queries below must never move onto #show.
    #
    # WITHOUT the AI opt-in there is nothing to confirm but the choice itself:
    # Actors::SelectAiPackage#enqueue_jobs returns early for a disabled org (§9,
    # decision 2), so no corpus is re-embedded, no credits are spent and no
    # content goes anywhere. Quoting a price and a data flow there would be a
    # dialog about events that cannot happen — the org's `ai_enabled` default is
    # false, so this is the common case, not the exotic one.
    def load_switch_consequences
      @current_package = @organisation.ai_package
      @current_jurisdiction = @current_package&.effective_jurisdiction
      @target_jurisdiction = @target_package&.effective_jurisdiction
      @jurisdiction_change = jurisdiction_change
      # T7: what happens to the content, not only where it is processed.
      # `@current_package` is nil for "Eigene Konfiguration", `derived_*` returns
      # nil for self_hosted. Both paths end the same way here, and the jurisdiction
      # line already describes both. That is why nothing is derived from them.
      @current_training = @current_package&.derived_training_usage
      @target_training = @target_package&.derived_training_usage
      @current_retention = @current_package&.derived_retention
      @target_retention = @target_package&.derived_retention
      @training_change = training_change
      return unless @organisation.ai_enabled?

      @estimate = ::Embeddings::SwitchEstimate.call(organisation: @organisation)
      load_quota_consequences
      # The org's CURRENT recipients, straight from the P5 disclosure — the same
      # answer the chat page gives, so the dialog cannot name a different "today"
      # than the notice the customer already reads. Only the current side: the
      # disclosure describes an organisation, and there is no org yet that sits
      # on the target.
      @disclosure = ::Lalabase::Llm::Factory.routing_disclosure(@organisation)
      @target_search_label = target_search_label
      # LAST of the four, because it needs the quota answer above.
      @search_outcome = search_outcome
    end

    # What the page says about search, derived ONCE from BOTH facts that decide it.
    #
    # It used to be two independent statements: the quota box carried its own "bis
    # dahin durchsucht die Suche unverändert den bisherigen Index" while the search
    # box branched on the pointer alone. They disagreed in two of these four
    # combinations, and the worst of them promised continuity to an organisation
    # whose search would be empty — and empty until the month rolled over. Enforcing
    # one rule by hand in two places is what produced that, so it is expressed once,
    # as data (#437 review, fourth round).
    #
    # Both axes are real and independent:
    #   * POINTER — without active_embedding_space_id,
    #     Factory.embedding_space_for(:active) falls back to the CONFIGURED triple,
    #     so reads jump onto the new, empty space as soon as the write lands (a HARD
    #     switch). Reachable: the column is nullable and #431's ActivationBackfill is
    #     fail-soft.
    #   * QUOTA — an exhausted budget does not stop the write, it postpones the
    #     REBUILD to next month (P4d's watcher resumes it), which moves the "until
    #     then" of every one of these sentences.
    #
    # fetch, not [], so a third state added to either axis fails loudly here instead
    # of rendering a nil key.
    def search_outcome
      SEARCH_OUTCOMES.fetch(
        [@organisation.active_embedding_space_id.present?, @quota_exhausted.present?]
      )
    end

    # Whether this switch is measured against the quota AT ALL — and only then what
    # the ledger says about it.
    #
    # The enforcing gate does NOT ask the organisation, it asks the CREDENTIAL:
    # `ensure_within_quota!` returns early unless `credential&.included_in_quota?`
    # (gate.rb), and that column defaults to false. Reading QuotaLedger
    # unconditionally therefore described a block that never fires — red saying "the
    # rebuild starts next month" for a run that starts immediately, and green
    # reassuring about credits nobody books (#437 review, blocker 1).
    #
    # Same predicate and same shape as Embeddings::SwitchWatcherJob#resume_build, so
    # the page and the machinery cannot disagree about who is metered. The provider
    # comes from the DERIVED target triple rather than the package's column — the
    # constant-model trap makes those two different answers, which is why
    # #embedding_triple_for exists (it also answers the `package: nil` way back).
    def load_quota_consequences
      credential = target_billing_credential
      @quota_relevant = credential&.included_in_quota? || false
      return unless @quota_relevant

      @quota = @organisation.ai_quota_ledger
      @quota_exhausted = @quota.hard_exhausted?
      # Measured against #remaining (budget − used) while #exhausted? asks the HARD
      # limit (budget + buffer). The asymmetry is deliberate and errs safe: an org
      # inside its grace buffer is warned although the run would still squeeze in.
      # Warning early about a limit it is about to cross is honest; silence until
      # the hard stop would risk the customer's chat and search without notice.
      #
      # The estimate carries a ±30 % rule of thumb (SwitchEstimate::CHARS_PER_TOKEN),
      # and only ONE of its two error sources points downwards. Compared with a
      # margin so the reassuring branch needs real headroom, not a coin flip.
      # The number the WARNING is decided and stated with — the estimate plus its
      # safety margin. Shown on the page rather than kept private: with only the raw
      # estimate visible, "2 Credits" against "1 left" produced "2 credits above",
      # and the page contradicted its own arithmetic (#437 review, fourth round).
      # Either the margin is named or the numbers have to reconcile without it;
      # hiding it was the one variant where the page argued against itself.
      @quota_planned = (@estimate.credits * ::Embeddings::SwitchEstimate::SAFETY_MARGIN).ceil
      @quota_shortfall = [@quota_planned - @quota.remaining, 0].max
    rescue ::Lalabase::Llm::Provider::Error => e
      # An unresolvable target lane is not a quota statement. The switch itself
      # still writes (P4a decision 3), so the dialog stays up and simply says
      # nothing about credits rather than guessing.
      Rails.logger.warn("#{self.class}: no quota statement for organisation " \
                        "#{@organisation.id} — #{e.class}: #{e.message}")
      @quota_relevant = false
    end

    # The credential the RUN will actually bill — not the one a provider NAME
    # resolves to. The full reasoning (and the #437 defect that produced it) lives at
    # Factory#embedding_billing_credential, which owns the question since P4c.
    #
    # It was two hand-written copies until then: this one and the same resolution
    # inside Embeddings::SwitchProgress, which reports on the very run this dialog
    # quotes a price for. Two derivations of "which credential does this cost" is how
    # the dialog comes to say "das Kontingent deckt den Wechsel" while the settings
    # page reports the same run as paused. Unified at the SECOND occurrence rather
    # than CLAUDE.md's third, because the first copy already got it wrong once.
    def target_billing_credential
      ::Lalabase::Llm::Factory.embedding_billing_credential(@organisation, package: @target_package)
    end

    # Who will receive the search input afterwards. A package answers with its own
    # embedding credential — the same row Factory#routing_disclosure would label
    # once the org sits on it, and the same string the package card already shows,
    # so "today → afterwards" is one vocabulary rather than two.
    #
    # The way back to "Eigene Konfiguration" gets a NAME, not a label: what serves
    # then is whatever the org configures in the provider form below the
    # catalogue, and that is a setting the customer owns — resolving it here would
    # state a recipient that the very next save can change.
    def target_search_label
      return t('views.organisations.ai_settings.packages.switch.recipient_custom') if @target_package.nil?

      @target_package.embedding_credential&.display_label.presence ||
        t('views.organisations.ai_settings.packages.card.tier_provider_missing')
    end

    # How the legal statement moves, as one of five cases.
    #
    # The comparison only means anything BETWEEN TWO MATRIX RUNGS. Two values fail
    # that test, and treating either as "not eu_native" prints an invented legal
    # statement — which is what this did until the #437 review:
    #
    #   * BLANK — "Eigene Konfiguration" claims no jurisdiction (E1-C), and it is
    #     the target of EVERY way back. An org leaving an eu_native package read
    #     "a third-country transfer ARISES" two lines above "no jurisdiction is
    #     recorded for this configuration". The page contradicted itself on the
    #     most-travelled path.
    #   * SELF_HOSTED — a THIRD axis, not a fifth rung: it answers WHO processes,
    #     not where, and AiPackage:66-68 exempts it from the matrix and from its
    #     consistency check for exactly that reason. Compared binarily against
    #     EU_NATIVE it came out as "a transfer arises" for the option that has none
    #     — the inversion of the truth, for arguably the strictest choice on offer.
    #
    # Asked against JURISDICTION_MATRIX rather than a hand-written list of four, so
    # a fifth rung added there cannot fall silently back into "third country" here.
    def jurisdiction_change
      return :unchanged if @current_jurisdiction == @target_jurisdiction
      # BLANK first, before anything else is derived from the other side. Both
      # self_hosted texts name an external provider — "geht an einen externen
      # Anbieter", "findet danach nicht mehr statt" — and both of those claims are
      # about the OPPOSITE side. When that side states nothing, the sentence is
      # invented: exactly the defect the binary == EU_NATIVE test had, one branch
      # deeper (#437 review, fourth round). "Eigene Konfiguration" is the target of
      # every way back, and this same page says two lines above that no jurisdiction
      # is recorded for it.
      return :unstated if @current_jurisdiction.blank? || @target_jurisdiction.blank?
      # self_hosted DOES make a statement, just not on the matrix axis — so it gets
      # its own two texts rather than "cannot be derived". Reporting a move to one's
      # own server as unstated understates a real improvement, and the badge two
      # lines above already names it ("Eigener Server"), so the page would have
      # contradicted itself a second time (#437 review, finding 6).
      return :self_hosted_target if @target_jurisdiction == AiPackage::SELF_HOSTED
      return :self_hosted_source if @current_jurisdiction == AiPackage::SELF_HOSTED
      return :unstated unless comparable_jurisdiction?(@current_jurisdiction) &&
                              comparable_jurisdiction?(@target_jurisdiction)
      return :to_eu_native if @target_jurisdiction == AiPackage::EU_NATIVE
      return :from_eu_native if @current_jurisdiction == AiPackage::EU_NATIVE

      :changed
    end

    # T7: the training promise as before/after. Built after the pattern of
    # #jurisdiction_change and with its dearly paid order: the BLANK CASES FIRST.
    # The #437 review removed four sentences from the neighbouring method that
    # claimed something about the OTHER side while that side stated nothing at
    # all.
    #
    # nil = no line at all, and that is the most important decision here. A blank
    # side comes about in two ways (self_hosted or "Eigene Konfiguration"), and
    # for BOTH the explaining sentence already sits in the jurisdiction line
    # above. A second, vague sentence next to it would be noise. The column itself
    # shows the badge and addendum of the target side anyway, so the warning
    # appears in exactly the words in which the customer chose the package.
    #
    # @return [Symbol, nil]
    def training_change
      return nil if @current_training.blank? || @target_training.blank?
      return :unchanged if @current_training == @target_training

      # "Nicht zugesichert" is not a promise one can compare against. A switch to
      # it is not a downgrade and a switch away from it is not an improvement.
      # Claiming either would be invented.
      answers = [@current_training, @target_training]
      return :not_comparable if answers.include?(AiCredentialContract::TRAINING_UNSPECIFIED)
      return :to_excluded if @target_training == AiCredentialContract::TRAINING_EXCLUDED

      :to_used
    end

    # @return [Boolean] does this value sit on the §3 matrix — i.e. does it make a
    #   statement about the third-country question at all?
    def comparable_jurisdiction?(jurisdiction)
      AiPackage::JURISDICTION_MATRIX.value?(jurisdiction)
    end

    # Everything the §7 card catalogue needs. Called from BOTH render paths of
    # this page (#show and #update's 422).
    def load_package_catalogue
      @package_catalogue = AiPackage.published.ordered.with_customer_claims.to_a
      @current_package = resolve_current_package
      @package_provider_scope = filter_scope(params[:provider_scope])
      @package_processing_scope = filter_scope(params[:processing_scope])
      @packages = filter_packages(@package_provider_scope, @package_processing_scope)
      # The "Eigene Konfiguration" card is a THIRD door into Actors::SelectAiPackage
      # and is subject to the very same switch refusal — deselecting can move the
      # embedding lane just as much as selecting. It had no such check, so for every
      # org actually on a package the way back was rendered as an enabled button that
      # always bounced off the Actor. Same helper the cards ask, `package: nil`.
      @custom_switch_blocked = ::Lalabase::Llm::Factory.embedding_switch?(@organisation, package: nil)
      # P4c: what a switch already underway is doing. Assigned HERE rather than in
      # #show for the reason the comment in #update names — this method is what both
      # the GET and the 422 re-render call, and the notice lives in the catalogue
      # partial. Cheap in the common case by construction (Embeddings::SwitchProgress).
      @switch_progress = ::Embeddings::SwitchProgress.call(organisation: @organisation)
      # A package the org sits on but the filters (or the operator's unpublish) keep
      # out of the grid — E5. Resolved here so the view renders a decision rather
      # than making one.
      @current_package_outside_grid = @current_package.present? &&
                                      @packages.exclude?(@current_package)
      return if @packages.any?

      # An empty result is a state of its own (§7.1), not a blank grid: name the
      # single relaxation that would bring the nearest package into view.
      @relaxing_provider_helps = filter_packages(FILTER_ANY, @package_processing_scope).any?
      @relaxing_processing_helps = filter_packages(@package_provider_scope, FILTER_ANY).any?
    end

    # An org can sit on a package the operator has since unpublished — the
    # catalogue would then hide the very package the "Aktuell" line has to name.
    # Prefer the eager-loaded catalogue row (one object, no second round of
    # credential fetches) and only pay for a separate load in that stale case.
    def resolve_current_package
      return nil if @organisation.ai_package_id.blank?

      @package_catalogue.find { |package| package.id == @organisation.ai_package_id } ||
        AiPackage.with_customer_claims
                 .find_by(id: @organisation.ai_package_id)
    end

    # Which of the two ways is OPEN (doc/ki_zugang_umbau_plan.md D6/6.3). An explicit
    # param wins; without one the page opens the way that is IN FORCE, so an admin who
    # arrives without a URL of their own sees their own arrangement rather than a
    # default that contradicts it.
    #
    # The last branch is a product decision, not a fallback for lack of a better idea:
    # an organisation with neither a package nor its own credentials is looking at this
    # page for the first time, and the curated packages are the recommended way and the
    # product promise. Landing such a visitor on an empty credentials pane would open
    # with the harder of the two answers.
    def resolve_package_mode
      return permitted_package_mode if permitted_package_mode
      return MODE_PACKAGES if @organisation.ai_package_id.present?
      return MODE_CUSTOM if @organisation.ai_custom_access_configured?

      MODE_PACKAGES
    end

    # The whitelist itself, so every reader of the param goes through ONE gate: #show
    # derives from it, and the redirects hand it back on. A typo, a stale bookmark or a
    # crafted value answers nil here and the caller falls back to its own default,
    # never to a third pane.
    def permitted_package_mode
      requested = params[:package_mode].presence
      requested if [MODE_PACKAGES, MODE_CUSTOM].include?(requested)
    end

    # Which pane a written record belongs to. Reads the record, not the request: after
    # a write the truth is what was saved.
    def mode_for(record)
      record&.ai_package_id.present? ? MODE_PACKAGES : MODE_CUSTOM
    end

    # FILTER_ANY is the only widening value; blank, a typo or a crafted param all
    # read as the strict default, so the catalogue cannot widen by accident.
    def filter_scope(value)
      value == FILTER_ANY ? FILTER_ANY : FILTER_EU
    end

    # Filtered in Ruby, not in SQL: `eu_company?` and `eu_processing_only?` are
    # facts about the CREDENTIALS a package references, not columns on it — a
    # `where` would have to restate that derivation and then maintain it twice
    # (§7.1). The catalogue is three to four rows by design (§7) and already
    # loaded with its credentials.
    def filter_packages(provider_scope, processing_scope)
      @package_catalogue.select do |package|
        (provider_scope == FILTER_ANY || package.eu_company?) &&
          (processing_scope == FILTER_ANY || package.eu_processing_only?)
      end
    end

    # #build_current_settings and #find_system_credential_for_provider are gone with S7,
    # together with the form that read them. Their five keys described the two axes that
    # no longer exist on this page: masked token, organisation id and the resolved system
    # credential belong to "Eigene Konfiguration" (which reads them itself), and the
    # has_custom_credentials/provider pair only existed to decide which radio the inline
    # script should pre-select.
    #
    # The S6 note they carried is still worth keeping: usage_stats and cost_stats left
    # earlier, and cost_stats never had a reader at all — a GROUP BY provider
    # SUM(cost_cents) on every render for a number no view showed. It is also the WRONG
    # number for a customer surface, because cost_cents is our purchasing side while L8
    # names credits as the binding figure.
  end
end
