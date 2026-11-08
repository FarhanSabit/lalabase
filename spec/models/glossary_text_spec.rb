# frozen_string_literal: true

require 'rails_helper'

# The normalizer of the glossary (GlossaryText). .compact is the key that
# groups the spelling variants of a term (K5b): the compared form without any
# whitespace and without hyphens. Invented words only.
RSpec.describe GlossaryText do
  describe '.compact' do
    it 'gives one key for spellings that differ only in hyphens, spaces and case' do
      keys = ['Zorbel-Hub', 'Zorbelhub', 'zorbel hub', 'ZORBEL HUB', ' Zorbel - Hub '].map { |value| described_class.compact(value) }

      expect(keys.uniq).to eq(['zorbelhub'])
    end

    it 'drops the hyphen-minus, the hyphen and the non-breaking hyphen' do
      expect(described_class.compact("Zorbel\u{002D}Hub")).to eq('zorbelhub')
      expect(described_class.compact("Zorbel\u{2010}Hub")).to eq('zorbelhub')
      expect(described_class.compact("Zorbel\u{2011}Hub")).to eq('zorbelhub')
    end

    it 'keeps every other dash and mark: only those three hyphens join a word' do
      expect(described_class.compact("Zorbel\u{2013}Hub")).to eq("zorbel\u{2013}hub")
      expect(described_class.compact("Zorbel\u{2212}Hub")).to eq("zorbel\u{2212}hub")
      expect(described_class.compact('Zorbel_Hub/Wub')).to eq('zorbel_hub/wub')
    end

    it 'drops any whitespace, also a no-break space, a tab and a line break' do
      expect(described_class.compact("Zor\u{00A0}bel\tHub\r\nWub")).to eq('zorbelhubwub')
    end

    it 'keeps umlauts and ß, so "Maße" and "Masse" stay apart' do
      expect(described_class.compact('Maße')).to eq('maße')
      expect(described_class.compact('Masse')).to eq('masse')
      expect(described_class.compact('Quärnix-Wub')).to eq('quärnixwub')
    end

    it 'normalizes first: what shows nothing goes, a decomposed umlaut composes' do
      expect(described_class.compact("Zor\u{200B}bel\u{00AD}Hub")).to eq('zorbelhub')
      expect(described_class.compact("Qua\u{0308}rnix")).to eq("qu\u{00E4}rnix")
    end

    it 'is empty for nil and for nothing but spaces and hyphens' do
      expect(described_class.compact(nil)).to eq('')
      expect(described_class.compact(" - \u{2010} \u{2011} ")).to eq('')
    end
  end
end
