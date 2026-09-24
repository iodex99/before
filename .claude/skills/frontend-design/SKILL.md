---
name: frontend-design
description: Apply the BEFORE design language to any iOS UI in this project.
user-invocable: true
---

# BEFORE design language

Premium, editorial, intelligent. Feminine without being childish. Closer to a
modern finance app than to a shopping app. Restraint is the brand.

## Tokens — always via `BeforeTheme`, never literals
Light: background `#FAF8F5` (warm off-white), surface `#FFFFFF`,
primaryText `#121212`, secondaryText `#6B6660`, divider `#E6E1DA`,
accent `#6E2639` (burgundy).
Dark: background `#121110`, surface `#1C1A18`, primaryText `#F5F2ED`,
secondaryText `#9A948C`, divider `#2E2B27`, accent `#C4677F`.
Verdicts: BUY `#2F6B4F`, WAIT `#9A6B1F`, BYE muted `#8A3D3D` — never alarm red.

## Typography
System SF Pro only. Display numerals for scores (`.monospacedDigit` on anything
that changes). Hero 34–40pt bold, tight tracking (-0.02em). Section headers 13pt
uppercase, wide tracking, secondaryText. Body 16–17pt. Never below 12pt.

## Spacing and shape
4pt grid. Screen gutter 20pt. Section spacing 32pt. Card padding 20pt.
Corner radius 16pt for cards, 12pt for controls, full-round only for pills.
One hairline divider is better than two boxes.

## Rules
- Shadows: at most one soft shadow per surface, or none. Prefer a hairline border.
- No gradients except the score ring sweep. No glassmorphism. No sparkle icons.
- No emoji in product UI.
- Colour never carries meaning alone — every verdict shows its word.
- Animation: 0.25s easeOut, purposeful. The score ring may animate once on reveal.
- Empty states get a sentence of real copy, not an illustration.

## Voice
Human, brief, specific. "You already own something similar." not "Duplication
detected". Never "AI-powered", never "unlock the future of shopping", never
guarantee savings.
