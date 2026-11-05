# frozen_string_literal: true

# What the dialog of a term correction shows (K4b), from what the browser sent
# and the transcript stored now: the mark resolved to its place in the stored
# text (Meetings::TranscriptMark), the heard form as typed and its occurrence
# at that place, how often it stands overall and in the turns of the speaker
# of the marked line (Meetings::TermReplacement), the digest it counted, and
# whether that is another transcript than the one the browser brought
# (recounted?: the page or the dialog was drawn from an older one).
#
# The dialog, its count and the correction itself all build their answer here,
# so what the dialog promised is what the correction is checked against. No
# database: the caller hands in the transcript, the meeting's participants and
# the HTML the page shows of the transcript.
#
# Entry point: new
module Meetings
  class TermCorrectionDialog
    # The most glossary terms the dialog suggests while typing.
    SUGGESTIONS = 500

    # mark: { text:, before:, after:, offset: } as the browser sent it.
    # heard: the heard form as typed, nil for the first opening (the mark itself).
    # digest: the digest the browser brought (the page's, or the dialog's last count).
    # render: the page's own rendering of a transcript text (see Meetings::TranscriptMark).
    def initialize(transcript:, render:, participants:, mark:, heard:, digest:)
      @transcript = transcript.to_s
      @render = render
      @participants = participants
      @mark = mark
      @heard = heard.nil? ? mark[:text].to_s.strip : heard.to_s
      @client_digest = digest.to_s
    end

    attr_reader :heard, :participants, :mark

    def digest
      @digest ||= Digest::SHA256.hexdigest(@transcript)
    end

    def recounted?
      @client_digest.present? && @client_digest != digest
    end

    # nil, or why the mark itself has no place (Meetings::TranscriptMark's
    # codes): then the dialog offers no form at all.
    def mark_error
      mark_result.error
    end

    # nil, or why the heard form as typed has no place at the mark
    # (not_at_mark, ambiguous): then the dialog offers no button.
    def heard_error
      heard_result&.error
    end

    # The place of the heard form at the mark in the stored transcript, proved
    # on the page (Meetings::TranscriptMark#place_of), or nil.
    def place
      heard_result&.place
    end

    def heard_blank?
      @heard.strip.empty?
    end

    # The occurrence of the heard form at that place, or nil: then nothing can
    # be replaced.
    def occurrence
      return if place.nil?

      @occurrence ||= replacement.at(**place.to_h)
    end

    def correctable?
      !occurrence.nil?
    end

    # Whether "everywhere" may run: the page shows every occurrence of the
    # heard form (Meetings::TranscriptMark#everywhere?). A match the page hides,
    # a link target say, leaves only "only here".
    def everywhere?
      correctable? && transcript_mark.everywhere?(@heard)
    end

    delegate :count, to: :replacement

    # Who spoke the marked line, a participant or nil.
    def speaker
      place && replacement.speaker_of(place.line_index)
    end

    # How often the form stands in the turns of that speaker.
    def speaker_count
      speaker && replacement.count_by_speaker.fetch(speaker, 0)
    end

    private

    def transcript_mark
      @transcript_mark ||= TranscriptMark.new(transcript: @transcript, render: @render, participants: @participants,
                                              **@mark.slice(:text, :before, :after, :offset))
    end

    def mark_result
      transcript_mark.resolve
    end

    def heard_result
      return if mark_error || heard_blank?

      @heard_result ||= transcript_mark.place_of(@heard)
    end

    def replacement
      @replacement ||= TermReplacement.new(text: @transcript, heard: @heard, participants: @participants)
    end
  end
end
