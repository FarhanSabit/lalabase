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
# of the same rendering (MeetingsHelper#meeting_transcript_html), finds the
# mark there (the offset first, the context as its proof; else the one place
# with that context), asks which whole-word match of the form it is, and
# takes the match with the same number in the stored transcript
# (Meetings::TermReplacement#scan, the rule of counting and replacing).
#
# The same number is no proof. Markdown can hide one match (a link target, a
# reference definition, a tag the sanitizer drops) and show another (an
# entity, a link text right at the word): the counts agree, the order does
# not (review round 1 of #121). So the match found is put back through the
# page's own rendering with a marker in its place, and it is taken only when
# the page then shows the marker exactly where the reader marked, with all
# the rest of its text unchanged.
#
# It refuses rather than guesses:
# * not_found: no place shows the mark with its context, or several do;
# * not_a_word: the mark is part of a longer word;
# * ambiguous: the page and the stored text hold the form a different number
#   of times, or the match with the same number does not show at the mark;
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

    # transcript: as stored. render: what the page shows for a transcript
    # text, as HTML (a callable; the caller hands in the page's own
    # rendering). participants: the meeting's (anything with a display_name).
    # text, before, after: strings from the browser. offset: an Integer or nil.
    def initialize(transcript:, render:, participants:, text:, before:, after:, offset:)
      @transcript = transcript.to_s
      @render = render
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

      stored = TermReplacement.new(text: @transcript, heard: @mark, participants: @participants)
      return refuse(:ambiguous) unless stored.scan.size == shown.size

      match = stored.scan[ordinal]
      return refuse(:speaker_label) if match.in_label
      return refuse(:ambiguous) unless shows_at_mark?(stored, match, start)

      Result.new(place: Place.new(line_index: match.line_index, char_offset: match.char_offset, length: match.length),
                 error: nil)
    end

    # The proof of the number: the stored match, replaced by a marker and
    # shown through the page's own rendering, shows the marker exactly at the
    # mark, and every other character of the page as before. The marker is
    # letters and digits only, so Markdown reads it as the word it replaces.
    def shows_at_mark?(stored, match, start)
      marker = "Q#{SecureRandom.alphanumeric(16)}Q"
      shown = text_of(@render.call(stored.replace(with: marker, only: match).text))
      shown == visible.byteslice(0, start) + marker + visible.byteslice(start + @mark.bytesize, visible.bytesize)
    end

    # The text the content element of the page holds, as the browser reads it
    # (the text of every node, in order).
    def visible
      @visible ||= text_of(@render.call(@transcript))
    end

    def text_of(html)
      Nokogiri::HTML5.fragment(html.to_s).text
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
