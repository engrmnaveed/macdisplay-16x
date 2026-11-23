# Working on Display 16X

## Read first

- [PRD.md](PRD.md) for scope and principles.
- [docs/core-architecture.md](docs/core-architecture.md) for the design the core is built to. It says what to implement now and what to reserve.
- [docs/roadmap.md](docs/roadmap.md) for the capability map and milestones.
- [docs/feature-inventory.md](docs/feature-inventory.md) for the full checklist of capabilities and the core hook each one depends on.
- [docs/feasibility.md](docs/feasibility.md) for what has been verified on hardware.

## Who changes what

- **Planning documents** (`PRD.md`, `docs/roadmap.md`, `docs/core-architecture.md`, `docs/feature-inventory.md`) are changed by the maintainer or the planning session only.
- **Build work** owns `Sources/`, `Tests/`, `scripts/`, `spikes/`, `.github/`, `packaging/`, `README.md`, `CHANGELOG.md`, `docs/feasibility.md`, `docs/install.md` and `docs/release.md`.
- **[docs/domain-log.md](docs/domain-log.md)** is how build work reports upward. Append a dated entry for anything about the domain or the product: how a monitor, a connection or macOS actually behaves, a rule the product should follow, a decision the maintainer needs to make, a place where the architecture did not fit and what was done instead. Keep implementation detail out of it. If the architecture needs to change, log it, take the smallest workable deviation, and carry on.

## Sessions and branches

- The planning session supervises. Each milestone is built in its own session, on its own branch, in its own worktree. The main checkout is the planning session's workspace.
- A change to a part that another session built goes back to that session, through the planning session. Do not rewrite the v0.1 core's existing behavior from a later milestone. Build on the hooks it reserved, and when existing behavior has to change, log it in the domain log and say so in your report.
- Finished branches are closed. `v0.1-core` takes no more commits. Work lands on the current line of development and ships with the milestone in progress, never as an addition to an older version.
- Everything reaches `main` through a pull request that passes CI. Commit locally at the end of each coherent piece. Pushing a branch, opening a pull request, merging into `main`, tagging and publishing each wait for the owner's word.
- Commit messages carry no co-author or tool attribution line. How the project is built is said once, in the README, under "How it is built". Set by the owner on 24 November 2026. Earlier commits stay as they are: history is never rewritten for this.

## Rules

- **Independent implementation.** Do not open, disassemble, trace or list symbols of BetterDisplay, DisplayBuddy or any other proprietary app, and do not copy their text, icons, screenshots or layouts. Allowed references are Apple documentation, public feature descriptions, exports of Apple's own frameworks, and MIT, BSD or Apache licensed projects, credited in `THIRD_PARTY.md` when code is adapted. GPL projects are concept references only.
- **Idle means idle.** No repeating timers and no polling. React to display reconfiguration, wake, and user input. Any feature that renders, captures or composites frames is off by default and starts only on an explicit user action.
- **Private interfaces stay in `DisplayPrivate`.** Resolve them at run time and expose each as an optional capability. A missing symbol disables a control. It never prevents launch.
- **Every surface goes through the command engine.** The menu, keys and CLI build a command. Nothing in the interface calls a controller directly.
- **Settings are keyed by display record tag**, never by a system display ID or UUID.
- **Every automatic write passes the automation gate**, and every change carries its origin.
- **DDC goes through one serial queue per display.** Coalesce writes so the latest value wins, bound retries, never block the main thread, and never read periodically. Add a captured reply to the tests for every monitor quirk.
- **Anything that changes the user's displays must be reversible.** Mode changes get a timed revert. Files written outside the app's own folders get a preview, administrator authorization and a removal path.
- **Reserve, do not build ahead.** Where the architecture says "reserved", add the type or case and stop.
- Target Apple silicon and Swift 6 with the Command Line Tools. No third-party dependencies in the core without a recorded reason.

## Testing on a Mac that is in use

- Run `swift test` for every change. Hardware checks come after the unit tests pass.
- Before a hardware write, read and record the current value. Restore it afterwards.
- Change arrangement, mirroring, the main display or a connection only in a check that the roadmap plans for it, with the owner present, after recording the layout, and put it back afterwards. Never do it in a unit test or an unattended run. Change a mode only through the timed revert.
- The owner's own running copy of Display 16X lives in `dist/` of the main checkout. Never build or package there, and do not quit or restart that copy during your work without the owner's word. When your milestone's work ends, make your build the running copy: keep the previous app and a copy of the settings folder, start the new build with the standard settings folder, and write down how to go back.
- Leave other display utilities that are running alone. Do not quit, configure or inspect them. Note in the domain log when one may have interfered with a result.
- Probes and spikes live in [`spikes/`](spikes). Keep them read-only unless the file name says otherwise, and record results in the feasibility notes with the Mac model, macOS build, monitor and connection.
