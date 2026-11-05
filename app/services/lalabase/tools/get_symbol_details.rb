# frozen_string_literal: true

module Lalabase
  module Tools
    # Fetches details for code symbols matching a fully-qualified name
    # (e.g. "Chatpost#destroy" or "Lalabase::Tools::Base.execute"). Returns
    # signature, file path, line range and language — but NOT the body.
    #
    # Multi-repo projects can have several symbols sharing a qualified_name
    # (e.g. the same class defined in two cloned repositories); all matches
    # are returned with one citation each so the LLM can disambiguate.
    class GetSymbolDetails < Base
      MAX_SIG_LEN = 500

      # Its reach is a rights question (Base.resolve_code_project) -- see
      # GetProjectVision for the whole reason.
      def self.requires_actor?
        true
      end

      def self.tool_name
        'get_symbol_details'
      end

      def self.description
        'Fetches details for code symbols matching a fully-qualified name ' \
          '(e.g. "Chatpost#destroy"). Returns signature, file path, line ' \
          'range and language — but NOT the body. Use after symbol search ' \
          'or when a symbol is referenced in the conversation and you need ' \
          'its exact location. Symbols belong to ONE project. In an org-wide ' \
          'assistant thread, name the project when several have connected code; ' \
          'the answer says which project it is about in its first line.'
      end

      def self.input_schema
        {
          type: 'object',
          properties: {
            qualified_name: { type: 'string', description: 'Fully-qualified symbol name' }
          }.merge(PROJECT_FILTER_SCHEMA),
          required: ['qualified_name']
        }
      end

      def self.execute(args:, context:)
        args = symbolized(args)
        qname = args[:qualified_name].to_s.strip
        return Result.invalid_input('qualified_name is required') if qname.empty?

        project = resolve_code_project(args, context)
        return project if project.is_a?(Result)

        coverage = code_coverage(args, context, project)
        # Pinning + project-wide fallback is shared with SearchCodeSymbols via
        # Base.repo_ids_for. Distinguish "project not indexed" from "search did
        # not match" — both would otherwise collapse to "No symbol found".
        repo_ids = repo_ids_for(context, project: project)
        if repo_ids.empty?
          return Result.new(content: with_code_project(context, project, 'This project has no indexed code repositories yet.'),
                            citations: [], kind: :empty, coverage: coverage)
        end

        symbols = CodeSymbol.where(organisation_id: context.organisation.id,
                                   project_repository_id: repo_ids,
                                   qualified_name: qname).to_a

        if symbols.empty?
          return Result.new(content: with_code_project(context, project, "No symbol found for #{qname}."),
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
      end

      def self.format_symbols(symbols)
        symbols.map do |s|
          # Name and path come from the repository as well (language and type are
          # validated against fixed lists): the result is fence_guarded, so nothing
          # after this point rewrites a fence in them.
          sig = Lalabase::FenceGuard.sanitize(s.signature.to_s[0, MAX_SIG_LEN])
          name = Lalabase::FenceGuard.sanitize(s.qualified_name)
          path = Lalabase::FenceGuard.sanitize(s.file_path)
          "## #{name}\n" \
            "_#{path}:#{s.start_line}-#{s.end_line} • #{s.language} • #{s.symbol_type}_\n\n" \
            "```\n#{sig}\n```"
        end.join("\n\n")
      end
      private_class_method :format_symbols
    end
  end
end
