# frozen_string_literal: true

# app/services/actors/import_glossary_terms.rb
#
# Imports many terms into the glossary of an organisation at once (K5), from
# the text of a textarea: one line per term, "Term" or "Term;Category". The
# controller refuses a user without view_glossary before this runs; the actor
# checks no right, it only asks GlossaryPolicy which status a new term gets.
#
# * Each line is cleaned (GlossaryText.clean) and split at its first ";": the
#   term on the left, the category on the right, each cleaned again. A line
#   that is blank then is skipped; the others keep their number in the input.
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
# * One transaction for the whole import. A dry run takes the same path and
#   rolls it back at the end, as Subscriptions::OrganisationMove does: the
#   preview shows the numbers of the real import, not a guess at them.
#
# The outcome is #report, read after a successful #call: a Line for every line
# that is not blank, in the order of the input, and the counts.
module Actors
  class ImportGlossaryTerms < BaseActor
    MAX_LINES = 500

    Report = Data.define(:lines, :counts)
    Line = Data.define(:number, :text, :term, :category, :verdict, :existing_status)

    # The verdict of a line, then what the import did: :new counts the terms
    # written (in a dry run: that would be written), :created and :proposed
    # split them by their status, :categorized counts terms the glossary had
    # that got the category of their line.
    VERDICTS = %i[new existing rejected duplicate invalid].freeze
    COUNTS = (VERDICTS + %i[created proposed categorized]).freeze

    # How a textarea ends a line: CR LF, or one of the two alone.
    LINE_BREAK = /\r\n|\r|\n/
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

    def perform
      lines = read_lines
      # requires_new: true is load-bearing. BaseActor#call runs this in a
      # transaction already; a block that joins it swallows the Rollback
      # without rolling anything back, and the dry run would write.
      ActiveRecord::Base.transaction(requires_new: true) do
        @report = import(lines)
        raise ActiveRecord::Rollback if @dry_run
      end
    end

    private

    attr_reader :current_user

    def refuse(code)
      raise ActorError.new(I18n.t("controllers.glossary.import.#{code}", max: MAX_LINES), code: code)
    end

    # [number, text] of every line that is not blank once cleaned. Stops at
    # the first line over the limit: a long paste is not cleaned to its end.
    def read_lines
      lines = []
      @text.split(LINE_BREAK).each.with_index(1) do |raw, number|
        text = GlossaryText.clean(raw)
        next if text.empty?

        refuse(:too_many_lines) if lines.size == MAX_LINES
        lines << [number, text]
      end
      refuse(:empty) if lines.empty?
      lines
    end

    def import(lines)
      rows = lines.map { |number, text| row_of(number, text) }
      classify(rows.reject { |row| row.verdict == :invalid })
      create_terms(rows.select { |row| row.verdict == :new })
      categorize(rows) if manage?
      report_of(rows)
    end

    def row_of(number, text)
      term, category = text.split(';', 2).map { |part| GlossaryText.clean(part) }
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

    # With manage_glossary only. The terms are locked in one statement in the
    # order of their ids (as Actors::MergeGlossaryTerms locks) and read again
    # under the lock: a term that got a category in the meantime keeps it,
    # and one deleted in the meantime is left out.
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
        Line.new(number: row.number, text: row.text, term: row.term, category: row.category, verdict: row.verdict,
                 existing_status: row.existing&.status)
      end
      Report.new(lines: lines.freeze, counts: counts.freeze)
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
