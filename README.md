# Tidy

A free, open source macOS menu bar app that keeps your folders organized. Rules are edited
in a normal Mac window; Tidy watches the folders they name and moves files as they land.

It is a small alternative to Hazel: no polling loop, no cron job, no account. Watches use
kernel file-system events, so a screenshot is filed the moment it hits the Desktop.

![The rules editor](docs/rules.png)

![The log](docs/log.png)

---

## Installation

```sh
brew install ryanstoffel/tap/tidy
```

Tidy is not notarized, so the first launch is blocked by macOS. Go to
**System Settings > Privacy & Security**, find the message about Tidy, and click
**Open Anyway**.

Update later with:

```sh
brew update && brew upgrade --cask tidy
```

### Folder permissions

Desktop, Downloads and Documents are protected by macOS. The first time Tidy reads one,
macOS asks for permission; allow it. If you deny by accident, or Tidy reports that it
cannot read a folder, either:

- **System Settings > Privacy & Security > Files and Folders** and enable Desktop,
  Downloads and Documents for Tidy, or
- **System Settings > Privacy & Security > Full Disk Access** and add Tidy, which covers
  every folder at once.

Reopen Tidy after changing either setting. Destinations outside those three folders
(`~/Pictures`, for example) need no permission.

---

## Menu

| Item | What it does |
| --- | --- |
| Organizing | Pauses or resumes everything without quitting |
| Dry Run | Evaluates rules and logs what *would* happen, moves nothing |
| Organize Now | Runs every rule immediately, including the age-based ones |
| Open Log | Native window listing recent moves, newest first |
| Edit Rules | Rule editor window: fields and folder pickers, no JSON required |
| Launch at Login | Registers the app with `SMAppService` |
| Quit Tidy | Stops watching |

Both windows are also reachable without the menu: `open tidy://log`, `open tidy://rules`,
and reopening Tidy from Spotlight, Finder or Raycast shows the log.

Saving in the editor applies the rules immediately. Editing `rules.json` outside the app
is still fine; those changes are picked up within a minute. No restart, no rebuild.

---

## Rules

Rules live in `~/Library/Application Support/Tidy/rules.json`, written with the four
default rules on first launch. A copy of that file is in this repo as
[`rules.json`](rules.json).

Top level:

| Key | Meaning |
| --- | --- |
| `settleSeconds` | Gap between the two size samples that decide a file finished downloading (default 5) |
| `courseTerm` | Substituted as `{term}`; bump it each semester |
| `courseCodes` | Course codes recognized in filenames, matched ignoring case, spaces and dashes |
| `skipExtensions` | Extensions that mean "still downloading" and are never touched |
| `ignoreProcesses` | Processes allowed to hold a file open without blocking a move |
| `rules` | The rules, evaluated top to bottom |

Each rule:

| Key | Meaning |
| --- | --- |
| `name` | Shown in the log |
| `enabled` | Set `false` to park a rule without deleting it (default `true`) |
| `trigger` | `event` reacts to file-system events and also runs in the daily sweep; `daily` only runs on the timer, which is what age-based rules want (default `event`) |
| `watch` | Folders to watch. Only their direct children are considered, never subfolders |
| `match` | Conditions, all of which must hold. An empty `match` accepts everything |
| `destination` | Destination folder, created if missing, with `{token}` substitution |
| `includeDirectories` | Allow the rule to move folders, not just files (default `false`) |

Conditions inside `match`:

| Key | Meaning |
| --- | --- |
| `extensions` | Extensions without the dot, compared case-insensitively |
| `namePattern` | Case-insensitive regex matched against the whole filename. Named groups such as `(?<year>\d{4})` become tokens |
| `minAgeDays` | Modified at least this many days ago |
| `minIdleDays` | Modified *and* last read at least this many days ago |
| `requiresCourseCode` | Filename must contain one of `courseCodes`; the match becomes `{course}` |

Tokens usable in `destination`, plus any named group from `namePattern`:

`{term}`, `{course}`, `{sourceFolder}`, `{name}`, `{stem}`, `{ext}`, `{fileYear}`,
`{fileMonth}`, `{fileDay}`

**First match wins**, so specific rules go above catch-alls. A rule whose destination uses
an unknown token never fires, and the menu shows the warning.

### The default rules

1. **Screenshots** — `Screenshot 2026-08-16 at 9.15.42 AM.png` on the Desktop moves to
   `~/Pictures/Screenshots/2026/08/`. Year and month come from the filename itself, via the
   pattern's named groups.
2. **School documents** — a PDF or Word file landing in `~/Downloads/Documents` whose name
   contains a known course code moves to `~/Documents/School/FA26/Courses/<CODE>/`. It sits
   above the archive rule, so a stale course document is still routed instead of archived.
   `CS101`, `cs-101` and `CS 101` all match the same configured code.
3. **Downloads sorting** — anything landing directly in `~/Downloads` goes to `Code/`,
   `Images/`, `Videos/`, `Documents/` or `Random/` by extension.
4. **Archive stale downloads** — files in those five folders untouched for 30 days move to
   `~/Downloads/Archive/<original folder>/`. Checked once a day, not on events.

If Spotlight keeps refreshing access times on your machine and rule 4 never fires, swap
`minIdleDays` for `minAgeDays`, which looks only at the modification date.

### The rules editor

**Edit Rules** opens a normal Mac window: rules down the left in evaluation order, the
selected rule's fields on the right. No JSON unless you want it.

- Checkbox per rule to turn it off without deleting it, drag to reorder, and **Add Rule**,
  **Duplicate**, **Delete** underneath. Order is what decides which rule claims a file.
- **General** holds the term folder, the course codes, and the settle window.
- A rule's fields: name, enabled, whether it runs on file-system events or once a day, the
  folders it watches (chosen with a folder picker), extensions, an optional filename
  pattern, the two age conditions, the course-code requirement, and the destination, also
  pickable, with the token list right underneath.
- Problems that would stop a rule working, such as a missing destination, appear in red at
  the bottom and **Save** stays disabled until they are fixed. Warnings, such as a
  destination using an unknown token, appear in orange and do not block saving.
- **Save** or Command-S writes the file, reloads the rules and sweeps at once.

### Editing the JSON directly

**Open in Text Editor** in the same window hands `rules.json` to your editor, and
**Reveal in Finder** shows it. Bring the Tidy window back to the front and it re-reads the
file, or run **Organize Now** from the menu; either way an outside edit lands within a
minute on its own.

Both routes write the same file, so mix them freely. Saving from the window rewrites the
JSON in its own formatting, but it never drops keys the window does not show, such as
`skipExtensions` and `ignoreProcesses`. If the file is broken, the window says where and
offers to open it in your editor or replace it with the built-in rules.

A rule as JSON, for example filing job application material by company:

```json
{
  "name": "Applications",
  "watch": ["~/Downloads/Documents"],
  "match": { "namePattern": "^(?<company>[A-Za-z0-9]+) (resume|cover letter).*\\.pdf$" },
  "destination": "~/Documents/Career/resume-and-cover-letter/applications/{company}"
}
```

---

## Dry run

Turn on **Dry Run** in the menu. Rules are evaluated normally and the log fills with
`dry` rows showing the exact destination each file would get, including the collision
suffix, but nothing moves. Turn it off when the log looks right.

The same check from the terminal, which never writes to the log:

```sh
/Applications/Tidy.app/Contents/MacOS/Tidy --sweep --dry-run
/Applications/Tidy.app/Contents/MacOS/Tidy --sweep --dry-run --rules /path/to/draft.json --verbose
```

`--verbose` also lists files a rule wanted but a safety check held back. `--sweep --live`
applies the rules once and exits. `--help` lists every flag.

---

## Log

Every move, dry run and failure is recorded in
`~/Library/Application Support/Tidy/log.json` with timestamp, rule name, source and
destination. The file is a rolling JSON array capped at 500 entries. **Open Log** shows it
in a window, newest first.

---

## What Tidy never does

- Overwrite: a name collision becomes `report (1).pdf`, then `report (2).pdf`.
- Touch a file that is still downloading: `.crdownload`, `.download`, `.part` and friends
  are skipped, and any other file must hold the same size across two samples five seconds
  apart before it moves.
- Touch a file another process has open, ignoring Spotlight, Quick Look and Time Machine.
- Touch hidden files, anything inside a `.git` directory, or anything inside an Obsidian
  vault (any folder containing `.obsidian`).
- Touch folders, unless a rule sets `includeDirectories`.
- Recurse: only the direct children of a watched folder are considered.

---

## Build from source

Requires macOS 13.0+ and Xcode Command Line Tools.

```sh
git clone https://github.com/RyanStoffel/tidy.git
cd tidy
./build.sh --install   # builds a universal .app and copies it to /Applications
swift test             # rules engine tests
./build.sh --zip       # release artifact plus the sha256 for the cask
```

The app icon is generated, not checked in by hand: `swift tools/make-icon.swift`. The
screenshots above come from the app itself: `Tidy --snapshot docs`.

---

## License

[MIT](LICENSE)
