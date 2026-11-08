# frozen_string_literal: true

# THE requirements side of the AI features — which lane, which pin, which metering
# action, which seam. Read by the UI gate (Organisation#ai_available_for?) AND by the
# routing (Lalabase::Llm::Factory.for_feature), so the two cannot drift apart.
# Entry point: fetch
module Lalabase
  module Llm
    # One entry per ROUTING DECISION (doc/ai_feature_registry_plan.md E2) — not per
    # call site, and not per ActionRegistry action: `summary` is booked by three
    # services with two different routing decisions, so an action-keyed table could
    # not answer for it. The criterion cuts in both directions, which is how you can
    # tell it is doing work: the three meetings services get three entries although
    # they share ONE inherited for_feature call site in BaseLlmService (their configuration is per subclass and
    # can diverge), while the assistant's surfaces share ONE entry (same job, one
    # decision) -- as the project chat did with it before projekt_chat_abbau.
    #
    # Why a registry at all: "may I offer this?" and "where does this go?" used to be
    # two independent derivations that agreed only by convention — and that
    # convention broke three times in one week (plan §1.2). Both questions now read
    # THIS table.
    #
    # The requirements are stated against what the FACTORY resolves for an org, never
    # against the org's provider columns (plan E7). That is what keeps this table
    # independent of the packages domain: when doc/ki_pakete_plan.md P2 changes how a
    # provider is resolved, it changes the innards of the resolution, and not one
    # line here.
    #
    # NOT a feature, deliberately: Factory.embedding_space_for. It resolves the
    # vector-space triple for a LOCAL DB read (no egress, no spend) and is therefore
    # gate-free on purpose (plan §7.5, Factory#embedding_space_for). UNGATED_RESOLUTIONS
    # below is what stops the completeness guard (R5) from "tidying it up".
    module FeatureRegistry
      class InvalidFeatureError < StandardError; end

      # The two lanes route INDEPENDENTLY (chat off ai_*, embeddings off embedding_*)
      # and their switching costs differ by orders of magnitude: a chat switch takes
      # effect immediately, an embedding switch forces a full reindex — without which
      # every search silently returns zero hits (plan §7.1, real incident 2026-07-30).
      # An entry therefore declares a SET of lanes, and the reason for a "no" always
      # names the lane it came from.
      LANES = %i[chat embedding].freeze

      # The five reasons, derived from states that actually exist (plan E4). Quota is
      # deliberately NOT among them: it is dynamic, it has its own UI (AiQuotaHelper +
      # shared/ai/*), and folding it in here would make the button disappear where the
      # right UX is "button plus quota banner".
      REASONS = %i[ai_disabled no_credential provider_incapable pinned_elsewhere
                   unsupported_provider].freeze

      Feature = Struct.new(:key, :lanes, :pin, :pin_reason, :action, :seam, :utility, keyword_init: true) do
        def pinned?
          pin.present?
        end

        # A HELPER path (KI-Pakete P3, doc/ki_pakete_plan.md §2.1): it takes the
        # package's cheapest rung no matter which rung the org picked, because an
        # expensive model buys almost nothing here.
        def utility?
          !!utility
        end

        def multi_lane?
          lanes.size > 1
        end
      end

      # The answer, not a boolean (plan E4): a surface that only knows "no" cannot say
      # anything useful, and asking a second time for the reason would run the
      # resolution twice — two runs that can disagree.
      #
      # `lane` is set only on a failure, and names the lane that failed; `reason` nil
      # means available. `required_provider` names the provider the failing (or, on
      # success, the first declared) lane resolves to — the interpolation for
      # shared.ai.unavailable.*.
      Availability = Struct.new(:available, :reason, :required_provider, :lane, keyword_init: true) do
        def available?
          !!available
        end
      end

      module_function

      # Public so the guard spec can exercise it against a SYNTHETIC bad entry
      # without a fixture (precedent: ServiceConventionDetectors). Runs at load time
      # for every entry below, so a half-defined feature cannot be deployed.
      def validate_entry!(feature)
        raise InvalidFeatureError, "Feature #{feature.key.inspect} declares no lane" if feature.lanes.blank?

        unknown = feature.lanes - LANES
        raise InvalidFeatureError, "Feature #{feature.key.inspect} declares unknown lane(s) #{unknown.inspect}" if unknown.any?

        # A pin and a utility marking contradict each other TODAY: a pin names
        # ONE provider this path may run on, a utility marking says "take the
        # cheapest rung the org's configuration offers" — and that rung routinely
        # sits on a different provider. The combination is not forbidden in
        # principle, it just has no defined precedence yet, and letting it load
        # would pick one silently. Whoever needs both decides here first
        # (KI-Pakete P3).
        if feature.pinned? && feature.utility?
          raise InvalidFeatureError,
                "Feature #{feature.key.inspect} is both pinned to #{feature.pin.inspect} and marked utility — " \
                'the pin names a provider, the utility rung names a different one; decide which wins before using both'
        end

        # pin_reason is MANDATORY with a pin — the machine-readable version of the
        # comments the pins carry today, and unlike a comment it disappears together
        # with the pin instead of outliving it (plan §5.1).
        return unless feature.pinned? && feature.pin_reason.blank?

        raise InvalidFeatureError, "Feature #{feature.key.inspect} is pinned to #{feature.pin.inspect} without a pin_reason"
      end

      def build_feature(key:, lanes:, action:, seam:, pin: nil, pin_reason: nil, utility: false)
        Feature.new(key: key, lanes: lanes.freeze, pin: pin, pin_reason: pin_reason,
                    action: action, seam: seam, utility: utility).tap { |feature| validate_entry!(feature) }
      end

      # The 13 entries: the 12 of plan §E2 and, since K5b, the glossary extraction
      # at the end. `action:` REFERENCES the ActionRegistry constant
      # rather than repeating its string, so a renamed action breaks loudly here
      # instead of quietly mis-attributing metering (plan §7.7).
      #
      # `utility: true` is a CODE property of the path, not a customer setting
      # (KI-Pakete P3, doc/ki_pakete_plan.md §2.1 — it settles the "Utility-Achse"
      # the Reichweite plan deferred in its E2). It says: on this path a more
      # expensive model buys close to nothing, so the org runs it on the cheapest
      # rung its configuration offers, whichever rung it picked for chat. Two
      # things it does NOT say, both easy to misread:
      #
      # * It is not a provider statement (E7). The rung is still the org's own —
      #   the jurisdiction it chose holds, only the model within it gets cheaper.
      #   That is why this line may live here while a provider name may not, and
      #   why the whole interpretation of the flag lives in the Factory.
      # * It is not a promise that anything changes. An org whose configuration
      #   has no ladder at all has no cheaper rung to take, so helper paths there
      #   route exactly as they did before this flag existed.
      FEATURES = [
        # The assistant's write paths (AssistantChatsController and
        # AssistantChatpostsController) enqueue the very same ChatResponseJob, so this
        # is one routing decision. Whoever wants a separate route splits the entry then.
        # Routes by key since R6 — a marking here (utility:, pin:) would be LIVE.
        # It deliberately carries none: the chat answer is what the customer
        # reads and judges the AI by, so the rung stays the org's own choice.
        build_feature(key: :chat, lanes: %i[chat],
                      action: ActionRegistry::CHAT_MESSAGE, seam: 'ChatResponseJob'),
        build_feature(key: :document_summary, lanes: %i[chat], utility: true,
                      action: ActionRegistry::SUMMARY, seam: 'SummaryProcessingService'),
        # Unpinned since #391/S2 — verified in TicketSummaryService#call, which
        # since KI-Pakete P3 both GATES and ROUTES on this row (for_feature).
        # The plan's §E2 table still shows the old pin.
        build_feature(key: :ticket_summary, lanes: %i[chat], utility: true,
                      action: ActionRegistry::SUMMARY, seam: 'TicketSummaryService'),
        # Unpinned since #391/S2 — verified in Actors::CreateAiPost#perform.
        # Routes by key since R6; unmarked for the same reason as :chat above —
        # the answer lands in front of the customer, so the rung is theirs.
        build_feature(key: :ask_ai_post, lanes: %i[chat],
                      action: ActionRegistry::POST_AI, seam: 'Actors::CreateAiPost'),
        # THE one technically justified pin, and the only one left of the original
        # eight. Since R3 this line is also the only PLACE a pin exists: the seam
        # builds it (factory.rb#for_feature) and the gate reads it, so
        # provider_pin_guard_spec's door-1 allowlist is empty.
        build_feature(key: :customer_description, lanes: %i[chat],
                      pin: ::AiCredential::PROVIDER_OPENAI,
                      pin_reason: 'gpt-5-nano is a reasoning model: reasoning_effort travels via ' \
                                  'provider_options and OpenAiProvider::REASONING_MODEL_PATTERN switches ' \
                                  'the request to the max_completion_tokens dialect (no temperature). ' \
                                  'Sending that to Anthropic or Gemini does not degrade — it breaks.',
                      action: ActionRegistry::CUSTOMER_DESCRIPTION, seam: 'CustomerDescriptionGenerator'),
        # Extraction, not composition: the answer is a list of names out of a
        # transcript, and the cheap model finds them.
        build_feature(key: :meeting_participant_detection, lanes: %i[chat], utility: true,
                      action: ActionRegistry::PARTICIPANT_DETECTION,
                      seam: 'Meetings::ParticipantDetectionService'),
        # The two READING features of the meeting pipeline stay on the org's own
        # rung: a meeting summary and an analysis are what the customer reads and
        # judges the AI by, so the quality choice is theirs to make.
        build_feature(key: :meeting_summary, lanes: %i[chat],
                      action: ActionRegistry::SUMMARY, seam: 'Meetings::SummaryService'),
        build_feature(key: :meeting_analysis, lanes: %i[chat],
                      action: ActionRegistry::MEETING_ANALYSIS, seam: 'Meetings::AnalysisService'),
        # Proposals the user reviews and accepts one by one before anything is
        # created — a wrong suggestion costs a click, not a wrong artefact.
        build_feature(key: :meeting_ticket_suggestions, lanes: %i[chat], utility: true,
                      action: ActionRegistry::TICKET_SUGGESTIONS,
                      seam: 'Meetings::TicketSuggestionService'),
        build_feature(key: :content_indexing, lanes: %i[embedding],
                      action: ActionRegistry::DOCUMENT_INDEXING, seam: 'EmbeddingProcessingService'),
        build_feature(key: :semantic_search, lanes: %i[embedding],
                      action: ActionRegistry::SEMANTIC_SEARCH, seam: 'Lalabase::QueryEmbedding'),
        # BOTH lanes in one operation (ProjectIndexerJob#generate_layer_4_and_3 builds
        # a chat provider AND an embedding provider), which is why an entry declares a
        # SET of lanes at all.
        #
        # action: nil is a VERIFIED fact, not an omission — this path books no
        # UsageTracking record today, neither for the Layer-4 chat call nor for the
        # embeddings (checked across app/jobs/project_indexer_job.rb and
        # app/services/lalabase/indexer/). That is a metering gap (plan §7.7), and
        # naming an action here would paper over it.
        #
        # utility: true covers the CHAT half only — the embedding lane has no
        # ladder to be cheap on (a package carries exactly one embedding model,
        # §2). The chat half writes the Layer-4 vision and the capability
        # descriptions that feed retrieval; that is indexing scaffolding, read by
        # the RAG pipeline rather than by a person, and it runs over whole
        # repositories, which is where an expensive rung would be felt most.
        build_feature(key: :repository_indexing, lanes: %i[chat embedding], utility: true,
                      action: nil, seam: 'ProjectIndexerJob'),
        # The glossary extraction (K5b): one call per batch of up to 60 candidate
        # terms, out of the texts of the whole organisation. Deliberately NOT
        # utility: telling the product and field names of an organisation from
        # ordinary words over its whole catalogue is the product here, not a
        # helper, and every candidate a weaker model gets wrong costs a person a
        # decision on a proposal (or loses a term nobody proposes). So it runs on
        # the organisation's own rung, like the meeting analysis.
        build_feature(key: :glossary_extraction, lanes: %i[chat],
                      action: ActionRegistry::GLOSSARY_EXTRACTION, seam: 'Glossary::Classifier')
      ].freeze

      BY_KEY = FEATURES.index_by(&:key).freeze

      # Files that resolve a provider through the raw lanes (Factory.for_chat /
      # for_embeddings) WITHOUT a registry row of their own. Read by the R5
      # completeness guard (feature_registry_guard_spec, plan §5.3 Guard B): a file
      # that routes and is neither a registered seam nor listed here breaks the
      # build. Classify-or-explain, the UserDataExports::Registry::EXCLUDED
      # contract — and like there, the REASON is the entry: an entry that cannot
      # say why it is no feature does not belong on this list, it belongs in
      # FEATURES.
      #
      # Shrink-only: an entry leaves when its caller either gets a registry row or
      # dies. It never absorbs a new caller silently — the guard's stale check
      # fails on entries that stopped routing.
      #
      # `calls:` is why an exemption cannot quietly grow. An entry excuses a
      # FILE, and without a count the file may then collect any number of further
      # routing calls — possibly for a real feature — because "at least one call
      # is still here" stays true (cross-model review 2026-08-03). The number is
      # the inventory: changing it is a reviewed diff, which is the whole point
      # of the list.
      EXCLUDED_CALLERS = {
        'app/services/lalabase/llm/connection_check.rb' => {
          calls: 1,
          reason: 'the connection test: probes the org\'s ACTUAL chat resolution once and renders a ' \
                  'flash — diagnostics for the settings screen, not a user-facing feature, so a registry ' \
                  'row would put a probe on the gate map and hand it an Availability nobody reads. ' \
                  'MOVED here from ai_settings_controller.rb with S7, together with the probe itself: ' \
                  'it now has two buttons behind it and routes through Factory#chat_probe, the gate-free ' \
                  'twin of the chat lane (doc/ki_bereich_navigation_plan.md, gap L6). ' \
                  '⚠️ Spelled with a # on purpose — the guard greps this file too, and the dotted form ' \
                  'in a reason string makes the registry look like a routing caller of itself'
        },
        'app/services/embeddings/organisation_reindexer.rb' => {
          calls: 1,
          reason: 'ops machinery (embedding v2): rebuilds vector spaces for a model flip under operator ' \
                  'control — not a user feature, and it must keep working for orgs whose FEATURE gates ' \
                  'say no (that is what a repair tool is for); the factory\'s own fail-closed gates still apply'
        }
      }.freeze

      # Factory resolutions that must NEVER get a registry row (plan §7.5) because
      # they never call a provider. Listed with a reason so a completeness sweep
      # cannot "tidy them up" into features.
      UNGATED_RESOLUTIONS = {
        'Lalabase::Llm::Factory.embedding_space_for' =>
          'resolves the vector-space triple for a LOCAL DB read (Embeddings::NearestNeighbors) — ' \
          'no egress, no spend, deliberately free of the ai_enabled and quota gates (pinned in ' \
          'factory_spec): an exhausted quota must not switch off search'
      }.freeze

      # @raise [KeyError] for an unknown key — loudly on purpose: a typo in a gate
      #   must not answer "not available" and hide a working feature.
      def fetch(key)
        BY_KEY.fetch(key.to_sym) do
          raise KeyError, "Unknown AI feature #{key.inspect} (known: #{keys.join(', ')})"
        end
      end

      def keys
        BY_KEY.keys
      end

      def all
        FEATURES
      end

      # Would the routing for this feature succeed for this org? The gate is DEFINED
      # as that question (plan §5.3 point 1) rather than derived alongside it, which
      # is what makes gate and route structurally unable to disagree.
      #
      # Beratend / advisory only: the fail-closed gates at the seam
      # (Factory#ensure_ai_enabled!, Gate.ensure_within_quota!) stay where they are
      # and run regardless (plan §7.3).
      # @return [Availability]
      def resolve(key, organisation)
        feature = fetch(key)
        # Opt-in first, in the same fail-closed order as the seam: an org without the
        # GDPR opt-in has ONE problem, and naming a credential problem instead sends
        # its admin to the wrong settings page.
        #
        # Deliberately WITHOUT an i18n text of its own: :ai_disabled reuses the
        # canonical shared.ai.disabled_member_hint / _admin_hint (plan E4 — reuse, do
        # not fork), which is why shared.ai.unavailable carries no ai_disabled key.
        return Availability.new(available: false, reason: :ai_disabled) unless organisation&.ai_enabled?

        feature.lanes.each do |lane|
          reason, provider = lane_failure(lane, feature, organisation)
          next if reason.nil?

          # First failure wins, in DECLARED lane order — reason and lane belong
          # together, so an org missing both configurations is told about one lane at
          # a time instead of getting a mixed answer.
          return Availability.new(available: false, reason: reason, required_provider: provider, lane: lane)
        end

        # On success `lane` stays nil (nothing failed); required_provider names the
        # first declared lane's provider, i.e. what this feature is "about".
        Availability.new(available: true, reason: nil, lane: nil,
                         required_provider: lane_provider(feature.lanes.first, feature, organisation))
      end

      # The sentence a surface shows when it withholds a feature. ONE place, because
      # the reason set and its copy are the same contract this module already owns —
      # the guard spec below already enforces a shared.ai.unavailable.<reason> per
      # locale for every reason but :ai_disabled.
      #
      # R3 is what made it worth extracting: three surfaces refuse the same feature
      # (the customer-export view, Actors::GenerateGroupCustomerDescriptions and its
      # async twin in BulkCustomerDescriptionGenerator). They differ in WHICH reasons
      # they explain — the view speaks only for :pinned_elsewhere — but never in WHAT
      # they say about one, and hand-writing that mapping a third time is the point
      # where a convention stops being one (CLAUDE.md, "fehlende Abstraktion").
      #
      # :ai_disabled deliberately reuses the canonical opt-in copy rather than a forked
      # key (E4) — the same decision the locale file records above the block.
      # A nil availability means "no organisation at all", which resolve(key, nil)
      # answers as :ai_disabled too; saying it here keeps every caller's nil branch out.
      # KNOWN LIMIT (adversarial review R3-B4, deferred to the flat R4 rollout):
      # :ai_disabled always answers with the MEMBER copy — this method has no user
      # context, so an admin reads "an administrator can enable it" about themself.
      # The admin/member split lives with the surfaces that know their audience.
      # @return [String, nil] nil for an available feature
      def unavailable_hint(availability, organisation)
        return nil if availability&.available?
        return I18n.t('shared.ai.disabled_member_hint') if availability.nil? || availability.reason == :ai_disabled

        # `current` is consumed only by :pinned_elsewhere (a pin is a chat-lane
        # property in v1); passing it always keeps the branch out of the caller.
        I18n.t("shared.ai.unavailable.#{availability.reason}",
               provider: provider_label(availability.required_provider),
               current: provider_label(Factory.chat_provider_name(organisation)))
      end

      # The name an admin knows from the AI settings screen, not the routing key —
      # "OpenAI (GPT)" says something to them, "openai" does not.
      def provider_label(name)
        ::AiCredential.provider_display_names.fetch(name, name)
      end
      private_class_method :provider_label

      # @return [Array(Symbol, String), nil] [reason, provider] on failure, nil when
      #   the lane is usable.
      def lane_failure(lane, feature, organisation)
        lane == :embedding ? embedding_failure(organisation) : chat_failure(feature, organisation)
      end
      private_class_method :lane_failure

      def chat_failure(feature, organisation)
        # The RUNG travels with the question (P3): a utility feature routes on the
        # package's cheapest rung, and the two rungs of a package may name
        # different providers. Asking about the org's rung while the request runs
        # on the utility rung is the same gate/route drift the registry exists to
        # end — only one package version later.
        provider = Factory.chat_provider_name(organisation, utility: feature.utility?)

        if feature.pinned?
          # These two lines ARE the S4 pair (ai_available_pinned? /
          # ai_pinned_elsewhere?, deleted in R3), ORDER included: that a usable
          # credential for the pinned provider exists is NOT enough. Running the
          # feature would ship the org's data to a provider its admin did not choose,
          # so the pin question is asked BEFORE the credential question — and it is
          # also the more actionable explanation. Swapping them leaves every boolean
          # identical and only changes the REASON, which is why the org that fails
          # BOTH halves is pinned twice in organisation_ai_availability_spec.
          return [:pinned_elsewhere, feature.pin] unless provider == feature.pin
          return [:no_credential, feature.pin] unless organisation.has_valid_ai_configuration?(feature.pin)

          return nil
        end

        # The same two questions has_valid_ai_configuration? answers internally, split
        # so the UI can tell "legacy provider we cannot build" from "no credential".
        # The BOOLEAN is identical either way — that is what keeps an unpinned chat
        # row equivalent to the pre-registry formula
        # (ai_enabled? && has_valid_ai_configuration?(chat_provider_name)), which the
        # equivalence matrix still compares against (plan §8).
        return [:unsupported_provider, provider] unless AiCredential.implemented_providers.include?(provider)
        return [:no_credential, provider] unless organisation.has_valid_ai_configuration?(provider, utility: feature.utility?)

        nil
      end
      private_class_method :chat_failure

      # No pin handling here on purpose: in v1 a pin is a CHAT-lane property (no
      # embedding path is pinned), and Factory.for_feature routes the embedding lane
      # the same way — gate and route stay paired.
      def embedding_failure(organisation)
        provider = Factory.embedding_provider_name(organisation)
        return [:unsupported_provider, provider] unless AiCredential.implemented_providers.include?(provider)

        # Capability, asked WITHOUT building a provider and without touching a
        # credential: embedding_capable_providers derives from the provider classes'
        # own supports_embeddings? declarations (AnthropicProvider inherits false), so
        # there is no second list to drift — and this module never names
        # PROVIDER_CLASSES itself, which is a guarded door (provider_pin_guard_spec).
        return [:provider_incapable, provider] unless AiCredential.embedding_capable_providers.include?(provider)
        return [:no_credential, provider] unless organisation.has_valid_embedding_configuration?(provider)

        nil
      end
      private_class_method :embedding_failure

      # Which provider a lane resolves to for this org — the pin for a pinned chat
      # feature, otherwise the org's own choice for that lane.
      def lane_provider(lane, feature, organisation)
        return feature.pin if lane == :chat && feature.pinned?
        return Factory.chat_provider_name(organisation, utility: feature.utility?) if lane == :chat

        Factory.embedding_provider_name(organisation)
      end
      private_class_method :lane_provider
      private_class_method :build_feature
    end
  end
end
