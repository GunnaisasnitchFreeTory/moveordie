Fate Beams — System Doc (Source of Truth)
Version: V1
Last updated: Feb 4, 2026

This document is the authoritative memory, design contract, and production behavior definition for Fate Beams.
It exists so the project can be resumed, extended, or rebuilt in any future chat or editor session without loss of context.

Core philosophy:
fast loops,
readable chaos,
puzzle-piece systems,
Cursor-first, ship-fast workflow.

---

0) One-Sentence Pitch,

A fast-paced Roblox survival minigame where players gamble their positioning on a shrinking platform as deadly sky beams eliminate unlucky choices, looping rapidly through tension, loss, and reward.

---

1) Current Reality Snapshot (IMPORTANT),

Status: Design-locked, pre-implementation

The core gameplay loop, economy, UI layout, and system boundaries are finalized.
No production code is considered canonical yet.

This project is intentionally treated as a **real game from day one**, not a disposable prototype.
All systems are expected to survive refactors, scaling, and future feature additions.

---

2) Original Vision,

Minimalist.
Punishing.
Replayable.

Inspired by:
luck-based survival games,
shrinking-zone pressure,
“freeze → reveal → resolve” tension loops.

The goal is not one minigame, but a reusable foundation for fast hazard-based survival experiences.

---

3) Core Ideology: Puzzle Pieces (Non-Negotiable),

Every system must be:
modular,
self-contained,
replaceable.

Rules:
one system = one responsibility,
no cross-system internal mutation,
public APIs only,
communication via:
function calls,
events,
shared config/interfaces.

This rule exists to prevent system sprawl and late-stage rewrites.

---

4) Core Gameplay Loop (Canonical),

Players spawn in a Lobby.

If a match is active:
players wait or spectate,
they join automatically next round.

Match flow:
short intermission,
teleport to square platform map,
players move freely,
warning phase (movement freeze),
beam telegraph appears,
beam strike resolves,
unsafe tiles eliminate players,
map shrinks / difficulty increases,
repeat rounds,
resolve win condition,
award coins,
return to lobby,
immediately loop.

Matches must feel fast, unforgiving, and decisive.

---

5) Square Platform & Beam Rules (Canonical),

Platform:
square,
grid-based,
tiles marked safe or unsafe per round.

Beam mechanics:
players are frozen before beams,
telegraph phase is always visible,
strike phase is lethal,
no surprise deaths without warning.

Difficulty scaling:
platform shrinks each round,
hazard density increases,
reaction time shortens.

Goal:
force outcomes,
avoid stalemates,
keep match length short.

---

6) Win Resolution & Rewards,

Primary win:
last player alive.

Fallback:
if no single winner,
top 3 surviving players receive coins.

All rewards are:
config-driven,
server-authoritative,
never client-trusted.

---

7) Economy & Progression,

Currency:
Coins.

Earned via:
participation,
wins,
daily rewards,
spin wheel,
Robux purchases.

Spent on:
pets,
auras,
crown hats / accessories,
crates,
premium Robux items.

All progression is persistent and validated server-side.

---

8) Data & Persistence,

Saved data:
Coins,
owned cosmetics,
server wins (lifetime),
weekly wins,
match history.

Rules:
autosave,
save-on-leave,
disconnect-safe,
no blind overwrites.

Data integrity is non-negotiable.

---

9) UI Direction (Canonical),

All primary UI:
anchored to left side,
vertical stack,
clean open/close behavior.

Includes:
shop,
pets,
auras,
crowns,
spin wheel,
history,
settings,
AFK / spectate.

Rules:
ScreenGui-based,
UIListLayout-driven,
single UI owner/controller.

---

10) AFK & Spectate Rules,

AFK:
toggleable in lobby,
AFK players do not enter matches.

Spectate:
eliminated players can spectate,
camera cycles through alive players,
read-only mode.

---

11) Stats & Leaderboards,

Tracked:
lifetime server wins,
weekly wins (auto-reset).

Displayed via:
lobby leaderboard,
player history UI.

Weekly reset uses time-keyed logic to prevent drift.

---

12) Technical Architecture (High-Level),

Server:
MatchManager,
MapManager,
HazardManager,
EconomyService,
DataService.

Client:
UIController,
SpectateController.

Shared:
Config module,
RemoteEvents / RemoteFunctions.

All tunable values live in Config.

---

13) Global Design Constraints,

Short, intense matches,
minimal downtime,
clear telegraphs,
luck-driven but readable outcomes,
performance-conscious systems.

---

14) Production & Cursor Execution Rules (Non-Design),

Cursor operates as a **Roblox rapid-production engineer**, not a tutorial generator.

Primary mandate:
build once,
reuse everywhere,
ship safely,
iterate fast.

### Production Priorities
- Produce complete, working systems (no pseudo-code, no placeholders)
- Design everything to be reusable across multiple games
- Extend existing systems instead of rebuilding
- Optimize for mobile first (phones & tablets)

### Mobile-First Constraints
- Touch-friendly UI (thumb-safe sizing & spacing)
- Avoid heavy visuals, particles, and post effects
- Avoid expensive per-frame client loops
- Keep Remote traffic minimal and intentional
- Assume low-end devices and poor network conditions
- Provide scalable quality via config

### Ship-Safe Requirements
- Prefer stable module APIs
- Validate inputs and fail gracefully
- Use explicit dependencies (no hidden coupling)
- Add debug flags and verification logs
- Systems must function even if optional subsystems are disabled
- Never claim a feature exists unless it is wired and verifiable at runtime

### How Features Are Built
- Break work into systems first
- Each system = standalone ModuleScript
- Dependencies must be explicit and minimal
- Assume every system will be reused in future games

### Reuse & Iteration Rules
- Treat each new game as a variant on a shared framework
- Favor config-driven behavior over hard-coded logic
- Support easy duplication via folder copying and config swaps
- Clearly explain changes when modifying existing systems

### Tooling Expectations
- Prefer proven patterns over guessing
- Reference Roblox docs and existing systems when useful
- Integrate external patterns cleanly into the modular architecture

### Output Expectations
- Prefer working code over long explanations
- Provide clear folder structures
- Label reusable systems explicitly
- Explain only what is necessary to implement or reuse

End goal:
a Roblox game factory workflow where systems are built once, games are assembled quickly, release speed increases over time, and stability is never sacrificed for speed.

---

END
