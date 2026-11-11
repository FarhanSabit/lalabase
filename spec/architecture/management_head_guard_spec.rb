# frozen_string_literal: true

require 'rails_helper'

# Guard: the management head stands only on a page of a management section.
#
# The rule: every template under app/views that renders
# organisations/shared/_settings_subnav lies in a folder directly under
# app/views/organisations/, and NavigationHelper.section_key_for(<that folder>)
# names a section. The folder stands for the controller, as in Rails' own
# template lookup: organisations/roles/index belongs to the roles controller.
#
# Why (doc/verwaltung_seitennavigation_plan.md section 8): since 2026-11-11 the
# sidebar lists the management sections instead of the app's entries while a page
# of the area is open, and it decides that by the same question,
# NavigationHelper#management_section_key. A page that renders the management
# head but whose controller is in neither SETTINGS_TABS nor
# MANAGEMENT_PAGE_SECTIONS would leave the sidebar in the app's mode, with no
# section marked: the head says management, the sidebar says the app.
#
# No allow list: every template that renders the head today belongs to a section.
# One consequence: a partial in organisations/shared/ cannot carry the head for
# several pages. The page renders the head itself, so its folder names its
# controller.
#
# What it does NOT see:
#   - a page of the area that renders no head at all (the sidebar is right there,
#     the head is missing: a question for that page);
#   - a head built by hand (NeoTitleBoxComponent with a section's title);
#   - a render through a variable (render partial: name), or one from
#     app/components, app/helpers or a controller;
#   - a template rendered by a controller other than the one its folder names.
# It reads text, so it is a tripwire, not a proof.
#
# It runs through the directory entry spec/architecture/ of the CI guard list.
RSpec.describe 'management head guard' do
  let(:area) { 'app/views/organisations' }

  # The two spellings of the render call, either quote, with or without
  # parentheses:
  #   render 'organisations/shared/settings_subnav', active: :roles
  #   render partial: "organisations/shared/settings_subnav", locals: { ... }
  let(:head_render) { %r{\brender[\s(]+(?:partial:\s*)?(['"])organisations/shared/settings_subnav\1} }

  def relative(path) = Pathname.new(path).relative_path_from(Rails.root).to_s

  # <%# ... %>: a comment that names the render call does not render anything.
  def strip_erb_comments(source) = source.gsub(/<%#.*?%>/m, '')

  def head_templates
    Dir[Rails.root.join('app/views/**/*.erb')]
      .select { |path| strip_erb_comments(File.read(path)).match?(head_render) }
      .map { |path| relative(path) }
      .sort
  end

  # Why the template's head has no section; nil when it has one.
  def missing_section(path)
    folder = File.dirname(path)
    return "not in a folder directly under #{area}/" unless File.dirname(folder) == area

    name = File.basename(folder)
    "NavigationHelper.section_key_for('#{name}') is nil" if NavigationHelper.section_key_for(name).nil?
  end

  describe 'the management head' do
    it 'stands only on a page whose controller has a section' do
      offenders = head_templates.filter_map do |path|
        reason = missing_section(path)
        "  #{path}: #{reason}" if reason
      end

      expect(offenders).to be_empty, <<~MSG
        A template renders the management head (organisations/shared/_settings_subnav)
        on a page that belongs to no management section.

        The sidebar switches to the management list only where
        NavigationHelper.section_key_for knows the controller. On these pages the
        head would name a section while the sidebar stays in the app's mode.

        Either add the controller to NavigationHelper::SETTINGS_TABS (a section of
        its own) or to NavigationHelper::MANAGEMENT_PAGE_SECTIONS (a page below a
        section), or do not render the management head there.

        #{offenders.join("\n")}
      MSG
    end

    it 'is found at all' do
      expect(head_templates).not_to be_empty, <<~MSG
        No template renders organisations/shared/_settings_subnav. If the partial
        was renamed or moved, point this guard at the new one instead of letting
        it pass on an empty list.
      MSG
    end

    # The expression itself, against every spelling it must see and the ones it
    # must not. Without this the guard could stop matching a form and stay green.
    it 'is recognised in every spelling of the render call, and nothing else is' do
      [
        %(render 'organisations/shared/settings_subnav', active: :roles),
        %(render "organisations/shared/settings_subnav", active: :roles),
        %(render partial: 'organisations/shared/settings_subnav', locals: { active: :roles }),
        %(render partial: "organisations/shared/settings_subnav", locals: { active: :roles }),
        %(render('organisations/shared/settings_subnav', active: :roles))
      ].each { |call| expect(call).to match(head_render), call }

      [
        %(render 'organisations/shared/subnav', tabs: []),
        %(render 'organisations/shared/times_subnav', active: :times),
        %(render 'organisations/shared/settings_subnav_extra'),
        %(render "organisations/shared/settings_subnav')
      ].each { |call| expect(call).not_to match(head_render), call }
    end
  end
end
