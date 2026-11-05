# frozen_string_literal: true

# Where a mark of the browser lies in the stored transcript (K4b). The page
# shows the transcript through Markdown (Neo::MarkdownPreviewComponent): bold
# speakers, no frontmatter, a link shows its text and not its target. A
# position in the page is no position in the stored text, and the page
# carries none of the source (and must not: the component and
# Lalabase::SafeMarkdown stay as they are).
#
# So the browser sends what the reader marked, up to CONTEXT_LENGTH
# characters of the text the page shows before and after it, and how many
# characters of that text stand before it. This class reads the same text out
# of the same HTML (MeetingsHelper#meeting_transcript_html), finds the mark
# there (the offset first, the context as its proof; else the one place with
# that context), asks which whole-word match of the form it is, and takes the
# match with the same number in the stored transcript
# (Meetings::TermReplacement#scan, the rule of counting and replacing).
#
# It refuses rather than guesses:
# * not_found: no place shows the mark with its context, or several do;
# * not_a_word: the mark is part of a longer word;
# * ambiguous: the page and the stored text hold the form a different number
#   of times (Markdown hid some of it, a link target or an escaped sign);
# * speaker_label: the mark stands in the speaker label of its line;
# * line_break, too_long: no heard form at all.
#
# Characters, not bytes and not UTF-16 units: the browser counts code points.
#
# Entry point: .resolve
module Meetings
  class TranscriptMark
    # What the browser sends on each side, and the most this class reads.
    CONTEXT_LENGTH = 40
    MAX_CONTEXT_LENGTH = 200

    Place = Data.define(:line_index, :char_offset, :length)

    Result = Data.define(:place, :error) do
      def success?
        error.nil?
      end
    end

    def self.resolve(**)
      new(**).resolve
    end

    # transcript: as stored. displayed_html: what the page shows of it.
    # participants: the meeting's (anything with a display_name). text,
    # before, after: strings from the browser. offset: an Integer or nil.
    def initialize(transcript:, displayed_html:, participants:, text:, before:, after:, offset:)
      @transcript = transcript.to_s
      @displayed_html = displayed_html.to_s
      @participants = participants
      raw = text.to_s
      lead = raw[/\A[[:space:]]*/]
      trail = raw[/[[:space:]]*\z/]
      @mark = raw[lead.length...(raw.length - trail.length)].to_s
      @before = before.to_s.last(MAX_CONTEXT_LENGTH) + lead
      @after = trail + after.to_s.first(MAX_CONTEXT_LENGTH)
      @offset = offset && (offset + lead.length)
    end

    def resolve
      return refuse(:not_found) if @mark.empty?
      return refuse(:line_break) if @mark.match?(/[\r\n]/)
      return refuse(:too_long) if @mark.length > GlossaryTerm::MAX_LENGTH

      start = locate
      return refuse(:not_found) unless start

      map(start)
    end

    private

    def map(start)
      shown = TermReplacement.new(text: visible, heard: @mark, skip_frontmatter: false).scan
      line_index, column = line_and_column(start)
      ordinal = shown.index { |match| match.line_index == line_index && match.byte_offset == column }
      return refuse(:not_a_word) unless ordinal

      stored = TermReplacement.new(text: @transcript, heard: @mark, participants: @participants).scan
      return refuse(:ambiguous) unless stored.size == shown.size

      match = stored[ordinal]
      return refuse(:speaker_label) if match.in_label

      Result.new(place: Place.new(line_index: match.line_index, char_offset: match.char_offset, length: match.length),
                 error: nil)
    end

    # The text the content element of the page holds, as the browser reads it
    # (the text of every node, in order).
    def visible
      @visible ||= Nokogiri::HTML5.fragment(@displayed_html).text
    end

    # Where the mark starts in the text the page shows, in bytes, or nil.
    # Bytes, because Ruby finds the n-th character of a text with umlauts by
    # counting from its start: a search over many candidates would count a
    # long transcript again for each of them.
    def locate
      if @offset && @offset >= 0
        start = visible[0, @offset].bytesize
        return start if fits?(start)
      end

      starts = []
      from = 0
      while (found = visible.byteindex(@mark, from))
        starts << found if fits?(found)
        break if starts.size > 1

        from = found + @mark[0].bytesize
      end
      starts.first if starts.one?
    end

    # The mark and its context at this place (in bytes).
    def fits?(start)
      finish = start + @mark.bytesize
      return false if start < @before.bytesize || finish + @after.bytesize > visible.bytesize

      visible.byteslice(start, @mark.bytesize) == @mark &&
        visible.byteslice(start - @before.bytesize, @before.bytesize) == @before &&
        visible.byteslice(finish, @after.bytesize) == @after
    end

    # The line of a place and where it starts in that line, in bytes, the way
    # TermReplacement::Match#byte_offset counts.
    def line_and_column(start)
      prefix = visible.byteslice(0, start)
      line_start = prefix.byterindex("\n")
      [prefix.count("\n"), line_start ? start - line_start - 1 : start]
    end

    def refuse(error)
      Result.new(place: nil, error: error)
    end
  end
end
