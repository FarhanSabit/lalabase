# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NeoTagComponent, type: :component do
  context 'with default attributes' do
    it 'renders a basic tag' do
      render_inline(described_class.new(text: 'Test Tag'))

      expect(page).to have_css('span.inline-flex.items-center.gap-1\\.5.rounded-full.font-medium.border.transition-all')
      expect(page).to have_text('Test Tag')
      expect(page).to have_css('span.bg-lime-200.text-cream-900.border-stroke') # default primary variant
    end
  end

  context 'with different variants' do
    it 'renders with secondary variant' do
      render_inline(described_class.new(text: 'Secondary', variant: :secondary))
      expect(page).to have_css('span.bg-gray-200.text-gray-800.border-gray-800')
    end

    it 'renders with success variant' do
      render_inline(described_class.new(text: 'Success', variant: :success))
      expect(page).to have_css('span.bg-green-100.text-green-900.border-green-900')
    end

    it 'renders with danger variant' do
      render_inline(described_class.new(text: 'Danger', variant: :danger))
      expect(page).to have_css('span.bg-red-100.text-red-900.border-red-900')
    end

    it 'renders with warning variant' do
      render_inline(described_class.new(text: 'Warning', variant: :warning))
      expect(page).to have_css('span.bg-yellow-200.text-yellow-900.border-stroke')
    end

    it 'renders with info variant' do
      render_inline(described_class.new(text: 'Info', variant: :info))
      expect(page).to have_css('span.bg-blue-100.text-blue-900.border-blue-900')
    end

    it 'renders with neutral variant' do
      render_inline(described_class.new(text: 'Neutral', variant: :neutral))
      expect(page).to have_css('span.bg-surface-raised.text-gray-800.border-gray-400')
    end
  end

  context 'with different sizes' do
    it 'renders small size' do
      render_inline(described_class.new(text: 'Small', size: :small))
      expect(page).to have_css('span.text-xs.px-2.py-0\\.5')
    end

    it 'renders medium size' do
      render_inline(described_class.new(text: 'Medium', size: :medium))
      expect(page).to have_css('span.text-sm.px-3.py-1')
    end

    it 'renders large size' do
      render_inline(described_class.new(text: 'Large', size: :large))
      expect(page).to have_css('span.text-base.px-4.py-1\\.5')
    end
  end

  context 'with icon' do
    it 'renders with icon' do
      render_inline(described_class.new(text: 'With Icon', icon: 'person'))
      expect(page).to have_css('i.bi.bi-person')
      expect(page).to have_text('With Icon')
    end
  end

  context 'with removable option' do
    it 'renders remove button' do
      render_inline(described_class.new(text: 'Removable', removable: true))

      expect(page).to have_css('button.remove-button')
      expect(page).to have_css("[data-controller='neo-tag']")
      expect(page).to have_css("[data-neo-tag-removable-value='true']")
      expect(page).to have_css("[data-action='click->neo-tag#remove']")
    end

    # One icon set (one_icon_set_guard_spec): the cross is the font's, not a pasted path.
    it 'draws the cross with the icon font and names the button in the reader\'s language' do
      render_inline(described_class.new(text: 'Removable', removable: true))

      expect(page).to have_css('button.remove-button i.bi.bi-x[aria-hidden="true"]')
      expect(page).to have_no_css('svg')
      expect(page).to have_css("button.remove-button[aria-label='Removable entfernen']")
    end

    it 'names the button after the content of a block, without its markup' do
      render_inline(described_class.new(removable: true)) { '<span data-chip-name>Anna Admin</span><input type="hidden" value="x">'.html_safe }

      expect(page).to have_css("button.remove-button[aria-label='Anna Admin entfernen']")
    end

    # Since Rails 8.1.4.1 strip_tags writes quotes as entities too, and the template
    # escapes the label once more: a reader heard "&quot;", and "&amp;" before that.
    it 'names the button with quotes, ampersands and no-break spaces as they read' do
      render_inline(described_class.new(removable: true)) { %q(<span>Werkstatt&nbsp;"Nord" &amp; Kim's</span>).html_safe }

      expect(page.find('button.remove-button')['aria-label']).to eq(%q(Werkstatt "Nord" & Kim's entfernen))
    end
  end

  context 'with href' do
    it 'renders as clickable tag' do
      render_inline(described_class.new(text: 'Clickable', href: '/test-path'))

      expect(page).to have_css("[data-controller='neo-tag']")
      expect(page).to have_css("[data-neo-tag-href-value='/test-path']")
      expect(page).to have_css("[data-action='click->neo-tag#navigate']")
      expect(page).to have_css('span.hover\\:shadow-sm.cursor-pointer')
    end
  end

  context 'with content block' do
    it 'renders block content instead of text' do
      render_inline(described_class.new) do
        'Block Content'
      end

      expect(page).to have_text('Block Content')
      expect(page).to have_css('span.tag-text', text: 'Block Content')
    end
  end

  context 'with custom classes' do
    it 'appends custom classes' do
      render_inline(described_class.new(text: 'Custom', class: 'custom-class'))
      expect(page).to have_css('span.custom-class')
    end
  end

  context 'with data attributes' do
    it 'merges data attributes' do
      render_inline(described_class.new(
                      text: 'Data',
                      removable: true,
                      data: { custom: 'value' }
                    ))

      expect(page).to have_css("[data-custom='value']")
      expect(page).to have_css("[data-controller='neo-tag']")
    end
  end

  # Belegungstabelle B15: the dashed "suggestion" chip is gone for good. A
  # proposal has its own row in the filter bar (F31); a tag that claims to be
  # "not yet saved" would be that row's competitor.
  it 'no longer knows a suggestion option' do
    expect { described_class.new(text: 'x', suggestion: true) }.to raise_error(ArgumentError, /suggestion/)
  end
end
