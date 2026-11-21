# Lockeye

A warlock toolkit for **World of Warcraft: Forever**. A sibling of
[Deadeye](https://github.com/CakeRepository/Deadeye), the hunter toolkit.

- **DoT tracker:** your Corruption, bane, Immolate, Siphon Life and curse on your target, with the
  time left on each. Ones that are missing turn red, ones about to run out turn orange. Below it,
  the other enemies you're fighting, with a check mark on the ones that are fully dotted.
- **Nightfall alert:** a purple line above your character while your next Shadow Bolt is instant.
- **Wand bar:** when your next wand shot goes off, where to stand still for it, where a cast still
  fits before it, and what moving or casting costs you.

Type `/lockeye` (or `/leye`) for the options. `/lockeye test` shows both frames with made-up timers.

## The DoT tracker

One row per spell, top to bottom: **Corruption**, your **bane**, **Immolate**, **Siphon Life** and
your **curse**. Forever renamed Curse of Agony and Curse of Doom to Bane of Agony and Bane of Doom,
and you keep one bane and one curse on an enemy, so each of those has one row that shows whichever
of yours is on.

- In a fight, a row you know the spell for turns red with "Missing" when it isn't on your target.
  The curse row only shows while a curse is on; you can make it flag a missing curse too, or turn
  any row off, in the options.
- A row turns orange when it has less than 3 seconds left (you can change that). You can pick a
  sound for it.
- Every rank counts.

Lockeye remembers your DoTs on each enemy, so when you tab to another target and back, the timers
are still there.

**Other enemies:** with enemy nameplates on (V by default), every other enemy you're fighting gets
a line: its name and a small icon per row with its time, missing ones grayed out. A green check
mark means it's fully dotted. The ones missing the most DoTs are on top, then the ones whose DoTs
run out soonest; fully dotted ones go last. Above the list: "Other enemies: 2 of 3 fully dotted".
You can leave out the enemies you haven't dotted yet in the options.

### What the game lets the addon see

Forever follows the new addon rules: in combat, the details of an enemy's debuffs (which spell,
when it ends) are hidden from addons. Sometimes even the list of your debuffs on an enemy comes back
empty, and a debuff can get a new ID when you target its enemy again. So Lockeye:

- remembers your DoTs per enemy: a DoT you cast at your target starts its timer on that enemy,
  timed from your cast and how long that rank lasts (from the game's spell data, or what it saw
  before);
- reads your debuffs in full whenever the game allows it (out of combat, or debuffs the game
  doesn't hide), and remembers how long each rank lasted;
- uses the list of your debuffs whenever the game shows it: a DoT whose debuff leaves the list is
  gone (run out, dispelled), and a cast whose debuff never shows up was resisted;
- when your debuffs come back under new IDs, tells which is which from the order the game sorts
  them in, which it can do even while it hides the details.

Limits: when the game shows no list, Lockeye can't see a resist or a dispel, so it goes by the
timer. A DoT you cast with a mouseover macro counts for your target. `/lockeye check` says what
Lockeye can see of your target right now.

## The Nightfall alert

When the Nightfall talent puts you in a Shadow Trance, your next Shadow Bolt has no cast time. A
purple line shows above your character with the Shadow Bolt icon and "Instant Shadow Bolt", and
drains as the trance runs out. It goes away as soon as you cast it. Lockeye sees the trance from
Shadow Bolt's cast time dropping to zero, which the game keeps readable in combat, and from the
buff itself whenever the game shows it.

Drag it with `/lockeye move`. Its color, size, icon, text, pulse and a sound are under Nightfall
alert in the options, or `/lockeye nightfall <setting> <value>`.

## The wand bar

The bar fills as your wand reloads after each shot. The green stretch at the end is where you
must stand still for the next shot; moving or casting there turns it red, and the shot waits. A
blue line marks the last moment to start a cast so it ends before that stretch, for the last attack
you cast with a cast time (or a spell you pick). If it can't fit, the line moves to the start with
the least it will cost, like "+0.8". While you cast, a line shows where the cast ends.

If Shoot turns off in a fight you were wanding in, the bar says "Shoot is off".

The stand-still stretch is 0.5 seconds plus your latency. If your wand fires while you move, set
it to 0 under Wand: text and timing.

## Commands

| Command | What it does |
| --- | --- |
| `/lockeye` | Open or close the options |
| `/lockeye test` | Show every frame with made-up timers |
| `/lockeye move` | Unlock the frames to drag them; again to lock |
| `/lockeye dots on` / `off` | Turn the DoT tracker on or off |
| `/lockeye nightfall on` / `off` | Turn the Nightfall alert on or off |
| `/lockeye <setting> <value>` | Change a wand bar setting, like `/lockeye width 250` |
| `/lockeye dots <setting> <value>` | Change a DoT tracker setting, like `/lockeye dots threshold 4` |
| `/lockeye settings` / `dots settings` | List the settings |
| `/lockeye check` | Say what Lockeye can see of your target's DoTs |
| `/lockeye log on` / `off` / `clear` | Keep a log of what Lockeye sees, saved at `/reload` (on by default) |
| `/lockeye debug` | Also print that log to chat as it happens |
| `/lockeye reset` | Reset all settings |

## Tests

The tests load the addon into a mock of the Forever client on Lua 5.1 and play out fights:

```bash
pip install lupa
python tests/run_tests.py
```

`lua5.1 tests/run.lua` also works if you have a standalone Lua 5.1.

## Releases

Push a tag such as `v0.3.0` and the [BigWigs packager](https://github.com/BigWigsMods/packager)
workflow builds the zip and creates a GitHub release. A tag with "beta" or "alpha" in it is marked
that way. It also uploads the zip to the CurseForge project (set in `Lockeye.toc` as
`## X-Curse-Project-ID`) when the repository has a CurseForge API token as the secret
`CF_API_TOKEN`. The CurseForge page's text is kept in `docs/curseforge.md`.

## License

MIT
