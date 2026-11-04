# frozen_string_literal: true

# app/services/actors/set_glossary_term_status.rb
#
# Confirms or rejects one term of the glossary (K4a, E5). Rights are the
# caller's (GlossaryPolicy, manage_glossary). A proposal comes only from a
# correction (K4b) or an extraction (K5), never from here: SETTABLE has no
# proposed. A rejected term stays, so it is not proposed again; confirming it
# later is allowed.
module Actors
  class SetGlossaryTermStatus < BaseActor
    SETTABLE = %w[confirmed rejected].freeze

    def initialize(term:, status:, current_user:)
      super()
      @term = term
      @status = status.to_s
      @current_user = current_user
    end

    def record
      @term
    end

    def perform
      raise ActorError.new(I18n.t('controllers.glossary.status.not_allowed'), code: :invalid_status) unless SETTABLE.include?(@status)

      @term.update!(status: @status)
    end

    private

    attr_reader :current_user
  end
end
