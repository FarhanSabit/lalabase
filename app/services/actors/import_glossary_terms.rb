# frozen_string_literal: true

# app/services/actors/import_glossary_terms.rb
#
# Imports many terms into the glossary of an organisation at once (K5), from
# the text of a textarea: one line per term, "Term" or "Term;Category", or
# term and category in two columns of a spreadsheet (a tab between them). The
# controller refuses a user without view_glossary before this runs; the actor
# checks no right, it only asks GlossaryPolicy which status a new term gets.
#
# * A line ends at CR LF, or at one of LF, CR, VT, FF, NEL, U+2028 and U+2029
#   (a paste from a word processor carries those). A line that is blank once
#   cleaned (GlossaryText.clean) is skipped; the others keep their number in
#   the input. Each is split at its first ";" or tab, whichever comes first,
#   and only then cleaned, since cleaning turns a tab into a space: the term
#   on the left, the category on the right.
#   More than MAX_LINES lines that are not blank, or none at all, refuse the
#   whole import before anything is read or written, in a dry run too.
# * The category is a key of GlossaryTerm::CATEGORIES or its display name in
#   a language of the app, compared as GlossaryText compares. Any other name
#   is no category, and the term still comes in.
# * A term that is blank or longer than GlossaryTerm::MAX_LENGTH is invalid.
#   A later line of a form already in the list is a duplicate: the first
#   spelling wins.
# * A term the organisation has (in any spelling of the same form, in any
#   status) is skipped and keeps its status: an import never confirms a
#   proposed or a rejected term. With manage_glossary such a term without a
#   category gets the one its line names.
# * A new term is confirmed with manage_glossary and proposed without, as
#   Actors::CorrectMeetingTerm decides (GlossaryPolicy.manage_allowed?), and
#   remembers who imported it. One that someone else created at the same
#   moment counts as existing, and the import goes on.
# * The one lock order of the glossary writes (Glossary::TermLock: the term
#   row first). The terms that get a category are locked before the first
#   new term is inserted, so the import never waits for the lock of a term
#   while it holds the index entries of its new terms. The other way round
#   it deadlocked with a rename of such a term into one of the new spellings
#   (review round 1 of #128). A term found only at its insert (created at
#   the same moment) is therefore not locked, and keeps the category it has.
# * One transaction for the whole import. A dry run takes the same path and
#   rolls it back at the end, as Subscriptions::OrganisationMove does: the
#   preview shows the numbers of the real import, not a guess at them.
# * All of it under the tenant of the organisation (ActsAsTenant.with_tenant,
#   as Glossary::Lookup reads), whatever tenant the caller has set. Under
#   another one the tenant scope hid the terms of the glossary, acts_as_tenant
#   wrote the new ones into that tenant, and the role GlossaryPolicy reads was
#   looked up there (review round 2 of #128).
#
# The outcome is #report, read after a successful #call: a Line for every line
# that is not blank, in the order of the input, and the counts. A Line names
# the category of its line (category) and whether the import gives it to the
# term (category_applied): true for a new term, and for a term the glossary
# has without one, with manage_glossary; false for a duplicate line, a term
# that keeps its own category and a term found only at its insert.
module Actors
  class ImportGlossaryTerms < BaseActor
    MAX_LINES = 500

    Report = Data.define(:lines, :counts)
    Line = Data.define(:number, :text, :term, :category, :category_applied, :verdict, :existing_status)

    # The verdict of a line, then what the import did: :new counts the terms
    # written (in a dry run: that would be written), :created and :proposed
    # split them by their status, :categorized counts terms the glossary had
    # that got the category of their line.
    VERDICTS = %i[new existing rejected duplicate invalid].freeze
    COUNTS = (VERDICTS + %i[created proposed categorized]).freeze

    # How a line ends: CR LF, as a textarea sends it, or one of LF, VT, FF,
    # CR, NEL, U+2028 and U+2029 alone (a manual line break of a word
    # processor is a VT).
    LINE_BREAK = /\r\n|[\n\v\f\r\u0085\u2028\u2029]/
    # What parts the term from its category: a ";" or a tab (two columns of a
    # spreadsheet), whichever comes first in the line.
    SEPARATOR = /[;\t]/
    CATEGORY_SCOPE = 'views.organisations.glossary.categories'

    # One line while it is imported; the report keeps a Line of it. form is
    # the compared form of the term (GlossaryText.normalize), existing the
    # term of that form the glossary has.
    Row = Struct.new(:number, :text, :term, :form, :category, :verdict, :existing, :categorized)
    private_constant :Row

    attr_reader :report

    # dry_run: true imports in a savepoint and rolls it back.
    def initialize(organisation:, text:, current_user:, dry_run: false)
      super()
      @organisation = organisation
      @text = text.to_s
      @current_user = current_user
      @dry_run = dry_run
    end

    def record
      @organisation
    end

    # Under the tenant of the organisation, never the caller's (header).
    def perform
      ActsAsTenant.with_tenant(@organisation) do
        lines = read_lines
        # requires_new: true is load-bearing. BaseActor#call runs this in a
        # transaction already; a block that joins it swallows the Rollback
        # without rolling anything back, and the dry run would write.
        ActiveRecord::Base.transaction(requires_new: true) do
          @report = import(lines)
          raise ActiveRecord::Rollback if @dry_run
        end
      end
    end

    private

    attr_reader :current_user

    def refuse(code)
      raise ActorError.new(I18n.t("controllers.glossary.import.#{code}", max: MAX_LINES), code: code)
    end

    # [number, line] of every line that is not blank once cleaned, the line
    # as it came: row_of splits it before it cleans it. Stops at the first
    # line over the limit: a long paste is not cleaned to its end.
    def read_lines
      lines = []
      @text.split(LINE_BREAK).each.with_index(1) do |raw, number|
        next if GlossaryText.clean(raw).empty?

        refuse(:too_many_lines) if lines.size == MAX_LINES
        lines << [number, raw]
      end
      refuse(:empty) if lines.empty?
      lines
    end

    # categorize before create_terms: the lock order (header).
    def import(lines)
      rows = lines.map { |number, raw| row_of(number, raw) }
      classify(rows.reject { |row| row.verdict == :invalid })
      categorize(rows) if manage?
      create_terms(rows.select { |row| row.verdict == :new })
      report_of(rows)
    end

    # Split first, then clean each part: cleaning turns a tab into a space,
    # and two columns of a spreadsheet came in as one term.
    def row_of(number, raw)
      text = GlossaryText.clean(raw)
      term, category = raw.split(SEPARATOR, 2).map { |part| GlossaryText.clean(part) }
      return Row.new(number: number, text: text, verdict: :invalid) if term.empty? || term.length > GlossaryTerm::MAX_LENGTH

      Row.new(number: number, text: text, term: term, form: GlossaryText.normalize(term), category: category_of(category))
    end

    # The first line of a form decides; a later one is a duplicate. The terms
    # of the organisation are read in one query.
    def classify(rows)
      known = existing_terms(rows.map(&:form).uniq)
      seen = Set.new
      rows.each do |row|
        if seen.include?(row.form)
          row.verdict = :duplicate
        elsif known[row.form]
          take_existing(row, known[row.form])
        else
          row.verdict = :new
        end
        seen << row.form
      end
    end

    # The terms of this organisation in these forms, by form. Another
    # organisation's terms are never read.
    def existing_terms(forms)
      terms.where(normalized_term: forms).index_by(&:normalized_term)
    end

    def take_existing(row, term)
      row.existing = term
      row.verdict = term.rejected? ? :rejected : :existing
    end

    # In the order of their form, not of the lines: two imports of
    # overlapping lists then wait for each other at their first common term,
    # instead of each holding a term the other one waits for (a deadlock).
    def create_terms(rows)
      status = manage? ? 'confirmed' : 'proposed'
      rows.sort_by(&:form).each { |row| create_term(row, status) }
    end

    # A term of the same form that someone else created at the same moment
    # (the validation that saw it, or the unique index that caught it) makes
    # the line one of an existing term, as in Actors::CorrectMeetingTerm. The
    # insert runs in a savepoint, so the index refusal leaves the transaction
    # of the import usable.
    def create_term(row, status)
      term = GlossaryTerm.new(organisation: @organisation, term: row.term, category: row.category, status: status,
                              created_by: current_user)
      return take_existing(row, term_of_the_same_form(row)) if term.invalid? && term.errors.of_kind?(:term, :taken)
      raise ActiveRecord::RecordInvalid, term if term.errors.any?

      GlossaryTerm.transaction(requires_new: true) { term.save!(validate: false) }
    rescue ActiveRecord::RecordNotUnique
      take_existing(row, term_of_the_same_form(row))
    end

    def term_of_the_same_form(row)
      terms.find_by!(normalized_term: row.form)
    end

    # With manage_glossary only, before the first insert (the lock order in
    # the header). The terms are locked in one statement in the order of
    # their ids (as Actors::MergeGlossaryTerms locks) and read again under the
    # lock: a term that got a category in the meantime keeps it, and one
    # deleted in the meantime is left out.
    def categorize(rows)
      wanted = rows.select { |row| row.existing && row.category && row.existing.category.nil? }
      return if wanted.empty?

      locked = terms.where(id: wanted.map { |row| row.existing.id }).order(:id).lock.index_by(&:id)
      wanted.each do |row|
        term = locked[row.existing.id]
        next if term.nil? || term.category

        term.update!(category: row.category)
        row.categorized = true
      end
    end

    def report_of(rows)
      counts = COUNTS.index_with(0)
      rows.each { |row| counts[row.verdict] += 1 }
      # Every new term got the same status (create_terms).
      counts[manage? ? :created : :proposed] = counts[:new]
      counts[:categorized] = rows.count(&:categorized)
      lines = rows.map do |row|
        Line.new(number: row.number, text: row.text, term: row.term, category: row.category,
                 category_applied: category_applied?(row), verdict: row.verdict, existing_status: row.existing&.status)
      end
      Report.new(lines: lines.freeze, counts: counts.freeze)
    end

    # The term has the category of its line through this import: a new term
    # written with it, or a term the glossary has that got it (categorize).
    def category_applied?(row)
      return false if row.category.nil?

      row.verdict == :new || row.categorized == true
    end

    # A key, or a display name in a language of the app; anything else is nil.
    def category_of(text)
      category_names[GlossaryText.normalize(text)] if text.present?
    end

    # Every way to name a category, by compared form. The keys go first, so
    # a key always means itself; then the display name in each language.
    def category_names
      @category_names ||= begin
        names = GlossaryTerm::CATEGORIES.index_by { |key| GlossaryText.normalize(key) }
        I18n.available_locales.product(GlossaryTerm::CATEGORIES).each do |locale, key|
          name = GlossaryText.normalize(I18n.t(key, scope: CATEGORY_SCOPE, locale: locale, default: ''))
          names[name] ||= key unless name.empty?
        end
        names
      end
    end

    # Asked once per import.
    def manage?
      return @manage if defined?(@manage)

      @manage = GlossaryPolicy.manage_allowed?(current_user, @organisation)
    end

    def terms
      GlossaryTerm.where(organisation_id: @organisation.id)
    end
  end
end
