# frozen_string_literal: true

# app/services/actors/set_glossary_term_status.rb
#
# Confirms or rejects one term of the glossary (K4a, E5). Rights are the
# caller's (GlossaryPolicy, manage_glossary). A proposal comes only from a
# correction (K4b) or an extraction (K5), never from here: SETTABLE has no
# proposed. A rejected term stays, so it is not proposed again; confirming it
# later is allowed. The term is locked first (Glossary::TermLock), so a term
# deleted or merged away in the meantime is refused as gone.
#
# Confirming a PROPOSED term confirms its open heard forms with it (K4b, E3):
# they came with the proposal, and the lane shows them to whoever confirms.
# Rejecting leaves them as they are (at a rejected term no form works), and so
# does confirming a rejected term later: what is open then is confirmed form
# by form (Actors::ConfirmHeardForm).
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

      Glossary::TermLock.call(term: @term)
      was_proposed = @term.proposed?
      @term.update!(status: @status)
      confirm_open_forms if was_proposed && @term.confirmed?
    end

    private

    attr_reader :current_user

    def confirm_open_forms
      TermCorrection.where(glossary_term_id: @term.id, status: 'proposed').update_all(status: 'confirmed', updated_at: Time.current)
    end
  end
end
