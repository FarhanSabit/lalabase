# frozen_string_literal: true

# app/services/actors/save_glossary_term.rb
#
# Creates or changes one term of the glossary by hand (K4a): its spelling and
# its category. Rights are the caller's (GlossaryPolicy, manage_glossary).
#
# * A term written by hand is confirmed and remembers who created it; the
#   status changes only through Actors::SetGlossaryTermStatus.
# * One spelling once per organisation (GlossaryTerm#term_not_taken). Two
#   saves of the same spelling at once pass the validation; the unique index
#   refuses the second, and that is the same refusal, not a crash.
# * The id is looked up inside the organisation: an id of another one is no
#   term at all. A saved term is locked before it changes (Glossary::TermLock),
#   so one deleted or merged away in the meantime is refused as gone.
module Actors
  class SaveGlossaryTerm < BaseActor
    ATTRIBUTES = %i[term category].freeze

    def initialize(organisation:, params:, current_user:, id: nil)
      super()
      @organisation = organisation
      @params = params.to_h.symbolize_keys
      @current_user = current_user
      @term = find_term(id)
    end

    def record
      @term
    end

    def perform
      raise ActorError.new(I18n.t('controllers.glossary.not_found'), code: :not_found) if @term.nil?

      Glossary::TermLock.call(term: @term) if @term.persisted?
      @term.assign_attributes(@params.slice(*ATTRIBUTES))
      if @term.new_record?
        @term.status = 'confirmed'
        @term.created_by = @current_user
      end
      save_term
    end

    private

    attr_reader :current_user

    def save_term
      @term.save!
    rescue ActiveRecord::RecordNotUnique
      @term.errors.add(:term, :taken)
      raise ActorError.new(@term.errors.full_messages, code: :validation_failed)
    end

    def find_term(id)
      return GlossaryTerm.new(organisation: @organisation) if id.blank?

      GlossaryTerm.where(organisation: @organisation).find_by(id: id)
    end
  end
end
