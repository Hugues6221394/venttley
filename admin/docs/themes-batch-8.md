# Batch 8 theme implementation and acceptance gates

The shared console now has a **disabled appearance pilot**, implemented on
2 October 2026. It adds light, dark and system preferences without changing
authorization, source data, notification semantics or workflow actions. This
is not all-route visual acceptance or completion of Batch 8 or Batch 9.

## Implemented behavior

- `ADMIN_THEME_UI=false` preserves the previous light presentation. When enabled,
  the account menu offers a labelled native appearance selector in both shells.
- `app/themes.css` defines semantic text, surface, status, control-boundary and
  action-fill colors. `globals.css` uses fallbacks to preserve the original
  colors while the flag is off. Tailwind keeps its existing token names and
  alpha modifiers, so shared cards, fields, tables, badges and navigation inherit
  the palette. Solid buttons retain contrasting white text independently of
  the lighter dark-mode accent used for links. Shared sparklines use these tokens.
- Shell, Overview, workflow, inbox, recovery and incident CSS use the new tokens.
  Images and evidence are not inverted or recolored. The system font stack and
  existing layouts remain; there are no new fonts, image requests or animations.
- System mode follows the device through CSS, including live device changes and
  a no-JavaScript fallback. A constant early script reads only the validated
  appearance preference. It never interpolates request or account data. The
  existing Content Security Policy is not widened; deployments must verify
  their script policy. If the early script is blocked, CSS system styling remains
  available, but a saved override can be delayed until hydration.
- Only `light`, `dark` or `system` is written to
  `venttly-console-appearance-v1` in local storage. No identity, source content,
  audit data, notification rows or secrets are stored. Cross-tab updates are
  supported. Blocked storage leaves the current tab usable and displays a
  truthful not-saved message. The preference is browser-local, not an account
  setting or a cross-device sync promise.
- Native control color schemes, visible focus outlines, reduced-motion rules
  and forced-color boundaries are included. The selector stays disabled until
  its handler is ready; listeners are removed on unmount.

## Verification status

`npm run check:theme` passed. It executes the preference controller and early
script with synthetic browser adapters: accepted/hostile values, disabled
rollout, blocked storage, cross-tab changes and listener cleanup. It also checks
that explicit dark and system-dark palettes match, and calculates contrast for
selected text/status/background/action pairs and control/focus boundaries.
These calculations do **not** measure actual composited page contrast or prove
screen-reader, keyboard, hydration, layout or visual acceptance.

Full type checking, enabled/disabled local production builds and whitespace checks passed.
The build's missing-Upstash warning concerns this local build environment only;
the owner reports production Redis is configured. Production was not inspected.

`npm run verify:local -- themes` passed locally on 2 October 2026, including
the active pgTAP suite and both production-build browser stages, with
`controlsRestored: true`. It uses the local-only harness and disposable account.
Two separately built stages exercise enabled and rollback states. The journey checks
selection, reload/navigation, device and cross-tab changes, a 320px viewport,
keyboard focus, blocked storage and no-JavaScript system fallback. It captures
no member content or credentials. Existing database/control preflight remains
in force; pending SQL drafts were not applied. The combined `all` suite and
production script policy are not certified by this targeted run.

`npm run check:analytics-browser` also passed eight isolated synthetic Chrome
cases using the built CSS: flag-off, light, dark and system at 1440px and 320px.
These checks measured rendered retention-cell contrast, page reflow, keyboard
access to chart values and true zero-height bars. They caught a narrow-screen
overflow; grid tracks and positioned scroll containers now contain the table's
hidden accessible labels. This is component-level browser evidence, not a
screen-reader review or a full authenticated analytics journey.

## Remaining acceptance work

1. Verify the actual deployed script policy, slow hydration and no-flash behavior
   on slow devices/networks. Local enabled/rollback journeys have passed.
2. Inspect every route in both themes, all six roles, 200% and 400% zoom, keyboard
   navigation, forced colors and screen-reader announcements. Check focus is not
   obscured by sticky headers or dialogs. Measure the rendered contrast, not
   only palette arithmetic.
3. Analytics chart accents and retention cells now use theme-aware colors and
   accessible value tables; light/dark retention bands pass palette calculations
   and synthetic rendered-contrast checks. Audit dynamic dossiers, exports and
   other page-specific treatments; shared tokens do not certify arbitrary
   inline styles or user-provided media.
4. Complete visual acceptance against the existing selected design references;
   this pass changes semantic colors, not a new 12ui layout direction. No new
   design candidates or external visual approval are claimed.
5. Measure production-build interaction/loading performance and complete the
   separate staging, incident/restore and rollback gates in Batch 9.

## Rollout and rollback

Keep `ADMIN_THEME_UI=false` until verification and owner review. Enable only in
an approved internal environment first; rebuild/restart so statically rendered
routes and dynamic pages agree. The appearance flag is independent of the shell
and backend controls. Disable it and rebuild/restart to restore light styling
and remove the selector. The stored preference is harmless and ignored while
disabled; no source records, audit history or permissions are changed.

No production configuration, migration, pilot, commit or push was performed.
