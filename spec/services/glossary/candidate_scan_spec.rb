# frozen_string_literal: true

require 'rails_helper'

# What: Glossary::CandidateScan, the sieve of the glossary extraction (K5b) without AI.
# Type: Plain Ruby spec, no database: sources are values, the common words and the stop words
#   small sets; one group reads the real Glossary::WordLists.
# Why:  Which words and names of the texts become candidate terms (rules 1 to 5), how their
#   spellings group (rule 6), how they rank and are cut, what a snippet holds (rule 7), and that
#   a stream of sources is read once. A name never starts or ends with a stop word, else an
#   article and a noun ("Die Rechnung") would take the places of real terms. Invented words and
#   names only.
RSpec.describe Glossary::CandidateScan do
  let(:common_words) do
    Set.new(%w[der die das den und ist wir testen morgen neue version termin heute läuft steht hier
               siehe bitte schreiben unter liegt pro sehr mögen nutzen kommt alles prüfen
               rechnung kunde wege])
  end
  # As in Glossary::WordLists, every stop word is a common word, not the other way round.
  let(:stop_words) { Set.new(%w[der die das den und ist wir]) }

  def source(text, id: 's1', type: 'Ticket', project_id: nil)
    described_class::Source.new(type: type, id: id, project_id: project_id, text: text)
  end

  # One source per text, with the ids s1, s2, ... in order.
  def sources_of(texts)
    texts.each_with_index.map { |text, index| source(text, id: "s#{index + 1}") }
  end

  def scan(*texts, known: [], max_candidates: 100, sources: sources_of(texts))
    described_class.call(sources: sources, known: known, common_words: common_words, stop_words: stop_words,
                         max_candidates: max_candidates)
  end

  def keys(*texts, **options)
    scan(*texts, **options).candidates.map(&:key)
  end

  def candidate(key, *texts, **options)
    scan(*texts, **options).candidates.find { |found| found.key == key }
  end

  describe 'words (rule 1)' do
    it 'keeps a hyphen and a dot inside a word, not a dot at the end of a sentence' do
      expect(keys('Wir nutzen Zorbel-Hub und Wub.io.')).to contain_exactly('zorbelhub', 'wub.io')
      expect(candidate('wub.io', 'Wir nutzen Wub.io.').forms).to eq(['Wub.io'])
    end

    it 'keeps umlauts and ß inside a word, also when an umlaut comes decomposed' do
      found = candidate('zörbelstraße', 'In der Zörbelstraße liegt alles.', "Zo\u0308rbelstraße")

      expect(keys('In der Zörbelstraße liegt alles.')).to eq(['zörbelstraße'])
      expect(found.forms).to eq(['Zörbelstraße'])
      expect(found.source_count).to eq(2)
      expect(found.snippets.last.text).to eq('Zörbelstraße')
    end

    it 'joins a word across what shows nothing, as GlossaryText does' do
      found = scan("Der Zor\u200Bbel-Hub und Quar\u00ADnix.")

      expect(found.candidates.map(&:key)).to include('zorbelhub', 'quarnix')
      expect(found.candidates.find { |c| c.key == 'zorbelhub' }.snippets.sole.text).to eq('Der Zorbel-Hub und Quarnix.')
    end

    it 'groups Grüwub-Werk with Grüwubwerk' do
      found = candidate('grüwubwerk', 'Das Grüwub-Werk liegt hier.', 'Im Grüwubwerk läuft alles.')

      expect(found.forms).to eq(%w[Grüwub-Werk Grüwubwerk])
      expect(found.source_count).to eq(2)
    end

    it 'reads a text with a byte that is no character' do
      expect(keys("Zorbel, \xFF Quarnix")).to contain_exactly('zorbel', 'quarnix')
    end
  end

  describe 'strings that are no words (rule 3)' do
    it 'drops addresses with a scheme or www., e-mail addresses and paths' do
      texts = ['Quarnix steht unter https://zorbel.example.com/wub-hub?x=1 und www.bexlo.example.org.',
               'Bitte an anna.beispiel@example.com schreiben.',
               'Siehe /srv/zorbel/quarnix, C:\\Wub\\Bexlo, ~/zorbel und ~bexlo.']

      expect(keys(*texts)).to eq(['quarnix'])
      expect(candidate('quarnix', *texts).source_count).to eq(1)
    end

    it 'keeps the text before an address in the same chunk' do
      expect(keys('Siehe [Zorbel Quarnix](https://zorbel.example.com/wub).'))
        .to contain_exactly('zorbel', 'quarnix', 'zorbelquarnix')
    end

    it 'drops numbers: a date, a decimal, a time and phone-like strings' do
      expect(keys('Bexlo 08.11.2026 2026-11-08 3,14 1.234,56 12:30 +49 170 1234567 0170-1234567')).to eq(['bexlo'])
    end

    it 'drops hex strings of six or more with a digit and UUIDs, keeps hex letters alone and five characters' do
      text = 'Bexlo, c0ffee42, a1b2c3, 2d09bbc77, 123e4567-e89b-12d3-a456-426614174000, ' \
             '123E4567-E89B-12D3-A456-426614174000, Abbade, a1b2c.'

      expect(keys(text)).to contain_exactly('bexlo', 'abbade', 'a1b2c')
    end

    it 'drops a string of eight characters without a vowel, keeps one of seven' do
      expect(keys('Krxtzpfl und Krxtzpf')).to eq(['krxtzpf'])
    end

    it 'drops words under three characters but keeps abbreviations of two capitals' do
      expect(keys('ab, ok, Ok, X, KI, Wub.')).to contain_exactly('ki', 'wub')
      expect(candidate('ki', 'Die KI.').forms).to eq(['KI'])
    end

    it 'drops a word longer than its snippet could hold, keeps one of exactly that length' do
      too_long = "Zorbel#{'a' * (GlossaryProposalSource::MAX_SNIPPET - 5)}"
      longest = "Quarnix#{'a' * (GlossaryProposalSource::MAX_SNIPPET - 7)}"
      found = scan("#{too_long} #{longest}")

      expect(found.candidates.map(&:key)).to eq([longest.downcase])
      expect(found.candidates.sole.snippets.sole.text).to eq(longest)
    end
  end

  describe 'common words (rule 4)' do
    it 'drops a single word in the injected set, a stop word alike, in any case' do
      expect(keys('Der Termin, die Zorbel und DER TERMIN.')).to eq(['zorbel'])
    end
  end

  describe 'names of several capitalised words (rule 2)' do
    it 'keeps a name of common words only from two sources on' do
      one = 'Wir testen Neue Version morgen. Neue Version kommt.'
      two = 'Heute läuft Neue Version.'

      expect(keys(one)).to eq([])
      expect(keys(one, two)).to eq(['neueversion'])
      expect(candidate('neueversion', one, two)).to have_attributes(source_count: 2, occurrences: 3)
    end

    it 'keeps a name with an uncommon word from one source on, and judges its words on their own' do
      expect(keys('Wir testen Zorbel Version morgen.')).to contain_exactly('zorbelversion', 'zorbel')
      expect(candidate('zorbelversion', 'Wir testen Zorbel Version morgen.').forms).to eq(['Zorbel Version'])
    end

    it 'takes up to three words in a row' do
      expect(keys('Zorbel Quarnix Wub Bexlo')).to contain_exactly(
        'zorbel', 'quarnix', 'wub', 'bexlo',
        'zorbelquarnix', 'quarnixwub', 'wubbexlo', 'zorbelquarnixwub', 'quarnixwubbexlo'
      )
    end

    it 'takes blanks between the words, never a line break or a punctuation mark' do
      expect(candidate('zorbelquarnix', "Zorbel \t\u00A0 Quarnix").forms).to eq(['Zorbel Quarnix'])
      expect(keys("Zorbel\nQuarnix", "Zorbel \r\n Quarnix", "Zorbel\u2028Quarnix", 'Zorbel, Quarnix', 'Zorbel. Quarnix',
                  "Zorbel \u2013 Quarnix")).to contain_exactly('zorbel', 'quarnix')
    end

    it 'makes no name of a word that is dropped' do
      expect(keys('Zorbel 2026 Quarnix, Zorbel Ab Quarnix, Zorbel https://zorbel.example.com Quarnix'))
        .to contain_exactly('zorbel', 'quarnix')
    end

    it 'makes no name of a stop word and a common noun, so they take no place of a term' do
      texts = Array.new(5, 'Die Rechnung liegt hier. Der Kunde kommt morgen.')

      expect(keys(*texts)).to eq([])
      expect(keys(*texts, 'Zorbel kommt morgen.', max_candidates: 1)).to eq(['zorbel'])
    end

    it 'makes no name that starts with a stop word, of two words or of three' do
      expect(keys('Das Zorbel-Werk läuft.')).to eq(['zorbelwerk'])
      expect(candidate('zorbelwerk', 'Das Zorbel-Werk läuft.').forms).to eq(['Zorbel-Werk'])
      expect(keys('Das Zorbel-Werk Quarnix läuft.')).to contain_exactly('zorbelwerk', 'quarnix', 'zorbelwerkquarnix')
    end

    it 'takes the name inside a window that starts with a stop word' do
      found = scan('Der Zorbel Hub läuft.').candidates

      expect(found.map(&:key)).to contain_exactly('zorbel', 'hub', 'zorbelhub')
      expect(found.find { |candidate| candidate.key == 'zorbelhub' }.forms).to eq(['Zorbel Hub'])
    end

    it 'makes no name that ends with a stop word, but keeps one with a stop word inside' do
      expect(keys('Wir testen Zorbel Und Quarnix morgen.')).to contain_exactly('zorbel', 'quarnix', 'zorbelundquarnix')
    end

    it 'keeps a name of common words that are no stop words from two sources on, as before' do
      expect(keys('Wir testen Neue Wege.')).to eq([])
      expect(keys('Wir testen Neue Wege.', 'Neue Wege kommt morgen.')).to eq(['neuewege'])
      expect(candidate('neuewege', 'Wir testen Neue Wege.', 'Neue Wege kommt morgen.').source_count).to eq(2)
    end
  end

  describe 'spellings (rule 6)' do
    it 'groups spellings that differ in case, spaces and hyphens, the most frequent first' do
      found = candidate('zorbelhub',
                        'Zorbel-Hub läuft. Bitte Zorbel-Hub prüfen.',
                        'Im Zorbelhub steht ZORBEL HUB.',
                        'wir mögen zorbel hub sehr.')

      expect(found.forms).to eq(['Zorbel-Hub', 'Zorbelhub', 'ZORBEL HUB', 'zorbel hub'])
      expect(found.display).to eq('Zorbel-Hub')
      expect(found).to have_attributes(source_count: 3, occurrences: 5)
    end

    it 'shows the most frequent spelling, ties by the first seen' do
      expect(candidate('quarnixwub', 'Quarnix Wub läuft.', 'wir mögen quarnix wub, quarnix wub!').forms)
        .to eq(['quarnix wub', 'Quarnix Wub'])
      expect(candidate('zorbel', 'zorbel und Zorbel', 'ZORBEL')).to have_attributes(
        forms: %w[zorbel Zorbel ZORBEL], display: 'zorbel'
      )
    end

    it 'makes no candidate of words in a row that are not capitalised' do
      expect(keys('wir mögen zorbel quarnix sehr.')).to contain_exactly('zorbel', 'quarnix')
    end

    it 'takes such words as a spelling of a candidate found in another source' do
      found = candidate('zorbelquarnix', 'Der Zorbel Quarnix läuft.', 'wir mögen zorbel quarnix sehr.')

      expect(found.forms).to eq(['Zorbel Quarnix', 'zorbel quarnix'])
      expect(found.source_count).to eq(2)
    end

    it 'takes them as a spelling only when every one of them is uncommon' do
      found = candidate('zorbelpro', 'Zorbel Pro läuft.', 'wir testen zorbel pro.')

      expect(found.forms).to eq(['Zorbel Pro'])
      expect(found.source_count).to eq(1)
    end
  end

  describe 'known terms (rule 5)' do
    {
      'a glossary term' => ['Zorbel Hub', 'Der zorbel-hub und ZORBELHUB.', 'zorbelhub'],
      'a heard form' => ['quarnix', 'QUARNIX und Quar-nix.', 'quarnix'],
      'a proposal' => ['WUB-WERK', 'Das Wubwerk und wub werk.', 'wubwerk'],
      "a person's name" => ['Anna Beispiel', 'ANNA BEISPIEL und Anna-Beispiel.', 'annabeispiel']
    }.each do |kind, (known, text, key)|
      it "drops #{kind} passed in known, also in another case and with hyphens" do
        expect(keys(text)).to include(key)
        expect(keys(text, known: [known].lazy)).not_to include(key)
      end
    end
  end

  describe 'ranking and the cut' do
    let(:texts) { ['Quarnix, Quarnix, Quarnix und Wub.', 'Zorbel, Zorbel und Wub.', 'Zorbel, Grüwub und Bexlo.'] }

    it 'ranks by distinct sources, then occurrences, then key' do
      expect(keys(*texts)).to eq(%w[zorbel wub quarnix bexlo grüwub])
    end

    it 'cuts at max_candidates, with the total before the cut' do
      expect(scan(*texts, max_candidates: 2)).to have_attributes(total: 5, truncated: true)
      expect(scan(*texts, max_candidates: 2).candidates.map(&:key)).to eq(%w[zorbel wub])
      expect(scan(*texts, max_candidates: 4)).to have_attributes(total: 5, truncated: true)
    end

    it 'is not truncated when every candidate fits' do
      whole = scan(*texts, max_candidates: 5)

      expect([whole.candidates.size, whole.total, whole.truncated]).to eq([5, 5, false])
    end
  end

  describe 'snippets (rule 7)' do
    # A filler of 15 letters and a space, so the room ends inside a word on both sides.
    it 'holds the occurrence in at most 240 characters, whitespace collapsed, cut between words' do
      filler = 'Loremipsumdolor ' * 25
      snippet = candidate('zorbelhub', "#{filler}\nZorbel-Hub\n\n  steht \t hier #{filler}").snippets.sole

      expect(snippet.text.length).to be_between(200, GlossaryProposalSource::MAX_SNIPPET)
      expect(snippet.text).to include('Zorbel-Hub steht hier')
      expect(snippet.text).not_to match(/\s{2}|[\n\t]|\A\s|\s\z/)
      expect(snippet.text.split(' ').uniq).to contain_exactly('Loremipsumdolor', 'Zorbel-Hub', 'steht', 'hier')
    end

    it 'counts its room after the whitespace is collapsed' do
      snippet = candidate('zorbel', "Zorbel#{"\n\n \t Wub" * 100}").snippets.sole

      expect(snippet.text).to start_with('Zorbel Wub Wub')
      expect(snippet.text.length).to be_between(230, GlossaryProposalSource::MAX_SNIPPET)
    end

    it 'is cut from its own source only' do
      snippets = candidate('zorbel', "#{'Alpha ' * 60}Zorbel", "Zorbel#{' Omega' * 60}").snippets

      expect(snippets.map(&:id)).to eq(%w[s1 s2])
      expect(snippets.first.text).to end_with('Alpha Zorbel')
      expect(snippets.first.text).not_to include('Omega')
      expect(snippets.last.text).to start_with('Zorbel Omega')
      expect(snippets.last.text).not_to include('Alpha')
      # The side without text gives its room to the other one.
      expect(snippets.map { |snippet| snippet.text.length }).to all(be_between(200, GlossaryProposalSource::MAX_SNIPPET))
    end

    it 'shows the first occurrence in its source' do
      text = "Zorbel steht vorn. #{'Lorem ' * 80}Zorbel steht hinten."

      expect(candidate('zorbel', text).snippets.sole).to have_attributes(occurrences: 2)
      expect(candidate('zorbel', text).snippets.sole.text).to start_with('Zorbel steht vorn.')
    end

    it 'keeps at most MAX_SOURCES snippets, the sources with the most occurrences first, ties by the first seen' do
      texts = [1, 3, 2, 3, 1, 4, 2].map { |count| Array.new(count, 'Zorbel').join(', ') }
      found = candidate('zorbel', *texts)

      expect(found.snippets.size).to eq(GlossaryProposal::MAX_SOURCES)
      expect(found.snippets.map(&:id)).to eq(%w[s6 s2 s4 s3 s7])
      expect(found.snippets.map(&:occurrences)).to eq([4, 3, 3, 2, 2])
      expect(found).to have_attributes(source_count: 7, occurrences: 16)
    end

    it 'carries the type, id and project of its source' do
      note = source('Zorbel steht hier.', type: 'Note', id: 'n1', project_id: 'p1')
      snippet = scan(sources: [note]).candidates.sole.snippets.sole

      expect(snippet).to have_attributes(type: 'Note', id: 'n1', project_id: 'p1', occurrences: 1,
                                         text: 'Zorbel steht hier.')
    end
  end

  # Review round 2 of #129. Every rare word and every name of two or three
  # words is a key, so without a bound the keys grow with the texts (some 1.1
  # million keys and 1.5 GB for 200 texts of 15,000 words). MAX_GROUPS bounds
  # them: at the bound the keys seen once in one source go, and once that
  # frees too little no new key comes in.
  describe 'the bound on keys' do
    # The bound is on memory, which the result does not show: these examples
    # watch the one hash that grows, and note its size after every key it
    # takes in.
    def watched_scan(*texts)
      scan = described_class.new(sources: sources_of(texts), known: [], common_words: common_words,
                                 stop_words: stop_words, max_candidates: 100)
      groups = scan.instance_variable_get(:@groups)
      sizes = []
      allow(groups).to receive(:[]=).and_wrap_original do |store, key, group|
        store.call(key, group).tap { sizes << groups.size }
      end
      [scan.call, sizes, groups]
    end

    it 'tracks at most MAX_GROUPS keys, keeps a key of two sources, drops the ones seen once, and says it cut' do
      stub_const('Glossary::CandidateScan::MAX_GROUPS', 6)

      result, sizes, groups = watched_scan('Zorbel, Wubbix.', 'Zorbel, Bexlo.', 'Glimmox, Trondel, Plumbix, Vexoria, Fizzbo.')

      expect(sizes).not_to be_empty
      expect(sizes.max).to eq(6)
      expect(groups.size).to be <= 6
      expect(result.truncated).to be(true)
      # Vexoria found the keys full: Wubbix, Bexlo and the three before it,
      # each seen once in one source, went. Zorbel, of two sources, stayed.
      expect(result.candidates.map(&:key)).to eq(%w[zorbel fizzbo vexoria])
      expect(result.candidates.first).to have_attributes(source_count: 2, occurrences: 2)
    end

    it 'takes no new key once a prune frees too little, and goes on counting the keys it has' do
      stub_const('Glossary::CandidateScan::MAX_GROUPS', 4)

      result, sizes, = watched_scan('Zorbel, Zorbel, Wubbix, Wubbix, Bexlo, Bexlo, Glimmox, Glimmox, Trondel.',
                                    'Zorbel, Plumbix.')

      expect(sizes.max).to eq(4)
      expect(result.truncated).to be(true)
      # Each of the four was seen twice, so the prune at Trondel freed nothing.
      expect(result.candidates.map(&:key)).to eq(%w[zorbel bexlo glimmox wubbix])
      expect(result.candidates.first).to have_attributes(source_count: 2, occurrences: 3)
    end

    # Too little is less than MIN_FREE_SHARE of MAX_GROUPS: a quarter of four
    # keys is one. Here each prune frees exactly one place, so new keys still
    # come in.
    it 'goes on taking new keys while a prune frees MIN_FREE_SHARE of MAX_GROUPS' do
      stub_const('Glossary::CandidateScan::MAX_GROUPS', 4)

      result, sizes, = watched_scan('Zorbel, Zorbel, Wubbix, Wubbix, Bexlo, Bexlo, Glimmox.', 'Trondel, Plumbix.')

      expect(sizes.max).to eq(4)
      expect(result.candidates.map(&:key)).to eq(%w[bexlo wubbix zorbel plumbix])
      expect(described_class::MIN_FREE_SHARE).to eq(Rational(1, 4))
    end

    it 'cuts nothing while the keys fit MAX_GROUPS' do
      stub_const('Glossary::CandidateScan::MAX_GROUPS', 3)

      expect(scan('Zorbel, Wubbix, Bexlo.')).to have_attributes(total: 3, truncated: false)
      expect(scan('Zorbel, Wubbix, Bexlo, Glimmox.').truncated).to be(true)
    end

    it 'keeps at most MAX_FORMS spellings of a key, and still counts the others' do
      stub_const('Glossary::CandidateScan::MAX_FORMS', 2)

      found = candidate('zorbel', 'Zorbel, ZORBEL.', 'zorbel, zorbel, zorbel.')

      expect(found.forms).to eq(%w[Zorbel ZORBEL])
      expect(found).to have_attributes(source_count: 2, occurrences: 5)
    end

    # A proposal holds its term and at most MAX_VARIANTS variants: a spelling
    # past those could never be written.
    it 'keeps as many spellings as a proposal holds' do
      expect(described_class::MAX_FORMS).to eq(GlossaryProposal::MAX_VARIANTS + 1)
    end
  end

  describe 'with the lists of Glossary::WordLists' do
    # No stop_words given: the scan takes Glossary::WordLists.stop_words.
    def keys_with_word_lists(*texts)
      described_class.call(sources: sources_of(texts), known: [], common_words: Glossary::WordLists.common,
                           max_candidates: 100).candidates.map(&:key)
    end

    it 'drops common abbreviations' do
      expect(keys_with_word_lists('Zorbel läuft, z.B. hier, bzw. morgen.')).to eq(['zorbel'])
    end

    it 'keeps a name with a legal form, never the legal form alone' do
      expect(keys_with_word_lists('Zorbel GmbH prüft das.', 'Eine GmbH prüft das.'))
        .to contain_exactly('zorbel', 'zorbelgmbh')
    end

    it 'takes the stop words of the lists when none are given' do
      expect(keys_with_word_lists('Der Zorbel Hub läuft.')).to contain_exactly('zorbel', 'zorbelhub')
      expect(keys_with_word_lists('Zorbel For Teams läuft.')).to contain_exactly('zorbel', 'zorbelforteams')
    end
  end

  describe 'sources' do
    it 'reads a lazy stream once' do
      reads = 0
      stream = Enumerator.new do |yielder|
        reads += 1
        yielder << source('Zorbel und Quarnix.', id: 's1')
        yielder << source('Zorbel.', id: 's2')
      end

      expect(keys(sources: stream.lazy)).to eq(%w[zorbel quarnix])
      expect(reads).to eq(1)
    end

    it 'refuses a type a proposal source cannot take' do
      expect { source('Zorbel', type: 'Meeting') }.to raise_error(ArgumentError, /Meeting/)
    end
  end
end
