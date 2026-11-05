# frozen_string_literal: true

module Lalabase
  module Tools
    # Semantic search across CodeSymbol records of the active chat's project,
    # ranked by cosine distance over signature embeddings.
    #
    # Drill-down companion to the M7 baseline retrieval: the baseline already
    # surfaces top-10 symbols for the user's primary message, while this tool
    # lets the LLM fetch additional or differently-phrased matches mid-answer.
    class SearchCodeSymbols < Base
      DEFAULT_LIMIT = 10
      MAX_LIMIT     = 25
      # Alias of the shared cap (Lalabase::QueryEmbedding) — kept for the boundary spec.
      MAX_QUERY_LEN = Lalabase::QueryEmbedding::MAX_QUERY_LENGTH
      # Per-result signature display cap (mirrors PromptBuilder's
      # MAX_SIGNATURE_IN_PROMPT); a result lists many symbols, so keep it short.
      MAX_SIGNATURE_IN_RESULT = 200

      # Its reach is a rights question (Base.resolve_code_project) -- see
      # GetProjectVision for the whole reason.
      def self.requires_actor?
        true
      end

      def self.tool_name
        'search_code_symbols'
      end

      def self.description
        'Semantic search across code symbols (classes, modules, methods) of the project. ' \
          'Returns top-N matches by cosine similarity over signature embeddings. ' \
          'Use when the baseline project context is too narrow or you need to look up ' \
          'additional code constructs related to the user question. The search runs ' \
          'in ONE project, never across several. In an org-wide assistant thread, ' \
          'name the project when several have connected code; the answer says which ' \
          'project it is about in its first line.'
      end

      def self.input_schema
        {
          type: 'object',
          properties: {
            query: { type: 'string', description: 'Natural-language search query' },
            limit: { type: 'integer', minimum: 1, maximum: MAX_LIMIT,
                     description: "Max results (default #{DEFAULT_LIMIT}, max #{MAX_LIMIT})" }
          }.merge(PROJECT_FILTER_SCHEMA),
          required: ['query']
        }
      end

      def self.execute(args:, context:)
        args = symbolized(args)
        query = args[:query].to_s.strip
        return Result.invalid_input('query is required') if query.empty?

        project = resolve_code_project(args, context)
        return project if project.is_a?(Result)

        coverage = code_coverage(args, context, project)
        # If the project has no indexed repositories yet, surface that
        # explicitly so the LLM doesn't conclude "the search engine is broken".
        repo_ids = repo_ids_for(context, project: project)
        if repo_ids.empty?
          return Result.new(content: with_code_project(context, project, 'This project has no indexed code repositories yet.'),
                            citations: [], kind: :empty, coverage: coverage)
        end

        limit = resolve_limit(args[:limit])
        embedding = embed_query(query, context.organisation)
        symbols = CodeSymbol.semantic_search(organisation: context.organisation, repo_ids: repo_ids,
                                             embedding: embedding, limit: limit).to_a

        if symbols.empty?
          return Result.new(content: with_code_project(context, project, 'No symbols matched.'),
                            citations: [], kind: :empty, coverage: coverage)
        end

        # format_symbols sanitizes the signature (the only foreign text here) and then
        # fences it on purpose. Declaring the result guarded keeps Runner#tool_result_message
        # from rewriting exactly those fences on the way to the model. with_code_project
        # sanitizes the project name for the same reason.
        Result.new(
          content: with_code_project(context, project, format_symbols(symbols)),
          citations: symbols.map { |s| Lalabase::Citations.symbol(s) },
          fence_guarded: true,
          coverage: coverage
        )
      # AiDisabledError and MissingCredentialError must be rescued BEFORE
      # Provider::Error: both inherit from it, so swapping the order would mask
      # them. Every case returns a FIXED message (no e.message): raw internal
      # exception text must not cross the MCP boundary to external clients. A
      # missing credential names credential and space ids or a package, a provider
      # error wraps the HTTP client's message with its endpoint. They go to the log.
      rescue Lalabase::Llm::AiDisabledError
        Result.refused('AI features are disabled for this organisation.', reason: :ai_disabled)
      rescue Lalabase::Llm::Factory::MissingCredentialError => e
        log_embedding_error(e)
        Result.refused('embedding unavailable: no usable embedding credential is configured', reason: :ai_unavailable)
      rescue Lalabase::Llm::Provider::Error => e
        log_embedding_error(e)
        Result.refused('embedding failed: the embedding provider did not answer', reason: :ai_unavailable)
      end

      def self.log_embedding_error(error)
        Rails.logger.warn("[#{name}] #{error.class}: #{error.message}")
      end
      private_class_method :log_embedding_error

      def self.resolve_limit(raw)
        return DEFAULT_LIMIT if raw.blank?

        [[raw.to_i, 1].max, MAX_LIMIT].min
      end
      private_class_method :resolve_limit

      def self.embed_query(query, organisation)
        Lalabase::QueryEmbedding.embed(query, organisation)
      end
      private_class_method :embed_query

      def self.format_symbols(symbols)
        symbols.map do |s|
          # Name and path come from the repository as well: the result is
          # fence_guarded, so nothing after this point rewrites a fence in them.
          sig = Lalabase::FenceGuard.sanitize(s.signature.to_s[0, MAX_SIGNATURE_IN_RESULT])
          name = Lalabase::FenceGuard.sanitize(s.qualified_name)
          path = Lalabase::FenceGuard.sanitize(s.file_path)
          "- #{name} (#{path}:#{s.start_line}-#{s.end_line})\n" \
            "  ```\n  #{sig}\n  ```"
        end.join("\n")
      end
      private_class_method :format_symbols
    end
  end
end
