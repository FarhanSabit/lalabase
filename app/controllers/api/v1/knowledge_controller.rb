# frozen_string_literal: true

module Api
  module V1
    # The knowledge of one project (notes and documents) for a program such as the terminal
    # client (REST R2), read through Knowledge::Lookup like the MCP tool search_knowledge
    # (cli_rest_plan D5): the same rows, order, fields and total for the same search.
    #
    # * Without `q` REST lists every readable row, newest first, so a client can open the
    #   knowledge area without a search term. MCP keeps `q` required.
    # * Paging: a page or per_page that is no whole number from 1 to the maximum is refused
    #   with 422, where MCP clamps: a program would get fewer rows than it asked for without
    #   being told. An absent or empty value means the default; a NUL in q or type is refused.
    #   Checked before the project is looked up, so the 422 does not depend on whether the
    #   project exists.
    # * The project gate is the one of MCP (Mcp::ToolCall#authorized_project): the token's reach
    #   and the owner's access to the project. A missing project, a malformed id, a project
    #   beyond the reach, one the owner cannot open and one of another organisation answer the
    #   same 404. A reader who may open the project but read no knowledge gets an empty list.
    class KnowledgeController < BaseController
      include ReadableProject

      rescue_from Knowledge::Lookup::InvalidOption, with: :invalid_input

      # GET /api/v1/projects/:project_id/knowledge?q=&type=&page=&per_page=
      def index
        options = Knowledge::Lookup.options(lookup_args, strict: true)
        project = readable_project(params[:project_id])

        ActsAsTenant.with_tenant(project.organisation) do
          # The rows are policy-scoped inside Knowledge::Lookup, per type (Pundit.policy_scope!);
          # a policy_scope here would be a second copy nothing reads.
          skip_policy_scope
          render json: Knowledge::Lookup.new(user: current_user, project: project).page(options).to_h
        end
      end

      private

      # Read raw, not through strong parameters: those would drop a list or a nested value and
      # let a malformed request through as "no filter".
      def lookup_args
        %i[q type page per_page].index_with { |key| params[key] }
      end

      def invalid_input(exception)
        render_error(error: 'invalid_input', code: 'invalid_input', message: exception.message,
                     status: :unprocessable_content)
      end
    end
  end
end
