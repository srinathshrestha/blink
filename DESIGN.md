# Blink — Design System ("Instrument")

*Playful precision: a serious instrument with a playful soul.*

Blink should look like something a person made on purpose: a matte hardware object, not a glowing app. No blur, no glow, no gradients, no translucent layers, no rainbow of tag colours. Everything below is fixed; there are no themes or options.

## 1. Principles (in priority order)

1. **Fast is a look.** Crisp edges, opaque surfaces, no motion that makes you wait. Anything that costs frames is cut.
2. **One accent, one meaning.** Orange means *"this is where your input is acting"*: the caret, the letters you matched, what Enter will do. It never decorates.
3. **Structure carries identity, not effects.** A strict grid, a fixed type system, an original icon alphabet and a hand-built numeral display make Blink recognisable with the colours stripped out.
4. **One expressive moment.** The calculator answer is the thing Blink is proudest of, so it is shown on a dot-matrix LCD. Everything else stays quiet.
5. **Remove before adding.** Every element must improve usability, carry identity, or remove a decision.

## 2. Directions explored

| | A · Instrument | B · Editorial | C · Teletype |
|---|---|---|---|
| Idea | Warm paper, black ink, one orange; hardware cues (keycaps, inverted selection bar, LCD) | Cream paper, serif names, italic labels, vermilion rule | Black, acid-lime, all mono, ASCII icons |
| Legibility | Excellent | Excellent | Good |
| Scanning by type | Icons + 3-letter tags | Words only → slower | Glyphs are ambiguous |
| Identity | Distinct, physical, ties to the calculator | Distinct, but reads as a reading app, not a tool | The look generated UI defaults to ("cyber") |
| Cost | Cheapest to draw (opaque, flat) | Cheap | Cheap |
| Verdict | **Chosen** | Rejected: calm but not "playful precision" | Rejected: cliché |

The previous design (dark glass, violet/cyan glow, gradient tiles, neon pills) was a fourth direction and was retired because it matched what generated interfaces tend to look like.

## 3. Tokens

**Colour** (light / dark)
`paper #ECE9E2 / #1C1C1B` body · `ink #1A1A19 / #ECE9E2` text and selected bar · `muted #5F5C56 / #A8A49B` secondary text · `hair #CBC7BD / #3A3936` rules · `recess #DED9CE / #121211` LCD well · `keyFill #DCD8CE / #2B2B29`, `keyEdge #BDB8AD / #484641` keycaps · `lcdOff #CDC9BE / #252523` unlit dots · `accent #FF5A1F` for shapes (caret, LCD underline) · `accentText #C93A07 / #FF6A33` for text on the body · `accentSoft #FF8A5C / #C93A07` for text on the selected bar.

**Type — three voices**
- *People's words*: Helvetica Neue. Query 24 Light; placeholder 18 Regular; names 14.5 Regular, matched letters Medium + accent.
- *Machines' words*: SF Mono. Paths 10.5, converted values 15 Medium, key names 9.5 Semibold.
- *Blink's own voice*: a **5 × 7 dot-matrix** set drawn by Blink, A–Z 0–9 , . −. Answers on the LCD (6.4 pt cells), kind tags in the list (2 pt cells).

**Icon alphabet** — 20-unit grid, butt caps, mitred joins, no curves except circles. Files share one *page* silhouette plus one inner mark; folders share one *folder*. **Solid = launchable (project), outline = passive.** Each sits on a 26 × 26 keycap (28 in settings), radius 5. Apps keep their real icons.

**Geometry** — query bar 58, row 46, LCD row 88, footer 44 (14 pt clear below the keys), panel 680 wide, radius 10; rows and keycaps radius 5, LCD well 6. Icon x = 18, text x = 56.

**Selection** — a solid bar of ink with paper text. It inverts between modes automatically.

**Hints** — outlined keys with plain labels.

## 4. The mark

The **block caret**: 10 × 26, solid, blinking at 1.1 s, solid for 0.5 s after each keystroke. It is the only thing that moves.

## 5. Motion

Only the caret. Opening, typing, selecting and closing are instant. *Instant is the animation.*

## 5a. Refinement log (why each change was made)

Problems measured on the previous build (WCAG contrast) or visible in screenshots, and the decision for each:

| Problem | Evidence | Decision |
|---|---|---|
| Stray orange block in the list | Screenshots: caret stranded after the panel resized | Caret's y is now a constraint to the field; only x is measured |
| Last row clipped | Default table style hid ~10 pt above the rows | `table.style = .plain`, zero insets |
| Footer keys touching the edge | Screenshot | Footer 26 → 44, 14 pt clear below the keys; footer view taller than the keys so outlines aren't clipped |
| Placeholder oversized and faint | 26 pt at 2.1:1 (light), 2.67:1 (dark) | 18 pt at 5.5:1 / 6.86:1 |
| Names too heavy | Medium weight competed with the match highlight | Regular; only matched letters are Medium |
| Rows too spacious | 54 pt fits 6 rows where 46 pt fits 7 | Row 46, keycap 26 |
| Secondary text weak | Muted 3.9:1 (light), separators 1.96:1 | Muted 5.5:1 / 6.86:1, separators no longer faded |
| Orange text weak on paper | 2.57:1 | `accentText` for text; plain accent only for shapes |
| Paths lost the end and repeated the name | Screenshots | Path shows the parent folder only, truncates in the middle, one quiet tone |
| Redundant labels | An app icon or folder glyph already says it; `⇄` already says conversion | No APP, DIR, CNV or CAL. PRO stays (it changes what Enter does); file kinds stay (they share a silhouette) |
| Inactive settings controls faint | Extra 70 % alpha on top of muted; off switch nearly invisible | Alpha removed, off thumb is muted |

**Identity: recognisable without orange or a logo.** Tested by rebuilding with the accent replaced by grey and reading the screenshots.

| Alternative | Result |
|---|---|
| Dot-matrix tags in the list | **Kept.** Extends the LCD voice to every list and does a job (kind at a glance). A 1.5 pt cell read as ghost outlines; 2 pt is legible |
| Ruler ticks under the query | **Kept, at the owner's call.** I first rejected it as decoration; it is identity rather than function, and it makes the panel read as an instrument at a glance. Tick every 8 pt, longer every 40 pt |
| Screw heads, panel seams, bevels | Not built. Skeuomorphic decoration, against the brief |

With the orange removed, Blink is still identified by four things together: dot-matrix tags and answers, the ruler, keycap icons, the solid inverted bar, and the block caret.

## 6. Non-goals

No themes, no font or icon options, no per-user customisation. One design, fixed.
