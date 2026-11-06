# frozen_string_literal: true

module Api
  module V1
    # The glossary of one organisation for a program (K4c): its working terms in their right
    # spelling, each with the heard forms speech recognition wrote for it, so a device can give
    # the terms to its recognition and replace a learnt wrong form before it sends. Read
    # through Glossary::Lookup like the MCP tool get_glossary, never through the models.
    #
    # * Reach (E4): an organisation the token reaches; outside it, foreign, missing and a
    #   malformed id answer the same 404. A token limited to some projects gets every term,
    #   but the heard forms of its projects only.
    # * Rights (E2): the glossary right of the token's owner (GlossaryPolicy, an active
    #   membership), 403 with the reason glossary_forbidden without it. A read token suffices.
    # * project_id (E5): that project's heard forms first; outside the organisation or the
    #   token the same 404, never ignored.
    # * Paging: 50 terms by default, at most 100, with the total; a value outside is a 400.
    class TermsController < BaseController
      # Pundit asks the glossary right first; Refused answers the same right taken away
      # between that check and the lookup's own.
      rescue_from Pundit::NotAuthorizedError, Glossary::Lookup::Refused, with: :glossary_forbidden
      rescue_from Glossary::Lookup::InvalidArgument, with: :bad_request
      rescue_from Glossary::Lookup::NotFound, with: :not_found

      # GET /api/v1/organisations/:organisation_id/terms?project_id=&page=&per_page=
      #
      # The reach, then the organisation's tenant, then the glossary right, the order of the
      # people directory: an organisation outside the token tells nothing about itself.
      def index
        lookup = Glossary::Lookup.for_token(reach: current_token.reach, viewer: current_user,
                                            organisation_id: params[:organisation_id])
        raise ActiveRecord::RecordNotFound if lookup.nil?

        ActsAsTenant.with_tenant(lookup.organisation) do
          authorize GlossaryTerm, :index?
          # The rows are policy-scoped inside Glossary::Lookup (GlossaryPolicy::Scope); a
          # policy_scope here would be a second copy nothing reads.
          skip_policy_scope
          # Read raw, not through strong parameters: those would drop a list and let a
          # malformed request through as the default.
          render json: lookup.read(project_id: params[:project_id], page: params[:page], per_page: params[:per_page])
        end
      end

      private

      # A rescue runs outside the action's around_action, so outside the token owner's language:
      # the text is put in it here (with_token_owner_locale, the one rule of a token request).
      def glossary_forbidden
        with_token_owner_locale do
          render_error(error: 'forbidden', reason: Glossary::Lookup::FORBIDDEN_REASON,
                       message: I18n.t('services.glossary.lookup.forbidden'), status: :forbidden)
        end
      end
    end
  end
end
