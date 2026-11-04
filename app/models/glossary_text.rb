# frozen_string_literal: true

# The ONE normalizer of the glossary (K4a): the form in which a term and a
# heard form are compared. Unicode NFC, any whitespace (also a no-break
# space) collapsed to one space and trimmed, lower case. Two terms that
# differ only in this are one term per organisation (unique index on
# glossary_terms.normalized_term).
#
# Deliberately NOT PersonName.normalize: that one also writes umlauts and ß
# out (ä -> ae, ß -> ss), which would make "Maße" and "Masse" one term.
module GlossaryText
  # The text as it is stored and shown: NFC, whitespace collapsed and trimmed,
  # case kept.
  def self.clean(value)
    value.to_s.unicode_normalize(:nfc).gsub(/[[:space:]]+/, ' ').strip
  end

  # The text as it is compared.
  def self.normalize(value)
    clean(value).downcase
  end
end
