# frozen_string_literal: true

# app/services/actors/merge_glossary_proposal_into_term.rb
#
# Merges a proposal of the glossary extraction into a term the glossary has
# (K5b): the run found another spelling of a term someone keeps already. The
# proposal is accepted for that term, and its spelling and the variants the
# person chose become heard forms of the term. The term keeps its spelling,
# its category and its status. The controller authorizes
# (GlossaryPolicy#accept?) and resolves the term through the policy scope,
# never from a raw id; the actor asks for the right again under the lock.
#
# * A term of another organisation is refused (:other_glossary) before
#   anything is locked.
# * The term is locked first (Glossary::TermLock, the one lock order of the
#   glossary: the term, then the proposal). A term deleted or merged away in
#   the meantime is :not_found. Then manage_glossary again
#   (GlossaryPolicy.manage_allowed?, an active membership): :forbidden without.
# * Then the term as the lock read it must be confirmed, the only kind the
#   page offers: a term rejected in the meantime, or one still proposed, is
#   :term_not_confirmed. It would take heard forms that work nowhere, and the
#   proposal would count as accepted, so its spelling would never be proposed
#   again.
# * Then the claim and the heard forms exactly as an accept writes them
#   (Actors::AcceptGlossaryProposal::Decision): one UPDATE whose condition is
#   the status of the row decides (:already_processed when someone decided
#   first), and only the proposal's spelling and its variants can become heard
#   forms, never a form the term has or is.
module Actors
  class MergeGlossaryProposalIntoTerm < BaseActor
    # variants: the strings the person chose.
    def initialize(proposal:, term:, current_user:, variants: [])
      super()
      @proposal = proposal
      @term = term
      @current_user = current_user
      @variants = variants
    end

    def record
      @term
    end

    def perform
      refuse(:other_glossary, 'controllers.glossary.merge.other_glossary') if @term && @term.organisation_id != @proposal.organisation_id

      Glossary::TermLock.call(term: @term)
      refuse(:forbidden) unless GlossaryPolicy.manage_allowed?(current_user, @proposal.organisation)
      refuse(:term_not_confirmed) unless @term.confirmed?

      decision = AcceptGlossaryProposal::Decision.new(proposal: @proposal, term: @term, current_user: current_user)
      decision.claim!
      decision.learn([@proposal.term, *decision.chosen(@variants)])
    end

    private

    attr_reader :current_user

    def refuse(code, key = "controllers.glossary.proposals.#{code}")
      raise ActorError.new(I18n.t(key), code: code)
    end
  end
end
