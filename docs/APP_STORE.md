# App Store listing — draft

Written from what is actually implemented. Every claim below is one the app can
stand behind.

---

## Name

**BEFORE**

## Subtitle (30 characters)

`Your second opinion on buys` — 27 characters.

Alternatives, all within limit:
`Ask before you buy` (18) · `Know before you buy` (19) · `Buy better, not more` (20)

## Promotional text (170 characters)

> BEFORE looks at what you are about to buy, checks it against what you already
> own, and tells you straight: buy it, wait, or skip it.

---

## Description

> **Before you buy it, ask BEFORE.**
>
> You are standing in a shop, or you are three tabs deep at midnight, and you
> cannot tell whether you actually want the thing or just want to want it.
>
> Send it to BEFORE. A photo, a screenshot, or a link. You get a straight answer
> — BUY, WAIT, or BYE — and the reasoning behind it.
>
> **It answers a different question.**
> Not "is this a good product". Shops already tell you that. BEFORE asks whether
> it is a good purchase *for you*: does it work with what you own, will you
> actually wear it, is it priced like the things you normally buy.
>
> **It is allowed to say no.**
> BEFORE will tell you that you already own something similar. That is the whole
> point. An app that says yes to everything is a shop with extra steps.
>
> **It learns what you actually wear.**
> Tell it what you bought, what you skipped, and how it worked out. Each answer
> makes the next one more specific to you.
>
> **It tells you what it does not know.**
> If the brand is unclear or the price could not be confirmed, BEFORE says so
> rather than guessing. Estimates are labelled as estimates.
>
> **Check from anywhere.**
> Share a post, a product page, or a screenshot straight to BEFORE from any app.
>
> — — —
>
> **What you get free**
> Five checks a month. Full verdicts, full reasoning — not a preview.
>
> **BEFORE Plus**
> Unlimited checks, full wardrobe memory, outcome tracking, and insights into
> your own shopping patterns.
>
> — — —
>
> BEFORE gives AI-generated advice based on the information you provide. It can
> be wrong, and it will sometimes tell you not to buy something. Your wardrobe
> and purchase history are private, are never sold, and can be deleted at any
> time from Settings.

---

## Keywords (100 characters)

```
shopping,wardrobe,closet,outfit,style,budget,second opinion,fashion,declutter,spending,capsule
```

97 characters. Deliberately omits "AI" — it is a crowded, low-intent term and the
description already discloses it where it matters.

---

## Claims to avoid

Never write, in the listing or in the app:

| Do not say | Why |
| --- | --- |
| "Guaranteed to save money" | unprovable, and BEFORE cannot know what someone would have bought |
| "You saved $X" | only "potential spend avoided" is defensible |
| "Always knows best" | it is advice, and it is sometimes wrong |
| "Predicts your purchases" | it does not predict, it advises |
| "AI stylist" | wrong product; the primary question is whether to buy |
| "Only 2 left" | fabricated scarcity — the safety scan strips this from model output too |

The in-app copy follows the same rules, and the phrase "potential spend avoided"
appears in the code with a comment explaining why it is not "you saved".

---

## Review notes

> **Signing in**
> BEFORE uses Sign in with Apple only. No other account type exists.
>
> **Demo**
> A demo account is not required — sign in with any Apple ID and the app is fully
> usable with five free checks. If a reviewer prefers not to sign in, we can
> supply a TestFlight build launched with `-BEFOREUseMockData`, which serves
> bundled fixtures with no network calls.
>
> **AI-generated content**
> Every verdict is AI-generated from information the user supplies. This is
> disclosed in "See how it works" during onboarding and again on the Profile
> screen. The model produces signals only; the final score and verdict are
> computed by deterministic server-side code.
>
> **Content safety**
> The app analyses clothing and products, never people. If an image contains a
> person, only the clothing is analysed. Model output is additionally scanned
> server-side, and any appearance, body, age, or protected-attribute judgement
> blocks the analysis outright rather than reaching the user.
>
> **Subscriptions**
> `before.plus.monthly` and `before.plus.yearly` in group `before_plus`. Prices
> shown in-app always come from StoreKit, including the annual saving, which is
> calculated from the two live prices. Auto-renewal is disclosed on the paywall.
> Restore Purchases is on the paywall and on the Profile screen.
>
> **Account deletion**
> Profile → Delete account, behind two confirmations. It permanently deletes the
> account, all analyses, saved items, wardrobe items, outcomes, and stored
> images. The flow states clearly that an App Store subscription must be
> cancelled separately through Apple, because we cannot do it.
>
> **Photos**
> The app uses `PhotosPicker` and never requests full photo library access.
> Camera access is requested only when the user taps "Take Photo". Images are
> resized and stripped of metadata on device before upload and are stored in a
> private bucket, accessed only through short-lived signed URLs. Images for
> analyses the user does not save are deleted within 24 hours.

---

## Screenshots — the order that tells the story

1. **Home.** "Before you buy it, ask BEFORE." with the Check something button.
2. **The result.** WAIT 78 with the score ring and the factor breakdown. This is
   the screenshot that sells the app.
3. **The good and the concern.** Specific reasoning referencing the user's own
   wardrobe.
4. **A BYE.** Showing that it says no is more persuasive than showing that it
   says yes.
5. **History.** Decisions building into a shopping memory.
6. **Paywall.** Honest, with the auto-renewal line visible.

No device frames with invented review quotes. No fake notification badges.

---

## Age rating

4+. No objectionable content, no user-generated content shown to other users, no
web browser, no gambling.

---

## Category

Primary: **Shopping**. Secondary: **Lifestyle**.

Shopping is right even though BEFORE reduces buying — it is where people look for
this, and the positioning ("buy better, not more") reads more sharply there.
