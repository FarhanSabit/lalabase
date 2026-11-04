# frozen_string_literal: true

# app/services/actors/destroy_glossary_term.rb
#
# Deletes one term of the glossary with its heard forms (K4a, plan §3.3).
# Rights are the caller's (GlossaryPolicy, manage_glossary).
module Actors
  class DestroyGlossaryTerm < BaseActor
    def initialize(term:, current_user:)
      super()
      @term = term
      @current_user = current_user
    end

    # A destroy leaves no surviving primary record.
    def record
      nil
    end

    def perform
      @term.destroy!
    end

    private

    attr_reader :current_user
  end
end
