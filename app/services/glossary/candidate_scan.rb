# frozen_string_literal: true

# The sieve of the glossary extraction (K5b), without AI: reads the texts of
# an organisation one source at a time and keeps the words and names that may
# be terms, with how often and where they stand. Pure Ruby, no database: the
# caller streams the sources and says what is known and what is common.
#
# * A word: letters, marks and digits of any script. A dot or a hyphen inside
#   a word belongs to it ("Zorbel-Hub", "Wub.io"), one at its end does not.
#   What shows nothing (GlossaryText::INVISIBLE) is gone first, so it joins.
# * A name: two or three capitalised words in a row with only blanks between
#   them, so never across a line or a punctuation mark ("Zorbel Hub Pro",
#   "Zorbel Hub"), and never with a stop word first or last: many German
#   sentences start with an article, so "Die Rechnung" makes no name and "Der
#   Zorbel Hub" only "Zorbel Hub". Each of its words still counts on its own.
#   German writes every noun with a capital, so a name of common words only
#   counts from two sources on.
# * Dropped: addresses, e-mail addresses, paths, numbers, codes (hex, UUID,
#   eight characters without a vowel), words under three characters but
#   abbreviations in capitals ("KI"), anything longer than a term may be,
#   common words (as a single word) and known terms.
# * Spellings group by GlossaryText.compact: "Zorbel-Hub", "Zorbelhub",
#   "zorbel hub" and "ZORBEL HUB" are one candidate. Words in a row that are
#   not all capitalised make no candidate of their own; when every one of
#   them is uncommon ("zorbel hub") they count as a spelling of a candidate
#   found as a word or a name.
# * Memory: at most MAX_GROUPS keys, each with its counts, at most MAX_FORMS
#   spellings and at most MAX_SNIPPETS snippets, never a whole text. When the
#   keys reach MAX_GROUPS, the ones seen once in one source go; when that
#   frees too little, no new key comes in for the rest of the scan, and the
#   keys it has go on counting. Either way the scan says it is truncated.
module Glossary
  class CandidateScan
    # One text to read. type: one of GlossaryProposalSource::SOURCE_TYPES.
    Source = Data.define(:type, :id, :project_id, :text) do
      def initialize(type:, id:, project_id:, text:)
        raise ArgumentError, "unknown source type #{type.inspect}" unless GlossaryProposalSource::SOURCE_TYPES.include?(type)

        super
      end
    end

    # One source of a candidate: the text around its first occurrence there
    # and how often it stands there.
    Snippet = Data.define(:type, :id, :project_id, :text, :occurrences)

    # key: GlossaryText.compact of its spellings. forms: the spellings seen,
    # the most frequent first, ties by the first seen; display: the first.
    # snippets: the sources with the most occurrences first, ties by the first
    # seen.
    Candidate = Data.define(:key, :display, :forms, :source_count, :occurrences, :snippets)

    # The best max_candidates; total counts the candidates before the cut.
    Scan = Data.define(:candidates, :total, :truncated)

    # A letter (with its marks) or a digit of any script.
    WORD_CHARACTER = '[\p{L}\p{M}\p{N}]'
    # Joins two pieces of a word: a dot or one of the three hyphens
    # GlossaryText.compact drops. At the end of a word it is punctuation.
    JOINER = '[.\u{2D}\u{2010}\u{2011}]'
    # One word ("Zorbel-Hub", "Wub.io", "Zörbelstraße").
    WORD = /#{WORD_CHARACTER}+(?:#{JOINER}#{WORD_CHARACTER}+)*/
    # A run of whitespace, as GlossaryText.clean collapses it.
    WHITESPACE = /[[:space:]]+/
    # Whitespace of a line break (no blank): the read text keeps one, where
    # GlossaryText.clean would make it a space, because a name ends there.
    LINE_BREAK = /[^[:blank:]]/
    # A piece of text between whitespace: addresses and paths are judged by
    # it. The read text has only spaces and line breaks left between them.
    CHUNK = /[^ \n]+/
    # A chunk that may hold an address, an e-mail address or a path: a quick
    # test, so the exact patterns run on few chunks.
    SUSPECT = %r{[@/\\]|\A~|www\.}i
    # Where an address begins: a scheme ("https://") or "www." at the start of
    # a word. The rest of the chunk is the address; what stands before it is
    # text ("[Zorbel](https://...").
    ADDRESS = %r{[[:alpha:]][[:alnum:]+.-]*://|(?<!#{WORD_CHARACTER})www\.}i
    # An e-mail address: a character of an address on both sides of an "@".
    EMAIL = /[\p{L}\p{M}\p{N}._%+-]@[\p{L}\p{M}\p{N}]/
    # A path: a slash or a backslash anywhere, or a tilde at the start.
    PATH = %r{[/\\]|\A~}
    # A number: digits, also with . , : - / between them (a date, a decimal,
    # a time, a phone number).
    NUMBER = %r{\A\p{N}+(?:[.,:/\u{2D}\u{2010}\u{2011}]\p{N}+)*\z}
    # A hex string: six or more hex characters with a digit and a letter among
    # them (a hash, a key). A word of the letters a to f alone stays.
    HEX = /\A(?=\h*\d)(?=\h*[a-fA-F])\h{6,}\z/
    # A UUID with its hyphens; one without them is a hex string.
    UUID = /\A\h{8}(?:-\h{4}){3}-\h{12}\z/
    # Eight or more characters without a vowel: a code, not a word.
    NO_VOWEL = /\A[^aeiouyäöüAEIOUYÄÖÜ]{8,}\z/
    # Two or more capital letters: an abbreviation ("KI"), kept though short.
    ABBREVIATION = /\A\p{Lu}{2,}\z/
    # A capital first letter.
    CAPITALISED = /\A[\p{Lu}\p{Lt}]/
    # A word under this many characters is no term, unless an abbreviation.
    MIN_LENGTH = 3
    # Longer is no term: a term may have GlossaryTerm::MAX_LENGTH characters,
    # and the snippet that shows it must hold it whole.
    MAX_FORM = [GlossaryTerm::MAX_LENGTH, GlossaryProposalSource::MAX_SNIPPET].min
    # A name has two words or three.
    NAME_SIZES = (2..3)
    # A name of common words only is a candidate from this many sources on.
    MIN_SOURCES_OF_COMMON_NAME = 2
    # What a run keeps of the places: GlossaryProposal and GlossaryProposalSource.
    MAX_SNIPPETS = GlossaryProposal::MAX_SOURCES
    MAX_SNIPPET = GlossaryProposalSource::MAX_SNIPPET
    # Bytes read on each side of an occurrence for its snippet: MAX_SNIPPET
    # characters even when each takes four bytes.
    SNIPPET_REACH = MAX_SNIPPET * 4
    # The spellings a key keeps: as many as a proposal holds, its term and
    # GlossaryProposal::MAX_VARIANTS variants. A spelling seen after these
    # adds its occurrences to the key, but not itself to the list.
    MAX_FORMS = GlossaryProposal::MAX_VARIANTS + 1
    # The keys tracked at most. Every rare word and every name of two or three
    # words is a key, so without a bound the keys grow with the texts: 200
    # texts of 15,000 words made 1.1 million keys and 1.5 GB more memory. A
    # key with its spellings and snippets takes some 1.5 KB, so 20,000 stay
    # near 30 MB. And they are far more than the candidates a run sends
    # (Glossary::Extraction::MAX_CANDIDATES), so a term found in several
    # sources is tracked long before that cut.
    MAX_GROUPS = 20_000
    # A prune that leaves less than this share of MAX_GROUPS free ends the
    # tracking of new keys: each prune reads every key, and one that freed
    # little would come again at once. With a quarter, the prunes read at
    # most four keys for each new key they make room for.
    MIN_FREE_SHARE = Rational(1, 4)

    # What the rules say about a word, the same wherever it stands. noise: no
    # term and no word of a name either. stop: a stop word, which no name
    # starts or ends with.
    Word = Data.define(:form, :key, :capitalised, :common, :stop, :noise)
    # A word where it stands: bytes from...to of the read text.
    Placed = Data.define(:word, :from, :to)
    # One occurrence of a key. kind: :word, :name (with an uncommon word),
    # :common_name (of common words only) or :spelling.
    Occurrence = Data.define(:key, :form, :kind, :from, :to)
    # A key in one source: how often, in which spellings, where first.
    Seen = Struct.new(:occurrences, :forms, :from, :to, :found, :common_name)
    # A key over the sources read so far.
    Group = Struct.new(:forms, :sources, :occurrences, :snippets, :found, :common_name)
    private_constant :Word, :Placed, :Occurrence, :Seen, :Group

    def self.call(sources:, known:, common_words:, max_candidates:, stop_words: nil)
      new(sources: sources, known: known, common_words: common_words, max_candidates: max_candidates,
          stop_words: stop_words).call
    end

    # known: strings in any spelling. common_words: answers include? for a
    # GlossaryText.normalize form. stop_words: the same for the stop words
    # alone; Glossary::WordLists.stop_words when not given.
    def initialize(sources:, known:, common_words:, max_candidates:, stop_words: nil)
      @sources = sources
      @known = known.each_with_object(Set.new) { |value, keys| keys << GlossaryText.compact(value) }
      @common_words = common_words
      @stop_words = stop_words || Glossary::WordLists.stop_words
      @max_candidates = max_candidates
      @groups = {}
      # cut: a prune ran, so the result may miss a key. full: no new key is
      # taken any more.
      @cut = false
      @full = false
    end

    def call
      @sources.each { |source| read(source) }
      ranked = @groups.select { |_key, group| candidate?(group) }
                      .sort_by { |key, group| [-group.sources, -group.occurrences, key] }
      Scan.new(candidates: ranked.first(@max_candidates).map { |key, group| candidate(key, group) },
               total: ranked.size, truncated: @cut || ranked.size > @max_candidates)
    end

    private

    # One source on its own: its keys first, then into the groups, so a
    # snippet is cut from this text only and nothing of it stays but that.
    def read(source)
      text = readable(source.text)
      seen = {}
      each_occurrence(text) { |occurrence| note(seen, occurrence) }
      seen.each { |key, entry| add(key, entry, source, text) }
    end

    # The text as the rules read it, as GlossaryText.clean would make it but
    # for the lines: UTF-8 (a byte that is no character dropped, so one broken
    # text cannot stop a run), what shows nothing dropped, Unicode NFC, and a
    # run of whitespace one space, or one line break where it holds one.
    def readable(value)
      text = value.to_s
      text = text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '') unless text.encoding == Encoding::UTF_8
      text = text.scrub('') unless text.valid_encoding?
      text.gsub(GlossaryText::INVISIBLE, '').unicode_normalize(:nfc)
          .gsub(WHITESPACE) { |run| run.match?(LINE_BREAK) ? "\n" : ' ' }
    end

    # Every occurrence of a key in the text, in text order: each word, and
    # each name or spelling that ends at it.
    def each_occurrence(text, &block)
      judged = {}
      run = []
      each_word(text) do |raw, from, to|
        word = judged[raw] ||= judge(raw)
        next if word.noise

        yield Occurrence.new(key: word.key, form: word.form, kind: :word, from: from, to: to) if term?(word)
        # A name goes on only across blanks; any other gap starts a new run.
        run.clear unless run.any? && blanks_between?(text, run.last.to, from)
        run << Placed.new(word: word, from: from, to: to)
        run.shift if run.size > NAME_SIZES.max
        each_name(text, run, &block)
      end
    end

    # Every word with its place in bytes, in text order. A chunk with an
    # e-mail address or a path gives no word, one with an address none from
    # where the address begins.
    def each_word(text)
      text.scan(CHUNK) do
        chunk_from = Regexp.last_match.byteoffset(0).first
        outside_addresses(Regexp.last_match[0]).scan(WORD) do
          from, to = Regexp.last_match.byteoffset(0)
          yield Regexp.last_match[0], chunk_from + from, chunk_from + to
        end
      end
    end

    # The part of a chunk to read for words: none of an e-mail address or a
    # path, the part before an address.
    def outside_addresses(chunk)
      return chunk unless chunk.match?(SUSPECT)

      start = chunk.index(ADDRESS)
      head = start ? chunk[0, start] : chunk
      head.match?(EMAIL) || head.match?(PATH) ? '' : head
    end

    def judge(raw)
      form = GlossaryText.clean(raw)
      compared = GlossaryText.normalize(form)
      Word.new(form: form, key: GlossaryText.compact(form), capitalised: form.match?(CAPITALISED),
               common: @common_words.include?(compared), stop: @stop_words.include?(compared), noise: noise?(form))
    end

    # Rule 3, and the length a term may have.
    def noise?(form)
      return true if form.length > MAX_FORM
      return !form.match?(ABBREVIATION) if form.length < MIN_LENGTH

      [NUMBER, HEX, UUID, NO_VOWEL].any? { |pattern| form.match?(pattern) }
    end

    # A single word that is a candidate: neither common (rule 4) nor known (rule 5).
    def term?(word)
      !word.common && !@known.include?(word.key)
    end

    # Only blanks between two words, inside a line: one space in the read text.
    # A dropped word between them is no blank either.
    def blanks_between?(text, from, to)
      text.byteslice(from, to - from) == ' '
    end

    # The names and spellings that end at the last word of the run.
    def each_name(text, run)
      NAME_SIZES.each do |size|
        break if size > run.size

        placed = run.last(size)
        kind = name_kind(placed.map(&:word))
        next unless kind

        from = placed.first.from
        to = placed.last.to
        form = GlossaryText.clean(text.byteslice(from, to - from))
        key = GlossaryText.compact(form)
        next if form.length > MAX_FORM || @known.include?(key)

        yield Occurrence.new(key: key, form: form, kind: kind, from: from, to: to)
      end
    end

    # Words in a row: all capitalised, a :name with an uncommon word or a
    # :common_name of common words only; not all capitalised, a :spelling when
    # every word is uncommon (else every uncommon word would bring its
    # neighbours along: "der zorbel", "zorbel ist"). Nothing when the first or
    # the last word is a stop word: an article at the start of a sentence and
    # a noun after it ("Die Rechnung") would be a name in hundreds of texts,
    # and "Der Zorbel" one next to "Zorbel". A stop word inside stays
    # ("Zorbel For Teams").
    def name_kind(words)
      return if words.first.stop || words.last.stop

      if words.all?(&:capitalised)
        words.all?(&:common) ? :common_name : :name
      elsif words.none?(&:common)
        :spelling
      end
    end

    def note(seen, occurrence)
      entry = seen[occurrence.key] ||= Seen.new(occurrences: 0, forms: Hash.new(0), from: occurrence.from, to: occurrence.to,
                                                found: false, common_name: false)
      entry.occurrences += 1
      entry.forms[occurrence.form] += 1
      entry.found ||= %i[word name].include?(occurrence.kind)
      entry.common_name ||= occurrence.kind == :common_name
    end

    def add(key, entry, source, text)
      group = @groups[key] || track(key)
      return unless group

      group.sources += 1
      group.occurrences += entry.occurrences
      entry.forms.each { |form, count| add_form(group, form, count) }
      group.found ||= entry.found
      group.common_name ||= entry.common_name
      keep_snippet(group, source, text, entry)
    end

    # A new key, while there is room. At MAX_GROUPS the long tail goes first
    # (prune); nil once a prune freed too little.
    def track(key)
      prune if !@full && @groups.size >= MAX_GROUPS
      return if @full

      @groups[key] = Group.new(forms: Hash.new(0), sources: 0, occurrences: 0, snippets: [],
                               found: false, common_name: false)
    end

    # Drops the long tail: the keys seen once in one source (rare words,
    # typos, names that stand once). They rank below every key seen more
    # often, and most keys are such keys. When that leaves less than
    # MIN_FREE_SHARE of MAX_GROUPS free, no new key is taken for the rest of
    # the scan. Either way the result may miss a key or a count, so the scan
    # says it is truncated.
    def prune
      @cut = true
      @groups.delete_if { |_key, group| group.sources == 1 && group.occurrences == 1 }
      @full = MAX_GROUPS - @groups.size < MAX_GROUPS * MIN_FREE_SHARE
    end

    # At most MAX_FORMS spellings; one seen after them is not kept.
    def add_form(group, form, count)
      group.forms[form] += count if group.forms.key?(form) || group.forms.size < MAX_FORMS
    end

    # Keeps this source among the MAX_SNIPPETS with the most occurrences. A
    # later source needs more than the last one kept, so a tie stays with the
    # first seen; the snippet is cut only when it is kept.
    def keep_snippet(group, source, text, entry)
      kept = group.snippets
      return if kept.size >= MAX_SNIPPETS && entry.occurrences <= kept.last.occurrences

      snippet = Snippet.new(type: source.type, id: source.id, project_id: source.project_id,
                            text: snippet_text(text, entry.from, entry.to), occurrences: entry.occurrences)
      kept.insert(kept.index { |other| other.occurrences < entry.occurrences } || kept.size, snippet)
      kept.pop if kept.size > MAX_SNIPPETS
    end

    # The text around an occurrence (bytes from...to of the read text, where
    # whitespace is collapsed already): its line breaks as spaces, at most
    # MAX_SNIPPET characters, the occurrence whole and as near the middle as
    # the text allows, cut between words where it can be. A byte slice may
    # cut a character in two: scrub drops the halves.
    def snippet_text(text, from, to)
      core = text.byteslice(from, to - from)
      start = [from - SNIPPET_REACH, 0].max
      before = text.byteslice(start, from - start).scrub('').tr("\n", ' ')
      after = text.byteslice(to, SNIPPET_REACH).scrub('').tr("\n", ' ')
      left, right = shares(MAX_SNIPPET - core.length, before.length, after.length)
      (ending(before, left) + core + beginning(after, right)).strip
    end

    # The room split between the two sides; what one side cannot use goes to
    # the other.
    def shares(room, before, after)
      left = [room / 2, before].min
      right = [room - left, after].min
      [[room - right, before].min, right]
    end

    # The last room characters of text, from the start of a word if cut.
    def ending(text, room)
      return text if text.length <= room
      return '' unless room.positive?

      piece = text[-room..]
      return piece if text[-room - 1] == ' '

      space = piece.index(' ')
      space ? piece[space..] : piece
    end

    # The first room characters of text, to the end of a word if cut.
    def beginning(text, room)
      return text if text.length <= room
      return '' unless room.positive?

      piece = text[0, room]
      return piece if text[room] == ' '

      space = piece.rindex(' ')
      space ? piece[0, space] : piece
    end

    def candidate?(group)
      group.found || (group.common_name && group.sources >= MIN_SOURCES_OF_COMMON_NAME)
    end

    def candidate(key, group)
      forms = group.forms.sort_by.with_index { |(_form, count), index| [-count, index] }.map(&:first)
      Candidate.new(key: key, display: forms.first, forms: forms.freeze, source_count: group.sources,
                    occurrences: group.occurrences, snippets: group.snippets.freeze)
    end
  end
end
