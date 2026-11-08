# frozen_string_literal: true

require 'rails_helper'

# Guard: a hard offset shadow means one thing in the application, "press me".
#
# A hard offset shadow is a shadow with an offset and no blur. It stands in three places
# only: on the main action (Neo::Buttons, the tokens shadow-press and shadow-press-hover),
# on a card that is wholly a link or a button while it is hovered (NeoCardComponent with
# shadow: :hover, the token shadow-lift), and on the logo tile. Anywhere else it says
# "press me" about something that cannot be pressed. The dark theme has no hard shadow at
# all. Source: rule 5 of the Belegungstabelle (doc/belegungstabelle_oberflaeche.md) and
# doc/schatten_stufen_plan.md.
#
# What this holds:
#   A. Written values (shadow-[2px_2px_0_...]) in templates, components, scripts, helpers
#      and services: the count per file on 2026-11-08, which may only shrink.
#   B. The three named hard tokens of config/tailwind.config.js stay with their owners.
#   C. Hard shadows declared in stylesheets: a closed list of file and selector.
#   D. Each of them, token or stylesheet rule, is turned off in the dark theme, and the
#      rule that turns off every written value is still there.
#
# It runs through the directory entry spec/architecture/ of the CI guard list.
#
# What it does NOT see: a shadow built at run time (a class put together from parts, a
# style set by a script), a shadow through a CSS variable, a token used through @apply in
# a stylesheet (rule B reads templates, Ruby and scripts), soft shadows (shadow-sm and the
# like), and the role of an element. A panel that gets shadow-lift in an owner's file
# passes here; that is for the person who reads the diff.
module ShadowLevels
  STYLESHEETS = Rails.root.join('app/assets/stylesheets')
  TAILWIND_CONFIG = Rails.root.join('config/tailwind.config.js')

  # Rules A and B read these directories, files ending in .erb, .rb and .js.
  APP_DIRS = %w[app/views app/components app/javascript app/helpers app/services].freeze
  APP_FILES = '**/*.{erb,rb,js}'

  # A written hard value: shadow-[Xpx_Ypx_0...], a blur of 0 after two offsets.
  WRITTEN_HARD = /shadow-\[-?\d+px_-?\d+px_0/

  # Rule A only. Rule B reads these directories as well.
  WRITTEN_EXCLUDED = {
    'app/views/admin/' => 'the admin area has a style guide of its own (owner decision 2026-06-01)',
    'app/views/style_guide/' => 'shows samples; brought in line in its own slice, S5'
  }.freeze

  # Shrink only: path => written hard values on 2026-11-08. Lower the count when a value
  # goes, delete the line when it reaches zero.
  LEGACY = {
    'app/components/neo/chat/transparency_notice_component.html.erb' => 1,
    'app/components/neo_card_component.rb' => 1, # shadow: :always, removed in slice S3
    'app/components/neo_notification_filter_component.html.erb' => 1,
    'app/javascript/controllers/attribute_form_controller.js' => 2,
    'app/javascript/controllers/neo_form_section_controller.js' => 4,
    'app/javascript/controllers/tag_input_controller.js' => 3,
    'app/javascript/controllers/time_session_form_controller.js' => 1,
    'app/services/notifications/broadcast_service.rb' => 1,
    'app/views/billing_accounts/index.html.erb' => 1,
    'app/views/billing_accounts/show.html.erb' => 2,
    'app/views/common/_button_container_standard_edit_form.html.erb' => 5,
    'app/views/common/_global_search_form.html.erb' => 3,
    'app/views/common/_navigation_application.html.erb' => 4,
    'app/views/common/_sidebar_project_list.html.erb' => 2,
    'app/views/common/_upgrade_box.html.erb' => 3,
    'app/views/devise/shared/_error_messages.html.erb' => 1,
    'app/views/layouts/_assistant_panel.html.erb' => 2,
    'app/views/layouts/_contextual_help_drawer.html.erb' => 1,
    'app/views/layouts/_global_search_overlay.html.erb' => 1,
    'app/views/layouts/_personal_tasks_drawer.html.erb' => 1,
    'app/views/layouts/_session_timeout.html.erb' => 1,
    'app/views/layouts/application.html.erb' => 1,
    'app/views/layouts/application_sessionless.html.erb' => 4,
    'app/views/notifications/_notification.html.erb' => 2,
    'app/views/organisations/_cockpit_settings_modal.html.erb' => 2,
    'app/views/organisations/_organisation_tiles.html.erb' => 4, # clickable tiles, may move to shadow-lift later
    'app/views/organisations/ai_protocols/show.html.erb' => 1,
    'app/views/organisations/ai_settings/_package_card.html.erb' => 1,
    'app/views/organisations/ai_settings/_package_chooser.html.erb' => 1,
    'app/views/organisations/ai_settings/confirm_package.html.erb' => 1,
    'app/views/organisations/ai_sync_statuses/_summary.html.erb' => 1,
    'app/views/organisations/appearances/_color_swatch.html.erb' => 2,
    'app/views/organisations/briefings/_onboarding_banner.html.erb' => 2,
    'app/views/organisations/changelog/show.html.erb' => 1,
    'app/views/organisations/codebase_import_files/show.html.erb' => 1,
    'app/views/organisations/meetings/_transcript_section.html.erb' => 1,
    'app/views/organisations/personal_tasks/_form.html.erb' => 1,
    'app/views/organisations/project_repositories/index_runs.html.erb' => 1,
    'app/views/organisations/shared/_ai_disabled_notice.html.erb' => 1,
    'app/views/organisations/smart_folders/_modal_form.html.erb' => 1,
    'app/views/organisations/smart_folders/edit.html.erb' => 1,
    'app/views/organisations/smart_folders/new.html.erb' => 1,
    'app/views/organisations/ticket_attribute_definitions/merge_option.html.erb' => 1,
    'app/views/organisations/tickets/_detail_settings_modal.html.erb' => 1,
    'app/views/organisations/tickets/_timeline_frame_content.html.erb' => 1,
    'app/views/organisations/time_sessions/index.html.erb' => 1,
    'app/views/shared/_brand_mark.html.erb' => 1, # the logo tile, as on the website; not a token
    'app/views/shared/_pagination_nav.html.erb' => 2,
    'app/views/shared/_pagination_nav_compact.html.erb' => 2,
    'app/views/users/personal_access_tokens/created.html.erb' => 1,
    'app/views/users/personal_access_tokens/edit.html.erb' => 2,
    'app/views/users/personal_access_tokens/new.html.erb' => 5
  }.freeze

  # The hard tokens of config/tailwind.config.js, all drawn from --ink.
  HARD_TOKENS = {
    'press' => '2px 2px 0 0 rgb(var(--ink))',
    'press-hover' => '3px 3px 0 0 rgb(var(--ink))',
    'lift' => '4px 4px 0 0 rgb(var(--ink))'
  }.freeze

  PRESS_USERS = {
    'app/components/neo/buttons/base.rb' => 'the main action: shadow-press at rest, shadow-press-hover on hover'
  }.freeze

  LIFT_USERS = {
    'app/components/neo_card_component.rb' => 'shadow: :hover, a card that is wholly a link or a button, lifted while hovered'
  }.freeze

  # token group => its owners. Rule B reads the admin area and the style guide too: a
  # token name is a promise about the role wherever it stands.
  OWNER_GROUPS = { %w[press press-hover] => PRESS_USERS, %w[lift] => LIFT_USERS }.freeze
  TOKEN_OWNERS = OWNER_GROUPS.flat_map { |tokens, owners| tokens.map { [_1, owners] } }.to_h.freeze

  # Rule C reads every stylesheet but these (relative to app/assets/stylesheets; a name
  # ending in / is a directory).
  CSS_EXCLUDED = {
    'landing_tokens.css' => 'a mirror of the website, held by spec/architecture/auth_styles_guard_spec.rb',
    'lp_base.css' => 'a mirror of the website, held by spec/architecture/auth_styles_guard_spec.rb',
    'auth.css' => 'the website sign-in styles plus an appendix, held by spec/architecture/auth_styles_guard_spec.rb',
    'bootstrap-icons/' => 'the vendored icon font'
  }.freeze

  # Shrink only: file (relative to app/assets/stylesheets) => { selector => reason }.
  CSS_HARD = {
    'application.tailwind.css' => {
      '.members-invite' => 'a CSS main action, the invite button of the members page'
    },
    'components/mobile_app.css' => {
      '.mobile-primary' => 'the main action of the mobile layout'
    },
    'layout.css' => {
      '.kanban-card.kanban-carried' => 'legacy: the board card while it is carried'
    },
    'slim_select_overrides.css' => {
      '.ss-main:hover' => 'legacy: a SlimSelect state; a later slice decides',
      '.ss-main:focus' => 'legacy: a SlimSelect state; a later slice decides',
      '.ss-main.ss-open' => 'legacy: a SlimSelect state; a later slice decides',
      '.ss-content' => 'legacy: the SlimSelect dropdown; a later slice decides',
      '.ss-search input:focus' => 'legacy: a SlimSelect state; a later slice decides'
    },
    'views.css' => {
      '.attr-defs-sortable .sortable-chosen' => 'legacy: the row being dragged',
      '#ticket-index-container .ticket-bulk-panel .tbp-dialog' => 'legacy: the bulk dialog, a floating layer that goes soft in slice S2'
    }
  }.freeze

  # Carries every written value in the dark theme.
  DARK_WRITTEN_VALUES = '.dark [class*="shadow-["] { box-shadow: none !important; }'

  LENGTH = /\A[-+]?(?:\d+(?:\.\d+)?|\.\d+)(?:[a-z]+|%)?\z/i
  IMPORTANT = /\s*!\s*important\s*\z/i

  # One declaration of a stylesheet, with the selector list of its innermost block.
  Declaration = Data.define(:file, :line, :selectors, :property, :value) do
    def box_shadow? = property == 'box-shadow'
    def important? = value.match?(IMPORTANT)
    def hard? = box_shadow? && ShadowLevels.hard?(value)
    def off? = box_shadow? && value.sub(IMPORTANT, '').strip.casecmp?('none')
  end

  # Reads rule blocks with nesting (@layer, @media). Braces and semicolons inside quotes
  # or parentheses are text.
  class StylesheetParser
    def initialize(css, file)
      @text = ShadowLevels.blank_comments(css)
      @file = file
    end

    def declarations
      @preludes = []
      @found = []
      @buffer = +''
      @start = nil
      @line = 1
      @quote = nil
      @depth = 0
      @escape = false
      @text.each_char { |char| read(char) }
      @found
    end

    private

    def read(char)
      if structural?(char)
        close(char)
      else
        @start ||= @line unless char.match?(/\s/)
        @buffer << char
        track(char)
      end
      @line += 1 if char == "\n"
    end

    def structural?(char) = !@escape && @quote.nil? && @depth.zero? && '{;}'.include?(char)

    def track(char)
      if @escape then @escape = false
      elsif char == '\\' then @escape = true
      elsif @quote then @quote = nil if char == @quote
      elsif ['"', "'"].include?(char) then @quote = char
      elsif char == '(' then @depth += 1
      elsif char == ')' && @depth.positive? then @depth -= 1
      end
    end

    def close(char)
      case char
      when '{' then @preludes.push(ShadowLevels.split_outside(@buffer) { _1 == ',' })
      when ';' then record
      when '}'
        record
        @preludes.pop
      end
      @buffer = +''
      @start = nil
    end

    def record
      return if @preludes.empty?

      match = @buffer.strip.match(/\A([\w-]+)\s*:\s*(.*)\z/m)
      return unless match

      @found << Declaration.new(file: @file, line: @start, selectors: @preludes.last,
                                property: match[1].downcase, value: match[2].strip.gsub(/\s+/, ' '))
    end
  end

  module_function

  def relative(path, root = Rails.root) = Pathname.new(path).relative_path_from(root).to_s

  # Every file rule B reads, relative path => text.
  def app_texts
    APP_DIRS.flat_map { |dir| Dir[Rails.root.join(dir, APP_FILES).to_s] }.uniq.sort
            .to_h { |path| [relative(path), File.read(path)] }
  end

  # Every file rule A reads, relative path => number of written hard values.
  def written_counts
    app_texts.reject { |path, _| WRITTEN_EXCLUDED.keys.any? { path.start_with?(_1) } }
             .transform_values { _1.scan(WRITTEN_HARD).size }
  end

  def token_class(token) = /(?<![\w-])shadow-#{Regexp.escape(token)}(?![\w-])/

  def tailwind_tokens
    block = TAILWIND_CONFIG.read[/boxShadow:\s*\{(.*?)\}/m, 1].to_s
    block.scan(/['"]?([\w-]+)['"]?\s*:\s*'([^']*)'/).to_h
  end

  def hard_tokens = tailwind_tokens.select { |_, value| hard?(value) }

  # Splits at the characters the block names, outside quotes, parentheses and brackets;
  # every part with its whitespace collapsed.
  def split_outside(text, &separator)
    parts = [+'']
    depth = 0
    quote = nil
    text.each_char do |char|
      if quote
        quote = nil if char == quote
      elsif ['"', "'"].include?(char)
        quote = char
      elsif '(['.include?(char)
        depth += 1
      elsif ')]'.include?(char)
        depth -= 1
      elsif depth.zero? && separator.call(char)
        parts << +''
        next
      end
      parts.last << char
    end
    parts.map { _1.strip.gsub(/\s+/, ' ') }.reject(&:empty?)
  end

  # Hard: a layer without inset, with an x or y offset other than 0 and a blur of 0 or none.
  def hard?(value)
    split_outside(value.sub(IMPORTANT, '')) { _1 == ',' }.any? { hard_layer?(_1) }
  end

  def hard_layer?(layer)
    words = split_outside(layer) { _1.match?(/\s/) }
    return false if words.any? { _1.casecmp?('inset') }

    x, y, blur = words.grep(LENGTH).map(&:to_f)
    return false if x.nil? || y.nil?

    (!x.zero? || !y.zero?) && (blur.nil? || blur.zero?)
  end

  # Comments become spaces, so every line keeps its number.
  def blank_comments(css) = css.gsub(%r{/\*.*?\*/}m) { _1.gsub(/[^\n]/, ' ') }

  def declarations(css, file = nil) = StylesheetParser.new(css, file).declarations

  def declarations_of(file)
    path = STYLESHEETS.join(file)
    path.file? ? declarations(path.read, file) : []
  end

  def stylesheet_files
    Dir[STYLESHEETS.join('**/*.css').to_s].map { relative(_1, STYLESHEETS) }.sort.reject do |file|
      CSS_EXCLUDED.keys.any? { |excluded| excluded.end_with?('/') ? file.start_with?(excluded) : file == excluded }
    end
  end

  def stylesheet_shadows = stylesheet_files.flat_map { declarations_of(_1) }.select(&:box_shadow?)
end

RSpec.describe 'shadow levels guard' do
  describe 'A, written hard values' do
    let(:written) { ShadowLevels.written_counts }

    it 'stay within the legacy entry of their file, and a file without an entry has none' do
      offenders = written.filter_map do |path, count|
        allowed = ShadowLevels::LEGACY.fetch(path, 0)
        "  #{path}: #{count} written hard shadow(s), #{allowed} allowed" if count > allowed
      end

      expect(offenders).to be_empty, <<~MSG
        A file writes a hard offset shadow (shadow-[Xpx_Ypx_0...]) beyond the legacy list.
        A hard shadow says "press me". For the main action render a Neo button with
        variant: :primary; for a card that is wholly a link or a button render
        NeoCardComponent with shadow: :hover. Anything else takes a border or a soft
        shadow, and never a written hard value.

        #{offenders.join("\n")}
      MSG
    end

    it 'keep the legacy list honest: an entry falls with its file' do
      stale = ShadowLevels::LEGACY.filter_map do |path, allowed|
        count = written.fetch(path, 0)
        if count.zero?
          "  #{path}: no written hard shadow left (or no such file), delete the line"
        elsif count < allowed
          "  #{path}: listed #{allowed}, the file has #{count}, lower the entry to #{count}"
        end
      end

      expect(stale).to be_empty, <<~MSG
        The legacy list allows more written hard shadows than a file still has. Lower the
        entry, or delete the line at zero, so the room a fixed file leaves is not a budget
        for the next one.

        #{stale.join("\n")}
      MSG
    end

    it 'are read at all: more than 500 files, the logo tile among them with its one shadow' do
      # Without this every example above passes the day a directory moves.
      expect(written.size).to be > 500
      expect(written['app/views/shared/_brand_mark.html.erb']).to eq(1)
    end
  end

  describe 'B, the named tokens' do
    let(:texts) { ShadowLevels.app_texts }

    it 'are the three hard tokens of tailwind.config.js, all drawn from --ink' do
      expect(ShadowLevels.hard_tokens).to eq(ShadowLevels::HARD_TOKENS), <<~MSG
        The hard shadow tokens in config/tailwind.config.js (block boxShadow) changed:
        #{ShadowLevels.hard_tokens.inspect}
        A new hard token, or one not drawn from --ink, needs an owner list here
        (PRESS_USERS, LIFT_USERS) and a dark rule in application.tailwind.css before it
        is pinned in HARD_TOKENS.
      MSG
    end

    it 'are used only by their owners' do
      offenders = texts.flat_map do |path, text|
        ShadowLevels::TOKEN_OWNERS.filter_map do |token, owners|
          next if owners.key?(path) || !text.match?(ShadowLevels.token_class(token))

          "  #{path}: shadow-#{token} (owners: #{owners.keys.join(', ')})"
        end
      end

      expect(offenders).to be_empty, <<~MSG
        A file uses a hard shadow token outside its owner list. shadow-press and
        shadow-press-hover belong to the main action: render a Neo button with
        variant: :primary. shadow-lift belongs to a card that is wholly a link or a
        button: render NeoCardComponent with shadow: :hover.

        #{offenders.join("\n")}
      MSG
    end

    it 'keep the owner lists honest: every owner still uses a token of its group' do
      stale = ShadowLevels::OWNER_GROUPS.flat_map do |tokens, owners|
        owners.keys.filter_map do |path|
          next if tokens.any? { texts.fetch(path, '').match?(ShadowLevels.token_class(_1)) }

          "  #{path}: uses none of #{tokens.map { "shadow-#{_1}" }.join(', ')}, delete the line"
        end
      end

      expect(stale).to be_empty, <<~MSG
        An owner list names a file that no longer uses a token of its group. Delete the
        line, so the entry is not room for something else in that file.

        #{stale.join("\n")}
      MSG
    end
  end

  describe 'C, hard shadows declared in stylesheets' do
    let(:shadows) { ShadowLevels.stylesheet_shadows }

    it 'stand only where CSS_HARD names their file and selector' do
      offenders = shadows.select(&:hard?).flat_map do |declaration|
        listed = ShadowLevels::CSS_HARD.fetch(declaration.file, {})
        declaration.selectors.reject { listed.key?(_1) }.map do |selector|
          "  #{declaration.file}:#{declaration.line} #{selector} { box-shadow: #{declaration.value} }"
        end
      end

      expect(offenders).to be_empty, <<~MSG
        A stylesheet declares a hard offset shadow (an offset, no blur) outside CSS_HARD.
        A hard shadow says "press me": a main action may carry one, and then it needs an
        entry with its reason and a .dark rule with box-shadow: none. Anything else takes
        a border or a soft shadow.

        #{offenders.join("\n")}
      MSG
    end

    it 'keep CSS_HARD honest: every entry still declares a hard shadow' do
      stale = ShadowLevels::CSS_HARD.flat_map do |file, selectors|
        selectors.keys.filter_map do |selector|
          next if shadows.any? { _1.file == file && _1.hard? && _1.selectors.include?(selector) }

          "  #{file}: #{selector}, delete the line"
        end
      end

      expect(stale).to be_empty, <<~MSG
        CSS_HARD names a selector that declares no hard shadow any more. Delete the line,
        so the entry is not room for the next one.

        #{stale.join("\n")}
      MSG
    end

    it 'are read at all: more than 20 box-shadow declarations' do
      # Without this every example above passes the day the stylesheets move.
      expect(shadows.size).to be > 20
    end

    it 'are told from the rest by the classifier' do
      hard = ['2px 2px 0 #000', '4px 6px 0 -1px rgba(35, 34, 30, 0.16)', '2px 2px 0 0 #000000 !important',
              '0 4px 0 #000', '2px 2px #000']
      not_hard = ['0 0 0 2px rgb(var(--ink))', 'inset 0 -2px 0 rgb(var(--ink))', '0 10px 15px -3px rgba(0, 0, 0, 0.1)',
                  '0 1px 3px rgb(var(--stroke) / 0.06), 0 3px 10px rgb(var(--stroke) / 0.06)', 'none']

      expect(hard.reject { ShadowLevels.hard?(_1) }).to be_empty
      expect(not_hard.select { ShadowLevels.hard?(_1) }).to be_empty
    end

    it 'take a transition of box-shadow for no box-shadow declaration' do
      declarations = ShadowLevels.declarations('.x { transition: box-shadow 0.2s; }')

      expect(declarations.map(&:property)).to eq(['transition'])
      expect(declarations.select(&:box_shadow?)).to be_empty
    end

    it 'take the selector list of the innermost block, split at top-level commas' do
      css = "@layer components {\n  .a,\n  .b:is(.c, .d)   .e { color: red; box-shadow: 2px 2px 0 #000 !important; }\n}"
      declaration = ShadowLevels.declarations(css).find(&:box_shadow?)

      expect(declaration.selectors).to eq(['.a', '.b:is(.c, .d) .e'])
      expect(declaration.line).to eq(3)
      expect(declaration).to be_hard
      expect(declaration).to be_important
    end
  end

  describe 'D, the dark theme' do
    let(:tailwind_css) { ShadowLevels::STYLESHEETS.join('application.tailwind.css') }

    it 'turns off every hard token in application.tailwind.css' do
      declarations = ShadowLevels.declarations_of('application.tailwind.css')
      missing = ShadowLevels.hard_tokens.keys.reject do |token|
        selectors = [%(.dark [class*="shadow-#{token}"]), ".dark .shadow-#{token}"]
        declarations.any? { _1.off? && _1.selectors.intersect?(selectors) }
      end

      expect(missing).to be_empty, <<~MSG
        A hard shadow token has no dark rule. Add one line per token to
        application.tailwind.css, next to the others:
        #{missing.map { %(  .dark [class*="shadow-#{_1}"] { box-shadow: none !important; }) }.join("\n")}
      MSG
    end

    it 'turns off every hard shadow of CSS_HARD in its own file, with !important where the shadow has it' do
      offenders = ShadowLevels::CSS_HARD.flat_map do |file, selectors|
        declarations = ShadowLevels.declarations_of(file)
        selectors.keys.filter_map do |selector|
          important = declarations.any? { _1.hard? && _1.important? && _1.selectors.include?(selector) }
          dark = declarations.select { _1.off? && _1.selectors.include?(".dark #{selector}") }
          if dark.empty?
            "  #{file}: no .dark #{selector} { box-shadow: none#{' !important' if important}; }"
          elsif important && dark.none?(&:important?)
            "  #{file}: .dark #{selector} needs box-shadow: none !important, the light rule carries !important"
          end
        end
      end

      expect(offenders).to be_empty, <<~MSG
        The dark theme has no hard shadow. Every CSS_HARD selector needs a rule in its own
        file that turns its shadow off; without !important it loses to a light rule that
        carries one.

        #{offenders.join("\n")}
      MSG
    end

    it 'keeps the rule that turns off every written value' do
      lines = ShadowLevels.blank_comments(tailwind_css.read).lines.map(&:strip)

      expect(lines).to include(ShadowLevels::DARK_WRITTEN_VALUES), <<~MSG
        application.tailwind.css lost the line
          #{ShadowLevels::DARK_WRITTEN_VALUES}
        It carries every written hard value (rule A) in the dark theme.
      MSG
    end
  end
end
