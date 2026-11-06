# frozen_string_literal: true

# The knowledge of a project (notes and documents) by title, one rule for two surfaces
# (cli_rest_plan D5): the MCP tool search_knowledge and GET /api/v1/projects/:project_id/knowledge
# read the same rows through this object. Each surface keeps its own envelope: the tool adds
# citations and requires a search term, REST also lists without one.
#
# Security (project mode, D7): every row comes through Pundit.policy_scope!, per type, in the
# project context. A reader without read access to a type gets no row of that type and no count
# of it, never a foreign title. The per-type search arm (incl. the document -> current_version
# title join) is Knowledge::TypeRegistry's, the link Documentation::KnowledgeLink's.
#
# Title only, not content: a lookup is for finding an object to link, and searching bodies
# would surface content the link never reveals. We do NOT reuse KnowledgeSearchQuery: it gates
# by whole-type accessible keys rather than per-record policy_scope, and its UNION/pagy/
# smart-folder machinery is far heavier than a title lookup needs.
#
# Entry point: options
module Knowledge
  class Lookup
    # Cap shared with the ticket list and the HTTP API, so both agent-facing surfaces bound a
    # page the same way.
    MAX_PER_PAGE = Tickets::Filter::MAX_PER_PAGE
    DEFAULT_PER_PAGE = 10
    # Bounds LIMIT page * per_page of each arm (the reasoning of Tickets::Reading::MAX_PAGE).
    MAX_PAGE = 100_000
    SEARCH_MODE = 'title_only'

    Options = Struct.new(:query, :type, :page, :per_page, keyword_init: true)
    class InvalidOption < ArgumentError; end

    # One page of hits: the records (documents with their current version loaded), the page
    # asked for and the count of every readable hit.
    Result = Struct.new(:records, :page, :per_page, :total, keyword_init: true) do
      def to_h
        { data: records.map { |record| Lookup.serialize(record) },
          meta: { page: page, per_page: per_page, total: total } }
      end
    end

    # Reads the options of a lookup. An unknown type is refused on both surfaces. Page and
    # per_page differ by surface: MCP has always read garbage as the default and clamped a
    # large per_page (`strict: false`); REST refuses what it cannot read (`strict: true`,
    # ListPaging.strict_number), where an absent or empty value still means the default.
    #
    # @param args [Hash] symbol keys q, type, page, per_page
    # @raise [InvalidOption] with a message naming the argument
    def self.options(args, strict: false)
      Options.new(
        query: text_arg(args[:q], 'q', strict),
        type: type_arg(args[:type], strict),
        page: strict ? strict_number(args[:page], 'page', 1, MAX_PAGE) : [args[:page].to_i, 1].max,
        per_page: strict ? strict_number(args[:per_page], 'per_page', DEFAULT_PER_PAGE, MAX_PER_PAGE) : clamp_per_page(args[:per_page])
      )
    end

    # Note#title is a column; Document#title delegates to its current_version: both respond to
    # #title, so serialization needs no per-type branch. The link is the shared contract
    # (KnowledgeLink), so it round-trips through the resolver.
    def self.serialize(record)
      {
        type: Documentation::KnowledgeLink.key_for(record),
        id: record.id,
        title: record.title,
        updated_at: record.updated_at&.iso8601,
        link: Documentation::KnowledgeLink.build(record)
      }
    end

    def initialize(user:, project:)
      @user = user
      @project = project
    end

    # @param options [Options] blank query = every readable row
    # @return [Result]
    def page(options)
      total = total(options)
      Result.new(records: page_records(options, total), page: options.page, per_page: options.per_page,
                 total: total)
    end

    # A NUL is refused before strip, which would drop one at the edges: inside the text it
    # reaches the database adapter, which raises (a 500 instead of a 422).
    def self.text_arg(value, name, strict)
      if strict && !value.nil?
        raise InvalidOption, "#{name} must be text" unless value.is_a?(String)
        raise InvalidOption, "#{name} must not contain NUL" if value.include?("\0")
      end

      value.to_s.strip
    end
    private_class_method :text_arg

    # Validated against the LINK contract's types: what can actually be output as a
    # lalabase:// link.
    def self.type_arg(value, strict)
      type = text_arg(value, 'type', strict)
      return type if type.empty? || Documentation::KnowledgeLink.type_keys.include?(type)

      raise InvalidOption, 'invalid type (expected "note" or "document")'
    end
    private_class_method :type_arg

    # The rule and the wording of every list that refuses a page value, refused as InvalidOption.
    def self.strict_number(value, name, default, max)
      ListPaging.strict_number(value, name: name, default: default, max: max)
    rescue ListPaging::InvalidArgument => e
      raise InvalidOption, e.message
    end
    private_class_method :strict_number

    def self.clamp_per_page(raw)
      value = raw.to_i
      return DEFAULT_PER_PAGE if value <= 0

      [value, MAX_PER_PAGE].min
    end
    private_class_method :clamp_per_page

    private

    def type_keys(options)
      options.type.present? ? [options.type] : Documentation::KnowledgeLink.type_keys
    end

    # One policy-scoped relation per knowledge type, title-filtered when there is a query.
    def arm(key, query)
      entry = Knowledge::TypeRegistry.fetch(key)
      scope = Pundit.policy_scope!(@user, entry[:base_scope].call(@project))
      return scope if query.empty?

      entry[:search_scope].call(scope, "%#{ActiveRecord::Base.sanitize_sql_like(query)}%", SEARCH_MODE)
    end

    # Merge-paginate the arms newest-first. Each arm is fetched with LIMIT = page * per_page,
    # all a correct offset merge can ever need, since the k-th global row sits at position <= k
    # inside one arm. The merged list is then sliced to the requested page.
    #
    # Ordering is `updated_at DESC, id ASC`, qualified through the arm's own arel_table: the
    # document arm joins document_versions, which ALSO has updated_at, and the id tiebreak
    # MATCHES the Ruby merge below, so rows with an identical updated_at are cut by the LIMIT
    # in the order the merge expects; without it a tie across a page boundary could drop or
    # repeat a row.
    #
    # A page beyond the total reads no rows: each arm's LIMIT grows with the page, and a large
    # page would otherwise load the whole readable knowledge of the project to slice off nothing.
    def page_records(options, total)
      offset = (options.page - 1) * options.per_page
      return [] if offset >= total

      limit = options.page * options.per_page
      records = type_keys(options).flat_map do |key|
        scope = arm(key, options.query)
        table = scope.arel_table
        scope.reorder(table[:updated_at].desc, table[:id].asc).limit(limit).to_a
      end
      page_records = records.sort_by { |record| [-record.updated_at.to_f, record.id] }
                            .slice(offset, options.per_page) || []
      preload_titles(page_records)
      page_records
    end

    def total(options)
      type_keys(options).sum { |key| arm(key, options.query).count }
    end

    # A Document's title lives on its current_version; serialize would otherwise load it once
    # per row (N+1). Preloaded for the final page only. Notes carry a title column.
    def preload_titles(records)
      documents = records.grep(Document)
      return if documents.empty?

      ActiveRecord::Associations::Preloader.new(records: documents, associations: :current_version).call
    end
  end
end
