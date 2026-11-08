# frozen_string_literal: true

# The one read gate for a single meeting behind a Personal Access Token (REST R8, MCP R9).
module Meetings
  # The one read gate for a single meeting a program reads behind a Personal Access Token:
  # GET /api/v1/meetings/:id (REST R8) and the MCP tool get_meeting (R9). Moved here from the
  # REST controller when the second door came, so both doors ask the same thing.
  #
  # Missing, malformed, beyond the token's reach, of another organisation, no read right in
  # the meetings area: all the same nothing, so no answer tells a meeting that exists from one
  # that does not. A transcript is what people said; a refusal that sounds different from "not
  # there" would say the meeting exists.
  #
  # The tenant is unknown at first, so discovery reads only organisation_id and project_id
  # without a tenant, and the row itself is read inside the tenant, through the policy scope,
  # then asked show?. The project_id from discovery stays in the condition: a meeting that
  # moves in between is gone from the project whose reach was checked.
  #
  # Each door marks the authorization its own way (the controller's `authorize`, the tool's
  # `authorize!`); this gate has already decided by then.
  #
  # Entry point: call
  module Readable
    # Yields the meeting inside its organisation's tenant and answers true, or answers false
    # without yielding.
    def self.call(id:, user:, token:)
      return false if id.blank?

      organisation_id, project_id = ActsAsTenant.without_tenant { Meeting.where(id: id).pick(:organisation_id, :project_id) }
      return false unless organisation_id

      ActsAsTenant.with_tenant(Organisation.find(organisation_id)) do
        meeting = read(id, project_id, user: user, token: token)
        next false unless meeting

        yield meeting
        true
      end
    end

    def self.read(id, project_id, user:, token:)
      return nil unless token.accessible_project?(Project.find_by(id: project_id))

      meeting = Pundit.policy_scope!(user, Meeting.where(id: id, project_id: project_id))
                      .preload(:creator, :meeting_participants, :project, :term_applications).take
      meeting if meeting && Pundit.policy!(user, meeting).show?
    end
    private_class_method :read
  end
end
