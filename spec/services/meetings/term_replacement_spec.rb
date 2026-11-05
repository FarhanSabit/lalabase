# frozen_string_literal: true

require 'rails_helper'

# The one rule for counting and replacing a heard form in a meeting text
# (K4b, plan §5.2), without a database: whole words after Unicode (letters
# and digits of every script, not \b), case as marked, several words across
# horizontal whitespace inside a line, never inside the speaker label at the
# start of a line, never in the frontmatter. The count of the dialog and the
# count of the replacement come from the same list. Invented words and names
# only.
RSpec.describe Meetings::TermReplacement do
  # A participant as the class reads it: only the name. No database.
  def participant(name)
    Struct.new(:display_name).new(name)
  end

  let(:anna) { participant('Anna Ananas') }
  let(:ben) { participant('Ben Birne') }

  def replacement(text, heard, participants: [])
    described_class.new(text: text, heard: heard, participants: participants)
  end

  def count(text, heard, participants: [])
    replacement(text, heard, participants: participants).count
  end

  def replaced(text, heard, with:, participants: [])
    replacement(text, heard, participants: participants).replace(with: with).text
  end

  describe 'whole words' do
    it 'finds umlauts and ß at either end of a word' do
      expect(count('Ärger mit der Straße, viel Ärger.', 'Ärger')).to eq(2)
      expect(count('Die Straße ist frei', 'Straße')).to eq(1)
      expect(count('Grüße an alle, Grüße', 'Grüße')).to eq(2)
    end

    it 'finds no word inside a longer one, also where it touches an umlaut or ß' do
      expect(count('Die Maßnahme und das Fußballspiel', 'Maß')).to eq(0)
      expect(count('Ein Fußball im Fußraum', 'Fuß')).to eq(0)
      expect(count('Lalabeisen und XLalabeis und Lalabeisä', 'Lalabeis')).to eq(0)
      expect(count('Hauptstraße', 'Straße')).to eq(0)
    end

    # The hyphen is no letter: a compound with a hyphen is two words for the
    # rule, so a misheard name is fixed inside "Lalabeis-Konto" too.
    it 'takes a hyphen for a boundary, and a hyphen in the form literally' do
      expect(replaced('Das Lalabeis-Konto und -Lalabeis', 'Lalabeis', with: 'Lalabase'))
        .to eq('Das Lalabase-Konto und -Lalabase')
      expect(count('Lala-Beis, Lala Beis, Lala-Beisel', 'Lala-Beis')).to eq(1)
    end

    # Where the rule differs from Ruby's \b: an underscore and a sign at the
    # end of the form are no letters and no digits.
    it 'takes an underscore for a boundary' do
      expect(count('datei_Lalabeis_neu.txt', 'Lalabeis')).to eq(1)
    end

    it 'finds a form that ends in a sign, but not inside a longer word' do
      expect(replaced('Wir nehmen C++ und Cobol, nicht C++x', 'C++', with: 'Java'))
        .to eq('Wir nehmen Java und Cobol, nicht C++x')
      expect(count('Läuft das auf Version 2.0?', '2.0?')).to eq(1)
    end

    # Review round 1 of #121: what shows nothing (GlossaryText::INVISIBLE: a
    # zero-width space, a soft hyphen, a bidi mark) joins what stands around it,
    # as the reader sees it and as the glossary compares it.
    it 'reads characters that show nothing as part of the word around them' do
      expect(count("Das Lalabeis\u200BKonto", 'Lalabeis')).to eq(0)
      expect(count("Lala\u00ADbeis", 'Lala')).to eq(0)
      expect(count("Lalabeis\u200E und \u200BLalabeis", 'Lalabeis')).to eq(2)
    end

    # Review round 2 of #121: the same rule before the form as after it, and
    # up to MAX_INVISIBLE_RUN characters that show nothing on either side.
    it 'reads characters that show nothing before the form as part of the word too, up to the same run on both sides' do
      expect(count("Konto\u200BLalabeis", 'Lalabeis')).to eq(0)
      expect(count("Konto\u200B\u200B\u200BLalabeis und Lalabeis\u200B\u200B\u200BKonto", 'Lalabeis')).to eq(0)
      expect(count("Wir \u200BLalabeis\u200B ok", 'Lalabeis')).to eq(1)
    end

    it 'counts digits of every script as part of a word' do
      expect(count('Raum 12 und Raum 123', 'Raum 12')).to eq(1)
      expect(count("Lalabeis\u0663 und Lalabeis", 'Lalabeis')).to eq(1)
    end
  end

  it 'keeps case as marked' do
    expect(count('Lalabeis, lalabeis, LALABEIS', 'Lalabeis')).to eq(1)
    expect(count('Lalabeis, lalabeis, LALABEIS', 'lalabeis')).to eq(1)
  end

  describe 'a form of several words' do
    it 'matches across horizontal whitespace inside a line' do
      text = "Lala Beis und Lala  Beis\nLala\tBeis und Lala\u00A0Beis"

      expect(count(text, 'Lala Beis')).to eq(4)
    end

    it 'never matches across a line break' do
      expect(count("Wir sagen Lala\nBeis dazu.", 'Lala Beis')).to eq(0)
      expect(count("Wir sagen Lala\r\nBeis dazu.", 'Lala Beis')).to eq(0)
    end

    it 'takes the whitespace inside the form as one gap' do
      expect(count('Lala Beis', "Lala \t Beis")).to eq(1)
    end
  end

  describe 'the speaker label at the start of a line' do
    let(:participants) { [anna, ben] }

    it 'is never counted or replaced' do
      text = "Anna: Anna hat recht.\nBen: Danke, Anna."

      expect(count(text, 'Anna', participants: participants)).to eq(2)
      expect(replaced(text, 'Anna', with: 'Hanna', participants: participants))
        .to eq("Anna: Hanna hat recht.\nBen: Danke, Hanna.")
    end

    it 'is protected in its bolded form and with a diarisation suffix too' do
      text = "**Anna:** Anna hier.\n**Ben**: Ben da.\nAnna (Speaker 2): Anna wieder."

      expect(replaced(text, 'Anna', with: 'Hanna', participants: participants))
        .to eq("**Anna:** Hanna hier.\n**Ben**: Ben da.\nAnna (Speaker 2): Hanna wieder.")
    end

    it 'is a label only for a participant, so a word before a colon in prose counts' do
      text = 'Problem: Problem gelöst.'

      expect(count(text, 'Problem', participants: participants)).to eq(2)
    end

    it 'is listed by the scan, marked as a label, for the mapping of a mark' do
      scan = replacement('Anna: Anna hat recht.', 'Anna', participants: participants).scan

      expect(scan.map { |match| [match.char_offset, match.in_label] }).to eq([[0, true], [6, false]])
    end
  end

  it 'leaves the frontmatter alone, and counts lines from the first line stored' do
    text = "---\nid: Lalabeis\n---\nLalabeis sagt hallo."
    subject = replacement(text, 'Lalabeis')

    expect(subject.occurrences.map { |match| [match.line_index, match.char_offset] }).to eq([[3, 0]])
    expect(subject.replace(with: 'Lalabase').text).to eq("---\nid: Lalabeis\n---\nLalabase sagt hallo.")
  end

  describe 'counting and replacing' do
    it 'finds nothing and changes nothing where the form is not' do
      subject = replacement("Anna: Alles gut.\n", 'Lalabeis', participants: [anna])
      result = subject.replace(with: 'Lalabase')

      expect([subject.count, result.count, result.text]).to eq([0, 0, "Anna: Alles gut.\n"])
    end

    it 'replaces exactly what it counts' do
      texts = [
        "Anna: Lalabeis und Lalabeis.\nLalabeis-Konto, Lalabeisen\nBen: lalabeis Lalabeis",
        "---\nx: Lalabeis\n---\nLalabeis\r\nLalabeis!",
        'Lalabeis_Lalabeis Lalabeis'
      ]

      texts.each do |text|
        subject = replacement(text, 'Lalabeis', participants: [anna, ben])
        result = subject.replace(with: 'Zirbel')

        expect(result.count).to eq(subject.count), text
        expect(result.text.scan('Zirbel').size).to eq(subject.count), text
        expect(replacement(result.text, 'Lalabeis', participants: [anna, ben]).count).to eq(0), text
      end
    end

    it 'replaces only the one occurrence it is given' do
      subject = replacement("Lalabeis eins\nLalabeis zwei, Lalabeis drei", 'Lalabeis')
      second = subject.occurrences[1]
      result = subject.replace(with: 'Lalabase', only: second)

      expect([result.text, result.count]).to eq(["Lalabeis eins\nLalabase zwei, Lalabeis drei", 1])
    end

    it 'refuses an occurrence that is not one of its own' do
      other = replacement('xx Lalabeis', 'Lalabeis').occurrences.first

      expect { replacement('Lalabeis', 'Lalabeis').replace(with: 'Lalabase', only: other) }.to raise_error(ArgumentError)
    end

    it 'keeps line endings and a last line break' do
      expect(replaced("Lalabeis\r\nLalabeis\n", 'Lalabeis', with: 'Lalabase')).to eq("Lalabase\r\nLalabase\n")
    end

    # A transcript can be one line of half a megabyte. Ruby finds the n-th
    # character of a text with umlauts by counting from its start; counting
    # each match from the start of the line again took about nine seconds for
    # this line (review of the first version), counting on takes milliseconds.
    it 'counts and replaces many matches in one long line in one pass' do
      line = (['Grüße an Lalabeis'] * 20_000).join(' und ')
      subject = replacement(line, 'Lalabeis')
      result = nil

      elapsed = Benchmark.realtime { result = subject.replace(with: 'Lalabase') }

      expect(elapsed).to be < 2
      expect(result.count).to eq(20_000)
      expect(subject.occurrences.last.char_offset).to eq(line.rindex('Lalabeis'))
      expect(result.text).to eq(line.gsub('Lalabeis', 'Lalabase'))
    end

    it 'counts in characters, not bytes' do
      occurrence = replacement('Grüße, Lalabeis', 'Lalabeis').occurrences.first

      expect([occurrence.line_index, occurrence.char_offset, occurrence.length]).to eq([0, 7, 8])
    end

    it 'finds nothing for a blank form or a blank text' do
      expect(count('Lalabeis', '  ')).to eq(0)
      expect(count(nil, 'Lalabeis')).to eq(0)
      expect(replacement(nil, 'Lalabeis').replace(with: 'x').text).to eq('')
    end
  end

  describe 'the speaker of a place' do
    let(:participants) { [anna, ben] }
    let(:text) do
      [
        'Vorweg ohne Sprecher: Lalabeis.',
        'Anna: Lalabeis ist gut.',
        'Und Lalabeis kann mehr.',
        '',
        'Ben: Lalabeis auch bei mir.',
        'Anna Ananas: Lalabeis zum Schluss.'
      ].join("\n")
    end
    let(:subject) { replacement(text, 'Lalabeis', participants: participants) }

    it 'is the participant named at the start of the line, by first name or full name' do
      expect(subject.speaker_of(1)).to eq(anna)
      expect(subject.speaker_of(4)).to eq(ben)
      expect(subject.speaker_of(5)).to eq(anna)
    end

    it 'is the speaker of the last labelled line for a line without a label' do
      expect(subject.speaker_of(2)).to eq(anna)
      expect(subject.speaker_of(3)).to eq(anna)
    end

    it 'is nobody before the first label' do
      expect(subject.speaker_of(0)).to be_nil
    end

    it 'counts the occurrences per speaker' do
      expect(subject.count_by_speaker).to eq(nil => 1, anna => 3, ben => 1)
    end

    # Two participants share the first name: the line is a speaker turn (the
    # page bolds it), but whose is unknown, and the turn is nobody's.
    it 'is nobody for a first name two participants share, and that line ends the turn before' do
      other_anna = participant('Anna Apfel')
      shared = replacement("Ben: eins\nAnna: Lalabeis\nweiter", 'Lalabeis', participants: [anna, other_anna, ben])

      expect(shared.speaker_of(0)).to eq(ben)
      expect(shared.speaker_of(1)).to be_nil
      expect(shared.speaker_of(2)).to be_nil
      expect(shared.scan.first.in_label).to be(false)
    end
  end

  describe 'the occurrence at a marked place' do
    let(:subject) { replacement('Wir nutzen Lala Beis und Lalabeis.', 'Lala Beis') }

    it 'is the occurrence that overlaps the marked span' do
      expect(subject.at(line_index: 0, char_offset: 11, length: 4)&.char_offset).to eq(11)
      expect(subject.at(line_index: 0, char_offset: 16, length: 4)&.char_offset).to eq(11)
    end

    it 'is nothing where the form does not stand' do
      expect(subject.at(line_index: 0, char_offset: 25, length: 8)).to be_nil
      expect(subject.at(line_index: 1, char_offset: 11, length: 4)).to be_nil
    end
  end
end
