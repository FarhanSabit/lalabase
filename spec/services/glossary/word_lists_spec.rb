# frozen_string_literal: true

require 'rails_helper'

# What: Glossary::WordLists, the common German and English words the glossary extraction
#   sieves out before it proposes a term (K5b).
# Type: Service spec against the vendored lists; the stop words of PostgreSQL through a
#   stubbed pg_config.
# Why:  A common word proposed as a term is noise. The lists decide in the compared form of
#   GlossaryText, whatever the case of the word; without pg_config or its files our own short
#   list stands in, and nothing fails. Invented words only.
RSpec.describe Glossary::WordLists do
  describe '.common_word?' do
    it 'takes common German and English words as common' do
      %w[und nicht the would].each do |word|
        expect(described_class.common_word?(word)).to be(true), "expected #{word} to be common"
      end
    end

    it 'takes invented words as not common' do
      %w[zorbel quarnix].each do |word|
        expect(described_class.common_word?(word)).to be(false), "expected #{word} not to be common"
      end
    end

    it 'does not care about case' do
      expect(described_class.common_word?('UND')).to be(true)
      expect(described_class.common_word?('Would')).to be(true)
      expect(described_class.common_word?('ZORBEL')).to be(false)
    end
  end

  describe '.common' do
    it 'is a frozen set of frozen words, built once and then the same object' do
      words = described_class.common

      expect(words).to be_a(Set).and be_frozen
      expect(words.all?(&:frozen?)).to be(true)
      expect(described_class.common).to equal(words)
    end
  end

  describe '.build' do
    # Without the 50k lists only the stop words are left, so the fallback can be told apart:
    # the 50k lists hold every word of it as well.
    before do
      stub_const("#{described_class}::FREQUENCY_FILES", [])
      allow(Open3).to receive(:capture2).and_call_original
    end

    let(:fallback) { Set.new(described_class::FALLBACK_STOP_WORDS.map { |word| GlossaryText.normalize(word) }) }

    def pg_config_names(directory)
      allow(Open3).to receive(:capture2).with('pg_config', '--sharedir')
                                        .and_return(["#{directory}\n", instance_double(Process::Status, success?: true)])
    end

    context 'without pg_config' do
      before { allow(Open3).to receive(:capture2).with('pg_config', '--sharedir').and_raise(Errno::ENOENT, 'pg_config') }

      it 'uses the fallback list, and a word from it is common' do
        allow(described_class).to receive(:common).and_return(described_class.build)

        expect(described_class.common).to eq(fallback)
        expect(described_class.common_word?('Und')).to be(true)
        expect(Open3).to have_received(:capture2).with('pg_config', '--sharedir').once
      end
    end

    context 'when pg_config fails' do
      before do
        allow(Open3).to receive(:capture2).with('pg_config', '--sharedir')
                                          .and_return(['', instance_double(Process::Status, success?: false)])
      end

      it 'uses the fallback list' do
        expect(described_class.build).to eq(fallback)
      end
    end

    context 'with a share directory of PostgreSQL' do
      let(:share) { Dir.mktmpdir('word-lists-spec-') }
      let(:stop_words) { File.join(share, 'tsearch_data') }

      before do
        FileUtils.mkdir_p(stop_words)
        File.write(File.join(stop_words, 'german.stop'), "Zorbel\nwub\n")
        File.write(File.join(stop_words, 'english.stop'), "Quarnix\n")
        pg_config_names(share)
      end

      after { FileUtils.remove_entry(share) }

      it 'reads the stop words of both files and leaves the fallback out' do
        expect(described_class.build).to eq(Set['zorbel', 'wub', 'quarnix'])
      end

      it 'adds the fallback list when one of the files is missing' do
        File.delete(File.join(stop_words, 'english.stop'))

        expect(described_class.build).to eq(Set['zorbel', 'wub'] | fallback)
      end

      it 'uses the fallback list when both files are missing' do
        FileUtils.remove_entry(stop_words)

        expect(described_class.build).to eq(fallback)
      end
    end
  end
end
