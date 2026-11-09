# frozen_string_literal: true

module Lalabase
  module Tools
    # Fetches a single document as JSON: its head, its CURRENT version and the
    # text extracted from that version's file
    # (doc/assistent_wissen_kontext_plan.md, step 2). Record-mode: the tool MUST
    # authorize the individual document via Base.authorize!(:show?).
    #
    # The reference names the DOCUMENT, and what gets read is its current version
    # -- always, whatever version a preview on the page happens to show. The
    # payload names the version it read (id, label, date) so the answer can say
    # which one it was.
    #
    # Nothing is extracted here. The text is what the processing job already
    # wrote into the version (plain_text_version); `text_status` says whether that
    # text exists, is missing, or was never extractable, in the same four words a
    # ticket's attachments use (ExtractPlainTextProcessingService.text_status).
    # ⚠️ Missing text is reported as missing, never explained: the stored columns
    # do not tell "not processed yet" from "processing failed", and an image-only
    # PDF stays without text however often it is processed.
    #
    # Caps: the text is cut at MAX_TEXT_CHARS with a marker, and the payload says
    # so (text_truncated, text_length).
    class GetDocument < Base
      MAX_TEXT_CHARS = 8_000

      # The description is free text as well, and an uncapped field is a way past
      # the text limit (review of #799): the Runner's budget refuses a result
      # only after letting it through. A description is a sentence or two; the
      # cap is generous for that and hopeless for a pasted document.
      MAX_DESCRIPTION_CHARS = 1_000

      # A document without a current version: the fifth word, beside the four the
      # extractor owns, because there is no file to have a status about.
      NO_VERSION = 'no_version'

      def self.authorization_mode
        :record
      end

      def self.requires_actor?
        true
      end

      def self.tool_name
        'get_document'
      end

      def self.description
        'Fetches a single document as JSON by document_id (its UUID): title, ' \
          'description, project, dates, the number of versions, and the text ' \
          'extracted from the CURRENT version\'s file, whatever version the person ' \
          'may be looking at; `version` names the one read (id, label, date, file). ' \
          'Use it when a question is about the content of a document the ' \
          'conversation refers to; the system prompt names the ids of referenced ' \
          'documents. text_status says whether the file has readable text ' \
          '("available"), was read and holds none, such as a scanned PDF ("empty"), ' \
          'has not been read out yet or the reading failed, so the same file may ' \
          'answer later ("unavailable"), is a type we never read text from ' \
          '("unsupported"), or the document has no version at all ("no_version"). ' \
          'Long texts are cut: text_truncated says so and text_length is the full ' \
          'length, and a cut text does not support a complete analysis, so say so. ' \
          'Authorized per record against the asking user; a document outside their ' \
          'reach is "not found".'
      end

      def self.input_schema
        {
          type: 'object',
          properties: {
            document_id: { type: 'string', description: 'UUID of the document to fetch.' }
          },
          required: ['document_id']
        }
      end

      def self.execute(args:, context:)
        return Result.new(error: 'project context missing') if context.project.nil? && context.scope.nil?

        args = symbolized(args)
        document_id = args[:document_id].to_s.strip
        return Result.new(error: 'invalid document_id format') unless document_id.match?(UUID_FORMAT)

        document = base_scope(context).find_by(id: document_id)
        # What the thread points at may be read even when the chip searches
        # elsewhere (Base.referenced_record); the read sets `outside`, nothing else.
        outside = document.nil? && (document = referenced_record(context, type: 'Document', id: document_id))
        return no_match("No document found for #{document_id}.", context) if document.nil?

        result = serve(document, context)
        result.coverage = outside ? outside_coverage(context, area: :documents) : coverage_for(context, area: :documents)
        result
      end

      # Org-wide the reach is the Scope's DOCUMENTS projects; explicitly
      # organisation-bound (Context contract). The current version travels with
      # its file's blob: the status reads the content type and the payload names
      # the file, and each would otherwise be a query of its own.
      def self.base_scope(context)
        base = if context.project
                 context.project.documents
               else
                 Document.where(organisation_id: context.organisation.id,
                                project_id: context.scope.project_ids(area: :documents))
               end
        base.includes({ project: :organisation }, current_version: { document_version_file_attachment: :blob })
      end
      private_class_method :base_scope

      def self.serve(document, context)
        authorize!(context, document, :show?)

        # ONE instance for text, metadata and citation: the version is resolved
        # here once, so the three cannot name different versions.
        version = document.current_version
        citation = if version
                     Lalabase::Citations.document(version)
                   else
                     Lalabase::Citations.document_record(document)
                   end
        json_result(payload(document, version), citations: [citation])
      end
      private_class_method :serve

      def self.payload(document, version)
        text = version&.plain_text_version
        description = version&.description
        {
          id: document.id,
          title: version&.title,
          description: cap_text(description, MAX_DESCRIPTION_CHARS),
          description_truncated: description.to_s.length > MAX_DESCRIPTION_CHARS,
          project: { id: document.project_id, name: document.project.name },
          created_at: document.created_at.iso8601,
          updated_at: document.updated_at.iso8601,
          versions_total: document.document_versions.count,
          version: version && version_payload(version),
          text_status: text_status(version),
          text_length: text.to_s.length,
          text_truncated: text.to_s.length > MAX_TEXT_CHARS,
          text: cap_text(text.presence, MAX_TEXT_CHARS)
        }
      end
      private_class_method :payload

      def self.version_payload(version)
        blob = version.document_version_file.blob
        {
          id: version.id,
          label: version.label,
          number: version.number,
          created_at: version.created_at.iso8601,
          file_name: blob&.filename.to_s,
          content_type: blob&.content_type,
          byte_size: blob&.byte_size
        }
      end
      private_class_method :version_payload

      # The version's own answer (DocumentVersion#text_status, the one rule for
      # every reader of a version's text), plus the fifth word for a document
      # without a version.
      def self.text_status(version)
        return NO_VERSION if version.nil?

        version.text_status
      end
      private_class_method :text_status

      def self.no_match(message, context)
        Result.new(content: message, citations: [], kind: :empty, coverage: coverage_for(context, area: :documents))
      end
      private_class_method :no_match
    end
  end
end
