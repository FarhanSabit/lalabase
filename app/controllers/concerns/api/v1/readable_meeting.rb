# frozen_string_literal: true

module Api
  module V1
    # One read gate for a single meeting (REST R8). Missing, malformed, beyond the token's
    # reach, of another organisation, no read right in the meetings area: the same
    # RecordNotFound, so the same 404 in status and body.
    #
    # A policy refusal is a 404 as well, never the 403 ReadableTicket leaves to the base
    # controller: a transcript is what people said, and a 403 would say the meeting exists.
    #
    # The tenant is unknown at first, so discovery reads only organisation_id and project_id
    # without a tenant, and the row itself is read inside the tenant, through the policy
    # scope. Query counts differ for a missing and a hidden meeting: ids are random UUIDs,
    # and the contract is equal status and body, not equal timing.
    #
    # The project_id from discovery stays in the condition: a meeting that moves in between
    # is gone from the project whose reach was checked, and answers the 404.
    module ReadableMeeting
      extend ActiveSupport::Concern

      private

      def with_readable_meeting(id)
        raise ActiveRecord::RecordNotFound if id.blank?

        organisation_id, project_id = ActsAsTenant.without_tenant { Meeting.where(id: id).pick(:organisation_id, :project_id) }
        raise ActiveRecord::RecordNotFound unless organisation_id

        ActsAsTenant.with_tenant(Organisation.find(organisation_id)) do
          yield read_meeting(id, project_id)
        end
      end

      def read_meeting(id, project_id)
        raise ActiveRecord::RecordNotFound unless current_token.accessible_project?(Project.find_by(id: project_id))

        meeting = policy_scope(Meeting.where(id: id, project_id: project_id)).preload(:creator, :meeting_participants).take!
        authorize meeting, :show?
        meeting
      rescue Pundit::NotAuthorizedError
        raise ActiveRecord::RecordNotFound
      end
    end
  end
end
