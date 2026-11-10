# frozen_string_literal: true

require 'rails_helper'

# What: Neo::OverflowMenuComponent — the "..." header overflow for rare page
#       actions (first used by the documentation header), reused as the generic
#       icon-trigger + dropdown primitive for the contextual-help "?" menu
#       (doc/kontexthilfe_plan.md).
# Why:  Guards the contracts that make the pattern safe to roll out:
#       (1) with no items the component renders NOTHING (policy-gated callers
#       must not leave an empty trigger behind), (2) items render as real
#       links inside an initially hidden dropdown menu wired to the generic
#       `dropdown` Stimulus controller, and (3) `icon:`/`trigger_label_key:`
#       let a caller repurpose the trigger (e.g. a "?" contextual-help button)
#       without a second, near-identical component — defaults stay unchanged
#       so the existing overflow usage is not a breaking change.
RSpec.describe Neo::OverflowMenuComponent, type: :component do
  it 'renders nothing when no items are present' do
    render_inline(described_class.new)

    expect(page.native.inner_html).to be_blank
  end

  it 'renders a three-dots trigger with an accessible label' do
    render_inline(described_class.new) do |menu|
      menu.with_item(label: 'Logbuch', url: '/logbuch', icon: 'clock-history')
    end

    expect(page).to have_css('[data-controller="dropdown"]')
    expect(page).to have_css('i.bi.bi-three-dots')
    expect(page).to have_css("[title='#{I18n.t('components.overflow_menu.label')}']")
  end

  it 'renders each item as a link with label and icon inside the hidden menu' do
    render_inline(described_class.new) do |menu|
      menu.with_item(label: 'Logbuch', url: '/logbuch', icon: 'clock-history')
      menu.with_item(label: 'Verbinden', url: '/verbinden')
    end

    menu = page.find('[data-dropdown-target="menu"]', visible: :all)
    expect(menu[:class]).to include('hidden')

    expect(page).to have_css('a[href="/logbuch"] i.bi-clock-history', visible: :all)
    expect(page).to have_css('a[href="/logbuch"] span', text: 'Logbuch', visible: :all)
    expect(page).to have_css('a[href="/verbinden"] span', text: 'Verbinden', visible: :all)
    expect(page).to have_no_css('a[href="/verbinden"] i', visible: :all)
  end

  it 'accepts a custom icon and trigger label, defaulting to the overflow "..." look' do
    render_inline(described_class.new) do |menu|
      menu.with_item(label: 'Logbuch', url: '/logbuch')
    end

    expect(page).to have_css('i.bi.bi-three-dots')
    expect(page).to have_css("[title='#{I18n.t('components.overflow_menu.label')}']")
  end

  it 'renders a custom icon/label when overridden (e.g. contextual-help trigger)' do
    render_inline(described_class.new(icon: 'question-circle', trigger_label_key: 'components.contextual_help.label')) do |menu|
      menu.with_item(label: 'Wie ändere ich die Ansicht?', url: '/hilfe/guides/ticket-views/configure-view')
    end

    expect(page).to have_css('i.bi.bi-question-circle')
    expect(page).to have_no_css('i.bi.bi-three-dots')
    expect(page).to have_css("[title='#{I18n.t('components.contextual_help.label')}']")
  end

  # A head whose other tools are small (the inbox: the "···" trigger and the
  # view switch, both 28 px) takes the quiet trigger, so the "?" is not the one
  # big box among them. It is the "···" trigger of those heads, same class.
  it 'renders the quiet trigger of the small heads when asked' do
    render_inline(described_class.new(icon: 'question-lg', trigger_label_key: 'components.contextual_help.label',
                                      quiet: true)) do |menu|
      menu.with_item(label: 'Hilfe-Frage', url: '/hilfe/guides/x')
    end

    trigger = page.find('button.more-menu__trigger')
    expect(trigger[:type]).to eq('button')
    expect(trigger['data-action']).to eq('click->dropdown#toggle')
    expect(trigger[:title]).to eq(I18n.t('components.contextual_help.label'))
    expect(trigger['aria-label']).to eq(I18n.t('components.contextual_help.label'))
    expect(trigger).to have_css('i.bi.bi-question-lg[aria-hidden="true"]')
    expect(trigger[:class]).not_to include('h-10')
  end

  it 'keeps the icon button trigger by default' do
    render_inline(described_class.new(size: :large)) do |menu|
      menu.with_item(label: 'Logbuch', url: '/logbuch')
    end

    expect(page).to have_no_css('.more-menu__trigger')
    expect(page).to have_css('button.h-10.w-10')
  end

  it 'forwards optional data attributes to the item link (drawer-trigger wiring)' do
    render_inline(described_class.new) do |menu|
      menu.with_item(
        label: 'Hilfe-Frage', url: '/hilfe/guides/x', icon: 'question-circle',
        data: { action: 'contextual-help-drawer#open',
                contextual_help_drawer_url_param: '/hilfe/guides/x' }
      )
    end

    link = page.find('a[href="/hilfe/guides/x"]', visible: :all)
    expect(link['data-action']).to eq('contextual-help-drawer#open')
    expect(link['data-contextual-help-drawer-url-param']).to eq('/hilfe/guides/x')
  end

  it 'renders items without data: as plain links — the pre-drawer default stays unchanged' do
    render_inline(described_class.new) do |menu|
      menu.with_item(label: 'Logbuch', url: '/logbuch')
    end

    link = page.find('a[href="/logbuch"]', visible: :all)
    expect(link['data-action']).to be_nil
  end

  # A consequential item (the version row's delete, S2 of
  # doc/dokumentansicht_plan.md) reads red; one text colour per item.
  it 'colours a danger item red and leaves the others in ink' do
    render_inline(described_class.new) do |menu|
      menu.with_item(label: 'Logbuch', url: '/logbuch')
      menu.with_item(label: 'Löschen', url: '/loeschen', danger: true)
    end

    expect(page.find('a[href="/logbuch"]', visible: :all)[:class]).to include('text-cream-900')
    expect(page.find('a[href="/loeschen"]', visible: :all)[:class]).to include('text-red-700')
    expect(page.find('a[href="/loeschen"]', visible: :all)[:class]).not_to include('text-cream-900')
  end
end
