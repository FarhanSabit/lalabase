# frozen_string_literal: true

module Api
  module V1
    # The project gate of a list inside one project (knowledge, meetings), the one of MCP
    # (Mcp::ToolCall#authorized_project): the token's reach and the owner's access to the
    # project. A missing project, a malformed id, a project beyond the reach, one the owner
    # cannot open (an archived one for a non-admin) and one of another organisation raise
    # the same RecordNotFound, so they answer the same 404. What the reader sees inside the
    # project stays with the rows' policy scope.
    module ReadableProject
      extend ActiveSupport::Concern

      private

      def readable_project(id)
        project = ActsAsTenant.without_tenant { Project.find_by(id: id) } if id.present?
        raise ActiveRecord::RecordNotFound unless project && current_token.accessible_project?(project)

        ActsAsTenant.with_tenant(project.organisation) do
          raise ActiveRecord::RecordNotFound unless AccessCheck::ProjectAccessService.can_access_project?(current_user, project)
        end
        project
      end
    end
  end
end
