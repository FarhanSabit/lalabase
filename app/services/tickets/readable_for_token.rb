# frozen_string_literal: true

# The one place that answers "which tickets can this holder find": the rows of `organisation`,
# inside the policy scope of `user`, inside the reach of `token`. Missing, foreign, unreadable
# and out of reach are all the same absence here, so a caller cannot tell them apart.
#
# It decides what can be FOUND, never the answer: no authorize, no 404, no wording. Those stay
# with the caller.
#
# token: nil is legitimate. The web pages and the assistant, which calls the same tools as MCP,
# have no token; their reach is the person's own, which is the policy scope alone. nil therefore
# means "no second limit", and the caller writes token: nil out: the keyword is required, because a caller that forgot it
# would silently widen an account admin to every project. A token's reach of nil means every project of the
# organisation, [] means none, also for an organisation outside the token.
#
# The reach comes before the policy scope. An organisation the token no longer reaches (a
# deactivated membership, say) is not asked about at all: an empty reach answers with an empty
# relation and no rights are looked up.
#
# Built under `organisation` as the tenant, like TicketRelation.visible_to, and bound by
# organisation_id, so the rows and the rights do not depend on the tenant current at the call.
# ⚠️ That holds for the rows only: a preload chained onto the relation runs at execution, under
# the tenant current THEN, and finds nothing under another one. The caller runs the query inside
# ActsAsTenant.with_tenant(organisation).
module Tickets
  class ReadableForToken
    def self.call(**)
      new(**).call
    end

    def initialize(user:, organisation:, token:, relation: Ticket)
      @user = user
      @organisation = organisation
      @relation = relation
      @token = token
    end

    def call
      ActsAsTenant.with_tenant(@organisation) do
        rows = @relation.where(organisation_id: @organisation.id)
        reached = reached_project_ids
        next rows.none if reached == []

        readable = Pundit.policy_scope!(@user, rows)
        reached.nil? ? readable : readable.where(project_id: reached)
      end
    end

    private

    # nil: no limit from a token, either because there is none or because it reaches every project.
    def reached_project_ids
      @token&.reach&.project_ids_for(@organisation.id)
    end
  end
end
