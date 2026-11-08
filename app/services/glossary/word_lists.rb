# frozen_string_literal: true

require 'monitor'
require 'open3'

# The common words of German and English (K5b): what the glossary extraction
# sieves out before it proposes a term. A word is common when it is one of the
# 50,000 most frequent words of either language, a stop word or one of our own
# EXTRA_COMMON_WORDS; everything else may be a term. The stop words are also a
# set of their own (stop_words): a name never starts or ends with one
# (Glossary::CandidateScan). All of them are kept in the compared form of
# GlossaryText.
#
# The stop words of the full text search of PostgreSQL are read at run time from
# the share directory pg_config names, not vendored: the PostgreSQL license is
# not on our allowlist (spec/architecture/third_party_license_guard_spec.rb), an
# app server may not have the files, and the 50k lists hold those words anyway.
# When a file cannot be read, our own short list stands in, and nothing fails.
#
# Entry point: common, stop_words
module Glossary
  class WordLists
    # FrequencyWords, unchanged (THIRD_PARTY_NOTICES.txt). Each line is
    # "word count"; the word is the first field.
    FREQUENCY_FILES = %w[vendor/wordlists/de_50k.txt vendor/wordlists/en_50k.txt].freeze

    # In the directory tsearch_data below the share directory of PostgreSQL.
    STOP_WORD_FILES = %w[german.stop english.stop].freeze

    # Our own list of the most common function words, German, then English, for
    # when the stop word files of PostgreSQL cannot be read.
    FALLBACK_STOP_WORDS = %w[
      der die das den dem des ein eine einen und oder aber dass wenn wie als
      nicht auch noch nur so ich du er sie es wir ist sind war hat in im mit
      von zu auf für
      the a an and or but if as than not no i you he she it we they me him her
      us them this that is are was were be have has had do will would can of
      to on at for with from by
    ].freeze

    # Our own list of common abbreviations and legal forms, German and English:
    # no terms, but the 50k lists hold only some of them, so "z.B." and "bzw."
    # would reach the model and each take the place of a term there. Written
    # as the scan reads them: in the compared form, a dot inside kept, a final
    # dot dropped ("z.B." is "z.b"). Common, but no stop words: a name may end
    # with one ("Zorbel GmbH").
    EXTRA_COMMON_WORDS = %w[
      z.b d.h u.a o.ä z.t u.u bzw usw ggf etc inkl evtl ca vgl ggü zzgl
      gmbh ag kg ug e.v
      ok e.g i.e vs approx
    ].freeze

    # A Monitor, not a Mutex: common asks stop_words while it holds the lock.
    MEMO = Monitor.new
    private_constant :MEMO

    class << self
      # Built on first use and then shared by every caller and thread: reading
      # 100,000 lines happens once per process. It holds stop_words, the same
      # words read once, and EXTRA_COMMON_WORDS.
      def common
        @common || MEMO.synchronize { @common ||= (build(stop_words) | compared(EXTRA_COMMON_WORDS)).freeze }
      end

      # The stop words alone, in the compared form: the files of PostgreSQL,
      # with FALLBACK_STOP_WORDS when one of them cannot be read. Built on first
      # use and then shared, like common.
      def stop_words
        @stop_words || MEMO.synchronize { @stop_words ||= build_stop_words }
      end

      def common_word?(word)
        common.include?(GlossaryText.normalize(word))
      end

      # A fresh set of what the files hold: the 50k lists and the stop words,
      # read anew unless given. Callers ask common, which keeps one.
      def build(stop_word_set = build_stop_words)
        compared(frequency_words).merge(stop_word_set).freeze
      end

      private

      # A fresh set of the stop words alone, read from the files; stop_words
      # keeps one.
      def build_stop_words
        compared(stop_word_lines).freeze
      end

      # The words in the compared form, each frozen; a word that is blank in
      # that form is left out.
      def compared(words)
        Set.new(words.filter_map { |word| GlossaryText.normalize(word).presence&.freeze })
      end

      def frequency_words
        FREQUENCY_FILES.flat_map do |path|
          File.foreach(Rails.root.join(path), chomp: true, encoding: Encoding::UTF_8).filter_map { |line| line.split(' ', 2).first }
        end
      end

      # Both files of PostgreSQL, and the fallback as soon as one of them cannot
      # be read: a language would go without its stop words otherwise.
      def stop_word_lines
        directory = postgres_share_directory
        found = STOP_WORD_FILES.filter_map { |name| read_stop_words(directory, name) }
        words = found.flatten
        found.size == STOP_WORD_FILES.size ? words : words + FALLBACK_STOP_WORDS
      end

      # A file of the system, not ours: invalid bytes are scrubbed, not raised.
      def read_stop_words(directory, name)
        return unless directory

        File.readlines(File.join(directory, 'tsearch_data', name), chomp: true, encoding: Encoding::UTF_8).map(&:scrub)
      rescue SystemCallError
        nil
      end

      # Called once per read of the stop words, with an argument list and no
      # shell. A missing pg_config, or one that fails, is no error: there is
      # nothing to read then.
      def postgres_share_directory
        output, status = Open3.capture2('pg_config', '--sharedir')
        output.strip.presence if status.success?
      rescue SystemCallError
        nil
      end
    end
  end
end
