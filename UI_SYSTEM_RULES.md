# UI SYSTEM RULES  
**Version:** 1.0  
**Last Updated:** 2026-02-08  

---

## SYSTEM ROLE & SCOPE

This document defines the **UI system itself**.

- It defines **structure, constraints, and expectations**
- It does **NOT** define behavior, tone, or prompting style
- It does **NOT** define how ChatGPT or Cursor should think

Related documents:
- `CHATGPT_OPERATING_RULES.md` → defines HOW ChatGPT applies this system
- `.cursor/rules/` → defines HOW Cursor implements this system in code
- `ROADMAP.md` → defines WHEN UI changes happen

This file is the **source of truth for UI consistency**.

---

## UI SYSTEM PHILOSOPHY

The UI is a **communication system**, not decoration.

Core principles:
- **Clarity over aesthetics**
- **Readability before animation**
- **Consistency before creativity**
- **Reusability across projects**
- **No per-screen hacks**

The UI must:
- Be immediately readable on first glance
- Scale cleanly across devices
- Avoid “AI-looking” randomness
- Feel intentional, not auto-generated

---

## FIGMA & DESIGN SOURCE OF TRUTH

Figma is the **visual design source**, not the UI system itself.

### Role of Figma
Figma is used to define:
- Layout and spacing
- Visual hierarchy
- Typography intent
- Color intent
- Component grouping

Figma does **NOT** define:
- Scaling logic
- Aspect ratio constraints
- Final responsiveness behavior
- Interaction scripting
- Animation timing logic

### Authority Rules
- Figma defines **how the UI should look**
- This document defines **how the UI must be built**
- Roblox Studio defines **how the UI actually behaves**

If there is conflict:
1. UI SYSTEM RULES override Figma
2. Structural rules override visual intent
3. Readability overrides aesthetics

### Figma → Implementation Contract
When Figma designs are provided:
- Cursor must treat them as **blueprints**
- No creative reinterpretation
- No visual “improvements” unless requested
- Layout and hierarchy must be respected

Figma designs must be:
- Modular
- Component-based
- Reusable across panels and future projects

---

## STRUCTURAL CONTRACT (NON-NEGOTIABLE)

### ScreenGui Rules
- Each major UI feature gets its **own ScreenGui**
- One ScreenGui = one responsibility
- No “mega” ScreenGuis

### Container Rules
- Each ScreenGui has **one main container frame**
- The container owns:
  - `UIAspectRatioConstraint`
  - Overall scaling logic
- **Children never own aspect ratio constraints**

### Scaling Rules
- **Scale is required**
- Offset is allowed only for:
  - Tiny internal spacing
  - Icon nudges
- No mixed scaling systems inside the same UI

### Hierarchy Rules
- Clear parent → child structure
- ZIndex must be intentional
- No overlapping logic without reason

---

## TEXT & READABILITY RULES

- Text must be readable at a glance
- Default assumption: **text is too small**
- Use:
  - Larger font sizes
  - High contrast
  - UIStroke or background separation when needed
- Text scaling must be enabled where appropriate

If text is unreadable:
1. Fix contrast
2. Fix size
3. Fix background
4. Only then consider stylistic changes

---

## COLOR & VISUAL CONSISTENCY

- Use a **defined color language**
- Vibrant does NOT mean noisy
- UI elements must visually belong to the same system
- Glows, gradients, and strokes must be intentional

Prefer:
- White or grayscale base assets
- Color applied in-engine for flexibility
- Reusable gradients and strokes

---

## ANIMATION RULES

- Animation is **additive**, never foundational
- UI must function perfectly **without animation**
- Animations should:
  - Be smooth
  - Be short
  - Never block readability
- No animation spam

Order of priority:
1. Structure
2. Readability
3. Interaction
4. Animation (last)

---

## UI CHANGE RULES (VERY IMPORTANT)

- **No UI changes unless explicitly requested**
- Do NOT:
  - Fix unrelated UI
  - “Improve” UI without scope
  - Revisit previously approved elements
- Each UI issue is treated independently

If something is not mentioned, it is assumed **correct and intentional**.

---

## SYSTEM REUSE & FUTURE-PROOFING

This UI system must:
- Be reusable across future projects
- Support:
  - New panels
  - New shops
  - New features
- Avoid hardcoded assumptions

Every UI should be:
- Modular
- Replaceable
- Extendable without refactoring

---

## FINAL NOTE

This file defines **WHAT the UI system is**.

It intentionally avoids:
- Prompting behavior
- AI decision-making
- Tool-specific instructions

Those live elsewhere by design.

Breaking these rules creates:
- Inconsistent UI
- Hard-to-maintain systems
- “AI-generated” feel

Follow this system strictly.
