# Lockeye changelog

## v0.4.0

- **What your demons know, at the demon trainer.** Lockeye notes each demon's abilities and ranks
  whenever you summon it (per character). At a vendor that sells grimoires, each one is marked
  **Known**, **Upgrade** or **New** for its demon, or **?** for a demon you haven't summoned yet.
  A list of your demons and their ranks opens beside the trainer's window, and grimoire tooltips
  say what your demon has. `/lockeye demons` shows the list anywhere.
- The game can show a demon's spells a moment after it's summoned or learns a rank, so Lockeye
  looks again after 1 and 3 seconds. Before, it could keep an old rank (such as Sacrifice's) until
  you summoned that demon again.

## v0.3.0

- **Nightfall alert.** When Nightfall puts you in a Shadow Trance, a purple line with the Shadow
  Bolt icon shows above your character, draining as the trance runs out, with "Instant Shadow
  Bolt" and the seconds left. It goes away when you cast it. You can move it (`/lockeye move`),
  change its color and size, turn off the pulse, or pick a sound under Nightfall alert in the
  options.
- **The other-enemies list no longer flickers.** An enemy you've fought stays listed for the rest
  of the fight, even when the game's threat answer for it blinks, and a nameplate that comes back
  is picked up at once.
- The wand bar no longer takes tradeskill casts (Bolt of Woolen Cloth...) as the cast to fit
  between shots.

## v0.2.1

- **A log for finding problems.** Lockeye keeps a short log of what the game shows it about your
  target and what the tracker shows, saved with its settings when you `/reload` or log out.
  `/lockeye log off` turns it off.
- Lua errors in Lockeye no longer stop its frames; they go in the log, and chat says so once.
- When the game hides an enemy's ID in combat, your target is tied to its nameplate instead, so
  its DoTs are still kept when you tab away and back (with nameplates on).

## v0.2.0

- **Tab back and your DoTs are still there.** Lockeye now remembers your DoTs on each enemy. Before,
  switching targets and back could show your DoTs as missing, or as "?".
- **Other enemies list:** every enemy you're fighting, not just the ones with your DoTs. A check mark
  shows the fully dotted ones; the ones missing the most DoTs are on top. Above the list: how many
  are fully dotted.
- A cast that gets resisted turns its row back to "Missing" once the game shows your other debuffs.
- New command: `/lockeye check` says what Lockeye can see of your target.

## v0.1.0

The first version.

- **DoT tracker:** Corruption, your bane (Agony, Doom or Havoc), Immolate, Siphon Life and your
  curse on your target, with the time left. Missing ones turn red in a fight, ones about to run
  out turn orange, with an optional sound. Every rank counts.
- **Other enemies:** the enemies with your DoTs on their nameplates, a line each, the one whose DoT
  runs out first on top.
- **Wand bar:** when your next wand shot goes off, where to stand still for it, where a cast still
  fits before it, and what a cast costs. Says so when Shoot is off in a fight.
- Options window (`/lockeye`), settings from chat, `/lockeye test`, frames you can drag
  (`/lockeye move` or Edit Mode).
