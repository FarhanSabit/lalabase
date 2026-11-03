# frozen_string_literal: true

# A page of a meeting's text, for a program that reads it in parts (MCP R9).
module Meetings
  # A page of a meeting's text, for a program that reads it in parts (MCP get_meeting, R9).
  #
  # Claude Code cuts a tool answer above its own bound (about 25,000 tokens) without saying
  # so, and a transcript runs to about a megabyte. So the text goes out in pages: from an
  # offset, at most `max` characters, ending at the last line break in the page's last
  # `window` characters where there is one, else at the bound. The next page starts where
  # this one ended (`next_offset`, nil at the end), so the pages add up to the text with
  # nothing lost or read twice. Offsets count characters, as Ruby's String does, never bytes,
  # so no page ends inside a character.
  #
  # Entry point: call
  class TextPage
    MAX_CHARS = 40_000
    LINE_WINDOW = 2_000

    def self.call(text:, offset:, max: MAX_CHARS, window: LINE_WINDOW)
      text = text.to_s
      return { offset: offset, next_offset: nil, text: '' } if offset >= text.length

      stop = offset + max
      return { offset: offset, next_offset: nil, text: text[offset..] } if stop >= text.length

      # A line break at the page's first character would end it there and read nothing.
      cut = text.rindex("\n", stop - 1)
      stop = cut + 1 if cut && cut > offset && cut >= stop - window
      { offset: offset, next_offset: stop, text: text[offset...stop] }
    end
  end
end
