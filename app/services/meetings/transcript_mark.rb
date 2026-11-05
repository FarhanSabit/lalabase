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
# The same number is no proof, and the same count is not either. Markdown can hide one match (a link target, a
# reference definition, a tag the sanitizer drops) and show another (an
# entity, a link text right at the word): the counts agree, the order does
# not (review round 1 of #121). So the match found is put back through the
# page's own rendering with a marker in its place, and it is taken only when
# the page then shows the marker exactly where the reader marked, with all
# the rest of its text unchanged.
#
# The dialog can change the heard form (#place_of): its occurrence at the mark
# gets the same proof. And "everywhere" replaces every stored match of the
# form (#everywhere?): it is offered only when the page shows each of them, a
# marker of its own in each place, and the page otherwise as before; a match
# in a link target, say, leaves only "only here" (review round 2 of #121).
#
# It refuses rather than guesses:
# * not_found: no place shows the mark with its context, or several do;
# * not_a_word: the mark is part of a longer word;
# * ambiguous: the match with the same number does not show at the mark (a
#   match Markdown hid stands before it, or the page shows one the stored text
#   does not hold); the proof decides, not the counts, so a hidden match after
#   the mark does not stand in the way;
# * speaker_label: the mark stands in the speaker label of its line;
# * line_break, too_long: no heard form at all;
# * not_at_mark (#place_of): the changed form does not stand at the mark.
#
# Characters, not bytes and not UTF-16 units: the browser counts code points.
#
# Entry point: .resolve
module Meetings
  class TranscriptMark
    # What the browser sends on each side, and the most this class reads.
    CONTEXT_LENGTH = 40
    MAX_CONTEXT_LENGTH = 200
    # Letters and digits only, so Markdown reads a marker as the word it stands for.
    MARKER = /Q[0-9A-Za-z]{16}Q/

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
      @resolve ||= begin
        start = locate if checked_mark.nil?
        checked_mark || (start ? map(start) : refuse(:not_found))
      end
    end

    # The place of a heard form at the mark: the mark's own place for the form
    # as marked, else the occurrence of the changed form that overlaps the mark,
    # proved at its place on the page the same way.
    def place_of(heard)
      result = resolve
      return result unless result.success?
      return result if same_form?(heard)

      replacement = replacement_for(heard)
      occurrence = replacement.at(**result.place.to_h)
      return refuse(:not_at_mark) unless occurrence

      start = @mark_start + (occurrence.byte_offset - @mark_match.byte_offset)
      return refuse(:ambiguous) unless start >= 0 && shows_at?(replacement, occurrence, start, replacement.text_at(occurrence).bytesize)

      Result.new(place: place_for(occurrence), error: nil)
    end

    # Whether "everywhere" may replace the heard form: the form stands at the
    # mark, and the page shows every stored occurrence of it, each at a place of
    # its own and in order, with the page otherwise as before.
    def everywhere?(heard)
      @everywhere ||= {}
      return @everywhere[heard] if @everywhere.key?(heard)

      @everywhere[heard] = place_of(heard).success? && all_shown?(replacement_for(heard))
    end

    private

    def map(start)
      shown = TermReplacement.new(text: visible, heard: @mark, skip_frontmatter: false).scan
      line_index, column = line_and_column(start)
      ordinal = shown.index { |match| match.line_index == line_index && match.byte_offset == column }
      return refuse(:not_a_word) unless ordinal

      stored = replacement_for(@mark)
      match = stored.scan[ordinal]
      return refuse(:ambiguous) unless match
      return refuse(:speaker_label) if match.in_label
      return refuse(:ambiguous) unless shows_at?(stored, match, start, @mark.bytesize)

      @mark_match = match
      @mark_start = start
      Result.new(place: place_for(match), error: nil)
    end

    def checked_mark
      if @mark.empty? then refuse(:not_found)
      elsif @mark.match?(/[\r\n]/) then refuse(:line_break)
      elsif @mark.length > GlossaryTerm::MAX_LENGTH then refuse(:too_long)
      end
    end

    def place_for(match)
      Place.new(line_index: match.line_index, char_offset: match.char_offset, length: match.length)
    end

    # The proof of a place: the stored match, replaced by a marker and shown
    # through the page's own rendering, shows the marker exactly where `length`
    # bytes of the page start at `start`, and every other character as before.
    def shows_at?(replacement, match, start, length)
      marker = new_marker
      shown = text_of(@render.call(replacement.replace(with: marker, only: match).text))
      shown == visible.byteslice(0, start) + marker + visible.byteslice(start + length, visible.bytesize)
    end

    # Every occurrence replaced by a marker of its own: the page shows the
    # markers once each, in order, and with the stored texts put back it is the
    # page as it was.
    def all_shown?(replacement)
      texts = {}
      probe = replacement.replace_each { |occurrence| new_marker.tap { |marker| texts[marker] = replacement.text_at(occurrence) } }
      shown = text_of(@render.call(probe.text))
      return false unless shown.scan(MARKER) == texts.keys

      shown.gsub(MARKER) { |marker| texts.fetch(marker, marker) } == visible
    end

    def new_marker
      "Q#{SecureRandom.alphanumeric(16)}Q"
    end

    def same_form?(heard)
      words(heard) == words(@mark)
    end

    def words(text)
      text.to_s.split(/[[:space:]]+/).reject(&:empty?)
    end

    def replacement_for(heard)
      @replacements ||= {}
      @replacements[words(heard)] ||= TermReplacement.new(text: @transcript, heard: heard, participants: @participants)
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
