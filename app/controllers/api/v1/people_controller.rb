# frozen_string_literal: true

module Api
  module V1
    # The people directory of one organisation for a program such as the terminal client
    # (People S3b): the list and the card of one person, read through People::Lookup like the
    # assistant's tools and their MCP twins (cli_rest_plan D5), never through Person itself.
    #
    # * Reach (E1): only a token that reaches every project of the organisation reads its
    #   directory. A token limited to some projects, an organisation outside the token, a
    #   missing one and a malformed id answer the same 404.
    # * Rights: the people right of the people page (PersonPolicy), 403 without it.
    # * Fields: the list rows never carry contact details or notes, the card carries the notes
    #   (E2 B). A missing and an invisible person are the same 404.
    # * Paging (E4): 50 rows by default, at most 100, with the total. A value outside is
    #   refused, not cut: a program would get fewer rows than it asked for without being told.
    class PeopleController < BaseController
      DEFAULT_PER_PAGE = 50
      MAX_PER_PAGE = 100
      # Far beyond any directory, so an absurd page number is refused rather than skipped to.
      MAX_PAGE = 100_000

      # A list parameter the endpoint cannot take (q, page, per_page).
      class InvalidParameter < StandardError; end

      # Pundit asks the people right first (with_directory); this answers the same right taken
      # away between that check and the lookup's own.
      rescue_from People::Lookup::Refused, with: :forbidden
      rescue_from People::Lookup::InvalidArgument, InvalidParameter, with: :bad_request

      # GET /api/v1/organisations/:organisation_id/people?q=&kind=&page=&per_page=
      def index
        with_directory do |people|
          # The rows are policy-scoped inside People::Lookup (People::Directory reads
          # PersonPolicy::Scope and MembershipPolicy::Scope itself); a policy_scope here would be
          # a second copy nothing reads.
          skip_policy_scope
          page = whole_number(:page, default: 1, max: MAX_PAGE)
          per_page = whole_number(:per_page, default: DEFAULT_PER_PAGE, max: MAX_PER_PAGE)
          found = people.find(query: query, kind: params[:kind], limit: per_page, offset: (page - 1) * per_page)

          render json: { data: found.entries.map { |entry| People::Lookup.row(entry) },
                         meta: { page: page, per_page: per_page, total: found.total } }
        end
      end

      # GET /api/v1/organisations/:organisation_id/people/:id, the id as the list hands it out
      # ("person:<uuid>" or "member:<uuid>").
      def show
        with_directory do |people|
          entry = people.entry(params[:id]) || raise(ActiveRecord::RecordNotFound)

          render json: { data: People::Lookup.card(entry, notes: true) }
        end
      end

      private

      # The reach (E1), then the organisation's tenant, then the people right, the order the
      # MCP twins keep (PeopleTool.with_token_lookup). PersonPolicy#index? reads the tenant.
      def with_directory
        people = People::Lookup.for_token(reach: current_token.reach, viewer: current_user,
                                          organisation_id: params[:organisation_id])
        raise ActiveRecord::RecordNotFound if people.nil?

        ActsAsTenant.with_tenant(people.organisation) do
          authorize Person, :index?
          yield people
        end
      end

      def query
        value = params[:q]
        return nil if value.nil?
        raise InvalidParameter, 'invalid q (expected text)' unless value.is_a?(String)

        value.strip
      end

      # A whole number from 1 to max, absent or blank the default, read the strict way
      # (ListPaging.strict_number: the rule and the wording of every list that refuses a page
      # value, in the token owner's language).
      def whole_number(name, default:, max:)
        ListPaging.strict_number(params[name], name: name, default: default, max: max)
      rescue ListPaging::InvalidArgument => e
        raise InvalidParameter, e.message
      end
    end
  end
end
