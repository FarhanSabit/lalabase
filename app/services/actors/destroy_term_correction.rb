# frozen_string_literal: true

# app/services/actors/destroy_term_correction.rb
#
# Deletes one heard form of a glossary term, one that was learnt wrong (K4a).
# The term stays, also without any heard form. Rights are the caller's
# (GlossaryPolicy, manage_glossary).
module Actors
  class DestroyTermCorrection < BaseActor
    def initialize(correction:, current_user:)
      super()
      @correction = correction
      @current_user = current_user
    end

    # A destroy leaves no surviving primary record.
    def record
      nil
    end

    def perform
      @correction.destroy!
    end

    private

    attr_reader :current_user
  end
end
