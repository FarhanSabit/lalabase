# frozen_string_literal: true

class ExtractPlainTextProcessingService
  # Markdown (K5c) is text as it stands, markup included: read like a .txt file.
  SUPPORTED_CONTENT_TYPES = {
    'application/pdf' => :extract_text_from_pdf,
    'text/plain' => :extract_text_from_text_file,
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document' => :extract_text_from_docx,
    'application/rtf' => :extract_text_from_rtf,
    'text/rtf' => :extract_text_from_rtf,
    'text/markdown' => :extract_text_from_text_file
  }.freeze

  # Whether this content type has an extractor at all. Asked by readers of the
  # RESULT (Tickets::Serializer) to tell "this file never had readable text in it"
  # apart from "we failed to read a file we can read" — two states that look
  # identical in an empty plain_text_version, and mean opposite things to whoever
  # gets the answer. Kept here so the allowlist above stays the only one.
  def self.text_extractable?(content_type)
    SUPPORTED_CONTENT_TYPES.key?(content_type.to_s)
  end

  # What a reader may say about a file's extracted text: four answers, because
  # they mean four different things to whoever reads them, and collapsed into a
  # bare nil they are one silence that a model fills with a guess.
  #
  #   available   -- text is there
  #   unsupported -- a type we never read text from (no extractor above)
  #   unavailable -- not read out yet, or the reading failed; may answer later
  #   empty       -- read, and the file held no text (a scanned PDF)
  #
  # ⚠️ Takes the RAW column, not .presence: NULL and '' are the distinction this
  # method exists for, and .presence is exactly what destroys it. #set_plain_text
  # writes '' when the extractor ran and found nothing; #clear_plain_text_data
  # writes NULL when it never ran or blew up. And it usually has not run yet: the
  # processing jobs are enqueued perform_later after the commit, so NULL is above
  # all the state of a file uploaded a second ago. "Ask me again in a moment" and
  # "this file has nothing in it" are opposite answers.
  #
  # Owned here next to the allowlist it reads, because two readers ask it
  # (Tickets::Serializer for a ticket's attachments, Tools::GetDocument for a
  # document's version) and the vocabulary has to be one.
  def self.text_status(raw, content_type)
    return 'available' if raw.present?
    return 'unsupported' unless text_extractable?(content_type)

    raw.nil? ? 'unavailable' : 'empty'
  end

  # text_status of a holder of one attached file (a document version): its
  # column and the type of its file. A holder without a file has nothing read
  # out yet, unavailable, the answer Lalabase::Tools::GetDocument gives for
  # it. Asked by the start of a glossary run over one document and its button
  # (K5c), so both say the same about the same version.
  def self.file_text_status(raw, file)
    blob = file&.blob
    return 'unavailable' if blob.nil?

    text_status(raw, blob.content_type)
  end

  def initialize(document_holder, document_accessor:, log_label:)
    @document_holder = document_holder
    @document = document_holder.send(document_accessor)
    @log_label = log_label
  end

  def process
    return false unless @document.present?

    extract_plain_text
    @document_holder.save!
    @document_holder.plain_text_version.present?
  end

  private

  def extract_plain_text
    extractor = SUPPORTED_CONTENT_TYPES[@document.content_type]

    if extractor
      send(extractor)
    else
      clear_plain_text_data
    end
  end

  def clear_plain_text_data
    @document_holder.plain_text_version = nil
    @document_holder.plain_text_word_count = nil
  end

  def extract_text_from_pdf
    require 'pdf-reader'

    text = @document.open do |file|
      PDF::Reader.new(file).pages.map(&:text).join("\n")
    end
    set_plain_text(text)
  rescue StandardError => e
    handle_text_extraction_error(e, 'PDF')
  end

  def extract_text_from_text_file
    text = @document.download.force_encoding('UTF-8')
    set_plain_text(text)
  rescue StandardError => e
    handle_text_extraction_error(e, 'Text')
  end

  def extract_text_from_docx
    text = @document.open do |file|
      Docx::Document.new(file).paragraphs.map(&:text).join("\n")
    end
    set_plain_text(text)
  rescue StandardError => e
    handle_text_extraction_error(e, 'DOCX')
  end

  def extract_text_from_rtf
    rtf = RTF::Document.new(@document.download)
    text = rtf.to_text
    set_plain_text(text)
  rescue StandardError => e
    handle_text_extraction_error(e, 'RTF')
  end

  def set_plain_text(text)
    @document_holder.plain_text_version = text
    @document_holder.plain_text_word_count = count_words(text)
  end

  def handle_text_extraction_error(error, file_type)
    Rails.logger.error "[#{@log_label}] Error reading the #{file_type} file: #{error.message}"
    clear_plain_text_data
  end

  def count_words(text)
    text.split(/\s+/).reject(&:blank?).size
  end
end
