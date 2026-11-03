# frozen_string_literal: true

require 'rails_helper'

# MCP R9: a meeting's text read in pages by a program (get_meeting on /api/mcp).
# What: a page starts at an offset in characters and ends at the last line break near its
#   end, else at its bound; the next page starts where it ended.
# Why: Claude Code cuts a tool answer above its own bound without saying so. A transcript runs
#   to about a megabyte, so it is read in parts, and the parts must add up to the whole: no
#   character lost or read twice, none cut in half.
RSpec.describe Meetings::TextPage do
  def pages(text, max:, window:)
    out = []
    offset = 0
    loop do
      page = described_class.call(text: text, offset: offset, max: max, window: window)
      out << page
      break if page[:next_offset].nil?

      offset = page[:next_offset]
    end
    out
  end

  it 'reads a text whole in pages that add up to it, none overlapping' do
    text = "#{Array.new(400) { |n| "Anna: Satz #{n} über den Plan, äöü und 😀.\n" }.join}Ende."
    read = pages(text, max: 1_000, window: 200)

    expect(read.size).to be > 10
    expect(read.pluck(:text).join).to eq(text)
    read.each_cons(2) { |a, b| expect(b[:offset]).to eq(a[:next_offset]) }
    expect(read.last[:next_offset]).to be_nil
    expect(read.first(read.size - 1)).to all(satisfy { |page| page[:text].end_with?("\n") })
  end

  it 'ends a page at its bound when no line break is near, never inside a character' do
    text = 'ä😀' * 3_000
    read = pages(text, max: 1_001, window: 100)

    expect(read.pluck(:text).join).to eq(text)
    expect(read.first[:text].length).to eq(1_001)
    expect(read.pluck(:text)).to all(satisfy(&:valid_encoding?))
  end

  it 'takes a line break inside the window only' do
    text = "#{'a' * 10}\n#{'b' * 100}"
    page = described_class.call(text: text, offset: 0, max: 50, window: 20)

    expect(page[:text]).to eq(text[0, 50])
    expect(page[:next_offset]).to eq(50)
  end

  it 'gives the rest as the last page, and an empty last page at or past the end' do
    expect(described_class.call(text: 'abc', offset: 1, max: 10, window: 5)).to eq(offset: 1, next_offset: nil, text: 'bc')
    expect(described_class.call(text: 'abc', offset: 3, max: 10, window: 5)).to eq(offset: 3, next_offset: nil, text: '')
    expect(described_class.call(text: 'abc', offset: 99, max: 10, window: 5)).to eq(offset: 99, next_offset: nil, text: '')
    expect(described_class.call(text: nil, offset: 0)).to eq(offset: 0, next_offset: nil, text: '')
  end

  it 'always moves on: a line break at the page start does not end the page there' do
    text = "\n#{'x' * 100}"
    page = described_class.call(text: text, offset: 0, max: 50, window: 50)

    expect(page[:next_offset]).to eq(50)
  end
end
