# frozen_string_literal: true

require 'rails_helper'

# Where a mark of the browser lies in the stored transcript (K4b). The page
# shows the transcript through Markdown, so the browser can only say what the
# reader marked and what the page shows around it. The class reads the same
# text out of the same HTML the page shows (MeetingsHelper#meeting_transcript_html)
# and maps the n-th whole-word match there to the n-th in the stored text, or
# refuses. Invented words and names only.
RSpec.describe Meetings::TranscriptMark do
  def participant(name)
    Struct.new(:display_name).new(name)
  end

  let(:participants) { [participant('Anna Ananas'), participant('Ben Birne')] }

  # The page's own rendering of a transcript text, as the controller hands it in.
  def render
    ->(text) { ApplicationController.helpers.meeting_transcript_html(text, participants) }
  end

  # The text the browser shows: what the content element of the page holds.
  def visible(transcript)
    Nokogiri::HTML5.fragment(render.call(transcript)).text
  end

  # What the browser sends for the nth (0-based) place of `mark` in the text
  # it shows: the mark, up to 40 characters around it, and its offset.
  def browser_mark(transcript, mark, nth: 0)
    shown = visible(transcript)
    start = shown.to_enum(:scan, mark).map { Regexp.last_match.begin(0) }.fetch(nth)
    { text: mark, before: shown[[start - 40, 0].max...start], after: shown[start + mark.length, 40], offset: start }
  end

  def resolve(transcript, **mark)
    described_class.resolve(transcript: transcript, render: render, participants: participants, **mark)
  end

  let(:transcript) do
    <<~TEXT
      ---
      id: aufnahme-7
      ---
      Anna: Wir reden über Lalabeis.
      Ben: **Lalabeis** ist gut, und Lalabeis-Konten auch.

      - ein Punkt mit Lalabeis
      Anna: Zum Schluss noch einmal Lalabeis.
    TEXT
  end

  it 'finds the place in the stored text, lines counted with the frontmatter, in characters' do
    result = resolve(transcript, **browser_mark(transcript, 'Lalabeis', nth: 2))

    expect(result).to be_success
    expect(result.place.to_h).to eq(line_index: 4, char_offset: 31, length: 8)
  end

  it 'finds every place of the form, in the order the page shows them' do
    places = (0..4).map { |nth| resolve(transcript, **browser_mark(transcript, 'Lalabeis', nth: nth)).place.to_h.values_at(:line_index, :char_offset) }

    expect(places).to eq([[3, 21], [4, 7], [4, 31], [6, 16], [7, 30]])
  end

  it 'takes the context alone when the offset is off, if only one place has it' do
    mark = browser_mark(transcript, 'Lalabeis', nth: 3).merge(offset: 3)

    expect(resolve(transcript, **mark).place.to_h.values_at(:line_index, :char_offset)).to eq([6, 16])
  end

  it 'refuses when the offset is off and the context fits several places' do
    text = "Ben: ja Lalabeis ja\nBen: ja Lalabeis ja\n"
    mark = browser_mark(text, 'Lalabeis').merge(before: 'ja ', after: ' ja', offset: 0)

    expect(resolve(text, **mark).error).to eq(:not_found)
  end

  it 'refuses a mark the page does not show there' do
    mark = browser_mark(transcript, 'Lalabeis').merge(before: 'nirgends ', offset: 1)

    expect(resolve(transcript, **mark).error).to eq(:not_found)
  end

  it 'refuses part of a longer word' do
    mark = browser_mark(transcript, 'Lalabei')

    expect(resolve(transcript, **mark).error).to eq(:not_a_word)
  end

  it 'refuses a mark in the speaker label' do
    mark = browser_mark(transcript, 'Anna')

    expect(resolve(transcript, **mark).error).to eq(:speaker_label)
  end

  # A link shows its text, not its target: the page holds the form once, the
  # stored text twice. Which one is which is a guess, so it is refused.
  it 'refuses when Markdown shows the form a different number of times than the stored text holds' do
    text = "Ben: [Seite](https://example.com/lalabeis) und lalabeis.\n"

    expect(resolve(text, **browser_mark(text, 'lalabeis')).error).to eq(:ambiguous)
  end

  # Review round 1 of #121: Markdown can hide one match (a link target, a
  # reference definition, a tag the sanitizer drops) and show another (an
  # entity, a link text right at the word). The counts agree, the order does
  # not, and the n-th match was another word. The match is put back through the
  # page's own rendering with a marker in its place; only where the marker
  # shows at the mark with everything around it unchanged is it taken.
  describe 'Markdown that hides one match and shows another' do
    it 'refuses a mark the stored text holds elsewhere (entity shown, reference target hidden)' do
      text = "Anna: &#76;alabeis ist neu.\nBen: Lalabeis ist gut.\n\n[x]: https://example.com/Lalabeis"

      expect(resolve(text, **browser_mark(text, 'Lalabeis', nth: 0)).error).to eq(:ambiguous)
      expect(resolve(text, **browser_mark(text, 'Lalabeis', nth: 1)).error).to eq(:ambiguous)
    end

    it 'refuses a mark that would land in a link target (target hidden, link text at the word shown)' do
      text = "Anna: Siehe [Wiki](https://example.com/Lalabeis) und [Lala](https://example.com)beis heute.\nBen: Lalabeis ist gut."

      expect(resolve(text, **browser_mark(text, 'Lalabeis', nth: 0)).error).to eq(:ambiguous)
    end

    it 'refuses a mark that would land in a tag the page drops' do
      text = "Anna: <Lalabeis> und &#76;alabeis.\nBen: ok"

      expect(resolve(text, **browser_mark(text, 'Lalabeis', nth: 0)).error).to eq(:ambiguous)
    end

    it 'still finds a word in a link text, a bold word and a word after an entity' do
      text = "Ben: Siehe [Lalabeis](https://example.com/wiki) heute.\nAnna: **Lalabeis** &amp; Lalabeis."

      places = (0..2).map { |nth| resolve(text, **browser_mark(text, 'Lalabeis', nth: nth)).place&.to_h&.values_at(:line_index, :char_offset) }
      expect(places).to eq([[0, 12], [1, 8], [1, 25]])
    end
  end

  it 'takes the context after the mark into account as well as the one before it' do
    text = "Ben: ja Lalabeis heute\nBen: ja Lalabeis morgen\n"

    result = resolve(text, text: 'Lalabeis', before: 'ja ', after: ' heute', offset: 0)

    expect(result.place.to_h.values_at(:line_index, :char_offset)).to eq([0, 8])
  end

  # Review round 2 of #121: the heard form can be changed in the dialog, and
  # "everywhere" replaces every stored match. Both need the same proof as the
  # mark: the changed form at the mark shows there, and every match that
  # "everywhere" would replace shows on the page at a place of its own.
  describe 'a changed heard form and "everywhere"' do
    def mark_object(text, nth: 0, mark: 'Lalabeis')
      described_class.new(transcript: text, render: render, participants: participants,
                          **browser_mark(text, mark, nth: nth))
    end

    it 'finds the changed form at the mark, and says that everywhere would reach a place the page hides' do
      text = "Anna: Lala beis heute.\nBen: siehe [Wiki](https://example.com/Lala) ok"
      mark = mark_object(text, mark: 'Lala beis')

      expect(mark.resolve).to be_success
      expect(mark.place_of('Lala').place.to_h).to eq(line_index: 0, char_offset: 6, length: 4)
      expect(mark.everywhere?('Lala')).to be(false)
      expect(mark.everywhere?('Lala beis')).to be(true)
    end

    it 'says that everywhere would reach a place the page hides, also for the form as marked' do
      text = "Ben: Lalabeis ist gut.\nAnna: siehe [Wiki](https://example.com/Lalabeis) ok"
      mark = mark_object(text)

      expect(mark.resolve).to be_success
      expect(mark.everywhere?('Lalabeis')).to be(false)
    end

    it 'allows everywhere where the page shows every match, in a link text, bold and in a list as well' do
      text = "Ben: [Lalabeis](https://example.com/wiki) und **Lalabeis**\n- Lalabeis\nAnna: Lalabeis."
      mark = mark_object(text, nth: 1)

      expect(mark.resolve).to be_success
      expect(mark.everywhere?('Lalabeis')).to be(true)
    end

    # The page shows "Lala beis", the stored text holds "Lala *beis*": the
    # changed form stands at the mark, but not as the page shows it.
    it 'refuses a changed form whose place the page shows otherwise' do
      text = "Anna: Lala *beis* heute.\n"
      mark = mark_object(text, mark: 'Lala')
      mark.resolve

      expect(mark.place_of('Lala *beis*').error).to eq(:ambiguous)
    end

    it 'refuses a changed form that does not stand at the mark' do
      text = "Anna: Lala beis heute.\nBen: Konto ok"
      mark = mark_object(text, mark: 'Lala beis')
      mark.resolve

      expect(mark.place_of('Konto').error).to eq(:not_at_mark)
      expect(mark.everywhere?('Konto')).to be(false)
    end
  end

  # Review round 2 of #121: the proof compares the whole text, not only what
  # stands before the marker.
  it 'refuses when the page shows anything after the marker other than before' do
    text = "Ben: Lalabeis ist gut.\n"
    changed_after = lambda do |source|
      html = ApplicationController.helpers.meeting_transcript_html(source, participants)
      source.match?(/Q[0-9A-Za-z]{16}Q/) ? html.sub('gut.', 'gut, anders.') : html
    end

    result = described_class.resolve(transcript: text, render: changed_after, participants: participants,
                                     **browser_mark(text, 'Lalabeis'))

    expect(result.error).to eq(:ambiguous)
  end

  # Review round 2 of #121: where the 40 characters around the mark repeat,
  # only the offset tells the places apart.
  it 'tells places with the same context apart by the offset alone' do
    text = Array.new(6) { 'Ben: Lalabeis ja' }.join("\n")

    result = resolve(text, **browser_mark(text, 'Lalabeis', nth: 2))

    expect(result.place.to_h.values_at(:line_index, :char_offset)).to eq([2, 5])
  end

  it 'refuses a mark over a line break and a mark too long for the glossary' do
    two_lines = "Anna: eins Lala\nBeis zwei\n"
    long = "Anna: #{'x' * 300}\n"

    expect(resolve(two_lines, text: "Lala\nBeis", before: 'eins ', after: ' zwei', offset: 11).error).to eq(:line_break)
    expect(resolve(long, **browser_mark(long, 'x' * 300)).error).to eq(:too_long)
  end

  it 'takes whitespace around the mark for context' do
    mark = browser_mark(transcript, 'Lalabeis', nth: 1)
    padded = mark.merge(text: ' Lalabeis ', before: mark[:before][0...-1], after: mark[:after][1..], offset: mark[:offset] - 1)

    expect(resolve(transcript, **padded).place.to_h.values_at(:line_index, :char_offset)).to eq([4, 7])
  end

  it 'counts the offset in characters, as the browser sends it' do
    text = "Anna: Grüße 👋 und Lalabeis\n"

    expect(resolve(text, **browser_mark(text, 'Lalabeis')).place.to_h.values_at(:line_index, :char_offset)).to eq([0, 18])
  end

  # One line of half a megabyte with the form 20,000 times, and an offset that
  # does not fit: the context search runs over every candidate. In characters
  # that took about eight seconds; in bytes it takes milliseconds.
  it 'finds a mark in one long line with many candidates quickly, also by its context alone' do
    line = "Anna: #{(['Grüße an Lalabeis'] * 20_000).join(' und ')}"
    shown = visible(line)
    start = shown.rindex('Lalabeis')
    mark = { text: 'Lalabeis', before: shown[start - 40, 40], after: shown[start + 8, 40].to_s, offset: 3 }
    result = nil

    elapsed = Benchmark.realtime { result = resolve(line, **mark) }

    expect(elapsed).to be < 2
    expect(result.place.to_h).to eq(line_index: 0, char_offset: line.rindex('Lalabeis'), length: 8)
  end

  it 'refuses a blank mark' do
    expect(resolve(transcript, text: '  ', before: '', after: '', offset: 0).error).to eq(:not_found)
  end
end
