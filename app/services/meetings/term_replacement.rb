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
    # Between the words of a form: horizontal whitespace only.
    WORD_GAP = '[[:blank:]]+'

    # One whole-word match: its line, where it starts in the line and how long
    # it is (characters), and whether it starts inside the speaker label.
    Match = Data.define(:line_index, :char_offset, :length, :in_label)
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
      by_line = targets.group_by(&:line_index)
      result = lines.each_with_index.map do |line, index|
        hits = by_line[index]
        next line unless hits

        hits.sort_by(&:char_offset).reverse.each_with_object(line.dup) do |hit, changed|
          changed[hit.char_offset, hit.length] = with
        end
      end
      Replaced.new(text: result.join("\n"), count: targets.size)
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

        label_end = labels[index]&.ends_at
        line.to_enum(:scan, regex).map do
          found = Regexp.last_match
          start = found.begin(0)
          Match.new(line_index: index, char_offset: start, length: found[0].length,
                    in_label: !label_end.nil? && start < label_end)
        end
      end
    end

    def pattern
      body = @words.map { |word| Regexp.escape(word) }.join(WORD_GAP)
      Regexp.new("(?<!#{WORD_CHARACTER})#{body}(?!#{WORD_CHARACTER})")
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
