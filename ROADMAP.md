Fate Beams — Roadmap (Anti-Drown)
Golden Rule:
Only build the next step after the current step works.
After each step: Test → Commit → Push.

---

MVP PHASE 1 — Get Playable (Ship the Loop)

Goal:
A fully playable Fate Beams match loop with saved progression.
Fast matches, clear outcomes, no polish required.

---

STEP 0 — Setup

[ ] Repo structure clean  
[ ] Rojo sync working  
[ ] Cursor rules + AGENTS.md in place  
[ ] Source of Truth + ChatGPT Operating Rules committed  
[ ] Basic lobby map exists (can be ugly)

---

STEP 1 — Lobby Flow + Player Gating

[ ] Players spawn into lobby  
[ ] Detect if match is active  
[ ] If match active → player waits or spectates  
[ ] AFK toggle available (basic, no UI polish)  
[ ] Track player state: Lobby / Waiting / InMatch / Spectating  

---

STEP 2 — Match State Machine Skeleton

[ ] MatchManager created  
[ ] States defined: Intermission / Playing / Ending  
[ ] Intermission timer works  
[ ] Players teleported into match map  
[ ] Clean handling of player leave/disconnect  

No hazards yet — just flow.

---

STEP 3 — Square Platform Map (Static)

[ ] Square platform spawns reliably  
[ ] Grid or tile layout established  
[ ] Platform cleanup/reset between matches  
[ ] Players can move freely on platform  

No shrinking, no beams yet.

---

STEP 4 — Round Loop Skeleton

[ ] Round counter exists  
[ ] Freeze phase implemented  
[ ] Round timing configurable  
[ ] Repeat rounds inside a match  
[ ] Match ends on win condition  

Still no deaths yet — structure first.

---

STEP 5 — Beam Hazard System (Minimal)

[ ] Unsafe tiles selected per round  
[ ] Telegraph phase visible  
[ ] Beam strike resolves  
[ ] Players on unsafe tiles eliminated  
[ ] Eliminated players enter spectate  

This is the **core gameplay moment**.

---

STEP 6 — Difficulty Scaling

[ ] Platform shrinking per round  
[ ] Hazard density increases  
[ ] Reaction time decreases  
[ ] Prevent long stalemates  

Game should now feel tense and fast.

---

STEP 7 — Win Resolution + Rewards

[ ] Last-alive detection  
[ ] Fallback top-3 survivor logic  
[ ] Coin rewards granted (server-side)  
[ ] Match cleanly ends and resets  

---

STEP 8 — Basic UI Plumbing

[ ] Left-side UI stack exists  
[ ] Simple notifications/toasts  
[ ] Spectate UI (next/prev)  
[ ] Settings toggle (music on/off)  

No animations, no polish.

---

STEP 9 — Economy Basics

[ ] Coins currency  
[ ] Participation rewards  
[ ] Win rewards  
[ ] Temporary (non-persistent) storage  

---

STEP 10 — Data Saving / Loading

[ ] DataStore save/load  
[ ] Retry + session safety  
[ ] Auto-save interval  
[ ] Save-on-leave  

At this point, progress is real.

---

PHASE 1 DONE =
A playable Fate Beams game you can ship privately or publicly.

---

PHASE 2 — Retention (Come Back Tomorrow)

Goal:
Give players reasons to return without bloating the game.

[ ] Daily rewards  
[ ] Spin wheel tuning  
[ ] Cosmetic unlock pacing  
[ ] Weekly wins leaderboard  
[ ] Light social pressure (leaderboards visible in lobby)  

No major new mechanics.

---

PHASE 3 — Scale + Monetize (Long-Term)

Goal:
Increase conversion and progression depth safely.

[ ] Premium cosmetics  
[ ] Crates and rarity tiers  
[ ] Robux coin packs  
[ ] VIP / boosters (multipliers via config)  
[ ] Additional hazard variants (optional)  

---

Notes:

- Systems must remain modular (“puzzle pieces”)  
- Fate Beams should always stay fast and simple  
- Do NOT add Phase 2 or 3 features before Phase 1 is rock solid  
- Speed comes from finishing loops, not adding ideas  

END
