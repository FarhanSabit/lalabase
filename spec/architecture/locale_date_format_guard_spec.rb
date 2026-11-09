# frozen_string_literal: true

require 'rails_helper'

# Guard: a date on a page is written in the reader's language, through I18n.
#
# strftime knows one language. Its month and day names are English on every page, and
# a format a person typed into the code ("%d.%m.%Y") is German on every page. Both
# reached readers: until 17.10.2026 the knowledge list said "14 Oct 2026" on the German
# page, and the open note still says "07.10.2026" on the English one. Each fix was one
# line, and each was found by looking at a page, not by a test.
#
# The rule: a date goes through l() with a named format (date.formats / time.formats
# in config/locales), and the locale files say what the reader expects. A literal
# format survives only where it means the same in every language:
#
# | Call | Allowed literal format |
# |---|---|
# | strftime(...) | ISO date and clock only: "%Y-%m-%d", "%H:%M", "%Y-%m-%dT%H:%M", " UTC" |
# | l(..., format: ...) | the same, and month or day names alone: "%B", "%B %Y", "%a" (I18n translates the names) |
#
# A day next to a month ("%d.%m.", "%d. %B", "%m/%Y"), a name through strftime, and a
# word in the format ("um", "at") are what this guard rejects.
#
# What it reads: the templates, components and helpers a reader of the application
# sees. Not the admin area (its own styleguide, run by the operator) and not the style
# guide. Not models, services or jobs: strftime there mostly names a file, a log line
# or an API value, and the few that reach a page (Overview::TimePeriod) are for the
# person who reads the diff.
#
# ⚠️ A format held in a variable is not seen. The one place that does it on purpose
# is display_time, display_time_split and display_date in ApplicationHelper: they print
# the format the reader chose in their own settings ("german", "international",
# custom), which is the reader's language by definition.
#
# The legacy list is what the files carried on 18.10.2026, per file and count, and it
# may only shrink, like the page width guard: a file below its count fails as well.
module LocaleDateFormatGuard
  SCOPE = %w[app/views/**/*.erb app/components/**/*.{rb,erb} app/helpers/**/*.rb].freeze
  OUT_OF_SCOPE = %r{\Aapp/(?:views/admin/|views/layouts/admin/|views/style_guide/|views/layouts/style_guide|components/admin/|helpers/admin/)}

  ISO = /\A(?:%Y(?:-%m(?:-%d)?)?)?(?:[ T]?%H:%M(?::%S)?)?(?: UTC)?\z/
  NAMES_ONLY = /\A%[BbAa](?: %Y)?\z/

  STRFTIME = /\bstrftime\(\s*(['"])(.*?)\1\s*\)/
  LOCALIZE = /\b(?:I18n\.)?l(?:ocalize)?\(.*?\bformat:\s*(['"])(.*?)\1/

  module_function

  def files
    paths = SCOPE.flat_map { |glob| Dir[Rails.root.join(glob)] }
    relative = paths.map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
    relative.reject! { |path| path.match?(OUT_OF_SCOPE) }
    relative.sort!
  end

  def offenders(path) = offenders_in(File.read(Rails.root.join(path)))

  def offenders_in(source)
    code = strip_comments(source)
    strftime = code.scan(STRFTIME).filter_map { |_, format| format unless neutral?(format) }
    localize = code.scan(LOCALIZE).filter_map { |_, format| format unless neutral?(format) || format.match?(NAMES_ONLY) }
    strftime.map { |format| "strftime(#{format.inspect})" } + localize.map { |format| "l(format: #{format.inspect})" }
  end

  def neutral?(format) = format.empty? || format.match?(ISO)

  # <%# ... %> and Ruby comment lines: a comment that names a format is not a call.
  def strip_comments(source) = source.gsub(/<%#.*?%>/m, '').lines.grep_v(/\A\s*#/).join
end

RSpec.describe 'locale date format guard' do
  # Shrink-only: path => number of language-bound formats on 18.10.2026. Lower the
  # count when a file moves to l() with a named format, delete the line at zero.
  let(:legacy) do
    {
      'app/components/dashboard/recent_notes_component.html.erb' => 1,
      'app/components/dashboard/recent_tickets_component.html.erb' => 3,
      'app/components/dashboard/smart_folder_tickets_component.html.erb' => 1,
      'app/components/dashboard/time_tracking_component.html.erb' => 2,
      'app/components/neo_activity_filter_component.rb' => 5,
      'app/components/neo_activity_timeline_component.rb' => 1,
      'app/components/neo_time_session_component.rb' => 1,
      'app/components/objekt_navigation_component.html.erb' => 1,
      'app/components/overview/projects_table_component.html.erb' => 1,
      'app/helpers/application_helper.rb' => 3,
      'app/helpers/tickets_helper.rb' => 4,
      'app/views/organisations/ai_sync_statuses/show.html.erb' => 1,
      'app/views/organisations/codebase_import_files/_import_files_table.html.erb' => 1,
      'app/views/organisations/codebase_import_files/assign_uploads.html.erb' => 1,
      'app/views/organisations/codebase_import_files/preview_time_sessions.html.erb' => 3,
      'app/views/organisations/codebase_import_files/rollback.html.erb' => 1,
      'app/views/organisations/codebase_import_files/select_project.html.erb' => 1,
      'app/views/organisations/codebase_import_files/show.html.erb' => 4,
      'app/views/organisations/notes/_note_show.html.erb' => 1,
      'app/views/organisations/project_repositories/index_runs.html.erb' => 1,
      'app/views/organisations/time_session_groups/_activities.html.erb' => 1,
      'app/views/organisations/time_session_groups/_groups_list.html.erb' => 3,
      'app/views/organisations/time_session_groups/_header.html.erb' => 3,
      'app/views/organisations/time_session_groups/aggregated.html.erb' => 2,
      'app/views/organisations/time_session_groups/billing_status.html.erb' => 1,
      'app/views/organisations/time_session_groups/chronological.html.erb' => 1,
      'app/views/organisations/time_session_groups/customer_export.html.erb' => 1,
      'app/views/shared/ai/_quota_history.html.erb' => 1
    }
  end

  let(:findings) { LocaleDateFormatGuard.files.index_with { |path| LocaleDateFormatGuard.offenders(path) } }

  it 'reads the templates, components and helpers it claims to read' do
    files = LocaleDateFormatGuard.files

    expect(files).to include('app/helpers/application_helper.rb',
                             'app/views/organisations/notes/_note_show.html.erb',
                             'app/components/neo_activity_filter_component.rb')
    expect(files.grep(%r{/admin/})).to be_empty
  end

  it 'tells a language-bound format from a neutral one' do
    neutral = ["strftime('%Y-%m-%d %H:%M:%S UTC')", "strftime('%H:%M')", "l(at, format: '%B %Y')",
               "l(at, format: '%Y-%m-%dT%H:%M')", 'l(at, format: :long)', 'strftime(format)',
               "# strftime('%d.%m.%Y')", "<%# l(at, format: '%d.%m.') %>"]
    bound = ["strftime('%d.%m.%Y')", "strftime('%B %d, %Y')", "l(at, format: '%d. %B %Y')",
             "strftime('%d.%m.%Y um %H:%M')", 'strftime("%m/%Y")', "I18n.l(at, format: '%d.%m.')"]

    expect(neutral.map { |line| LocaleDateFormatGuard.offenders_in(line) }).to all(be_empty)
    expect(bound.map { |line| LocaleDateFormatGuard.offenders_in(line) }).to all(be_present)
  end

  it 'finds no language-bound date format beyond the legacy list' do
    over = findings.filter_map do |path, found|
      allowed = legacy.fetch(path, 0)
      "  #{path}: #{found.size} found, #{allowed} allowed: #{found.join(', ')}" if found.size > allowed
    end

    expect(over).to be_empty, <<~MSG
      A template, component or helper writes a date in a fixed language. Use l() with a
      named format (date.formats / time.formats in config/locales/de.yml and en.yml), or
      add a named format there when none fits. A literal format is allowed only when it
      reads the same in every language: ISO dates and the clock, or month and day names
      alone through l().

      #{over.join("\n")}
    MSG
  end

  it 'keeps the legacy list honest: a fixed file takes its line off the list' do
    stale = legacy.filter_map do |path, allowed|
      count = findings.fetch(path, []).size
      "  #{path}: listed #{allowed}, the file has #{count}" if count < allowed
    end

    expect(stale).to be_empty, <<~MSG
      The legacy list allows more language-bound formats than a file still has. Lower
      the count, or delete the line at zero.

      #{stale.join("\n")}
    MSG
  end
end
