# frozen_string_literal: true

require 'rails_helper'

# The STRUCTURE half of R1 (doc/ai_feature_registry_plan.md §8) — the table itself:
# that every entry is fully defined, that a pin can never lose its reason, that the
# seams and metering actions it names actually exist, and that the module stays
# decoupled from the packages domain (E7).
#
# The BEHAVIOUR half — does the resolution answer the same thing the pre-registry
# predicates answered — lives in spec/models/organisation_ai_availability_spec.rb,
# because that is where the org states are.
RSpec.describe Lalabase::Llm::FeatureRegistry do
  let(:module_source) { File.read(Rails.root.join('app/services/lalabase/llm/feature_registry.rb')) }
  # Whole comment lines couple nothing — a rule about what the code READS must be
  # measured on code, exactly as provider_pin_guard_spec does it (`code_of`).
  # Without this the module could not even explain in prose which door it avoids.
  let(:module_code) { module_source.lines.reject { |line| line.lstrip.start_with?('#') }.join }

  describe 'the table' do
    # The count is pinned deliberately: E2 decided "one entry per routing decision"
    # and arrived at twelve. A new entry is not wrong, but it means a routing
    # decision was added or split, and that is a decision, not a detail. The
    # thirteenth is the glossary extraction (K5b), a decision of its own: its
    # classifier sends texts of the whole organisation and runs on the org rung.
    it 'holds the twelve v1 entries and the glossary extraction' do
      expect(described_class.keys).to contain_exactly(
        :chat, :document_summary, :ticket_summary, :ask_ai_post, :customer_description,
        :meeting_participant_detection, :meeting_summary, :meeting_analysis,
        :meeting_ticket_suggestions, :content_indexing, :semantic_search, :repository_indexing,
        :glossary_extraction
      )
    end

    # Written out with literals, so the row cannot drift to a sibling's seam,
    # action or rung while every generic check above stays green.
    it 'routes the glossary extraction through its classifier, on its own action, unpinned' do
      feature = described_class.fetch(:glossary_extraction)

      expect([feature.lanes, feature.seam, feature.action, feature.pin])
        .to eq([%i[chat], 'Glossary::Classifier', 'glossary_extraction', nil])
    end

    it 'raises loudly for an unknown key — a typo must not read as "not available"' do
      expect { described_class.fetch(:does_not_exist) }.to raise_error(KeyError, /does_not_exist/)
    end

    it 'accepts a string key (view code has no symbols)' do
      expect(described_class.fetch('chat').key).to eq(:chat)
    end

    described_class::FEATURES.each do |feature|
      context "entry #{feature.key}" do
        it 'declares at least one known lane' do
          expect(feature.lanes).to be_present
          expect(feature.lanes - described_class::LANES).to be_empty
        end

        it 'names a seam class that exists' do
          expect(feature.seam.safe_constantize).to be_present, "seam #{feature.seam} does not resolve"
        end

        it 'references a known metering action (or none, deliberately)' do
          next expect(feature.key).to eq(:repository_indexing) if feature.action.nil?

          expect(Lalabase::Llm::ActionRegistry).to be_known(feature.action)
        end

        it 'carries a pin_reason whenever it is pinned' do
          expect(feature.pin_reason).to be_present if feature.pinned?
        end
      end
    end

    # Verified against the code, not against the plan text: #391/S2 unpinned P3 and P4
    # (both route by their own key via for_feature since R6), so exactly ONE entry
    # carries a pin.
    #
    # Since R3 this table is the ONLY place a pin is written: the pin guard's door-1
    # allowlist is empty, because CustomerDescriptionGenerator routes through
    # Factory.for_feature instead of naming a provider itself. The literal below is
    # therefore spelled out from the provider vocabulary rather than read back from
    # the service — reading it from the service would only ask the registry what the
    # registry already said.
    it 'pins exactly one path, and it is the customer description' do
      pinned = described_class.all.select(&:pinned?)

      expect(pinned.map(&:key)).to eq([:customer_description])
      expect(pinned.first.pin).to eq(::AiCredential::PROVIDER_OPENAI)
      expect(pinned.first.seam).to eq('CustomerDescriptionGenerator')
    end

    it 'names the technical reason for the pin, not a preference' do
      reason = described_class.fetch(:customer_description).pin_reason

      expect(reason).to include('reasoning', 'provider_options', 'REASONING_MODEL_PATTERN')
    end

    # ProjectIndexerJob#generate_layer_4_and_3 builds a chat provider AND an embedding
    # provider in one operation — the reason an entry declares a SET of lanes at all
    # (plan §2.3). A single-lane entry here would make the whole lane machinery
    # decorative.
    it 'declares both lanes for the one operation that builds both' do
      expect(described_class.fetch(:repository_indexing).lanes).to eq(%i[chat embedding])
      expect(described_class.fetch(:repository_indexing)).to be_multi_lane
    end
  end

  # The load-time assertion from plan §5.1: pin_reason is a FIELD, not a comment, so
  # it cannot outlive the pin — and a half-defined entry cannot be deployed. Tested
  # against a synthetic entry (precedent: ServiceConventionDetectors), because the
  # real table is by definition valid.
  describe '.validate_entry!' do
    def entry(**attrs)
      described_class::Feature.new({ key: :synthetic, lanes: %i[chat], action: nil,
                                     seam: 'ChatResponseJob' }.merge(attrs))
    end

    it 'rejects a pin without a pin_reason' do
      expect { described_class.validate_entry!(entry(pin: 'openai')) }
        .to raise_error(described_class::InvalidFeatureError, /pin_reason/)
    end

    it 'accepts a pin with a pin_reason' do
      expect { described_class.validate_entry!(entry(pin: 'openai', pin_reason: 'because')) }
        .not_to raise_error
    end

    it 'rejects an entry without a lane' do
      expect { described_class.validate_entry!(entry(lanes: [])) }
        .to raise_error(described_class::InvalidFeatureError, /lane/)
    end

    it 'rejects an invented lane' do
      expect { described_class.validate_entry!(entry(lanes: %i[chat telepathy])) }
        .to raise_error(described_class::InvalidFeatureError, /telepathy/)
    end

    # KI-Pakete P3. A pin names ONE provider this path may run on; a utility
    # marking says "take the cheapest rung available", and that rung routinely
    # sits on another provider. The combination has no defined precedence, and
    # resolving it silently in the Factory is how a pin turns into a suggestion.
    # Refusing at LOAD time means nobody can deploy the ambiguity.
    it 'rejects an entry that is both pinned and utility' do
      expect { described_class.validate_entry!(entry(pin: 'openai', pin_reason: 'because', utility: true)) }
        .to raise_error(described_class::InvalidFeatureError, /pinned.*utility|utility.*pinned/m)
    end

    it 'accepts a utility entry without a pin' do
      expect { described_class.validate_entry!(entry(utility: true)) }.not_to raise_error
    end

    # nil is what a Struct hands back for a field nobody set — every entry
    # predating P3 — and a gate asking `feature.utility` would then thread nil
    # into a boolean kwarg. #utility? is the answer, and it is a real boolean.
    it 'answers utility? as false for an entry that never mentions it' do
      expect(entry.utility?).to be(false)
      expect(entry(utility: true).utility?).to be(true)
    end
  end

  # THE product decision of P3 (doc/ki_pakete_plan.md §2.1, fixed 2026-08-02),
  # written out as data rather than described: which paths take the cheapest rung
  # and which follow the org's own choice.
  #
  # Pinned as an exhaustive PARTITION, not as four positive assertions. The point
  # of the flag is the line between the two groups, and a list that only names
  # the utility side would let a new entry default into "follows the org" without
  # anybody deciding — which is precisely how the eight original pins accumulated.
  describe 'the utility partition (P3)' do
    it 'marks exactly the helper paths' do
      expect(described_class.all.select(&:utility?).map(&:key)).to contain_exactly(
        :ticket_summary, :document_summary, :meeting_participant_detection,
        :meeting_ticket_suggestions, :repository_indexing
      )
    end

    # :glossary_extraction is on this side on purpose: telling the product and
    # field names of an organisation from ordinary words over its whole
    # catalogue is the product there, not a helper, and a person decides on
    # every proposal a weaker model gets wrong.
    it 'leaves the paths the customer reads on the org rung' do
      expect(described_class.all.reject(&:utility?).map(&:key)).to contain_exactly(
        :chat, :ask_ai_post, :customer_description, :meeting_summary, :meeting_analysis,
        :content_indexing, :semantic_search, :glossary_extraction
      )
    end

    # The three meetings rows are the reason an entry is per ROUTING DECISION and
    # not per service directory: two of them read the org's rung and one does not,
    # although all three run through the same line in Meetings::BaseLlmService.
    it 'splits the three meetings rows' do
      expect(described_class.fetch(:meeting_ticket_suggestions)).to be_utility
      expect(described_class.fetch(:meeting_summary)).not_to be_utility
      expect(described_class.fetch(:meeting_analysis)).not_to be_utility
    end

    # The embedding-only rows carry no ladder to be cheap on — a package has
    # exactly one embedding model (§2). Marking one would be a statement with
    # nothing behind it.
    it 'leaves the embedding-only rows alone' do
      expect(described_class.fetch(:content_indexing)).not_to be_utility
      expect(described_class.fetch(:semantic_search)).not_to be_utility
    end
  end

  # E7: the registry states its requirements against what the FACTORY resolves for an
  # org, never against the org's provider columns. That is what makes it independent
  # of doc/ki_pakete_plan.md P2 — packages change the innards of the resolution, and
  # not a line here.
  #
  # Word boundaries, not substrings: Factory.embedding_provider_name CONTAINS
  # "embedding_provider" and is exactly the indirection this rule asks for. What must
  # not appear is the bare attribute read (organisation.embedding_provider).
  describe 'decoupling from the packages domain (E7)' do
    it 'never reads the org provider columns directly' do
      expect(module_code).not_to match(/\bai_provider\b/)
      expect(module_code).not_to match(/\bembedding_provider\b/)
    end

    it 'asks the factory instead — the same derivation the routing uses' do
      expect(module_source).to include('Factory.chat_provider_name', 'Factory.embedding_provider_name')
    end

    # Door 2 of provider_pin_guard_spec: a module naming PROVIDER_CLASSES would need
    # an allowlist entry there. The capability question goes through
    # AiCredential.embedding_capable_providers, which derives from the very same
    # registry — one list, no drift, no new guard exception.
    it 'asks about embedding capability without touching the provider registry' do
      expect(module_code).not_to match(/\bPROVIDER_CLASSES\b/)
      expect(module_code).to include('AiCredential.embedding_capable_providers')
    end
  end

  describe 'i18n completeness (E4)' do
    # NEITHER I18n.t NOR I18n.exists? can answer "is this translated into EN?" in
    # this app. config/initializers/i18n.rb sets `fallbacks = [:de]`, so the English
    # chain is [:en, :de]: a MISSING English key makes I18n.exists?(key, :en) return
    # true and I18n.t(key, locale: :en) return the GERMAN sentence — present,
    # interpolated, and wrong. Measured, not suspected: deleting both
    # shared.ai.unavailable.no_credential and shared.ai.features.chat from en.yml
    # left this whole file green (82 examples, 0 failures).
    #
    # The per-locale translation tree is the only thing that knows the difference,
    # so every "does EN have this" question below is asked there. The rendering
    # questions stay on I18n.t — that is what catches an interpolation the copy
    # names but the caller never passes.
    def translation_in(locale, key)
      I18n.backend.eager_load!
      I18n.backend.translations.dig(locale, *key.split('.').map(&:to_sym))
    end

    # Every reason a surface can receive must be sayable in both locales — really in
    # both, not by way of the fallback.
    (described_class::REASONS - [:ai_disabled]).each do |reason|
      %i[de en].each do |locale|
        it "explains #{reason} in #{locale}" do
          expect(translation_in(locale, "shared.ai.unavailable.#{reason}")).to be_present

          # And it must RENDER: a text that names %{provider} but never gets one
          # raises at render time, which is a bug this spec should catch rather than
          # hide behind a bare presence check.
          text = I18n.t("shared.ai.unavailable.#{reason}", locale: locale, default: nil,
                                                           provider: 'OpenAI', current: 'Gemini')
          expect(text).to be_present
          expect(text).not_to include('%{')
        end
      end
    end

    # Pins the E4 decision itself, not just its result: :ai_disabled REUSES the
    # canonical opt-in copy. A forked shared.ai.unavailable.ai_disabled would be the
    # second source this project keeps deleting (the locale file says so above the
    # block: "ONE source per audience — do not fork per context").
    it 'reuses the canonical opt-in copy for :ai_disabled instead of forking it' do
      expect(described_class::REASONS).to include(:ai_disabled)
      expect(translation_in(:de, 'shared.ai.unavailable.ai_disabled')).to be_nil
      expect(translation_in(:en, 'shared.ai.unavailable.ai_disabled')).to be_nil
      expect(translation_in(:de, 'shared.ai.disabled_member_hint')).to be_present
      expect(translation_in(:en, 'shared.ai.disabled_member_hint')).to be_present
      expect(translation_in(:de, 'shared.ai.disabled_admin_hint')).to be_present
      expect(translation_in(:en, 'shared.ai.disabled_admin_hint')).to be_present
    end

    described_class::BY_KEY.each_key do |key|
      it "labels the feature #{key} in DE and EN" do
        expect(translation_in(:de, "shared.ai.features.#{key}")).to be_present
        expect(translation_in(:en, "shared.ai.features.#{key}")).to be_present
      end
    end
  end

  # R3: the reason→copy mapping, extracted here because three surfaces refuse the
  # same feature (customer-export view, the actor, its async twin) and hand-writing
  # the mapping at each of them is where a convention stops being one.
  describe '.unavailable_hint' do
    let(:organisation) { build_stubbed(:organisation, ai_provider: 'google') }

    def availability(reason, provider = 'openai')
      described_class::Availability.new(available: false, reason: reason, required_provider: provider)
    end

    it 'says nothing about an available feature' do
      hint = described_class::Availability.new(available: true, reason: nil)

      expect(described_class.unavailable_hint(hint, organisation)).to be_nil
    end

    # The pin's copy is the one that needs BOTH providers: without the second half
    # the admin knows what the feature wants but not what the org is currently on,
    # and a withheld button explains nothing.
    it 'names the required AND the current provider for :pinned_elsewhere' do
      text = described_class.unavailable_hint(availability(:pinned_elsewhere), organisation)

      expect(text).to include(::AiCredential.provider_display_names.fetch('openai'))
      expect(text).to include(::AiCredential.provider_display_names.fetch('google'))
      expect(text).not_to include('%{')
    end

    it 'names only the provider a credential is missing for' do
      text = described_class.unavailable_hint(availability(:no_credential), organisation)

      expect(text).to eq(I18n.t('shared.ai.unavailable.no_credential',
                                provider: ::AiCredential.provider_display_names.fetch('openai')))
    end

    # E4: :ai_disabled REUSES the canonical opt-in copy instead of forking a key —
    # the decision the locale file records and the i18n block above pins from the
    # other side (no shared.ai.unavailable.ai_disabled exists to fall back on).
    it 'falls back to the canonical opt-in copy for :ai_disabled' do
      expect(described_class.unavailable_hint(availability(:ai_disabled, nil), organisation))
        .to eq(I18n.t('shared.ai.disabled_member_hint'))
    end

    # A nil availability means "no organisation at all", which resolve(key, nil)
    # answers as :ai_disabled too. Without this branch every caller would need a nil
    # check of its own — and one of them would forget it.
    it 'treats a nil availability as the missing opt-in rather than raising' do
      expect(described_class.unavailable_hint(nil, nil)).to eq(I18n.t('shared.ai.disabled_member_hint'))
    end

    # Every reason must be sayable, including the two no R3 surface produces today:
    # a caller reaching one of them must get a sentence, not a raw key or a raise.
    (described_class::REASONS - [:ai_disabled]).each do |reason|
      it "renders a complete sentence for #{reason}" do
        text = described_class.unavailable_hint(availability(reason), organisation)

        expect(text).to be_present
        expect(text).not_to include('%{')
        expect(text).not_to include('translation missing')
      end
    end
  end
end
