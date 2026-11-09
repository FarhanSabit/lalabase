# frozen_string_literal: true

class NeoCardComponent < ViewComponent::Base
  # Warm-Editorial (Part G): default = `surface` (warm cream-50, stands out from the
  # cream-100 base). `white` remains available for TRULY floating layers (G5: modal/
  # popover). Semantic tints (lime/amber/red/green) carry meaning; the decorative
  # cool ones (blue/cyan/orange/gray) are mapped to warm until the tint axis (G4) takes effect.
  VARIANTS = {
    surface: 'bg-cream-50',
    white: 'bg-surface-raised',
    ticket: 'bg-yellow-300',
    lime: 'bg-lime-50',
    blue: 'bg-cream-50',
    amber: 'bg-amber-50',
    cyan: 'bg-cream-50',
    orange: 'bg-cream-50',
    green: 'bg-green-50',
    red: 'bg-red-50',
    gray: 'bg-cream-100',
    transparent: 'bg-transparent'
  }.freeze

  # P1/P6: shadow = elevation (card "sits on the surface"); hover lift = "clickable".
  # :always = static elevation WITHOUT hover motion (non-interactive content panels).
  # :hover  = lift only on hover — use ONLY for genuinely clickable/interactive cards.
  # :hover draws the `lift` token in ink (tailwind.config.js); :always still writes its value (later slice).
  SHADOWS = {
    none: '',
    hover: 'hover:shadow-lift hover:-translate-x-0.5 hover:-translate-y-0.5',
    always: 'shadow-[2px_2px_0_0_#14110c]'
  }.freeze

  PADDINGS = {
    none: '',
    small: 'p-4',
    medium: 'py-6 px-4 md:px-5 lg:px-8',
    large: 'p-8'
  }.freeze

  ALLOWED_TAGS = %i[div section article].freeze

  def initialize(
    variant: :surface,
    shadow: :hover,
    padding: :medium,
    tag: :div,
    classes: nil,
    data: {},
    **options
  )
    @variant = variant.to_sym
    @shadow = shadow.to_sym
    @padding = padding.to_sym
    @tag = ALLOWED_TAGS.include?(tag.to_sym) ? tag.to_sym : :div
    @classes = classes
    @data = data
    @options = options
  end

  private

  def component_classes
    [
      'border border-cream-300 rounded-lg',
      VARIANTS.fetch(@variant, VARIANTS[:surface]),
      SHADOWS.fetch(@shadow, SHADOWS[:hover]),
      PADDINGS.fetch(@padding, PADDINGS[:medium]),
      'transition-all duration-200',
      @classes
    ].compact.reject(&:blank?).join(' ')
  end
end
