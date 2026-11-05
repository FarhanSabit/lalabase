# frozen_string_literal: true

# Bolds the speaker labels of a transcript at RENDER time, so "Samira: …" reads
# like the "**Samira:**" form the transcript tools sometimes emit and sometimes
# do not. Storage stays untouched: the edit textarea keeps showing what was pasted.
#
# The rule is deliberately NOT a generic "words + colon at line start" heuristic.
# That pattern matches ordinary prose — "Problem:", "Folge:", "Für die Kasse
# relevant:" (see spec/fixtures/meeting_transcripts/fixture_05_fallstricke.md) —
# and would bold half the notes. Instead the meeting's OWN participant list is the
# whitelist: a label is a speaker only if it normalizes onto a known participant.
# A speaker missing from that list stays unmarked (deliberate: the gap is a useful
# hint that a participant was not captured, and guessing brings the false positives
# straight back).
#
# THIRD site enforcing the speaker-line rule, after participant_parser.js
# (SPEAKER_LINE) and the prose rules in ParticipantDetectionService#system_prompt.
# They cannot be merged across the three runtimes; instead this mirrors the
# precedent of MeetingParticipant.normalize_name ↔ name_normalizer.js — mirrored
# implementations pinned to the SAME fixtures by spec.
module Meetings
  class SpeakerMarkup
    # A speaker label is short. The bound also stops the regex from scanning far
    # into a long prose line before failing.
    MAX_LABEL_LENGTH = 80

    # Label at line start, up to the first colon. Excludes "*" so an already bolded
    # line can never match halfway through its own markup.
    SPEAKER_LINE = /\A(\s*)([^:*\n]{1,#{MAX_LABEL_LENGTH}}?)\s*:/

    # Diarisation noise the transcript tools append to a name: "(Speaker 2)",
    # "(Sprecher 3)" — the pair participant_parser.js strips — plus "(?)", which
    # marks an uncertain attribution. Stripped for the LOOKUP only; the label is
    # rendered with its suffix intact, so nothing is lost on screen.
    DIARISATION_SUFFIX = /\s*\((?:(?:speaker|sprecher)\s*\d+|\?)\)\s*\z/i

    # The label as the tools sometimes emit it, already bolded: "**Samira:**"
    # or "**Samira**:". mark leaves such a line as it is; #label reads it,
    # because the page shows it as a label too.
    BOLD_SPEAKER_LINE = /\A(\s*)\*\*([^:*\n]{1,#{MAX_LABEL_LENGTH}}?)\s*(?::\*\*|\*\*\s*:)/

    # A speaker label at the start of a line: where it ends (the character
    # after its colon, and after the closing ** of a bolded one) and the name
    # it gives, without a diarisation suffix.
    Label = Data.define(:ends_at, :name)

    def self.call(...)
      new(...).call
    end

    def initialize(text:, participant_names:)
      @text = text.to_s
      @participant_names = Array(participant_names)
    end

    def call
      return text if text.blank? || lookup.empty?

      text.each_line.map { |line| mark(line) }.join
    end

    # The speaker label at the start of one line, or nil: the rule mark bolds
    # by, against the same participant list, so nothing counts as a label that
    # the page does not show as one. Meetings::TermReplacement never replaces
    # inside it and reads the speaker of a line from it (K4b).
    def label(line)
      match = SPEAKER_LINE.match(line) || BOLD_SPEAKER_LINE.match(line)
      return if match.nil? || !speaker?(match[2])

      Label.new(ends_at: match.end(0), name: match[2].sub(DIARISATION_SUFFIX, '').strip)
    end

    private

    attr_reader :text, :participant_names

    def mark(line)
      # Already bolded by the source — leave it alone rather than nesting a second
      # pair of asterisks around it.
      return line if line.lstrip.start_with?('**')

      match = SPEAKER_LINE.match(line)
      return line if match.nil?

      label = match[2]
      return line unless speaker?(label)

      "#{match[1]}**#{label}:**#{match.post_match}"
    end

    def speaker?(label)
      core = label.sub(DIARISATION_SUFFIX, '').strip
      return false if core.blank?

      lookup.include?(MeetingParticipant.normalize_name(core))
    end

    # Normalized full names PLUS their first token, because the same person appears
    # as "Samira Barati" in the participant chips and as "Samira" in the transcript.
    # An ambiguous first token (two participants named Guido) is included anyway:
    # this decides "is this line a speaker turn", not WHICH person it is, and for
    # that question the answer is yes either way. participant_parser.js drops
    # ambiguous first names because it must resolve identity — a different job.
    def lookup
      @lookup ||= participant_names.filter_map { |name| variants(name) }
                                   .flatten.reject(&:blank?).to_set
    end

    def variants(name)
      value = name.to_s.strip
      return nil if value.blank?

      [MeetingParticipant.normalize_name(value),
       MeetingParticipant.normalize_name(value.split(/\s+/).first)]
    end
  end
end
