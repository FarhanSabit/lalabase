# frozen_string_literal: true

require 'rails_helper'

# Speaker labels in a transcript are bolded at render time, checked against the
# meeting's OWN participant list (never a generic "words + colon" heuristic — see the
# false-positive cases below, which are the reason the whitelist approach exists).
RSpec.describe Meetings::SpeakerMarkup do
  def mark(text, names)
    described_class.call(text: text, participant_names: names)
  end

  describe 'the participant whitelist' do
    it 'bolds a label that matches a participant' do
      expect(mark("Samira: Diese Tickets hier.\n", ['Samira Barati']))
        .to eq("**Samira:** Diese Tickets hier.\n")
    end

    it 'matches the full name as well as the bare first name' do
      expect(mark("Samira Barati: Ja.\n", ['Samira Barati'])).to eq("**Samira Barati:** Ja.\n")
    end

    # THE reason this is a whitelist and not a heuristic: these lines all look like
    # "label + colon at line start" and none of them is a speaker.
    it 'leaves prose lines that merely contain a colon untouched' do
      %w[Problem Folge Lösung Hinweis].each do |word|
        line = "#{word}: Materialcodes werden separat angezeigt.\n"
        expect(mark(line, ['Samira Barati'])).to eq(line)
      end
    end

    it 'leaves a multi-word prose lead-in untouched' do
      line = "Für die Kasse relevant: Ist beim Kuchenverkauf etwas ausgefallen?\n"
      expect(mark(line, ['Karl Krause'])).to eq(line)
    end

    # The user's decision: an unlisted speaker stays unmarked rather than being guessed.
    it 'leaves a speaker who is not a participant unmarked' do
      line = "Jürgen: Ich war auch dabei.\n"
      expect(mark(line, ['Samira Barati'])).to eq(line)
    end

    it 'returns the text unchanged when there are no participants' do
      line = "Samira: Diese Tickets hier.\n"
      expect(mark(line, [])).to eq(line)
      expect(mark(line, nil)).to eq(line)
    end
  end

  describe 'label variants' do
    it 'matches through a (Speaker N) suffix and keeps it on screen' do
      expect(mark("Bert Bauer (Speaker 2): Ja.\n", ['Bert Bauer']))
        .to eq("**Bert Bauer (Speaker 2):** Ja.\n")
    end

    it 'matches through an uncertainty suffix "(?)"' do
      expect(mark("Guido (?): Nee, du bist es hier.\n", ['Guido Boyke']))
        .to eq("**Guido (?):** Nee, du bist es hier.\n")
    end

    it 'matches across umlaut spellings via the shared name normalization' do
      expect(mark("Juergen: Hallo.\n", ['Jürgen Krause'])).to eq("**Juergen:** Hallo.\n")
    end

    it 'does not double-bold a line the source already marked up' do
      line = "**Samira:** Schon fett.\n"
      expect(mark(line, ['Samira Barati'])).to eq(line)
    end

    it 'ignores a colon that appears later in the line' do
      line = "Wir haben lange kein Update gemacht, Samira: das stimmt.\n"
      expect(mark(line, ['Samira Barati'])).to eq(line)
    end

    it 'leaves an absurdly long lead-in alone (a label is short)' do
      line = "#{'wort ' * 30}: kein Sprecher.\n"
      expect(mark(line, ['Samira Barati'])).to eq(line)
    end
  end

  describe 'structure preservation' do
    it 'keeps blank lines, indentation and the trailing newline' do
      text = "Samira: Eins.\n\n  Guido: Zwei.\n"
      expect(mark(text, ['Samira Barati', 'Guido Boyke']))
        .to eq("**Samira:** Eins.\n\n  **Guido:** Zwei.\n")
    end

    it 'marks a speaker line at end of file without a trailing newline' do
      expect(mark('Samira: Letzte Zeile.', ['Samira Barati'])).to eq('**Samira:** Letzte Zeile.')
    end

    it 'returns blank input unchanged' do
      expect(mark('', ['Samira Barati'])).to eq('')
    end
  end

  # Pinned to the SAME corpus the JS parser is tested against, so the two mirrored
  # speaker-line rules cannot drift apart unnoticed (see the class header).
  describe 'against the shared transcript fixtures' do
    def fixture(name)
      Rails.root.join('spec/fixtures/meeting_transcripts', name).read
    end

    it 'marks the unmarked speakers of fixture 06, and nothing else' do
      result = mark(fixture('fixture_06_unmarkierte_sprecher.md'), ['Anna', 'Karl', 'Bert Bauer'])

      expect(result).to include('**Anna:** Kurzer Abgleich')
      expect(result).to include('**Karl (?):** Bei der Kasse')
      expect(result).to include('**Bert Bauer (Speaker 2):** Ich bringe')
      # The traps in the same fixture stay untouched.
      expect(result).to include("\nFür die Kasse relevant: Die Abrechnung")
      expect(result).to include('Problem: Die Belege')
      expect(result).to include('Hinweis: Der Aushang')
      expect(result).to include("\n**Fazit:** Getränke bestellt")
      expect(result).not_to include('****')
    end

    it 'leaves an already bolded fixture completely unchanged' do
      text = fixture('fixture_05_fallstricke.md')
      expect(mark(text, ['Bert Bauer', 'Karl Krause'])).to eq(text)
    end
  end

  # The label of one line (K4b): what Meetings::TermReplacement never replaces
  # and reads the speaker from. The same participant list decides, in the plain
  # and in the already bolded form.
  describe '#label' do
    def label(line, names = ['Samira Barati'])
      described_class.new(text: '', participant_names: names).label(line)
    end

    it 'gives where a plain label ends and the name it gives' do
      expect(label('Samira: Diese Tickets.').to_h).to eq(ends_at: 7, name: 'Samira')
      expect(label('  Samira Barati (Speaker 2): Ja.').to_h).to eq(ends_at: 28, name: 'Samira Barati')
    end

    it 'reads a bolded label in both forms' do
      expect(label('**Samira:** Ja.').to_h).to eq(ends_at: 11, name: 'Samira')
      expect(label('**Samira**: Ja.').to_h).to eq(ends_at: 11, name: 'Samira')
    end

    it 'is nothing for prose before a colon, a bolded lead-in or a line without a colon' do
      expect(label('Problem: Die Belege fehlen.')).to be_nil
      expect(label('**Fazit:** Getränke bestellt.')).to be_nil
      expect(label('Samira sagt ja.')).to be_nil
    end
  end
end
