# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ExtractPlainTextProcessingService do
  let(:document_holder) do
    Struct.new(:plain_text_version, :plain_text_word_count, :attachment, keyword_init: true) do
      def save!
        # noop in tests
      end

      def test_file
        attachment
      end
    end.new(plain_text_version: nil, plain_text_word_count: nil)
  end

  # double instead of instance_double: ActiveStorage delegates content_type via
  # method_missing to the blob, which RSpec's verification does not recognize.
  let(:attachment) do
    double('ActiveStorage::Attached::One',
           content_type: content_type,
           present?: true)
  end

  before do
    document_holder.attachment = attachment
  end

  subject do
    described_class.new(
      document_holder,
      document_accessor: :test_file,
      log_label: 'TestLabel'
    )
  end

  # ---------------------------------------------------------------------------
  # Happy Path: PDF
  # ---------------------------------------------------------------------------
  describe 'PDF-Extraktion' do
    let(:content_type) { 'application/pdf' }

    it 'extrahiert Text aus PDF-Seiten mit Newline-Separator' do
      page1 = instance_double('PDF::Reader::Page', text: 'Seite eins')
      page2 = instance_double('PDF::Reader::Page', text: 'Seite zwei')
      reader = instance_double('PDF::Reader', pages: [page1, page2])

      allow(attachment).to receive(:open).and_yield(StringIO.new('fake-pdf'))
      allow(PDF::Reader).to receive(:new).and_return(reader)

      expect(subject.process).to be true

      expect(document_holder.plain_text_version).to eq("Seite eins\nSeite zwei")
      expect(document_holder.plain_text_word_count).to eq(4)
    end

    it 'speichert nach erfolgreicher Extraktion' do
      page = instance_double('PDF::Reader::Page', text: 'Inhalt')
      reader = instance_double('PDF::Reader', pages: [page])

      allow(attachment).to receive(:open).and_yield(StringIO.new('fake-pdf'))
      allow(PDF::Reader).to receive(:new).and_return(reader)

      expect(document_holder).to receive(:save!)
      subject.process
    end

    it 'setzt plain_text auf nil und gibt false zurück bei PDF-Lesefehler' do
      allow(attachment).to receive(:open).and_yield(StringIO.new('broken'))
      allow(PDF::Reader).to receive(:new).and_raise(PDF::Reader::MalformedPDFError, 'corrupt')

      expect(subject.process).to be false

      expect(document_holder.plain_text_version).to be_nil
      expect(document_holder.plain_text_word_count).to be_nil
    end

    it 'loggt den PDF-Fehler mit log_label' do
      allow(attachment).to receive(:open).and_yield(StringIO.new('broken'))
      allow(PDF::Reader).to receive(:new).and_raise(StandardError, 'kaputt')

      expect(Rails.logger).to receive(:error).with('[TestLabel] Error reading the PDF file: kaputt')

      subject.process
    end
  end

  # ---------------------------------------------------------------------------
  # Happy Path: Plain Text
  # ---------------------------------------------------------------------------
  describe 'Text-Extraktion' do
    let(:content_type) { 'text/plain' }
    let(:text_content) { 'Hallo Welt, das ist ein Test.' }

    before do
      allow(attachment).to receive(:download).and_return(text_content.dup.force_encoding('ASCII-8BIT'))
    end

    it 'extrahiert den Text und zählt Wörter' do
      subject.process

      expect(document_holder.plain_text_version).to eq(text_content)
      expect(document_holder.plain_text_word_count).to eq(6)
    end

    it 'speichert den document_holder nach Extraktion' do
      expect(document_holder).to receive(:save!)
      subject.process
    end

    it 'fängt Fehler ab und loggt sie als Text-Fehler' do
      allow(attachment).to receive(:download).and_raise(StandardError, 'encoding error')

      expect(Rails.logger).to receive(:error).with('[TestLabel] Error reading the Text file: encoding error')

      subject.process
    end
  end

  # ---------------------------------------------------------------------------
  # Happy Path: DOCX
  # ---------------------------------------------------------------------------
  describe 'DOCX-Extraktion' do
    let(:content_type) { 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' }

    it 'extrahiert Text aus DOCX-Paragraphen mit Newline-Separator' do
      para1 = double('Paragraph', text: 'Absatz eins')
      para2 = double('Paragraph', text: 'Absatz zwei')
      doc = double('Docx::Document', paragraphs: [para1, para2])

      allow(attachment).to receive(:open).and_yield(StringIO.new('fake-docx'))
      allow(Docx::Document).to receive(:new).and_return(doc)

      subject.process

      expect(document_holder.plain_text_version).to eq("Absatz eins\nAbsatz zwei")
      expect(document_holder.plain_text_word_count).to eq(4)
    end

    it 'setzt plain_text auf nil bei DOCX-Lesefehler' do
      allow(attachment).to receive(:open).and_yield(StringIO.new('broken'))
      allow(Docx::Document).to receive(:new).and_raise(StandardError, 'corrupt docx')

      subject.process

      expect(document_holder.plain_text_version).to be_nil
      expect(document_holder.plain_text_word_count).to be_nil
    end

    it 'loggt den DOCX-Fehler mit log_label' do
      allow(attachment).to receive(:open).and_yield(StringIO.new('broken'))
      allow(Docx::Document).to receive(:new).and_raise(StandardError, 'corrupt docx')

      expect(Rails.logger).to receive(:error).with('[TestLabel] Error reading the DOCX file: corrupt docx')

      subject.process
    end
  end

  # ---------------------------------------------------------------------------
  # Happy Path: RTF
  # ---------------------------------------------------------------------------
  describe 'RTF-Extraktion' do
    let(:content_type) { 'application/rtf' }

    it 'extrahiert Text aus RTF' do
      rtf_doc = double('RTF::Document', to_text: 'RTF Inhalt hier')

      allow(attachment).to receive(:download).and_return('fake-rtf-data')
      allow(RTF::Document).to receive(:new).and_return(rtf_doc)

      subject.process

      expect(document_holder.plain_text_version).to eq('RTF Inhalt hier')
      expect(document_holder.plain_text_word_count).to eq(3)
    end

    it 'setzt plain_text auf nil bei RTF-Lesefehler' do
      allow(attachment).to receive(:download).and_return('broken')
      allow(RTF::Document).to receive(:new).and_raise(StandardError, 'invalid rtf')

      subject.process

      expect(document_holder.plain_text_version).to be_nil
      expect(document_holder.plain_text_word_count).to be_nil
    end

    it 'loggt den RTF-Fehler mit log_label' do
      allow(attachment).to receive(:download).and_return('broken')
      allow(RTF::Document).to receive(:new).and_raise(StandardError, 'invalid rtf format')

      expect(Rails.logger).to receive(:error).with('[TestLabel] Error reading the RTF file: invalid rtf format')

      subject.process
    end
  end

  # ---------------------------------------------------------------------------
  # RTF with text/rtf MIME type (previously not supported)
  # ---------------------------------------------------------------------------
  describe 'RTF mit text/rtf MIME-Type' do
    let(:content_type) { 'text/rtf' }

    it 'wird jetzt korrekt als RTF erkannt' do
      rtf_doc = double('RTF::Document', to_text: 'Text RTF Inhalt')

      allow(attachment).to receive(:download).and_return('fake-rtf-data')
      allow(RTF::Document).to receive(:new).and_return(rtf_doc)

      subject.process

      expect(document_holder.plain_text_version).to eq('Text RTF Inhalt')
      expect(document_holder.plain_text_word_count).to eq(3)
    end
  end

  # ---------------------------------------------------------------------------
  # Edge case: Unknown content type
  # ---------------------------------------------------------------------------
  describe 'unbekannter Content-Type' do
    let(:content_type) { 'application/octet-stream' }

    it 'setzt plain_text_version und word_count auf nil und gibt false zurück' do
      expect(subject.process).to be false

      expect(document_holder.plain_text_version).to be_nil
      expect(document_holder.plain_text_word_count).to be_nil
    end

    it 'persistiert die Löschung via save!' do
      expect(document_holder).to receive(:save!)
      subject.process
    end
  end

  # ---------------------------------------------------------------------------
  # Edge case: Attachment not present
  # ---------------------------------------------------------------------------
  describe 'wenn kein Attachment vorhanden' do
    let(:content_type) { 'text/plain' }

    before do
      allow(attachment).to receive(:present?).and_return(false)
    end

    it 'gibt false zurück ohne Verarbeitung' do
      expect(document_holder).not_to receive(:save!)

      expect(subject.process).to be false

      expect(document_holder.plain_text_version).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # Edge case: Empty text after extraction
  # ---------------------------------------------------------------------------
  describe 'wenn extrahierter Text leer ist' do
    let(:content_type) { 'text/plain' }

    before do
      allow(attachment).to receive(:download).and_return(''.dup.force_encoding('ASCII-8BIT'))
    end

    it 'setzt plain_text_version auf leeren String und gibt false zurück' do
      expect(subject.process).to be false
      expect(document_holder.plain_text_version).to eq('')
    end

    it 'setzt word_count auf 0' do
      subject.process
      expect(document_holder.plain_text_word_count).to eq(0)
    end
  end

  # ---------------------------------------------------------------------------
  # Edge case: Only whitespace after extraction
  # ---------------------------------------------------------------------------
  describe 'wenn extrahierter Text nur Whitespace enthält' do
    let(:content_type) { 'text/plain' }

    before do
      allow(attachment).to receive(:download).and_return("   \n\t  ".dup.force_encoding('ASCII-8BIT'))
    end

    it 'setzt word_count auf 0' do
      subject.process
      expect(document_holder.plain_text_word_count).to eq(0)
    end
  end

  # ---------------------------------------------------------------------------
  # Edge case: save! raises an error
  # ---------------------------------------------------------------------------
  describe 'wenn save! fehlschlägt' do
    let(:content_type) { 'text/plain' }

    before do
      allow(attachment).to receive(:download).and_return('Inhalt')
      allow(document_holder).to receive(:save!).and_raise(StandardError, 'Validation failed')
    end

    it 'propagiert den Fehler zum Caller' do
      expect { subject.process }.to raise_error(StandardError, 'Validation failed')
    end
  end

  # ---------------------------------------------------------------------------
  # Word count
  # ---------------------------------------------------------------------------
  describe 'Wortzählung' do
    let(:content_type) { 'text/plain' }

    {
      'einfacher Text' => ['eins zwei drei', 3],
      'mehrfache Leerzeichen' => ['eins   zwei    drei', 3],
      'Tabs und Newlines' => ["eins\tzwei\ndrei", 3],
      'ein einzelnes Wort' => ['Wort', 1],
      'leerer String' => ['', 0],
      'nur Whitespace' => ["  \n\t  ", 0]
    }.each do |beschreibung, (text, expected_count)|
      it "zählt korrekt bei: #{beschreibung}" do
        allow(attachment).to receive(:download).and_return(text.dup.force_encoding('ASCII-8BIT'))
        subject.process
        expect(document_holder.plain_text_word_count).to eq(expected_count)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # log_label is now used correctly
  # ---------------------------------------------------------------------------
  describe 'log_label wird in allen Fehlermeldungen verwendet' do
    let(:content_type) { 'application/pdf' }

    it 'enthält den log_label in Extraktionsfehlern' do
      allow(attachment).to receive(:open).and_yield(StringIO.new('broken'))
      allow(PDF::Reader).to receive(:new).and_raise(StandardError, 'error')

      expect(Rails.logger).to receive(:error) do |msg|
        expect(msg).to include('TestLabel')
      end

      subject.process
    end
  end

  # ---------------------------------------------------------------------------
  # Stale data: clear_plain_text_data is now persisted
  # ---------------------------------------------------------------------------
  describe 'Stale-Data-Fix: unsupporteter Typ persistiert Löschung' do
    let(:content_type) { 'image/png' }

    it 'löscht vorhandene Daten und persistiert via save!' do
      document_holder.plain_text_version = 'Alter PDF-Text'
      document_holder.plain_text_word_count = 2

      expect(document_holder).to receive(:save!)

      subject.process

      expect(document_holder.plain_text_version).to be_nil
      expect(document_holder.plain_text_word_count).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # nil content type
  # ---------------------------------------------------------------------------
  describe 'nil Content-Type' do
    let(:content_type) { nil }

    it 'fällt in den else-Branch und löscht plain_text_data' do
      subject.process

      expect(document_holder.plain_text_version).to be_nil
      expect(document_holder.plain_text_word_count).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # SUPPORTED_CONTENT_TYPES constant
  # ---------------------------------------------------------------------------
  describe 'SUPPORTED_CONTENT_TYPES', :no_attachment do
    let(:content_type) { nil }

    it 'holds all 6 supported MIME types' do
      expect(described_class::SUPPORTED_CONTENT_TYPES.keys).to contain_exactly(
        'application/pdf',
        'text/plain',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'application/rtf',
        'text/rtf',
        'text/markdown'
      )
    end

    it 'ist frozen' do
      expect(described_class::SUPPORTED_CONTENT_TYPES).to be_frozen
    end
  end

  # ---------------------------------------------------------------------------
  # Markdown (K5c): a .md file is text, read the way a .txt file is read
  # ---------------------------------------------------------------------------
  describe 'Markdown' do
    let(:content_type) { 'text/markdown' }
    let(:text_content) { "# Zorbel-Hub\n\nWir nutzen **Quarnix** im Team." }

    before do
      allow(attachment).to receive(:download).and_return(text_content.dup.force_encoding('ASCII-8BIT'))
    end

    it 'reads the text as it stands, markup included, and counts its words' do
      expect(subject.process).to be true

      expect(document_holder.plain_text_version).to eq(text_content)
      expect(document_holder.plain_text_version.encoding).to eq(Encoding::UTF_8)
      expect(document_holder.plain_text_word_count).to eq(7)
    end

    it 'reads it with the reader of a .txt file, and logs a failure as such' do
      allow(attachment).to receive(:download).and_raise(StandardError, 'kaputt')

      expect(Rails.logger).to receive(:error).with('[TestLabel] Error reading the Text file: kaputt')

      expect(subject.process).to be false
      expect(document_holder.plain_text_version).to be_nil
    end

    it 'keeps an empty file empty, not unread' do
      allow(attachment).to receive(:download).and_return(''.dup.force_encoding('ASCII-8BIT'))

      expect(subject.process).to be false
      expect(document_holder.plain_text_version).to eq('')
    end
  end

  # ---------------------------------------------------------------------------
  # The four words of the text status, for Markdown as for every other type
  # ---------------------------------------------------------------------------
  describe '.text_status', :no_attachment do
    let(:content_type) { nil }

    it 'answers for Markdown as for plain text' do
      %w[text/plain text/markdown].each do |type|
        expect(described_class.text_extractable?(type)).to be(true), type
        expect(described_class.text_status('Quarnix', type)).to eq('available')
        expect(described_class.text_status(nil, type)).to eq('unavailable')
        expect(described_class.text_status('', type)).to eq('empty')
      end
    end

    it 'calls a type without a reader unsupported' do
      expect(described_class.text_extractable?('image/png')).to be(false)
      expect(described_class.text_status(nil, 'image/png')).to eq('unsupported')
      expect(described_class.text_status('', 'image/png')).to eq('unsupported')
    end
  end

  # ---------------------------------------------------------------------------
  # .file_text_status: the status of a holder of one attached file
  # ---------------------------------------------------------------------------
  describe '.file_text_status', :no_attachment do
    let(:content_type) { nil }

    def file_of(type)
      double('ActiveStorage::Attached::One', blob: double('ActiveStorage::Blob', content_type: type))
    end

    it 'asks text_status with the type of the attached file' do
      expect(described_class.file_text_status('Quarnix', file_of('text/markdown'))).to eq('available')
      expect(described_class.file_text_status(nil, file_of('text/markdown'))).to eq('unavailable')
      expect(described_class.file_text_status('', file_of('application/pdf'))).to eq('empty')
      expect(described_class.file_text_status(nil, file_of('image/png'))).to eq('unsupported')
    end

    it 'calls a holder without a file unavailable: nothing was read out of it yet' do
      expect(described_class.file_text_status(nil, double('ActiveStorage::Attached::One', blob: nil))).to eq('unavailable')
      expect(described_class.file_text_status('Quarnix', nil)).to eq('unavailable')
    end
  end
end
