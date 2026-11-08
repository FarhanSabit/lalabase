# frozen_string_literal: true

# Shared logic for Neo::Buttons::ButtonComponent and Neo::Buttons::IconButtonComponent.
# Contains variants, sizes, CSS class assembly and HTML attribute logic.
module Neo
  module Buttons
    module Base
      extend ActiveSupport::Concern

      # Soft-flat look (user, 04.09.2026): generous radius. Secondary buttons (every variant
      # but PRIMARY) are flat: NO offset shadow and no hover lift - hover feedback is the
      # background shift each variant brings. The main action (PRIMARY, below) is the one
      # exception: it carries the hard offset shadow of the tokens shadow-press and
      # shadow-press-hover (CLAUDE.md "Shadows").
      # Hierarchy comes from border strength + fill color:
      # - LOUD  = meaningful actions (colored semantics): translucent stroke that
      #           reads as a darker shade of the fill, not as a hard black outline
      #           (user, 04.09.2026).
      # - QUIET = frequent neutral actions (Show all/Edit): soft cream border,
      #           steps back next to the loud face.
      LOUD  = 'border border-stroke/30'
      QUIET = 'border border-cream-300 hover:border-cream-400'

      # The main action (user, 08.09.2026, "Hauptaktions-Knopf vereinheitlichen"):
      # lime, ink for word and glyph, the ONE hard edge a view has (1 px ink
      # border, 8 px radius) and a hard offset shadow, 2 px at rest, 3 px on
      # hover, none when pressed while the button sinks into its own shadow.
      # Off: the selected surface, the edge, faint text, no shadow, no pointer.
      # One primary surface per visible area; no other element carries the
      # ink edge or the offset shadow. Soft shadows stay with layers and modals.
      PRIMARY = 'bg-btn-primary text-ink font-semibold border border-ink ' \
                'shadow-press hover:shadow-press-hover ' \
                'active:shadow-none active:translate-x-[2px] active:translate-y-[2px] ' \
                'disabled:bg-selected disabled:border-edge disabled:text-faint disabled:shadow-none ' \
                'disabled:translate-x-0 disabled:translate-y-0 disabled:cursor-default'

      # Editorial-Quiet palette: calm backgrounds, gentle hover.
      # - primary: Lime (brand accent, only primary action) — EMPHASIS
      # - info/warning/danger/success/ai: colored semantics — EMPHASIS (meaningful)
      # - secondary/edit/ghost: neutral secondary actions — QUIET (step back)
      VARIANTS = {
        primary: PRIMARY, # the one main action (G4): lime, the hard edge, the offset shadow
        secondary: "bg-surface-raised hover:bg-cream-100 #{QUIET}", # neutral secondary action — quiet
        danger: "bg-red-200 hover:bg-red-300 text-red-900 #{LOUD}", # reversible delete (C3)
        danger_zone: "!border-red-500 text-red-600 bg-surface-raised hover:bg-red-600 hover:text-on-fill #{LOUD}", # irreversible (C4/P8)
        success: "bg-green-200 hover:bg-green-300 #{LOUD}",
        edit: "bg-surface-raised hover:bg-cream-100 #{QUIET}",
        ghost: 'bg-transparent hover:bg-cream-100 border border-transparent hover:border-cream-300',
        warning: "bg-yellow-200 hover:bg-yellow-300 #{LOUD}",
        info: "bg-cobalt-200 hover:bg-cobalt-300 #{LOUD}",
        ai: "bg-purple-200 hover:bg-purple-300 #{LOUD}",
        plain: '!bg-transparent !border-transparent hover:!bg-transparent'
      }.freeze

      SIZES = {
        small: 'h-6 px-2 text-xs',
        medium: 'h-8 px-3 text-sm',
        large: 'h-10 px-4 text-base'
      }.freeze

      private

      def base_classes
        # Token base (see doc/design_system.md):
        # - rounded-md: ONE radius (6px) for every button so squares read square
        #   (user, 04.09.2026); the main action alone is 8 px (radius_classes)
        # - flat: no shadow, no hover lift - hover is the variant's background
        #   shift; the main action alone carries the hard offset shadow (PRIMARY)
        # - focus-visible for keyboard operation, equivalent to the mouse (P10):
        #   a ring for the quiet variants, an ink outline set off by 3 px for the
        #   main action (focus_classes)
        # Shared: layout, transition. Border strength comes PER VARIANT
        # (LOUD = loud / QUIET = quiet / PRIMARY) - see VARIANTS above.
        'font-medium inline-flex items-center justify-center transition-all'
      end

      def primary?
        @variant == :primary
      end

      def radius_classes
        primary? ? 'rounded-lg' : 'rounded-md'
      end

      def focus_classes
        if primary?
          'focus:outline-none focus-visible:outline focus-visible:outline-2 focus-visible:outline-ink focus-visible:outline-offset-[3px]'
        else
          'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:ring-ink'
        end
      end

      # The disabled look of a <button> follows its disabled ATTRIBUTE (Tailwind's
      # disabled: variants), so a controller that sets `button.disabled = false`
      # takes the look with it. Until 08.09.2026 the classes were static: the
      # bulk panel's confirming button lost the attribute but kept
      # pointer-events-none, and no real click ever reached it. The static
      # classes stay for a link, which has no disabled attribute, and for a
      # loading button, whose look neo_button_controller.js owns.
      def disabled_classes
        'opacity-50 cursor-not-allowed pointer-events-none'
      end

      def disabled_state_classes
        'disabled:opacity-50 disabled:cursor-not-allowed disabled:pointer-events-none'
      end

      def disabled_look_classes
        # The main action's off state is its own (PRIMARY: surface, edge,
        # faint text, no shadow, no pointer); only the reach is taken away.
        return 'disabled:pointer-events-none' if primary? && @tag == :button && !@loading
        return disabled_state_classes if @tag == :button && !@loading

        @disabled ? disabled_classes : nil
      end

      # The plus of the main action is a drawn stroke cross, not the font's
      # glyph, whose centring and stroke are the font's accident: 18 px in the
      # sign button, stroke 1.5, in the current colour.
      def plus_cross_svg(size, css = nil)
        content_tag(:svg, viewBox: '0 0 18 18', width: size, height: size, class: css, 'aria-hidden': true) do
          tag.path(d: 'M9 2.5v13M2.5 9h13', fill: 'none', stroke: 'currentColor', 'stroke-width': '1.5', 'stroke-linecap': 'round')
        end
      end

      def loading_classes
        'cursor-wait'
      end

      # Height + horizontal padding for buttons with a text label.
      # IconButtonComponent overrides this: icon-only buttons are square.
      def size_classes
        SIZES[@size]
      end

      def component_classes
        [
          base_classes,
          radius_classes,
          focus_classes,
          size_classes,
          VARIANTS[@variant],
          disabled_look_classes,
          @loading ? loading_classes : nil,
          @options[:class]
        ].compact.join(' ')
      end

      # The button inside a form: (button_to). The confirmation belongs to the
      # form (data-turbo-confirm); the button's own confirm would ask a second
      # time before Turbo asks again.
      def form_button_attributes
        attrs = component_attributes.except(:href, :type)
        attrs[:data]&.delete(:neo_button_confirm_value)
        attrs
      end

      def component_attributes
        attrs = @options.except(:class).dup

        attrs[:href] = @url if @tag == :a && @url.present?
        attrs[:disabled] = true if @disabled || @loading
        attrs[:type] = attrs[:type].presence || 'button' if @tag == :button

        if @interactive
          attrs[:data] ||= {}
          attrs[:data].merge!(
            controller: 'neo-button',
            neo_button_loading_value: @loading.to_s,
            neo_button_confirm_value: @confirm
          )
          attrs[:data][:action] = 'click->neo-button#handleClick' if @tag == :button || (@tag == :a && attrs[:data][:turbo_method])
        end

        attrs
      end

      def render_spinner(visible: false)
        hidden_class = visible ? '' : 'hidden '
        content_tag(:span, data: { neo_button_target: 'spinner' }, class: "#{hidden_class}mr-2") do
          # A ring drawn with a border, in the button's own colour: the track at a
          # quarter of it, one side in full.
          tag.span(class: 'block h-4 w-4 rounded-full border-2 ' \
                          'border-[color-mix(in_srgb,currentColor_25%,transparent)] border-t-current animate-spin',
                   'aria-hidden': true)
        end
      end
    end
  end
end
