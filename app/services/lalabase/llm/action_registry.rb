# frozen_string_literal: true

module Lalabase
  module Llm
    # THE price list for AI actions, in ABSTRACT integer credits (decision 7A).
    #
    # The credit is deliberately decoupled from currency: an action costs whole
    # credits from this registry, currency only enters at pack-sale time (S7). This
    # is what makes "no call can cost 0 credits" structurally true — see #credits_for.
    #
    # Each action carries:
    #   :credits    — base price (flat actions) or price per started token block
    #   :per_tokens — nil for a flat action; N for a token-metered action
    #                 (credits = base * ceil(tokens / N), floored at 1 block)
    #
    # The i18n label lives under shared.ai.actions.<action> (DE + EN). A guard spec
    # (spec/services/lalabase/llm/action_registry_guard_spec.rb) pins that EVERY
    # action has a positive price AND both locale labels, so a new action can never
    # be deployed half-defined (failure mode "new action without price", plan §13).
    #
    # Start values are pauschale margins calibrated against the §3 cost frame; they
    # are documented in the PR body for confirmation and are trivially tunable here
    # (data, not schema).
    module ActionRegistry
      class UnknownActionError < StandardError; end

      CHAT_MESSAGE          = 'chat_message'
      SEMANTIC_SEARCH       = 'semantic_search'
      DOCUMENT_INDEXING     = 'document_indexing'
      SUMMARY               = 'summary'
      POST_AI               = 'post_ai'
      CUSTOMER_DESCRIPTION  = 'customer_description'
      PARTICIPANT_DETECTION = 'participant_detection'
      MEETING_ANALYSIS      = 'meeting_analysis'
      TICKET_SUGGESTIONS    = 'ticket_suggestions'
      GLOSSARY_EXTRACTION   = 'glossary_extraction'

      ACTIONS = {
        CHAT_MESSAGE => { credits: 2, per_tokens: nil },
        SEMANTIC_SEARCH => { credits: 1, per_tokens: nil },
        DOCUMENT_INDEXING => { credits: 1, per_tokens: 1_000 },
        SUMMARY => { credits: 2, per_tokens: nil },
        POST_AI => { credits: 2, per_tokens: nil },
        CUSTOMER_DESCRIPTION => { credits: 2, per_tokens: nil },
        # Meetings Slice 5: LLM participant detection over a full transcript —
        # same input profile as SUMMARY, so the same flat price. The endpoint's
        # payload cap (MAX_DETECT_BYTES) keeps the flat price honest.
        PARTICIPANT_DETECTION => { credits: 2, per_tokens: nil },
        # Meetings Slice 7a: a free-prompt AI analysis over a meeting's source
        # (transcript/notes) — same input profile as SUMMARY, so the same flat price.
        MEETING_ANALYSIS => { credits: 2, per_tokens: nil },
        # Meetings Slice 8: derive ticket suggestions from a meeting's source
        # (transcript/notes) — same input profile as SUMMARY, so the same flat price.
        # The per-suggestion similarity matching bills separately via SEMANTIC_SEARCH
        # (QueryEmbedding self-meters each call), so a run costs 2 + N credits (F14).
        TICKET_SUGGESTIONS => { credits: 2, per_tokens: nil },
        # Glossary extraction (K5b): one call classifies up to 60 candidate terms,
        # each with one or two passages of context (at most 240 characters each),
        # and answers a short JSON object per candidate. That is less input than a
        # capped meeting transcript and less output than a meeting analysis, so the
        # same flat price per call. A run makes at most 8 calls, so a whole run costs
        # at most 16 credits, and the flat price lets the run say so before it starts.
        GLOSSARY_EXTRACTION => { credits: 2, per_tokens: nil }
      }.freeze

      LABEL_SCOPE = 'shared.ai.actions'

      module_function

      def keys
        ACTIONS.keys
      end

      def known?(action)
        ACTIONS.key?(action.to_s)
      end

      # Credits for ONE call.
      # - flat action  → its base price (>= 1 by construction)
      # - token action → base * units, units = at least 1 per started `per_tokens`
      #   block: [ceil(tokens / per_tokens), 1].max. So a run with any tokens — even
      #   a handful — books >= 1 credit; NO call can ever cost 0 (decision 7A, test 10).
      def credits_for(action, tokens: 0)
        cfg = ACTIONS.fetch(action.to_s) do
          raise UnknownActionError, "Unknown AI action: #{action.inspect}"
        end
        return cfg[:credits] if cfg[:per_tokens].nil?

        units = [(tokens.to_i.to_f / cfg[:per_tokens]).ceil, 1].max
        units * cfg[:credits]
      end

      # Localised, human-readable action label for the usage history.
      def label(action, locale: I18n.locale)
        I18n.t("#{LABEL_SCOPE}.#{action}", locale: locale, default: action.to_s)
      end
    end
  end
end
