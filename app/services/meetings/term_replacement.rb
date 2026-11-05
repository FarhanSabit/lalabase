# frozen_string_literal: true

# The ONE rule for counting and replacing a heard form in a meeting text (K4b,
# plan §5.2): the transcript, and on "replace everywhere" its AI summary too.
# Pure Ruby, no database: the caller hands in the text and the meeting's
# participants (anything with a display_name).
#
# * A match is a whole word: no letter (with its marks) and no digit of any
#   script directly before or after it. Not \b: Ruby's \b takes "_" for a
#   letter and wants a letter at both ends of the form, so "C++" or "2.0?"
#   would never match where they stand alone. A hyphen is a boundary, so
#   "Lalabeis-Konto" holds "Lalabeis".
# * Case as marked. A form of several words matches across horizontal
#   whitespace (space, tab, no-break space) inside one line, never across a
#   line break: a place has one line (term_corrections.line_index).
# * Never inside the speaker label at the start of a line
#   (Meetings::SpeakerMarkup#label, the rule the page bolds by): the label
#   belongs to the participant list. Never in the frontmatter
#   (Meeting::FRONTMATTER_BLOCK): the page does not show it.
#
# #occurrences is the one list behind the count of the dialog and the
# replacement, so the two cannot disagree. Lines are counted from the first
# line stored (with the frontmatter), offsets in characters, not bytes.
#
# Entry point: scan, occurrences, count, replace, at, speaker_of, count_by_speaker
module Meetings
  class TermReplacement
    # A letter (with its combining marks) or a digit of any script.
    WORD_CHARACTER = '[\p{L}\p{M}\p{N}]'
    # What shows nothing (a zero-width space, a soft hyphen, a bidi mark: the
    # set GlossaryText drops) joins what stands around it, as the reader sees
    # it: "Lalabeis<zero-width space>Konto" reads as one word. The boundary
    # looks past a run of up to MAX_INVISIBLE_RUN such characters, the same on
    # both sides (a look-behind has a fixed width, so the run has a limit;
    # a longer run counts as a boundary on both sides alike).
    INVISIBLE = GlossaryText::INVISIBLE.source
    MAX_INVISIBLE_RUN = 3
    # Between the words of a form: horizontal whitespace only.
    WORD_GAP = '[[:blank:]]+'

    # One whole-word match: its line, where it starts in the line and how long
    # it is (characters, what term_corrections stores), whether it starts inside
    # the speaker label, and the same place in bytes. The bytes are for the
    # work: Ruby finds the n-th character of a text with umlauts by counting
    # from its start, so a long line with many matches would be counted over
    # and over (a transcript can be one line of a megabyte).
    Match = Data.define(:line_index, :char_offset, :length, :in_label, :byte_offset, :byte_length)
    Replaced = Data.define(:text, :count)

    # skip_frontmatter: false for a text that has none by construction (the
    # text a page shows, Meetings::TranscriptMark), where a leading block of
    # "---" lines is content.
    def initialize(text:, heard:, participants: [], skip_frontmatter: true)
      @text = text.to_s
      @words = heard.to_s.split(/[[:space:]]+/).reject(&:empty?)
      @participants = Array(participants)
      @skip_frontmatter = skip_frontmatter
    end

    # Every whole-word match outside the frontmatter, in text order, the ones
    # in a speaker label included (in_label). Meetings::TranscriptMark maps a
    # mark of the browser through it; counting and replacing use #occurrences.
    def scan
      @scan ||= @words.empty? ? [] : collect_matches
    end

    # The matches that count and are replaced: every one outside a label.
    def occurrences
      @occurrences ||= scan.reject(&:in_label)
    end

    def count
      occurrences.size
    end

    # The text with `with` in place of every occurrence, or only of the one
    # given (one of #occurrences), and how many it replaced.
    def replace(with:, only: nil)
      targets = only.nil? ? occurrences : [own!(only)]
      rewrite(targets.map { |hit| [hit, with] })
    end

    # The text with every occurrence replaced by what the block gives for it
    # (Meetings::TranscriptMark puts a marker of its own in each one).
    def replace_each
      rewrite(occurrences.map { |hit| [hit, yield(hit)] })
    end

    # The stored text of one match, as it stands in its line.
    def text_at(match)
      lines[match.line_index].byteslice(match.byte_offset, match.byte_length)
    end

    # The occurrence that overlaps a marked span of one line, or nil.
    def at(line_index:, char_offset:, length:)
      finish = char_offset + length
      occurrences.find do |match|
        match.line_index == line_index && match.char_offset < finish && char_offset < match.char_offset + match.length
      end
    end

    # Who spoke a line: the participant its label names (full name, or a first
    # name only one participant has), else whoever spoke the last labelled
    # line before it. nil before the first label, after a label that names
    # nobody or two participants, and in the frontmatter.
    def speaker_of(line_index)
      speakers[line_index]
    end

    # How often the form stands in the turns of each speaker (nil: nobody known).
    def count_by_speaker
      occurrences.group_by { |match| speaker_of(match.line_index) }.transform_values(&:size)
    end

    private

    def lines
      @lines ||= @text.split("\n", -1)
    end

    def collect_matches
      regex = pattern
      lines.each_with_index.flat_map do |line, index|
        next [] if index < first_content_line

        matches_in(line, index, regex)
      end
    end

    # The matches of one line. The character offset is counted on from the
    # match before, never from the start of the line again.
    def matches_in(line, index, regex)
      label_end = labels[index]&.ends_at
      chars = 0
      bytes = 0
      line.to_enum(:scan, regex).map do
        found = Regexp.last_match
        byte_start = found.byteoffset(0).first
        chars += line.byteslice(bytes, byte_start - bytes).length
        bytes = byte_start
        Match.new(line_index: index, char_offset: chars, length: found[0].length,
                  in_label: !label_end.nil? && chars < label_end, byte_offset: byte_start, byte_length: found[0].bytesize)
      end
    end

    # One line with `with` in place of its hits, put together from the pieces
    # between them (in bytes, one pass).
    # pairs: [match, the text in its place], at most one per match.
    def rewrite(pairs)
      by_line = pairs.group_by { |hit, _with| hit.line_index }
      result = lines.each_with_index.map do |line, index|
        here = by_line[index]
        here ? replaced_line(line, here) : line
      end
      Replaced.new(text: result.join("\n"), count: pairs.size)
    end

    def replaced_line(line, pairs)
      cursor = 0
      result = pairs.sort_by { |hit, _with| hit.byte_offset }.each_with_object(+'') do |(hit, with), changed|
        changed << line.byteslice(cursor, hit.byte_offset - cursor) << with
        cursor = hit.byte_offset + hit.byte_length
      end
      result << line.byteslice(cursor, line.bytesize - cursor)
    end

    def pattern
      body = @words.map { |word| Regexp.escape(word) }.join(WORD_GAP)
      before = (0..MAX_INVISIBLE_RUN).map { |run| "(?<!#{WORD_CHARACTER}#{INVISIBLE * run})" }.join
      Regexp.new("#{before}#{body}(?!#{INVISIBLE}{0,#{MAX_INVISIBLE_RUN}}#{WORD_CHARACTER})")
    end

    # The frontmatter's lines are no content: nobody sees or marks them. A
    # block that ends the text without a line break ends on a line of its own.
    def first_content_line
      @first_content_line ||= begin
        block = @text[Meeting::FRONTMATTER_BLOCK] if @skip_frontmatter
        if block.nil? then 0
        elsif block.end_with?("\n") then block.count("\n")
        else block.count("\n") + 1
        end
      end
    end

    def labels
      @labels ||= begin
        reader = Meetings::SpeakerMarkup.new(text: '', participant_names: @participants.map(&:display_name))
        lines.each_with_index.map { |line, index| reader.label(line) if index >= first_content_line }
      end
    end

    def speakers
      @speakers ||= begin
        current = nil
        labels.each_with_index.map do |label, index|
          next if index < first_content_line

          current = participant_named(label.name) if label
          current
        end
      end
    end

    def participant_named(name)
      key = MeetingParticipant.normalize_name(name)
      full = @participants.select { |participant| normalized_names[participant].first == key }
      return full.first if full.size == 1
      return if full.size > 1

      first = @participants.select { |participant| normalized_names[participant].last == key }
      first.first if first.size == 1
    end

    # [full name, first name] of each participant, normalized once.
    def normalized_names
      @normalized_names ||= @participants.to_h do |participant|
        name = participant.display_name.to_s.strip
        [participant, [MeetingParticipant.normalize_name(name), MeetingParticipant.normalize_name(name.split(/\s+/).first)]]
      end
    end

    def own!(match)
      raise ArgumentError, 'not an occurrence of this text' unless occurrences.include?(match)

      match
    end
  end
end
