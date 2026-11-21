# CurseForge project page

Created on CurseForge as project **1820221** (authors.curseforge.com/#/projects/1820221), visible
once a moderator approves the first file. The text below is what was entered, kept here so the
page can be edited later. Settings: comments off, third-party distribution allowed (as Deadeye).

**Name:** Lockeye - Warlock DoT Timers, Nightfall Alert & Wand Bar (Forever)

CurseForge search matches words in project titles, so the title carries the words players search
for: warlock, DoT, timers, Nightfall, wand, forever.

**Summary:**
Timers for your Corruption, bane, Immolate, Siphon Life and curse on your target and every enemy you fight, a Nightfall alert for instant Shadow Bolts, and a wand Shoot bar, for WoW: Forever warlocks.

**Logo:** `docs/logo.png`

**Category:** Warlock, with Buffs & Debuffs and Combat as additional categories

**License:** MIT License

**Source:** https://github.com/CakeRepository/Lockeye

**Game version for the file:** WoW: Forever 1.60.1 &nbsp;·&nbsp; **Release type:** Release

---

**Description:**

# Lockeye

A warlock toolkit built for **World of Warcraft: Forever**. A sibling of Deadeye, the hunter
toolkit.

## DoT timers

One row per DoT on your target: **Corruption**, your **bane** (Agony, Doom or Havoc),
**Immolate**, **Siphon Life** and your **curse**, each with the time left.

- In a fight, a DoT that isn't on your target turns red: **Missing**.
- A DoT about to run out turns orange (under 3 seconds; you can change that), with an optional
  sound.
- Every rank counts. Forever's Bane of Agony and Bane of Doom are in, and each of your banes and
  curses shares one row, as you keep one of each on an enemy.
- Tab to another target and back: your DoTs on each enemy are remembered.

## Every enemy you fight

Below your target's rows, a line for each other enemy you're fighting (from enemy nameplates):
its name and a small icon per DoT with its time, missing ones grayed out. A **green check mark**
means it's fully dotted. The enemies missing the most DoTs are on top. Above the list: "Other
enemies: 2 of 3 fully dotted".

## Nightfall alert

When Nightfall puts you in a Shadow Trance, a purple line shows above your character with the
Shadow Bolt icon and "Instant Shadow Bolt", draining as the trance runs out. It goes away as
soon as you cast it.

## Wand bar

When your next wand shot goes off, where to stand still for it, where a cast still fits before
it, and what moving or casting costs you. It says so when Shoot is off in a fight.

## Built for Forever's addon rules

In combat, Forever hides the details of enemy debuffs from addons. Lockeye times each DoT from
your own cast and how long that rank lasts (from the game's spell data, or what it read from the
debuff before), remembers it per enemy, and reads your debuffs in full whenever the game allows.

## Options

Type **/lockeye** for the options window, with a live preview. Every frame can be moved
(**/lockeye move**, or Blizzard's Edit Mode), resized and recolored. **/lockeye test** shows them
all with made-up timers, and **/lockeye help** lists every command.
