# The agents' marks

`AgentMarks.xcassets` holds the logo mark of each coding agent the app recognizes, as a custom
symbol (`agent.<kind>`). The app, the widgets, the watch app and its complications draw them
through `AgentGlyph` (GlanceUI) wherever they show which agent runs in a pane: the sidebar, the
tab strip, the agent board, Go to Anything, the pane menus, the widgets and the watch.

These marks are trademarks of their owners. They are used here only to identify each agent next
to its own name and status. They are not Pteron's marks, they do not appear in Pteron's icon,
Beacon or any of Pteron's own branding, and their use implies no endorsement, sponsorship or
partnership. All rights belong to their owners.

## The marks

| Kind | Mark | Owner | Source |
|------|------|-------|--------|
| `claude` | The Claude spark | Anthropic | Anthropic's press kit, linked from <https://www.anthropic.com/news> ("Download press kit"): `Claude logos/3 Claude Spark/SVG/Claude Spark - Clay.svg` |
| `codex` | The OpenAI Blossom (Codex publishes no mark of its own) | OpenAI | <https://openai.com/brand/>, bundle <https://cdn.openai.com/brand/openai-logos.zip>: `SVGs/OAI_OpenAI-Blossom_Black.svg` |
| `gemini` | The Gemini CLI icon | Google | <https://geminicli.com/brand-kit/>: <https://geminicli.com/brandassets/gemini-cli-icon_monotone_on_light.svg> |
| `opencode` | The opencode mark | Anomaly (opencode) | <https://opencode.ai/brand>: <https://opencode.ai/brand/files/opencode-logo-transparent-light.svg> |
| `aider` | Aider's site icon (its favicon's pinned-tab vector; Aider publishes no brand kit) | Aider | <https://github.com/Aider-AI/aider/blob/main/aider/website/assets/icons/safari-pinned-tab.svg> |
| `cursor` | The Cursor cube (2D) | Anysphere | <https://cursor.com/brand>, bundle `cursor-brand-assets.zip`: `General Logos/Cube/SVG/CUBE_2D_DARK.svg` |
| `amp` | None: Amp publishes only a wordmark (<https://ampcode.com/press-kit>) | | Keeps the SF Symbol `cpu` |

## Usage terms, as published

- **Anthropic** (<https://www.anthropic.com/legal/trademark-guidelines>): use only as permitted
  and in materials Anthropic approves beforehand; no alterations, including color or proportion;
  keep a reasonable space around the mark; never imply sponsorship or endorsement.
- **OpenAI** (<https://openai.com/brand/>): use the logo as provided, only where it relates to
  OpenAI's services, and acknowledge that it belongs to OpenAI; don't add colors to the Blossom
  or modify it; give it its prescribed space; don't imply endorsement.
- **Gemini CLI** (<https://geminicli.com/brandassets/gemini_cli_logo_icon_guidelines.pdf>): the
  assets should not be altered; don't make new gradients; clear space of one icon width
  horizontally and half its height vertically. The repository's Apache-2.0 licence grants no
  trademark rights.
- **opencode** (<https://opencode.ai/brand>): tools that work with opencode may say so; don't
  suggest endorsement or sponsorship; don't recolor it in new colors or a single bright color, or
  swap its tones; two strokes of space on every side; at least 16 × 20 px.
- **Aider**: no guidelines published. The repository's Apache-2.0 licence grants no trademark
  rights.
- **Cursor** (<https://cursor.com/brand>): 2D logo by default; call it Cursor. No other rules
  published.

## How they were made

Each mark is its owner's own vector, unchanged in shape: only scaled, placed on Apple's symbol
template and drawn in one color. Nothing else was added or redrawn.

No mark is recolored. On its own (the agent board's ring, the widgets' and the watch's rings) a
mark is drawn in the text's foreground color, near black or near white, and Claude's in
Anthropic's own Clay; a state's color stays on the ring around it. In a tile (the sidebar, the
tab strip, the widgets' tiles) the mark is knocked out in the background color. The widgets'
tinted and clear modes and the Lock Screen and watch faces tint everything, marks included: that
is the system's doing (`AgentGlyph.ink` in GlanceUI).

- Each is sized to read as large as the SF Symbols it replaced at the same font size (about 68
  to 84 units tall at 100 pt, centered on the cap height) with a 7-unit margin on each side.
- The same drawing stands for every weight (Ultralight, Regular and Black), so a mark keeps its
  shape however bold the text around it is.
- The Gemini CLI file draws its icon twice, a gradient copy under a solid one; only the solid one
  is kept. opencode's mark has a second, 20% tone inside its frame; a symbol draws one tone, so
  only the frame is kept. Aider's file is a filled square with the letter cut out of it.
- The files hold paths only, plus the template-version line the asset compiler needs: no other
  metadata, no hidden layers, text or images.
