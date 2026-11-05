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
    def initialize(transcript:, displayed_html:, participants:, mark:, heard:, digest:)
      @transcript = transcript.to_s
      @displayed_html = displayed_html
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

    # mark_error: nil, or why the mark has no place (Meetings::TranscriptMark's
    # codes). place: the marked span in the stored transcript, or nil.
    delegate :error, :place, to: :mark_result, prefix: false
    alias mark_error error

    def heard_blank?
      @heard.strip.empty?
    end

    # The occurrence of the heard form at the mark, or nil: then nothing can
    # be replaced (the form was changed into one that does not stand there).
    def occurrence
      return if place.nil? || heard_blank?

      @occurrence ||= replacement.at(**place.to_h)
    end

    def correctable?
      !occurrence.nil?
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

    def mark_result
      @mark_result ||= TranscriptMark.resolve(transcript: @transcript, displayed_html: @displayed_html,
                                              participants: @participants, **@mark.slice(:text, :before, :after, :offset))
    end

    def replacement
      @replacement ||= TermReplacement.new(text: @transcript, heard: @heard, participants: @participants)
    end
  end
end
