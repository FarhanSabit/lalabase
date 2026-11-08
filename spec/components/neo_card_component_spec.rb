# frozen_string_literal: true

require 'rails_helper'

# A hard offset shadow means "press me": a card that lifts on hover draws the
# named `lift` token (config/tailwind.config.js), never a written value.
RSpec.describe NeoCardComponent, type: :component do
  def card_classes(**options)
    render_inline(described_class.new(**options)) { 'Content' }
    page.find('div')[:class]
  end

  context 'with shadow: :hover' do
    it 'lifts with the lift token and no written shadow value' do
      render_inline(described_class.new(shadow: :hover)) { 'Content' }

      expect(page).to have_css('div.hover\\:shadow-lift.hover\\:-translate-x-0\\.5.hover\\:-translate-y-0\\.5')
      expect(page).to have_no_css('div[class*="shadow-["]')
    end
  end

  context 'with shadow: :always' do
    it 'keeps its written shadow unchanged' do
      render_inline(described_class.new(shadow: :always)) { 'Content' }

      expect(page).to have_css('div.shadow-\\[2px_2px_0_0_\\#14110c\\]')
    end
  end

  context 'with shadow: :none' do
    it 'carries no shadow class' do
      render_inline(described_class.new(shadow: :none)) { 'Content' }

      expect(page).to have_css('div', text: 'Content')
      expect(page).to have_no_css('div[class*="shadow"]')
    end
  end

  context 'without a shadow argument' do
    it 'renders the same classes as shadow: :hover' do
      default_classes = card_classes
      hover_classes = card_classes(shadow: :hover)

      expect(default_classes).to include('hover:shadow-lift')
      expect(default_classes).to eq(hover_classes)
    end
  end
end
