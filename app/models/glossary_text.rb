# frozen_string_literal: true

# The ONE normalizer of the glossary (K4a): the form in which a term and a
# heard form are compared. Characters that show nothing dropped, Unicode NFC,
# any whitespace (also a no-break space) collapsed to one space and trimmed,
# lower case. Two terms that differ only in this are one term per
# organisation (unique index on glossary_terms.normalized_term).
#
# Deliberately NOT PersonName.normalize: that one also writes umlauts and ß
# out (ä -> ae, ß -> ss), which would make "Maße" and "Masse" one term.
module GlossaryText
  # What shows nothing: format characters (zero-width space and joiners, soft
  # hyphen, bidi controls, byte order mark), what Unicode marks as ignorable
  # in display (a Hangul filler, a variation selector), and control
  # characters. Whitespace among them (tab, line break) is left to the
  # whitespace rule and becomes a space. Dropped, not replaced: "Lala<zero-
  # width space>base" looks like "Lalabase" and is that term. A term of
  # nothing else is blank.
  INVISIBLE = /[\p{Cf}\p{Default_Ignorable_Code_Point}\p{Cc}&&[^[:space:]]]/

  # The text as it is stored and shown: invisible characters dropped (before
  # NFC, so an umlaut split by one composes), whitespace collapsed and
  # trimmed, case kept.
  def self.clean(value)
    value.to_s.gsub(INVISIBLE, '').unicode_normalize(:nfc).gsub(/[[:space:]]+/, ' ').strip
  end

  # The text as it is compared.
  def self.normalize(value)
    clean(value).downcase
  end

  # The key that groups the spelling variants of a term (K5b): the compared
  # form without any whitespace and without the three hyphens that join a
  # word (hyphen-minus U+002D, hyphen U+2010, non-breaking hyphen U+2011), so
  # "Zorbel-Hub", "Zorbelhub" and "zorbel hub" are one key. Only a key for
  # grouping, never stored as a term: umlauts and ß stay, as in normalize.
  def self.compact(value)
    normalize(value).gsub(/[[:space:]\u{002D}\u{2010}\u{2011}]/, '')
  end
end
