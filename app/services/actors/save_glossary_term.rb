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
# * A stale save (lock_version, as Actors::SavePerson): the form sends the
#   lock_version it was opened with. The lock reloads the row, so without it
#   the form's old values would write over a change made in the meantime.
#   Assigned to the row, it makes the save raise StaleObjectError, which
#   BaseActor maps to code :stale_object; the controller shows the form again
#   with the current values. A request without the key is not checked.
module Actors
  class SaveGlossaryTerm < BaseActor
    ATTRIBUTES = %i[term category lock_version].freeze
    # lock_version is an integer column (4 bytes).
    LOCK_VERSION_RANGE = (0..((2**31) - 1))

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

      check_lock_version
      Glossary::TermLock.call(term: @term) if @term.persisted?
      attributes = @params.slice(*ATTRIBUTES)
      attributes.delete(:lock_version) if @term.new_record?
      @term.assign_attributes(attributes)
      if @term.new_record?
        @term.status = 'confirmed'
        @term.created_by = @current_user
      end
      save_term
    end

    private

    attr_reader :current_user

    # On an update, a lock_version that is not a number the column can hold (a
    # hand-made request) cannot say what the writer saw; Rails would raise on
    # it. Treated as stale. A new term has none to compare.
    def check_lock_version
      return if @term.new_record? || !@params.key?(:lock_version)
      return if LOCK_VERSION_RANGE.cover?(Integer(@params[:lock_version].to_s, exception: false))

      raise ActorError.new(I18n.t('controllers.glossary.update.stale'), code: :stale_object)
    end

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
