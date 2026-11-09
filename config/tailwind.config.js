const defaultTheme = require('tailwindcss/defaultTheme')

module.exports = {
  content: [
    './app/components/**/*.html.erb',
    './app/components/**/*.rb',
    './public/*.html',
    './app/helpers/**/*.rb',
    './app/javascript/**/*.js',
    './app/views/**/*.{erb,haml,html,slim}'
  ],
  theme: {
    extend: {
      fontFamily: {
        sans: ['Inter var', ...defaultTheme.fontFamily.sans],
        mono: ['"JetBrains Mono"', ...defaultTheme.fontFamily.mono],
      },
      // ── SEMANTIC TOKEN LAYER (phase 1, value-preserving) ────────────────────
      // All colours are now backed by CSS variables (raw RGB triples + <alpha-value>,
      // so opacity modifiers like `bg-cream-50/50` keep working). The values live
      // in app/assets/stylesheets/application.tailwind.css (:root), exactly the current
      // state → light stays pixel-identical. Dark mode/per-org later override ONLY
      // these variables in ONE place. See doc/token_layer_HANDOFF.md.
      colors: {
        // Palette (existing, now variable)
        cobalt: {
          50:  'rgb(var(--cobalt-50) / <alpha-value>)',
          100: 'rgb(var(--cobalt-100) / <alpha-value>)',
          200: 'rgb(var(--cobalt-200) / <alpha-value>)',
          300: 'rgb(var(--cobalt-300) / <alpha-value>)',
          400: 'rgb(var(--cobalt-400) / <alpha-value>)',
          500: 'rgb(var(--cobalt-500) / <alpha-value>)',
          600: 'rgb(var(--cobalt-600) / <alpha-value>)',
          700: 'rgb(var(--cobalt-700) / <alpha-value>)',
          800: 'rgb(var(--cobalt-800) / <alpha-value>)',
          900: 'rgb(var(--cobalt-900) / <alpha-value>)',
        },
        cream: {
          50:  'rgb(var(--cream-50) / <alpha-value>)',
          100: 'rgb(var(--cream-100) / <alpha-value>)',
          200: 'rgb(var(--cream-200) / <alpha-value>)',
          300: 'rgb(var(--cream-300) / <alpha-value>)',
          400: 'rgb(var(--cream-400) / <alpha-value>)',
          500: 'rgb(var(--cream-500) / <alpha-value>)',
          600: 'rgb(var(--cream-600) / <alpha-value>)',
          700: 'rgb(var(--cream-700) / <alpha-value>)',
          800: 'rgb(var(--cream-800) / <alpha-value>)',
          900: 'rgb(var(--cream-900) / <alpha-value>)',
        },
        ink: 'rgb(var(--ink) / <alpha-value>)',
        // Cold legacy backed by variables (value-preserving) → dark-capable without view churn.
        // Full scale range, so the override (extend) loses no default shade.
        gray: {
          50:  'rgb(var(--gray-50) / <alpha-value>)',
          100: 'rgb(var(--gray-100) / <alpha-value>)',
          200: 'rgb(var(--gray-200) / <alpha-value>)',
          300: 'rgb(var(--gray-300) / <alpha-value>)',
          400: 'rgb(var(--gray-400) / <alpha-value>)',
          500: 'rgb(var(--gray-500) / <alpha-value>)',
          600: 'rgb(var(--gray-600) / <alpha-value>)',
          700: 'rgb(var(--gray-700) / <alpha-value>)',
          800: 'rgb(var(--gray-800) / <alpha-value>)',
          900: 'rgb(var(--gray-900) / <alpha-value>)',
          950: 'rgb(var(--gray-950) / <alpha-value>)',
        },
        slate: {
          50:  'rgb(var(--slate-50) / <alpha-value>)',
          100: 'rgb(var(--slate-100) / <alpha-value>)',
          200: 'rgb(var(--slate-200) / <alpha-value>)',
          300: 'rgb(var(--slate-300) / <alpha-value>)',
          400: 'rgb(var(--slate-400) / <alpha-value>)',
          500: 'rgb(var(--slate-500) / <alpha-value>)',
          600: 'rgb(var(--slate-600) / <alpha-value>)',
          700: 'rgb(var(--slate-700) / <alpha-value>)',
          800: 'rgb(var(--slate-800) / <alpha-value>)',
          900: 'rgb(var(--slate-900) / <alpha-value>)',
          950: 'rgb(var(--slate-950) / <alpha-value>)',
        },
        black: 'rgb(var(--black) / <alpha-value>)',
        white: 'rgb(var(--white) / <alpha-value>)',
        // purple baked into variables (WS-3): AI/special accent -> flips in dark via the .dark ramp,
        // instead of an !important band-aid. Light == Tailwind default (same values).
        purple: {
          50:  'rgb(var(--purple-50) / <alpha-value>)',
          100: 'rgb(var(--purple-100) / <alpha-value>)',
          200: 'rgb(var(--purple-200) / <alpha-value>)',
          300: 'rgb(var(--purple-300) / <alpha-value>)',
          400: 'rgb(var(--purple-400) / <alpha-value>)',
          500: 'rgb(var(--purple-500) / <alpha-value>)',
          600: 'rgb(var(--purple-600) / <alpha-value>)',
          700: 'rgb(var(--purple-700) / <alpha-value>)',
          800: 'rgb(var(--purple-800) / <alpha-value>)',
          900: 'rgb(var(--purple-900) / <alpha-value>)',
        },

        // Semantic aliases (additive, no view change needed). They point to the same
        // variables → new/converted views can use them; existing ones stay valid.
        surface:          'rgb(var(--cream-50) / <alpha-value>)',   // content/table surface
        'surface-shell':  'rgb(var(--cream-100) / <alpha-value>)',  // shell/sidebar/sunken
        'surface-raised': 'rgb(var(--white) / <alpha-value>)',      // modal/popover/input
        selected:         'rgb(var(--cream-200) / <alpha-value>)',  // active/selected
        divider:          'rgb(var(--cream-200) / <alpha-value>)',  // thin dividers
        edge:             'rgb(var(--cream-300) / <alpha-value>)',  // card/table edge
        'edge-strong':    'rgb(var(--ink) / <alpha-value>)',        // ink stroke (== ink)
        heading:          'rgb(var(--cream-900) / <alpha-value>)',  // headings
        body:             'rgb(var(--cream-800) / <alpha-value>)',  // body text
        muted:            'rgb(var(--cream-600) / <alpha-value>)',  // muted/caption
        faint:            'rgb(var(--cream-500) / <alpha-value>)',  // very quiet/placeholder
        accent:           'rgb(var(--accent) / <alpha-value>)',     // primary action (lime), FIXED, no per-user override
        info:             'rgb(var(--info) / <alpha-value>)',       // data/links/focus
        brand:            'rgb(var(--brand) / <alpha-value>)',      // per-user org recognition colour: ONLY chrome/identity (chip/edge line/banderole), NEVER action/status. Default :root = lime-200.
        'btn-primary':    'rgb(var(--btn-primary) / <alpha-value>)', // primary button fill (adjustable per theme)
        // WS-0 role split: ink was stroke+text+scrim at once. Now separate tokens per role.
        stroke:           'rgb(var(--stroke) / <alpha-value>)',     // STROKE (borders), decoupled from ink text/scrim
        'on-fill':        'rgb(var(--on-fill) / <alpha-value>)',    // text on coloured/dark fill, light in ALL themes
        scrim:            'rgb(var(--scrim) / <alpha-value>)',      // modal backdrop, dark regardless of theme (with /60)
        shadow:           'rgb(var(--ink) / <alpha-value>)',        // micro shadows
        // Booked time as bar segments. The empty rest is NOT painted, it is the
        // transparent track with its border. The only
        // consumer is NeoTimeShareBarComponent; measurements + reasoning sit with the
        // variables in application.tailwind.css.
        'time-in-billing': 'rgb(var(--time-in-billing) / <alpha-value>)',
        'time-billed':     'rgb(var(--time-billed) / <alpha-value>)',
      },
      animation: {
        marquee: 'marquee 30s linear infinite',
      },
      keyframes: {
        marquee: {
          '0%':   { transform: 'translateX(0)' },
          '100%': { transform: 'translateX(-50%)' },
        },
      },
      // Hard offset shadows (blur 0) mean one thing: "press me".
      // press = the main action at rest, press-hover = the main action hovered,
      // lift = a card that is wholly a link or button, while hovered.
      // Drawn from --ink so every theme follows; the dark theme drops them
      // (application.tailwind.css). Soft shadows for menus and modals come
      // later, not here. Held by spec/architecture/shadow_levels_guard_spec.rb.
      boxShadow: {
        press: '2px 2px 0 0 rgb(var(--ink))',
        'press-hover': '3px 3px 0 0 rgb(var(--ink))',
        lift: '4px 4px 0 0 rgb(var(--ink))',
      },
      zIndex: {
        'base': '0',
        'sticky': '10',
        'backdrop': '20',
        'dropdown': '30',
        // Companion lane (assistant panel, S3a T4): above page content, below
        // every overlay. Shares the level with dropdowns and wins ties because
        // it is rendered after <main> in the body.
        'drawer': '30',
        'sidebar': '40',
        'modal': '50',
        'toast': '60',
        'popover': '70',
        'mobile-nav': '80',
      },
    },
  },
  safelist: [
    // The status ladder of the surface table (TicketColorMap, app/models is not scanned)
    'bg-cobalt-500', 'bg-amber-500', 'bg-green-500', 'bg-cream-500', 'bg-cream-400', 'bg-red-500',
    'bg-cobalt-100', 'bg-amber-100', 'bg-green-100', 'bg-cream-200', 'bg-red-100',
    'text-cobalt-900', 'text-amber-900', 'text-green-900', 'text-cream-700', 'text-cream-600', 'text-red-900', 'text-red-800',
    'bg-red-100',
    'bg-red-400',
    'bg-amber-100',
    'bg-amber-400',
    'bg-green-100',
    'bg-green-400',
    'hover:bg-red-300',
    'hover:bg-amber-300',
    'hover:bg-green-300',
    'bg-sky-100',
    'border-sky-600',
    'text-sky-800',
    'bg-cobalt-50',
    'bg-cobalt-100',
    'bg-cobalt-200',
    'bg-cobalt-600',
    'bg-cobalt-700',
    'text-cobalt-600',
    'text-cobalt-700',
    'text-cobalt-900',
    'border-cobalt-200',
    'border-cobalt-300',
    'border-cobalt-500',
    'border-cobalt-600',
    'border-l-cobalt-500',
    'border-lime-400',
    'border-slate-400',
    'bg-lime-200',
    'bg-yellow-200',
    'bg-green-200',
    'bg-slate-200',
    'bg-red-200',
    'text-slate-900',
    'text-slate-600',
    'text-red-900',
    'hover:bg-cobalt-700',
    'bg-cream-50',
    'bg-cream-100',
    'bg-cream-200',
    'bg-cream-300',
    'hover:bg-cream-100',
    'hover:bg-cream-200',
    'border-cream-200',
    'border-cream-300',
    'border-l-cream-300',
    'border-l-cream-400',
    'text-cream-500',
    'text-cream-600',
    'text-cream-700',
    'text-cream-800',
    'text-cream-900',
    'bg-ink',
    'text-ink',
    'border-ink',
    'border-l-ink',
    'bg-cream-900',
    'text-cream-50',
    'text-cream-200',
    'border-cream-400',
    'border-cream-900',
    'bg-amber-50',
    'bg-amber-200',
    'border-amber-300',
    'border-amber-500',
    'text-amber-800',
    'z-base',
    'z-sticky',
    'z-backdrop',
    'z-dropdown',
    'z-drawer',
    'z-sidebar',
    'z-modal',
    'z-toast',
    'z-popover',
    'z-mobile-nav',
    // Used only by the views of the operator console (gboyke/lalabase-operator),
    // which ships no assets and loads this build (doc/oss_core_split_plan.md 9.1
    // "as built"). Its spec/tailwind_classes_spec.rb compares its views against
    // the build: a class missing here fails there, with its name. Nothing else
    // keeps this list; the engine's views are not in `content` on purpose.
    'col-span-2',
    'col-span-3',
    'gap-x-8',
    'md:grid-cols-12',
    'min-w-[9rem]',
    'sm:grid-cols-[max-content_1fr]',
    'text-lime-900'
  ],
  plugins: [
    require('@tailwindcss/forms'),
    require('@tailwindcss/typography'),
    require('@tailwindcss/container-queries'),
  ],
  darkMode: 'class'
}
