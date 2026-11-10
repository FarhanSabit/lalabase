# frozen_string_literal: true

require 'rails_helper'

# Guard: a hard offset shadow means one thing in the application, "press me".
#
# A hard offset shadow is a shadow with an offset and no blur. It stands in three places
# only: on the main action (Neo::Buttons, the tokens shadow-press and shadow-press-hover),
# on a card that is wholly a link or a button while it is hovered (NeoCardComponent with
# shadow: :hover, the token shadow-lift), and on the logo tile. Anywhere else it says
# "press me" about something that cannot be pressed. The dark theme turns off the tokens,
# the written values and the stylesheet shadows; the inline literals of A2 still draw one
# there. Source: rule 5 of the Belegungstabelle (doc/belegungstabelle_oberflaeche.md) and
# doc/schatten_stufen_plan.md.
#
# What this holds:
#   A. Written values (shadow-[...] whose value is hard, _ read as a space) in templates,
#      components, scripts, helpers and services: the count per file on 2026-11-08,
#      which may only shrink.
#   A2. Hard box-shadow literals in the same files (a style attribute, a CSS string, a
#      boxShadow in a script): a list of the same kind. These keep their shadow in the
#      dark theme until a later slice.
#   B. The three named hard tokens of config/tailwind.config.js stay with their owners.
#      A stylesheet that uses one through @apply is never an owner.
#   C. Hard shadows declared in stylesheets, a written hard value through @apply
#      included: a closed list of file and selector.
#   D. Each token and each stylesheet shadow is turned off in the dark theme, and the
#      rule that turns off every written value is still there.
#
# It runs through the directory entry spec/architecture/ of the CI guard list.
#
# What it does NOT see: a shadow built at run time (a class or a style put together from
# parts, a value from a variable or a template expression), a shadow through a CSS
# variable, soft shadows (shadow-sm and the like), and the role of an element. A panel
# that gets shadow-lift in an owner's file passes here; that is for the person who reads
# the diff.
module ShadowLevels
  STYLESHEETS = Rails.root.join('app/assets/stylesheets')
  TAILWIND_CONFIG = Rails.root.join('config/tailwind.config.js')

  # Rules A, A2 and B read these directories, files ending in .erb, .rb and .js.
  APP_DIRS = %w[app/views app/components app/javascript app/helpers app/services].freeze
  APP_FILES = '**/*.{erb,rb,js}'

  # A written value, with any variant prefix: shadow-[2px_2px_0_0_#000], hover:shadow-[...].
  WRITTEN_VALUE = /shadow-\[([^\]]+)\]/

  # A box-shadow literal: a CSS declaration in the text (a style attribute, a CSS string),
  # and a boxShadow in a script, quoted with ', " or a backtick.
  CSS_LITERAL = /box-shadow\s*:\s*([^;"'}<>\n]+)/
  SCRIPT_LITERAL = /boxShadow\s*[:=]\s*(['"`])((?:(?!\1).)*)\1/

  # Rules A and A2 only. Rule B reads these directories as well.
  WRITTEN_EXCLUDED = {
    'app/views/admin/' => 'the admin area has a style guide of its own (owner decision 2026-06-01)',
    'app/views/style_guide/' => 'shows samples; brought in line in its own slice, S5'
  }.freeze

  # Shrink only: path => written hard values on 2026-11-08. Lower the count when a value
  # goes, delete the line when it reaches zero.
  LEGACY = {
    'app/components/neo/chat/transparency_notice_component.html.erb' => 1,
    'app/components/neo_card_component.rb' => 1, # shadow: :always, removed in slice S3
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
    'app/views/organisations/time_sessions/_bulk_action_bar.html.erb' => 1,
    'app/views/organisations/time_sessions/index.html.erb' => 1,
    'app/views/shared/_brand_mark.html.erb' => 1, # the logo tile, as on the website; not a token
    'app/views/shared/_pagination_nav.html.erb' => 2,
    'app/views/shared/_pagination_nav_compact.html.erb' => 2,
    'app/views/users/personal_access_tokens/created.html.erb' => 1,
    'app/views/users/personal_access_tokens/edit.html.erb' => 2,
    'app/views/users/personal_access_tokens/new.html.erb' => 5
  }.freeze

  # Shrink only: path => hard box-shadow literals on 2026-11-08, lowered and deleted like
  # LEGACY. These keep their shadow in the dark theme until a later slice: the attribute
  # rule of the dark theme (.dark [class*="shadow-["]) cannot reach a style attribute.
  INLINE_LEGACY = {
    'app/components/neo_toggle_component.rb' => 1,
    'app/javascript/controllers/neo_notification_bulk_action_controller.js' => 1,
    'app/javascript/controllers/neo_toggle_controller.js' => 1,
    'app/javascript/controllers/time_session_popup_controller.js' => 1
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

  # token group => its owners. Rule B reads the admin area, the style guide and every
  # stylesheet too: a token name is a promise about the role wherever it stands, and a
  # stylesheet is never an owner.
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

  # A named token in an @apply of a stylesheet.
  AppliedToken = Data.define(:file, :line, :selectors, :token)

  # Reads rule blocks with nesting (@layer, @media). Braces and semicolons inside quotes
  # or parentheses are text.
  class StylesheetParser
    attr_reader :declarations, :applied_tokens

    def initialize(css, file)
      @file = file
      @declarations = []
      @applied_tokens = []
      @preludes = []
      @buffer = +''
      @start = nil
      @line = 1
      @quote = nil
      @depth = 0
      @escape = false
      ShadowLevels.blank_comments(css).each_char { |char| read(char) }
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

      text = @buffer.strip
      return record_apply(text.delete_prefix('@apply')) if text.start_with?('@apply')

      match = text.match(/\A([\w-]+)\s*:\s*(.*)\z/m)
      add_declaration(match[1].downcase, match[2]) if match
    end

    # In an @apply a written hard value is a box-shadow declaration of the block, and a
    # named token is a use of that token. Variants (hover:, md:) and a leading ! go first.
    def record_apply(list)
      words = ShadowLevels.split_outside(list) { _1.match?(/\s/) }
      all_important = words.delete('!important')
      words.each do |word|
        utility = ShadowLevels.utility(word)
        important = all_important || utility.start_with?('!')
        utility = utility.delete_prefix('!')
        value = utility[/\Ashadow-\[(.+)\]\z/m, 1]
        token = utility[/\Ashadow-([\w-]+)\z/, 1]
        if value && ShadowLevels.written_hard?(value)
          add_declaration('box-shadow', "#{value.tr('_', ' ')}#{' !important' if important}")
        elsif TOKEN_OWNERS.key?(token)
          @applied_tokens << AppliedToken.new(file: @file, line: @start, selectors: @preludes.last, token: token)
        end
      end
    end

    def add_declaration(property, value)
      @declarations << Declaration.new(file: @file, line: @start, selectors: @preludes.last,
                                       property: property, value: value.strip.gsub(/\s+/, ' '))
    end
  end

  module_function

  def relative(path, root = Rails.root) = Pathname.new(path).relative_path_from(root).to_s

  # Every file rule B reads, relative path => text.
  def app_texts
    APP_DIRS.flat_map { |dir| Dir[Rails.root.join(dir, APP_FILES).to_s] }.uniq.sort
            .to_h { |path| [relative(path), File.read(path)] }
  end

  # Every file rules A and A2 read, relative path => text.
  def written_texts = app_texts.reject { |path, _| WRITTEN_EXCLUDED.keys.any? { path.start_with?(_1) } }

  def written_hard?(value) = hard?(value.tr('_', ' '))

  def written_count(text) = text.scan(WRITTEN_VALUE).count { |(value)| written_hard?(value) }

  def inline_literals(text)
    text.scan(CSS_LITERAL).map(&:first) + text.scan(SCRIPT_LITERAL).map(&:last).reject { _1.include?('${') }
  end

  def inline_count(text) = inline_literals(text).count { hard?(_1) }

  # A file above its entry; a file without an entry allows none.
  def over_legacy(counts, legacy)
    counts.filter_map do |path, count|
      allowed = legacy.fetch(path, 0)
      "  #{path}: #{count} found, #{allowed} allowed" if count > allowed
    end
  end

  # An entry above its file: lower it, or delete it at zero.
  def stale_legacy(counts, legacy)
    legacy.filter_map do |path, allowed|
      count = counts.fetch(path, 0)
      if count.zero?
        "  #{path}: none left (or no such file), delete the line"
      elsif count < allowed
        "  #{path}: listed #{allowed}, the file has #{count}, lower the entry to #{count}"
      end
    end
  end

  def token_class(token) = /(?<![\w-])shadow-#{Regexp.escape(token)}(?![\w-])/

  def dark_token_selector(token) = %(.dark [class*="shadow-#{token}"])

  def tailwind_tokens
    block = TAILWIND_CONFIG.read[/boxShadow:\s*\{(.*?)\}/m, 1].to_s
    block.scan(/['"]?([\w-]+)['"]?\s*:\s*(['"])(.*?)\2/).to_h { |name, _quote, value| [name, value] }
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

  # A class without its variants (up to the last : outside brackets): hover:!x is !x.
  def utility(word)
    depth = 0
    cut = -1
    word.each_char.with_index do |char, index|
      depth += 1 if char == '['
      depth -= 1 if char == ']'
      cut = index if char == ':' && depth.zero?
    end
    word[(cut + 1)..]
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

  def parse(css, file = nil) = StylesheetParser.new(css, file)

  def declarations(css, file = nil) = parse(css, file).declarations

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

  # Every token use through @apply, in every stylesheet, without rule C's exclusions.
  def applied_tokens
    Dir[STYLESHEETS.join('**/*.css').to_s].sort.flat_map do |path|
      parse(File.read(path), relative(path, STYLESHEETS)).applied_tokens
    end
  end
end

RSpec.describe 'shadow levels guard' do
  describe 'A, written hard values' do
    let(:written) { ShadowLevels.written_texts.transform_values { ShadowLevels.written_count(_1) } }

    it 'stay within the legacy entry of their file, and a file without an entry has none' do
      offenders = ShadowLevels.over_legacy(written, ShadowLevels::LEGACY)

      expect(offenders).to be_empty, <<~MSG
        A file writes a hard offset shadow (shadow-[...] with an offset and no blur) beyond
        the legacy list. A hard shadow says "press me". For the main action render a Neo
        button with variant: :primary; for a card that is wholly a link or a button render
        NeoCardComponent with shadow: :hover. Anything else takes a border or a soft
        shadow, and never a written hard value.

        #{offenders.join("\n")}
      MSG
    end

    it 'keep the legacy list honest: an entry falls with its file' do
      stale = ShadowLevels.stale_legacy(written, ShadowLevels::LEGACY)

      expect(stale).to be_empty, <<~MSG
        LEGACY allows more written hard shadows than a file still has. Lower the entry, or
        delete the line at zero, so the room a fixed file leaves is not a budget for the
        next one.

        #{stale.join("\n")}
      MSG
    end

    it 'are read at all: more than 500 files, the logo tile among them with its one shadow' do
      # Without this every example above passes the day a directory moves.
      expect(written.size).to be > 500
      expect(written['app/views/shared/_brand_mark.html.erb']).to eq(1)
    end
  end

  describe 'A2, hard box-shadow literals' do
    let(:inline) { ShadowLevels.written_texts.transform_values { ShadowLevels.inline_count(_1) } }

    it 'stay within the legacy entry of their file, and a file without an entry has none' do
      offenders = ShadowLevels.over_legacy(inline, ShadowLevels::INLINE_LEGACY)

      expect(offenders).to be_empty, <<~MSG
        A file writes a hard box-shadow literal (a style attribute, a CSS string, a
        boxShadow in a script) beyond INLINE_LEGACY. It keeps its shadow in the dark
        theme, where no hard shadow belongs, because no dark rule reaches a style. For the
        main action render a Neo button with variant: :primary; for a card that is wholly
        a link or a button render NeoCardComponent with shadow: :hover. Anything else
        takes a border or a soft shadow.

        #{offenders.join("\n")}
      MSG
    end

    it 'keep the legacy list honest: an entry falls with its file' do
      stale = ShadowLevels.stale_legacy(inline, ShadowLevels::INLINE_LEGACY)

      expect(stale).to be_empty, <<~MSG
        INLINE_LEGACY allows more hard box-shadow literals than a file still has. Lower the
        entry, or delete the line at zero, so the room a fixed file leaves is not a budget
        for the next one.

        #{stale.join("\n")}
      MSG
    end

    it 'are read at all: more than 500 files, and both forms of a literal' do
      # Without this every example above passes the day a directory moves or a pattern breaks.
      samples = {
        %(<div style="box-shadow: 4px 4px 0 #000"></div>) => 1,
        %('background: white; box-shadow:2px 2px 0 0 #000000 !important;') => 1,
        %(label.style.boxShadow = '2px 2px 0 0 #000000') => 1,
        %(Object.assign(el.style, { boxShadow: "3px 3px 0 #000" })) => 1,
        %(el.style.boxShadow = `${x}px 4px 0 #000`) => 0,
        %(<p style="box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1)"></p>) => 0
      }

      expect(inline.size).to be > 500
      expect(samples.to_h { |text, _| [text, ShadowLevels.inline_count(text)] }).to eq(samples)
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

    it 'are used only by their owners, and never through @apply in a stylesheet' do
      in_files = texts.flat_map do |path, text|
        ShadowLevels::TOKEN_OWNERS.filter_map do |token, owners|
          next if owners.key?(path) || !text.match?(ShadowLevels.token_class(token))

          "  #{path}: shadow-#{token} (owners: #{owners.keys.join(', ')})"
        end
      end
      in_stylesheets = ShadowLevels.applied_tokens.map do |use|
        "  app/assets/stylesheets/#{use.file}:#{use.line} #{use.selectors.join(', ')} { @apply shadow-#{use.token} }"
      end
      offenders = in_files + in_stylesheets

      expect(offenders).to be_empty, <<~MSG
        A hard shadow token is used outside its owner list. shadow-press and
        shadow-press-hover belong to the main action: render a Neo button with
        variant: :primary. shadow-lift belongs to a card that is wholly a link or a
        button: render NeoCardComponent with shadow: :hover. A stylesheet is never an
        owner: a CSS main action writes its own value, with a CSS_HARD entry and a dark
        rule.

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
        A stylesheet declares a hard offset shadow (an offset, no blur; a written hard
        value through @apply counts) outside CSS_HARD. A hard shadow says "press me": a
        main action may carry one, and then it needs an entry with its reason and a .dark
        rule with box-shadow: none. Anything else takes a border or a soft shadow.

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
      written_hard = ['0_-4px_0_0_#14110c']
      written_not_hard = ['inset_3px_0_0_0_#fbbf24', '4px_0_12px_-6px_rgba(0,0,0,0.25)', '0_0_0_1px_theme(colors.cream.400)']

      expect(hard.reject { ShadowLevels.hard?(_1) }).to be_empty
      expect(not_hard.select { ShadowLevels.hard?(_1) }).to be_empty
      expect(written_hard.reject { ShadowLevels.written_hard?(_1) }).to be_empty
      expect(written_not_hard.select { ShadowLevels.written_hard?(_1) }).to be_empty
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

    it 'read an @apply: a written hard value is a box-shadow of the block, a token a use of it' do
      css = '.y { @apply flex hover:!shadow-[2px_2px_0_0_#000] shadow-[0_1px_3px_#000] md:shadow-lift shadow-sm; }'
      parsed = ShadowLevels.parse(css, 'probe.css')

      expect(parsed.declarations.map { [_1.selectors, _1.value] }).to eq([[['.y'], '2px 2px 0 0 #000 !important']])
      expect(parsed.applied_tokens.map { [_1.selectors, _1.token] }).to eq([[['.y'], 'lift']])
    end
  end

  describe 'D, the dark theme' do
    let(:tailwind_css) { ShadowLevels::STYLESHEETS.join('application.tailwind.css') }

    it 'turns off every hard token in application.tailwind.css, through the class attribute and with !important' do
      declarations = ShadowLevels.declarations_of('application.tailwind.css')
      missing = ShadowLevels.hard_tokens.keys.reject do |token|
        declarations.any? { _1.off? && _1.important? && _1.selectors.include?(ShadowLevels.dark_token_selector(token)) }
      end

      expect(missing).to be_empty, <<~MSG
        A hard shadow token has no dark rule that holds. Each token needs its own line in
        application.tailwind.css, next to the others:
        #{missing.map { "  #{ShadowLevels.dark_token_selector(_1)} { box-shadow: none !important; }" }.join("\n")}
        The attribute selector, because .dark .shadow-<token> never matches a variant
        class such as hover:shadow-lift. And !important, because at equal specificity the
        hover utility comes later in the build and wins.
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
        The dark theme draws no hard shadow from a stylesheet. Every CSS_HARD selector needs
        a rule in its own file that turns its shadow off; without !important it loses to a
        light rule that carries one.

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
