# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Neo::Buttons::ButtonComponent, type: :component do
  subject(:component) { described_class.new(**options) }

  let(:options) { {} }
  let(:content) { 'Click me' }

  def rendered_component
    render_inline(component) { content }
  end

  describe 'basic rendering' do
    it 'renders a button with default attributes' do
      rendered_component

      expect(page).to have_css("button[type='button']")
      expect(page).to have_content('Click me')
    end

    context 'when tag is :a' do
      let(:options) { { tag: :a, href: '/test' } }

      it 'renders a link instead of button' do
        rendered_component

        expect(page).to have_css("a[href='/test']")
        expect(page).to have_content('Click me')
      end
    end
  end

  describe 'variants' do
    described_class::VARIANTS.keys.each do |variant|
      context "when variant is #{variant}" do
        let(:options) { { variant: variant } }

        it 'applies the correct variant classes' do
          rendered_component

          variant_classes = described_class::VARIANTS[variant]
          expect(page).to have_css("button[class*='#{variant_classes.split.first}']")
        end
      end
    end

    context 'with invalid variant' do
      let(:options) { { variant: :invalid } }

      it 'renders without variant-specific classes' do
        rendered_component

        # Should have base classes but no variant classes.
        # (Border/shadow come PER VARIANT since the LIFT/QUIET hierarchy, no longer
        #  universally in base_classes -> only check the stable base classes here.)
        expect(page).to have_css('button.font-medium.rounded-md.inline-flex')
        # Should not have any variant background colors
        expect(page).not_to have_css("button[class*='bg-']")
      end
    end
  end

  describe 'sizes' do
    described_class::SIZES.keys.each do |size|
      context "when size is #{size}" do
        let(:options) { { size: size } }

        it 'applies the correct size classes' do
          rendered_component

          size_classes = described_class::SIZES[size]
          expect(page).to have_css("button[class*='#{size_classes.split.first}']")
        end
      end
    end
  end

  describe 'icons' do
    context 'with icon on the left' do
      let(:options) { { icon: 'plus-lg' } }

      it 'renders icon before content' do
        rendered_component

        expect(page).to have_css('i.bi.bi-plus-lg')
        expect(page).to have_css('i.mr-2')
      end
    end

    context 'with icon on the right' do
      let(:options) { { icon: 'plus-lg', icon_position: :right } }

      it 'renders icon after content' do
        rendered_component

        expect(page).to have_css('i.bi.bi-plus-lg')
        expect(page).to have_css('i.ml-2')
      end
    end

    context 'with icon and content' do
      let(:options) { { icon: 'trash' } }
      let(:content) { 'Delete' }

      it 'renders icon with margin' do
        rendered_component

        expect(page).to have_css('i.bi.bi-trash')
        expect(page).to have_css('i.mr-2')
      end
    end
  end

  describe 'disabled state' do
    let(:options) { { disabled: true } }

    it 'adds disabled attribute and classes' do
      rendered_component

      expect(page).to have_css('button[disabled]')
      # The look rides on the attribute: a controller that clears it gets an enabled button.
      expect(page).to have_css('button.disabled\:opacity-50.disabled\:cursor-not-allowed.disabled\:pointer-events-none')
      expect(page).to have_no_css('button.pointer-events-none')
    end
  end

  describe 'loading state' do
    let(:options) { { loading: true } }

    it 'adds disabled attribute and loading classes' do
      rendered_component

      expect(page).to have_css('button[disabled]')
      expect(page).to have_css('button.cursor-wait')
    end

    # A ring drawn with a border, in the button's own colour. It was a pasted SVG until
    # 2026-09-30 (one_icon_set_guard_spec).
    it 'shows a spinner of its own making' do
      rendered_component

      expect(page).to have_css('[data-neo-button-target="spinner"]:not(.hidden) span.animate-spin.rounded-full[aria-hidden="true"]')
      expect(page).to have_no_css('[data-neo-button-target="spinner"] svg')
    end
  end

  describe 'interactive features' do
    context 'with confirmation' do
      let(:options) { { confirm: 'Are you sure?', interactive: true } }

      it 'adds Stimulus controller and data attributes' do
        rendered_component

        expect(page).to have_css("button[data-controller='neo-button']")
        expect(page).to have_css("button[data-neo-button-confirm-value='Are you sure?']")
        expect(page).to have_css("button[data-action='click->neo-button#handleClick']")
      end
    end

    context 'when interactive is true without confirm' do
      let(:options) { { interactive: true } }

      it 'adds Stimulus controller' do
        rendered_component

        expect(page).to have_css("button[data-controller='neo-button']")
      end
    end

    context 'when confirm is present (interactive auto-enabled)' do
      let(:options) { { confirm: 'Delete this?' } }

      it 'automatically enables interactive mode' do
        rendered_component

        expect(page).to have_css("button[data-controller='neo-button']")
        expect(page).to have_css("button[data-neo-button-confirm-value='Delete this?']")
      end
    end
  end

  describe 'form integration' do
    context 'with form options' do
      let(:options) do
        {
          variant: :danger,
          form: {
            action: '/posts/1',
            method: :delete
          }
        }
      end

      it 'renders a form with button inside' do
        rendered_component

        expect(page).to have_css("form[action='/posts/1'][method='post']")
        expect(page).to have_css("form input[name='_method'][value='delete']", visible: false)
        expect(page).to have_css("form button[type='submit']")
      end
    end
  end

  describe 'custom attributes' do
    let(:options) do
      {
        data: { turbo_method: :delete },
        class: 'custom-class',
        id: 'special-button',
        title: 'Custom tooltip'
      }
    end

    it 'passes through custom attributes' do
      rendered_component

      expect(page).to have_css('button#special-button')
      expect(page).to have_css("button[title='Custom tooltip']")
      expect(page).to have_css("button[data-turbo-method='delete']")
      expect(page).to have_css('button.custom-class')
    end
  end

  describe 'type attribute' do
    context 'when type is specified' do
      let(:options) { { type: 'submit' } }

      it 'uses the specified type' do
        rendered_component

        expect(page).to have_css("button[type='submit']")
      end

      it 'does not override with default button type' do
        rendered_component

        expect(page).not_to have_css("button[type='button']")
      end
    end

    context 'when type is not specified' do
      it 'defaults to button type' do
        rendered_component

        expect(page).to have_css("button[type='button']")
      end
    end

    context 'when type is blank string' do
      let(:options) { { type: '' } }

      it 'defaults to button type' do
        rendered_component

        expect(page).to have_css("button[type='button']")
      end
    end

    context 'when type is nil' do
      let(:options) { { type: nil } }

      it 'defaults to button type' do
        rendered_component

        expect(page).to have_css("button[type='button']")
      end
    end

    # Regression test for the bug: type='submit' was being overwritten
    context 'regression: submit button in form' do
      let(:options) { { type: 'submit', variant: :primary } }

      it 'preserves submit type for form submission' do
        rendered_component

        # Must have exactly type="submit", not type="button"
        expect(page).to have_css("button[type='submit']")
        expect(page).not_to have_css("button[type='button']")
      end

      it 'can be used to submit forms' do
        # Simulate a form context
        form_html = <<~HTML
          <form action="/test" method="post">
            #{rendered_component}
          </form>
        HTML

        expect(form_html).to include('type="submit"')
        expect(form_html).not_to include('type="button"')
      end
    end
  end

  # A button with form: renders a real form, and the confirmation sits on the
  # form (data-turbo-confirm). Until 26.10.2026 the button ALSO carried
  # neo-button's own confirm, so a delete asked twice.
  describe 'form button with confirmation' do
    let(:options) { { confirm: 'Delete this?', form: { action: '/things/1', method: :delete } } }

    it 'asks once, through the form' do
      rendered_component

      expect(page).to have_css("form[data-turbo-confirm='Delete this?']")
      expect(page).to have_css('form button')
      expect(page).to have_no_css('button[data-neo-button-confirm-value]')
    end
  end

  describe 'complex scenarios' do
    context 'form submit button with icon and confirmation' do
      let(:options) do
        {
          variant: :danger,
          size: :small,
          icon: 'trash',
          confirm: 'Delete permanently?',
          type: 'submit'
        }
      end

      it 'combines all features correctly' do
        rendered_component

        expect(page).to have_css("button[type='submit']")
        expect(page).to have_css("button[data-controller='neo-button']")
        expect(page).to have_css("button[data-neo-button-confirm-value='Delete permanently?']")
        expect(page).to have_css('i.bi.bi-trash')
        expect(page).to have_css('button.h-6') # small size
      end
    end

    context 'link styled as button with loading state' do
      let(:options) do
        {
          tag: :a,
          href: '/new',
          variant: :primary,
          loading: true,
          icon: 'plus-lg'
        }
      end

      it 'renders disabled link with loading cursor' do
        rendered_component

        expect(page).to have_css("a[href='/new'][disabled]")
        expect(page).to have_css('a.cursor-wait')
        # The main action's plus is a drawn cross, not the font's glyph.
        expect(page).to have_css('a svg path[stroke="currentColor"]')
      end
    end
  end
  # The main action (user, 08.09.2026): lime, the ONE hard edge a view has, the
  # hard offset shadow that grows on hover and vanishes when pressed, an ink
  # outline for the keyboard, and an off state of its own without opacity.
  describe 'the main action' do
    let(:options) { { variant: :primary } }

    it 'carries the hard edge, the offset shadow and the 8 px radius' do
      rendered_component

      expect(page).to have_css('button.bg-btn-primary.text-ink.border.border-ink.rounded-lg')
      expect(page).to have_css('button.shadow-press')
      expect(page).to have_css('button.hover\\:shadow-press-hover')
      expect(page).to have_no_css('button[class*="shadow-["]')
      expect(page).to have_css('button.active\\:shadow-none.active\\:translate-x-\\[2px\\]')
      expect(page).to have_css('button.focus-visible\\:outline-ink.focus-visible\\:outline-offset-\\[3px\\]')
      expect(page).to have_css('button.h-8.px-\\[14px\\].text-\\[13px\\].font-semibold')
      expect(page).to have_no_css('button.rounded-md')
      expect(page).to have_no_css('button.focus-visible\\:ring-2')
    end

    it 'has an off state of its own, without the fade' do
      render_inline(described_class.new(variant: :primary, disabled: true)) { 'Go' }

      expect(page).to have_css('button[disabled].disabled\\:bg-selected.disabled\\:border-edge.disabled\\:text-faint.disabled\\:shadow-none')
      expect(page).to have_no_css('button.disabled\\:opacity-50')
    end
  end
end
