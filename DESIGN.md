# AM Track interface

## Theme
A quiet native listening journal. Music titles lead; recording and archive maintenance remain easy to reach without competing with the music. The menu is for a quick choice, the window for browsing.

## Palette
Use macOS semantic colors: `windowBackgroundColor` for the shell, `textBackgroundColor` for the reading surface, primary and secondary system text, the user's accent for music marks and the queue action, and orange with a warning symbol for problems. Support Aqua and Dark Aqua without hard-coded light backgrounds.

## Typography
Use the Apple system font with native CJK fallback. Page titles: 23 pt semibold. Song titles: 14 pt semibold in the window, 13 pt medium in the menu. Artist and album metadata: 12 pt. Reasons and status: 11 pt. Counts and timestamps use tabular figures. Long titles can wrap to two lines in the window; menu titles fit a measured width and retain the full identity in tooltips.

## Components
Keep native buttons, menus, segmented navigation, table, search, and disclosure controls. Their press, focus, and disabled feedback come from AppKit and SwiftUI. A song row has Play, Like, and a labeled accessibility menu containing Not now, Less like this, and Find in Music. The single prominent action is Next for you. The current-song feedback menu is available from either page.

The dropdown stays at 340 pt, fitting displayed menu text within native gutters and retaining complete text in tooltips. The header and commands share a solid, theme-aware window-background material, with within-window blending so pages behind the dropdown do not tint it.

The dropdown uses a non-interactive playback heading followed by real NSMenuItems. Recommendation rows have a title and artist line; album rows explicitly name their type. The first five recommendations fit a quick scan. Browse all recommendations opens the complete batch. Keep recommendation identities stable while the menu is open.

## Layout
Use 24 pt window insets, 16–18 pt between sections, and 12–14 pt within music groups. The playback summary and recording control share the header. Navigation and contextual search sit directly below. Recommendations use one continuous reading surface with dividers, not individual cards. History maintenance lives in an inline disclosure; warnings stay visible even when it is collapsed.

## Depth
Semantic background steps and hairline dividers establish structure. No gradients, decorative shadows, glass cards, or synthetic album artwork. SF Symbols identify media types and actions. Radius scale: 3 pt for metadata tags, 7–8 pt for fields and tables, 10 pt for the reading surface and media marks.

## Guardrails
- Show playback independently of recording state.
- Keep native keyboard navigation and menu highlighting.
- Label icon-only actions for accessibility and provide explanatory tooltips.
- Keep disabled playback and album validation behavior intact.
- Distinguish an empty library, a search with no results, and library loading.
- Do not imply observed seconds are completed plays or invent imported timestamps.
- Preserve explicit History.dat checks and local-data privacy.
- Never refresh menu rows under the pointer.

## Window behavior
Initial content: 1100 × 680 pt. Minimum window frame: 888 × 490 pt. The table and recommendation list scroll; content must not grow the AppKit window. Setup scrolls at short heights. Light and dark appearances use the same hierarchy. No custom motion: browsing and switching pages must feel immediate.

## Maintenance guide
Use `Interface.swift` for visual changes and its semantic tokens for surfaces. Keep non-visual Music behavior in the model and playback files. Run the design preview command in `docs/DEVELOPMENT.md` for deterministic native renders using an isolated temporary archive. Preview fixtures are separate from runtime data.

## Song preference feedback

Like and Less like this sit together as direct icon buttons on the current song
and recommendation rows. Like is a feedback action: a new click briefly fills
the heart pink and shows a song-specific footer receipt with Undo for three
seconds, then returns to an outline. Saved likes continue to influence ranking
but never leave persistent hearts in history, recommendation subtitles, or
current-song menu commands. Repeating Like sends positive feedback again;
it does not clear the saved preference. Less like this keeps its selected
warm-brown treatment and can be cleared by pressing it again. Native menu
receipts offer Undo while available; menu rows stay stable until dismissal.
Each receipt has an identity so an earlier expiry cannot dismiss a later click.
Native press feedback is immediate, with no added animation.
