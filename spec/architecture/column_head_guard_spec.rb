# frozen_string_literal: true

require 'rails_helper'

# Guard: the head of a column has one look, and one owner, the class
# .column-head (application.tailwind.css; F43 of the Belegungstabelle,
# doc/belegungstabelle_oberflaeche.md): small mono capitals in the muted tone.
#
# Until 2026-11-11 every template wrote that look out by hand. The copies had
# drifted into five looks in twenty files (mono or sans, 11px or text-xs, grey
# 500, cream-600 or nearly black, four paddings), layout.css set the type of
# the list tables a second time, and the people list had a look of its own.
# The user saw it as "the table heads of Personen are not right".
#
# What this holds:
#   A. Every head cell of a table (a <th> inside <thead>) in a template or a
#      component carries column-head. The cells without it per file stand in
#      HEAD_LEGACY, which may only shrink (90 cells in 18 files when the
#      class came, 2 by the end of the same day).
#      One exception, by decision (user, 2026-11-11): the head of a matrix
#      that names a thing (a project of the access matrix, a role of the
#      roles matrix) is a name, not the label of a column, and keeps its own
#      look. It says so with data-matrix-head, and only the files of
#      MATRIX_FILES may say it, so the attribute is no way around the class.
#   B. The recipe of the column head (font-mono, text-[11px], uppercase and
#      tracking-wider in one class list) is written nowhere but in
#      .column-head: not in a template, a component, a helper or a
#      stylesheet. The copies per file stand in RECIPE_LEGACY, which may only
#      shrink. Two of them are no column heads but labels of the same look; a
#      label gets a row of its own in the Belegungstabelle before it moves.
#
# Not read: app/views/admin/ (its own style guide, decided 2026-06-01) and
# app/views/style_guide/ (it shows samples).
# Not seen: a class list put together at run time from parts; a <th> in a
# partial that is rendered into a <thead> elsewhere (shared/_sortable_header);
# a head of a list that is no table and writes another look than the recipe
# (the flex heads of the time groups wear the recipe and are held by B). It is
# a tripwire, not a proof.
#
# It runs through the directory entry spec/architecture/ of the CI guard list.
module ColumnHeads
  ROOTS = %w[app/views app/components app/helpers].freeze
  UNREAD = %r{\Aapp/views/(admin|style_guide)/}
  STYLESHEETS = 'app/assets/stylesheets'
  RECIPE = %w[font-mono text-[11px] uppercase tracking-wider].freeze
  OWNER = '.column-head'
  ERB_MARKS = ['<%', '%>'].freeze

  # Head cells without column-head, per file, on 2026-11-11. Only shrinks:
  # a file that moves to the class lowers its entry, a count too high is red
  # as well. Left are the tag pages, which no navigation links to and which
  # raise as soon as an organisation has a tag (url_for with a hash in
  # shared/_sortable_header): repair or removal is a decision of its own.
  HEAD_LEGACY = {
    'app/views/organisations/tags/index.html.erb' => 2
  }.freeze

  # The recipe written out, per file, on 2026-11-11. Only shrinks.
  RECIPE_LEGACY = {
    # Labels of the same look, no column heads: the group words of the bulk
    # edit menu and the figure labels of a billing.
    'app/views/organisations/tickets/bulk_edit.html.erb' => 1,
    'app/views/organisations/time_session_groups/_header.html.erb' => 1
  }.freeze

  # The matrices, whose heads name a thing (data-matrix-head). Closed.
  MATRIX_FILES = %w[
    app/views/organisations/access_matrix/index.html.erb
    app/views/organisations/roles/index.html.erb
  ].freeze

  module_function

  def files
    ROOTS.flat_map { |root| Dir[Rails.root.join(root, '**', '*.{erb,rb}')] }
         .map { |path| relative(path) }
         .reject { |path| path.match?(UNREAD) }
         .sort
  end

  def read(path) = Rails.root.join(path).read

  def relative(path) = Pathname(path).relative_path_from(Rails.root).to_s

  # The opening tags of the <th> cells inside each <thead>. A tag ends at the
  # first ">" outside an ERB tag, so `<th data-x="<%= y %>">` is one tag.
  def head_cells(text)
    text.scan(%r{<thead\b.*?</thead>}m).flat_map do |head|
      head.to_enum(:scan, /<th\b/).map { opening_tag(head, Regexp.last_match.begin(0)) }
    end
  end

  def opening_tag(text, start)
    index = start
    in_erb = false
    while index < text.length
      pair = text[index, 2]
      if ERB_MARKS.include?(pair)
        in_erb = pair == '<%'
        index += 2
        next
      end
      return text[start..index] if text[index] == '>' && !in_erb

      index += 1
    end
    text[start..]
  end

  def class_words(tag)
    value = tag[/\sclass="([^"]*)"/m, 1].to_s
    value.gsub(/<%.*?%>/m, ' ').split
  end

  def heads_without_class(text)
    head_cells(text).count { |tag| !class_words(tag).include?('column-head') && !matrix_head?(tag) }
  end

  def matrix_head?(tag) = tag.match?(/\sdata-matrix-head[\s>=]/)

  # Every quoted string (one line) whose words hold the whole recipe.
  def recipe_copies(text)
    text.scan(/"([^"\n]*)"|'([^'\n]*)'/).count do |double, single|
      words = (double || single).gsub(/<%.*?%>/, ' ').split
      (RECIPE - words).empty?
    end
  end

  # @apply lines of the stylesheets that hold the whole recipe, with their
  # selector; the owner's own line is the one allowed.
  def stylesheet_copies
    Dir[Rails.root.join(STYLESHEETS, '**', '*.css')].sort.flat_map do |path|
      File.readlines(path).filter_map do |line|
        next unless line.include?('@apply') && (RECIPE - line.scan(/[^\s;{}]+/)).empty?

        "#{relative(path)}: #{line.strip}"
      end
    end
  end

  def counts(&counter)
    files.index_with { |path| counter.call(read(path)) }.select { |_path, count| count.positive? }
  end

  def over_legacy(found, legacy)
    found.filter_map { |path, count| "#{path}: #{count} (allowed #{legacy.fetch(path, 0)})" if count > legacy.fetch(path, 0) }
  end

  def stale_legacy(found, legacy)
    legacy.filter_map { |path, allowed| "#{path}: #{found.fetch(path, 0)} (listed #{allowed})" if found.fetch(path, 0) < allowed }
  end
end

RSpec.describe 'column head guard' do
  describe 'A: the head cells of a table' do
    let(:found) { ColumnHeads.counts { |text| ColumnHeads.heads_without_class(text) } }

    it 'carry column-head, beyond the legacy entry of their file' do
      offenders = ColumnHeads.over_legacy(found, ColumnHeads::HEAD_LEGACY)

      expect(offenders).to be_empty, <<~MSG
        A head cell of a table (<th> in <thead>) without the class column-head:
          #{offenders.join("\n  ")}
        Give it class="column-head ..." and keep only its padding and alignment;
        the type is the class's (F43). Do not raise the legacy entry.
      MSG
    end

    it 'keep the legacy list honest: an entry falls with its cells' do
      stale = ColumnHeads.stale_legacy(found, ColumnHeads::HEAD_LEGACY)

      expect(stale).to be_empty, <<~MSG
        HEAD_LEGACY allows more head cells without column-head than a file still has.
        Lower the entry, or remove it at zero:
          #{stale.join("\n  ")}
      MSG
    end

    it 'name a thing as a matrix head only in the matrices' do
      marked = ColumnHeads.files.select { |path| ColumnHeads.read(path).include?('data-matrix-head') }

      expect(marked).to match_array(ColumnHeads::MATRIX_FILES)
      ColumnHeads::MATRIX_FILES.each do |path|
        cells = ColumnHeads.head_cells(ColumnHeads.read(path))
        expect(cells.count { |tag| ColumnHeads.matrix_head?(tag) }).to be >= 2, path
      end
    end

    it 'are read at all: the heads of the tickets, the meetings and Wissen, with the class' do
      %w[app/views/organisations/tickets/_tickets_results.html.erb
         app/views/organisations/meetings/_meetings_table.html.erb
         app/views/organisations/knowledge/_knowledge_results.html.erb].each do |path|
        cells = ColumnHeads.head_cells(ColumnHeads.read(path))
        expect(cells).not_to be_empty, path
        expect(cells.map { |tag| ColumnHeads.class_words(tag) }).to all(include('column-head')), path
      end
      expect(ColumnHeads.files.size).to be > 500
    end
  end

  describe 'B: the recipe of the column head' do
    let(:found) { ColumnHeads.counts { |text| ColumnHeads.recipe_copies(text) } }

    it 'is written out nowhere beyond the legacy entry of a file' do
      offenders = ColumnHeads.over_legacy(found, ColumnHeads::RECIPE_LEGACY)

      expect(offenders).to be_empty, <<~MSG
        The column head written out by hand (#{ColumnHeads::RECIPE.join(' ')}):
          #{offenders.join("\n  ")}
        Use the class column-head instead. Do not raise the legacy entry.
      MSG
    end

    it 'keeps the legacy list honest: an entry falls with its copies' do
      stale = ColumnHeads.stale_legacy(found, ColumnHeads::RECIPE_LEGACY)

      expect(stale).to be_empty, <<~MSG
        RECIPE_LEGACY allows more copies than a file still has. Lower the entry, or remove it at zero:
          #{stale.join("\n  ")}
      MSG
    end

    it 'stands in a stylesheet only as the class itself' do
      copies = ColumnHeads.stylesheet_copies

      expect(copies.size).to eq(1), "the recipe through @apply outside .column-head:\n  #{copies.join("\n  ")}"
      expect(copies.first).to include("app/assets/stylesheets/application.tailwind.css: #{ColumnHeads::OWNER} {")
    end
  end

  describe 'the readers' do
    it 'take a head tag whole, ERB inside its attributes included' do
      text = <<~ERB
        <table><thead><tr>
          <th scope="col" data-x="<%= a > b %>" class="column-head py-3 <%= extra %>">A</th>
          <th class="py-3 text-[11px]">B</th>
        </tr></thead><tbody><tr><th>row</th></tr></tbody></table>
      ERB

      expect(ColumnHeads.head_cells(text).size).to eq(2)
      expect(ColumnHeads.heads_without_class(text)).to eq(1)
    end

    it 'take a head marked as a matrix head for one with the class' do
      text = '<table><thead><tr><th class="am-colhead" data-matrix-head>P</th><th class="x">Q</th></tr></thead></table>'

      expect(ColumnHeads.heads_without_class(text)).to eq(1)
    end

    it 'find the recipe in any order, in single and double quotes, and nothing short of it' do
      expect(ColumnHeads.recipe_copies(%(<div class="uppercase text-[11px] x tracking-wider font-mono">))).to eq(1)
      expect(ColumnHeads.recipe_copies(%(labels = 'font-mono text-[11px] uppercase tracking-wider'))).to eq(1)
      expect(ColumnHeads.recipe_copies(%(<span class="font-mono text-xs uppercase tracking-wider">))).to eq(0)
      expect(ColumnHeads.recipe_copies(%(<span class="column-head">))).to eq(0)
    end
  end
end
