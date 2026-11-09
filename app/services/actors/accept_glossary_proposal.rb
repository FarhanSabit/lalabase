# frozen_string_literal: true

# app/services/actors/accept_glossary_proposal.rb
#
# Accepts a proposal of the glossary extraction (K5b): the proposal becomes a
# confirmed term of the glossary, and the variants the person chose become
# heard forms of that term. The controller authorizes (GlossaryPolicy#accept?);
# the actor asks for the right again under the lock.
#
# * The spelling is the one the form gives (GlossaryText.clean), or the
#   proposal's when the form gives none. The term of that compared form in the
#   proposal's organisation is found and confirmed: an import or a correction
#   in a meeting may have left it proposed, and a person accepts it now. It
#   gets a category only when it has none (the form's, else the proposal's).
#   A term that was PROPOSED takes its open heard forms along into confirmed
#   (GlossaryTerm#confirm_open_forms!), as Actors::SetGlossaryTermStatus does:
#   both ways to "confirmed" hand the device the same forms. A rejected term
#   keeps what is open, form by form.
#   Without such a term one is created, confirmed, by this person, with that
#   category; one that someone else created at the same moment is that term
#   (as in Actors::CorrectMeetingTerm).
# * The term is locked first (Glossary::TermLock), the one lock order of the
#   glossary: the term, then the proposal, never the other way round. A term
#   gone in the meantime is :not_found. Then manage_glossary again
#   (GlossaryPolicy.manage_allowed?, an active membership): :forbidden without.
#   A term renamed to another compared form before the lock is :term_changed.
# * Then Decision#claim!, one UPDATE whose condition is the status of the row:
#   a proposal accepted, dismissed or merged away in the meantime is
#   :already_processed, whatever the copy in memory says, and the transaction
#   takes back the term written a moment ago.
# * Then Decision#learn: the chosen variants that are variants of the proposal
#   (compared by form, written as the proposal spells them), and its own
#   spelling once the form changed it, become heard forms.
#
# Decision is shared with Actors::MergeGlossaryProposalIntoTerm, which decides
# a proposal for a term the person picked.
module Actors
  class AcceptGlossaryProposal < BaseActor
    # The two steps that decide a proposal for a term, in this order, after
    # the term's lock and the rights check.
    class Decision
      def initialize(proposal:, term:, current_user:)
        @proposal = proposal
        @term = term
        @current_user = current_user
      end

      # The atomic claim (the 3A rule of Actors::AcceptTicketSuggestion): one
      # UPDATE on the open row, nothing read before it. Exactly one row, or
      # someone else decided first. The UPDATE takes the proposal's row lock
      # after the term's. The proposal is read again under that lock: what
      # follows works on what is stored now.
      def claim!
        now = Time.current
        claimed = GlossaryProposal.where(id: @proposal.id, organisation_id: @proposal.organisation_id, status: 'open')
                                  .update_all(status: 'accepted', glossary_term_id: @term.id, decided_by_id: @current_user.id,
                                              decided_at: now, updated_at: now)
        raise ActorError.new(I18n.t('controllers.glossary.proposals.already_processed'), code: :already_processed) unless claimed == 1

        @proposal.reload
      end

      # The given strings that are the proposal's spelling or one of its
      # variants, compared by form and written as the proposal spells them.
      # Anything else (another word, no text at all) is left out.
      def chosen(given)
        spellings = [@proposal.term, *@proposal.variants].grep(String).index_by { |text| GlossaryText.normalize(text) }
        Array(given).grep(String).filter_map { |text| spellings[GlossaryText.normalize(text)] }
      end

      # Each form becomes a confirmed heard form of the term, from the
      # extraction: no meeting, no place, no speaker, counted once, in the
      # project of the busiest source that has one. A form that is the term
      # itself or that the term has already (in any status) is skipped, and so
      # is a second spelling of one form.
      #
      # Every row goes through the model's checks (the references within the
      # organisation above all), and all rows are checked before any is
      # written. The rows name the same organisation, term and project, so the
      # checks ask the database the same questions for each; the query cache
      # answers each question once.
      def learn(forms)
        known = Set.new(TermCorrection.where(organisation_id: @term.organisation_id, glossary_term_id: @term.id)
                                      .distinct.pluck(:normalized_heard)) << @term.normalized_term
        fresh = forms.select { |heard| known.add?(GlossaryText.normalize(heard)) }
        return if fresh.empty?

        project_id = busiest_project_id
        rows = fresh.map do |heard|
          TermCorrection.new(organisation: @term.organisation, glossary_term: @term, project_id: project_id, heard: heard,
                             status: 'confirmed', origin: 'extraction', replaced_count: 1, corrected_by: @current_user)
        end
        TermCorrection.cache { rows.each(&:validate!) }
        rows.each { |row| row.save!(validate: false) }
      end

      private

      def busiest_project_id
        GlossaryProposalSource.where(organisation_id: @proposal.organisation_id, glossary_proposal_id: @proposal.id)
                              .where.not(project_id: nil)
                              .order(occurrences: :desc, created_at: :asc, id: :asc)
                              .pick(:project_id)
      end
    end

    # term: the spelling from the form; category: a key of
    # GlossaryTerm::CATEGORIES; variants: the strings the person chose.
    def initialize(proposal:, current_user:, term: nil, category: nil, variants: [])
      super()
      @proposal = proposal
      @current_user = current_user
      @spelling = GlossaryText.clean(term).presence || proposal.term
      @category = category.presence || proposal.category
      @variants = variants
      @term = nil
    end

    def record
      @term
    end

    def perform
      @term = existing_term || create_term
      Glossary::TermLock.call(term: @term)
      refuse(:forbidden) unless GlossaryPolicy.manage_allowed?(current_user, @proposal.organisation)
      refuse(:term_changed) unless @term.normalized_term == GlossaryText.normalize(@spelling)

      adopt_term
      decision = Decision.new(proposal: @proposal, term: @term, current_user: current_user)
      decision.claim!
      decision.learn(decision.chosen(@variants))
    end

    private

    attr_reader :current_user

    def refuse(code)
      raise ActorError.new(I18n.t("controllers.glossary.proposals.#{code}"), code: code)
    end

    # Under the lock. A term this accept created is confirmed and has its
    # category already; a found one is confirmed now and keeps a category it
    # has. A found term that was proposed takes its open heard forms along.
    def adopt_term
      was_proposed = @term.proposed?
      @term.status = 'confirmed'
      @term.category ||= @category
      @term.save! if @term.changed?
      @term.confirm_open_forms! if was_proposed
    end

    def existing_term
      terms.find_by(normalized_term: GlossaryText.normalize(@spelling))
    end

    # A term of the same form created at the same moment is that term: the
    # validation that saw it, or the unique index that caught it, finds it.
    # The insert runs in a savepoint, so the index refusal leaves the
    # transaction usable.
    def create_term
      term = GlossaryTerm.new(organisation_id: @proposal.organisation_id, term: @spelling, category: @category,
                              status: 'confirmed', created_by: current_user)
      return term_of_the_same_form if term.invalid? && term.errors.of_kind?(:term, :taken)
      raise ActiveRecord::RecordInvalid, term if term.errors.any?

      GlossaryTerm.transaction(requires_new: true) { term.save!(validate: false) }
      term
    rescue ActiveRecord::RecordNotUnique
      term_of_the_same_form
    end

    def term_of_the_same_form
      terms.find_by!(normalized_term: GlossaryText.normalize(@spelling))
    end

    def terms
      GlossaryTerm.where(organisation_id: @proposal.organisation_id)
    end
  end
end
