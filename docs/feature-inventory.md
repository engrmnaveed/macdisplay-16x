# Feature inventory

Compiled from the public guide of BetterDisplay 5 and other display utilities on 22 November 2026, as a checklist of capabilities. All code and interface design in Display 16X are our own.

This file is a completeness checklist, so that no capability is forgotten when we plan a release. It also maps each capability to the part of the [core architecture](core-architecture.md) that keeps it possible, so the core can be checked before a feature is built. The milestone column follows the [roadmap](roadmap.md) and the feature groups in the [PRD](../PRD.md): `v0.1` to `v0.4` are scheduled milestones, `Later` is in scope but not scheduled, and `Not planned` is out of scope.

A core hook of `gap` marks a capability the architecture does not cover. The first pass found 61. The architecture was revised to cover them, so none remain. Keep it that way when adding rows.

## Display identity and records

| Capability | What it does | Milestone | Core hook |
| --- | --- | --- | --- |
| Saved display record | Keeps a display's settings while it is absent | v0.1 | display records |
| Display tag | Gives each record a stable small number for scripts and logs | v0.1 | display records |
| Full identifier capture | Stores vendor, model, serials, product name, date, EDID hash and port at first sight | v0.1 | display records |
| Per-display match rule | Chooses which identifiers bind a live display to its record | v0.1 | identity matcher |
| Default rule for new displays | Applies only to displays never seen before | v0.1 | identity matcher |
| Port-based matching | Tells identical monitors apart by the port they use | Later | identity matcher (reserved rule) |
| Full EDID matching | Binds by the complete EDID, falling back to the system UUID | Later | identity matcher (reserved rule) |
| Model key | Shares settings across every unit of one vendor and model | v0.1 | settings scopes |
| Custom display name | Label shown in the app, never used for matching | v0.1 | display records |
| Custom display icon | Symbol shown next to the display in the menu | Later | display records |
| Display sort order | User-set order key for the menu, virtual screens last by default | Later | display records |
| Remembered displays | Lists offline records with a disconnected marker | v0.1 | display records |
| Retention period | Removes records unseen for a set number of days | v0.1 | display records |
| Retention classes | Forgets weakly identified displays sooner and exempts ones linked to virtual screens | Later | display records |
| Forget and reset | Deletes an absent record or resets a present one to defaults | v0.1 | display records |
| Transfer settings | Moves an old record's settings onto the current display, replacing them | v0.1 | display records |
| Swap identical displays | Exchanges identity mapping, position and mode between two same-model monitors | Later | display records |
| Alternate identity | Links original and overridden identifiers after an EDID change | Later | identity alias map (reserved) |
| Duplicate record warning | Flags several records that seem to be one monitor | Later | identity matcher |
| Wake placeholder filtering | Ignores the temporary generic display reported during wake | v0.1 | display records |
| Display kinds | Separates built-in, external, virtual, Sidecar, AirPlay and DisplayLink | v0.1 | display records (kinds reserved) |
| Display traits | Built-in, Apple-made, main, orientation and mirror role as filterable facts | v0.1 | display records |
| Physical size override | Corrects panel size used for scale matching and nits | Later | display records |
| Visual identify | Briefly marks the physical screen a menu entry refers to | Later | app target |
| Information report | Lists identifiers, capabilities, current mode and connection details | v0.1 | probe |
| Report export | Saves the report as text for bug reports | v0.1 | probe |
| Link diagnostics | Reports bandwidth, compression, copy protection and link registers | Later | feature registry reports; link services (reserved) |
| Model adaptations | Applies known per-model defaults with opt-out and a recorded state | Later | settings scopes (model key) |

## Display modes and scaling

| Capability | What it does | Milestone | Core hook |
| --- | --- | --- | --- |
| Full mode list | Shows every mode with size, HiDPI, refresh and depth | v0.1 | mode model |
| Hidden scaled modes | Lists and selects the HiDPI modes the public mode list leaves out | v0.1 | mode model |
| Logical and pixel size | Separates desktop size from backing size | v0.1 | mode model |
| Mode flags | Marks native, default, unsafe and invalid modes | v0.1 | mode model |
| Mode filters | Narrows the list by HiDPI, refresh, aspect and depth | v0.1 | mode filter chain |
| Show all modes | Includes unsafe and invalid modes on request | v0.1 | mode filter chain |
| Low-resolution floor | Hides modes under 720 lines unless allowed | v0.1 | mode filter chain |
| Resolution slider | Steps through sizes while keeping refresh, depth and density | v0.1 | mode filter chain |
| Commit on release | Applies the slider choice after dragging stops | v0.1 | mode model |
| Relative size label | Shows each size relative to the default desktop size | v0.1 | mode filter chain |
| Magnification view | Presents sizes as zoom levels in reverse order | Later | mode filter chain |
| Slider limits | Sets minimum and maximum sizes for the slider and shortcuts | Later | mode filter chain |
| HiDPI toggle | Switches to the nearest mode of the other density | v0.1 | mode model |
| Refresh rate list | Lists rates at the current size, density and depth | v0.1 | mode model |
| Variable refresh | Shows adaptive refresh ranges as entries | v0.1 | mode model (reserved range) |
| Fractional rates | Keeps rates such as 59.94 distinct from whole rates | v0.1 | mode model |
| Connection-only rates | Offers extra link-level rates outside the normal list | v0.4 | mode model (connection layer) |
| Refresh reporter | Shows measured versus nominal rate while its menu is open | Later | app target |
| Partial mode request | Picks a mode from any of size, density, refresh and depth | v0.1 | mode model |
| Nearest match | Applies the closest mode and reports the difference | v0.1 | mode model |
| Verify after apply | Reads the mode back after reconfiguration settles | v0.1 | mode model |
| Timed revert | Rolls back an unconfirmed interactive mode change | v0.1 | mode model |
| Countdown on request | Lets a command from the CLI ask for Keep or Revert | v0.1 | command engine |
| Favourite modes | Saves a few full modes per display | v0.2 | mode model |
| Favourite tolerance | Matches favourites despite small depth or rate drift | v0.2 | mode model |
| Undo last mode | Returns to the mode before the last change | v0.2 | mode model |
| Default and native jumps | Switches straight to the default or native mode | v0.2 | mode model |
| Notch area toggle | Switches between full-height and below-notch modes | Later | mode model (reserved notch variant) |
| Mirror target modes | Allows size changes on mirrored displays as an opt-in | v0.2 | mode model |
| Rotation | Sets 0, 90, 180 or 270 degrees | v0.1 | DisplayPrivate |
| Relative rotation | Rotates by one step with wrap-around | v0.2 | command engine |
| Rotation of mirror targets | Rotates displays the system does not offer it for | Later | DisplayPrivate |
| GPU limit readout | Shows the width and allocation limits that cap HiDPI | Later | probe |
| Flexible HiDPI scaling | Adds fine scaled sizes through a model override | v0.3 | permissions and privilege |
| Custom scaled resolutions | Adds chosen sizes in both densities | v0.3 | permissions and privilege |
| Native size override | Corrects the reported native pixel size | v0.3 | permissions and privilege |
| Default mode override | Sets the mode the system picks first | v0.3 | permissions and privilege |
| Sizes above 8K | Allows very large scaled and virtual desktops | v0.3 | mode model |
| Mirror-based HiDPI | Mirrors a HiDPI virtual screen onto a panel that lacks it | v0.3 | display records (relationships) |
| Skip mode-change fade | Intel-only fast mode switching | Not planned | none |
| Framebuffer depth menu | Intel-only depth selection | Not planned | none |

## Hardware control (DDC and other controllers)

| Capability | What it does | Milestone | Core hook |
| --- | --- | --- | --- |
| Several controllers per display | Lets more than one mechanism serve a display at once | v0.1 | controllers and capabilities |
| Per-control capability | Records absolute, relative or toggle, and readable or write-only | v0.1 | controllers and capabilities |
| Controller precedence | Picks one owner per control | v0.1 | resolver |
| Manual assignment | Stops automatic reassignment of a control | v0.1 | resolver |
| Add and remove controllers | Keeps a controller's settings after removal | v0.1 | controllers and capabilities |
| DDC detection | Tests the channel, reads the capability string and current values | v0.1 | DDC transport |
| Ignored control detection | Marks a control the monitor reports and ignores, with a way to check again | v0.1 | controllers and capabilities |
| Repeated queries | Sends each query more than once for monitors that drop the first | v0.1 | DDC transport |
| Reply matching | Accepts a reply only when it names the feature that was asked for | v0.1 | DDC transport |
| Detection outcome | Reports no channel, unsupported, limited or working | v0.1 | DDC transport |
| Auto-configure | Enables reported features and adopts their ranges | v0.1 | DDC transport |
| Full code report | Lists every reported code, mapped or not | v0.1 | probe |
| Per-feature enable | Turns one DDC control on or off | v0.1 | controllers and capabilities |
| Raw range | Maps to device maxima such as 100, 200 or 255 | v0.1 | control mapping |
| Curve and invert | Skews or flips the value mapping | v0.1 | control mapping |
| Neutral value | Sets the resting value for contrast, gains and similar | v0.1 | control mapping |
| Code override | Sends a control to another code, or to several codes | v0.1 | control mapping |
| On and off values | Sets the data sent for each state of a switch | v0.1 | control mapping |
| DDC contrast | Hardware contrast over DDC | v0.1 | controllers and capabilities |
| RGB gain and black level | Per-channel hardware color controls | Later | controllers and capabilities |
| Other picture codes | Hardware saturation and similar monitor settings | Later | controllers and capabilities |
| Monitor factory reset | Sends the reset command, optionally clearing stored values | Later | controllers and capabilities |
| Raw DDC commands | Reads or writes any code by number from the CLI | v0.2 | command engine |
| User-defined controls | Named sliders, switches or actions on chosen codes | Later | feature registry |
| Per-display queue | Serial queue where the newest request replaces queued ones | v0.1 | DDC transport |
| Shared queue option | Serializes every display on one queue when several misbehave | Later | DDC transport |
| Transport tuning | Sets repeats, gaps, retries and waits per display | v0.1 | DDC transport |
| Lenient replies | Tolerates bad checksums and duplicated bytes | v0.1 | DDC transport |
| Startup value policy | Trusts, writes or reads stored values at start | v0.1 | controllers and capabilities |
| Reapply on wake | Resends stored values after wake with an extra delay | v0.1 | reconciler |
| Adopt on wake | Reads values after wake and keeps what the monitor reports, where restore is not wanted | v0.1 | reconciler |
| Write on reconnect | Resends ranged and on/off values when a display returns | v0.1 | reconciler |
| On-demand readback | Reads a value from the monitor when asked | v0.1 | controllers and capabilities |
| Periodic readback | Reads monitor values on a timer | Not planned | none by design: no background reads |
| Apple displays withheld | Uses native control only on Apple-made displays | v0.1 | controllers and capabilities |
| Generic Apple override | Allows DDC on an Apple display at the user's risk | v0.1 | resolver |
| Separate clear scopes | Forgets stored values apart from resetting configuration | v0.1 | settings scopes |
| HDMI-CEC control | Volume, mute, input and standby over HDMI or a tunnelling adapter | Later | controllers (reserved CEC) |
| Network TV control | Paired control of networked TVs for volume, input, picture and power | Later | controllers (reserved network device) |
| Wake over network | Powers a networked TV on with a wake packet | Later | controllers (reserved network device) |
| Receiver control | Power, input and volume on a networked audio receiver | Later | controllers (reserved network device) |
| Script controller | Custom controls that run a shell command, URL or notification | Later | controllers (reserved script) |
| Script readback | Parses a value from command output with a pattern | Later | controllers (reserved script) |
| Remote control windows | Floating or inline button pads for CEC and network devices | Later | app target |
| DisplayLink control | Brightness and color through the vendor's manager | Not planned | none |

## Brightness and dimming

| Capability | What it does | Milestone | Core hook |
| --- | --- | --- | --- |
| DDC brightness | Hardware brightness over DDC | v0.1 | controllers and capabilities |
| Native brightness | Brightness on built-in and Apple displays | v0.1 | controllers and capabilities |
| One brightness scale | Spans software dimming and the hardware range in one slider | v0.1 | brightness composition |
| Addressable parts | Exposes hardware and software parts on their own | v0.1 | brightness composition |
| Switchover point | Sets where hardware hands over to software dimming | v0.1 | brightness composition |
| Hardware floor | Sets the lowest hardware level before dimming starts | v0.1 | brightness composition |
| Black at zero | Lets zero turn the image fully black as an opt-in | v0.1 | brightness composition |
| Single-scale opt-out | Drops the software range for one display | v0.1 | brightness composition |
| Sub-sliders | Shows the parts under the main slider | Later | brightness composition |
| Prefer hardware | Chooses whether the main slider uses hardware or software | v0.1 | resolver |
| Gamma dimming | Dims by scaling the gamma table | v0.1 | software dimmer |
| Overlay dimming | Dims with a dark window where tables are unsafe | Later | software dimmer (reserved overlay) |
| Compositor dimming | Dims through a system compositor filter | Later | color pipeline backends (reserved) |
| Active method readout | Reports which dimming method is in use | v0.1 | software dimmer |
| Custom profile guard | Blocks color tables when any display has a custom profile | v0.1 | software dimmer |
| Table enable switches | Global and per-display permission to use color tables | v0.1 | software dimmer |
| Reapply tables | Restores gamma after wake and reconfiguration, clears on quit | v0.1 | software dimmer |
| Dimming curve | Adjusts how quickly gamma dimming darkens | Later | software dimmer |
| Software zero level | Sets how dark the software range gets at zero | v0.1 | brightness composition |
| Restore policy | Restores all, all but brightness, or nothing at start and wake | v0.1 | reconciler |
| Restore floor | Keeps an automatic restore of software dimming above a minimum level | v0.1 | brightness composition |
| Dark-wake guard | Rejects low values captured during a dark wake | v0.1 | reconciler |
| Auto-brightness setting | Turns system auto-brightness on or off for Apple displays | v0.1 | controllers and capabilities |
| Outside change tracking | Follows brightness changed by system controls | v0.1 | change origin |
| Smooth transitions | Ramps changes, or sends fewer writes when off | Later | command engine |
| Nits readout | Shows estimated luminance next to the slider | Later | brightness scale: nits mapping (reserved) |
| Nits ranges | Manual minimum, maximum and HDR anchors per display | Later | brightness scale: nits mapping (reserved) |
| Dim on lock | Dims displays while locked or in the screen saver | Later | event bus (lock, screen saver); automation gate |
| Screen off on lock | Turns non-main screens off while locked | Later | event bus |
| Overlays out of screenshots | Hides dimming overlays during native screenshots | Later | color pipeline backends: overlay (reserved) |
| Overlays out of capture | Excludes overlays from screen capture | Later | software dimmer |
| Scroll on sliders | Adjusts sliders by scrolling, with a floor above black | Later | app target |
| Ambient light reading | Shows the light sensor value while a menu is open | Later | reserved services: sensors and lights |
| Logo light control | Controls the lit logo on MacBooks that have one | Later | reserved services: sensors and lights |
| Keyboard backlight keys | Steps the laptop keyboard backlight from shortcuts | Later | reserved services: sensors and lights |
| Rounded corners | Draws corner masks on a display | Later | software dimmer (reserved overlay) |

## Audio

| Capability | What it does | Milestone | Core hook |
| --- | --- | --- | --- |
| DDC volume | Monitor speaker volume over DDC | v0.1 | controllers and capabilities |
| DDC mute | Separate mute control with its own values | v0.1 | controllers and capabilities |
| Mute strategy | Uses a mute command, volume to zero, or both in either order | v0.1 | controllers and capabilities |
| Unmute strategy | Sets the order of unmuting and restoring volume | v0.1 | controllers and capabilities |
| Zero volume behavior | Sends mute or sets the lowest level at 0% | v0.1 | controllers and capabilities |
| Remembered volume | Restores the level held before muting | v0.1 | controllers and capabilities |
| Step-only and toggle-only audio | Handles controllers without absolute level or mute state | v0.1 | controllers and capabilities |
| Associated output | Links a display to a system output by name or identifier | v0.1 | key engagement and targets |
| Native output volume | Uses the system volume path for the linked output | Later | controllers (reserved audio device) |
| Software volume | Adjusts volume and mute in software on any stereo output | Later | controllers: audio device (reserved) |
| Software audio processing | Equalizer, dynamics and level meters | Later | reserved services: audio processing |
| Feedback sound | Plays a click on key release, following the system setting | v0.1 | key engagement and targets |
| Feedback routing | Sends the click to the display's linked output | v0.1 | key engagement and targets |

## Inputs and power

| Capability | What it does | Milestone | Core hook |
| --- | --- | --- | --- |
| Input switching | Changes the monitor input over DDC | v0.1 | controllers and capabilities |
| Input list editing | Labels, icons, grouping and hidden entries per display | v0.1 | controllers and capabilities |
| Monitor's own input list | Builds the input list from the values the monitor lists, and numbers the ones it cannot name | v0.1 | controllers and capabilities |
| Alternate input command | Uses another command for monitors that need it | v0.1 | controllers and capabilities |
| Input identifiers | Keeps input ids separate from raw values and per controller | v0.1 | controllers and capabilities |
| Risk confirmation | Confirms input switches and power-off before sending | v0.1 | controllers and capabilities |
| Remembered dismissals | Lets the user stop a warning from showing again | Later | app target |
| DDC power off | Turns the monitor off over DDC | Later | controllers and capabilities |
| Backlight off | Turns the panel light off while staying powered | Later | controllers and capabilities |
| Header switch action | Chooses whether a display's switch disconnects, darkens or powers off | Later | app target |
| Input shortcuts | Slots that pick a display and an input | v0.2 | command engine |
| Prevent sleep | Keeps the Mac awake globally or while a display is connected | Later | reserved services: power assertions |
| Operation sleep guard | Holds a short wake lock around risky operations | Later | reserved services: power assertions |

## Keyboard and on-screen indicator

| Capability | What it does | Milestone | Core hook |
| --- | --- | --- | --- |
| Brightness keys | Drive external and software brightness from the keyboard | v0.1 | key capture |
| Volume and mute keys | Drive monitor audio from the keyboard | v0.1 | key capture |
| Active capture | Claims keys through an event tap with Accessibility | v0.1 | key capture |
| No-permission capture | Captures keys through remapping and hotkeys without a prompt | Later | key capture (spike) |
| Listen-only capture | Observes keys with Input Monitoring only | Later | key capture |
| Remap recovery | Restores key remaps on quit and after a crash | Later | recovery store |
| Permission setup | Shows what is missing and when a restart is needed | v0.1 | permission broker |
| Brightness engagement | Claims keys only when the target display is ours | v0.1 | key engagement and targets |
| Volume engagement | Claims keys only when the output belongs to a controlled display | v0.1 | key engagement and targets |
| System fallback | Passes unhandled volume keys to macOS | v0.1 | key engagement and targets |
| Mute key to system | Leaves the mute key with macOS | Later | key engagement and targets |
| Apple display pass-through | Lets macOS handle brightness on displays it controls natively | Later | key engagement and targets |
| Target policy | Pointer, focused or all suitable displays | v0.1 | key engagement and targets |
| Mirror expansion | Includes mirror targets in the key target | v0.2 | key engagement and targets |
| Per-display opt-out | Excludes a display from keyboard control | v0.1 | key engagement and targets |
| Modifier targets | Built-in only, externals only, or all but current | Later | key engagement and targets |
| Standard and fine steps | Logical step scale with a fine modifier | v0.1 | key engagement and targets |
| Fine by default | Inverts the fine modifier per control | Later | key engagement and targets |
| Alternate brightness keys | Accepts F14 and F15 as brightness keys | v0.1 | key capture |
| Settings shortcuts | Opens display or sound settings with a modifier | Later | key capture |
| Indicator | Shows value and segments on the affected display | v0.1 | indicator |
| Indicator styles | Several positions and a destination screen rule | Later | indicator |
| Indicator content options | Value, nits, device name and background choices | Later | indicator |
| Indicator suppression | Hides it globally or for monitors with their own | v0.1 | indicator |
| Action indicator | Shows icons for non-brightness actions | Later | indicator |
| Outbound indicator events | Broadcasts value and maximum for other overlay apps | Later | indicator |
| Indicator by command | Shows the indicator without changing a value | v0.2 | command engine |
| Custom shortcuts | Global hotkeys for any command | v0.2 | command engine |
| Shortcut recorder | Records keys and warns about conflicts | v0.2 | app target |
| Resolution shortcuts | Step sizes with a short delayed commit | v0.2 | mode model |
| Rotation shortcuts | Set or toggle rotation from keys | v0.2 | command engine |
| System status indicator | Hands the indicator to a system live activity | Later | indicator |
| Version-specific system indicator | Uses a style only one macOS release offered | Not planned | none |
| Touch and island indicators | Touch interaction and notch capsule styles | Not planned | none |

## Connection management

| Capability | What it does | Milestone | Core hook |
| --- | --- | --- | --- |
| Disconnect and reconnect | Removes a display from use without unplugging it | v0.2 | display records (reserved states) |
| Reconnect every display | Brings back all app-disconnected displays | v0.2 | command engine |
| Disconnect all but main | Leaves only the main display active | v0.2 | command engine |
| Make the only display | Connects one display, confirms it, then disconnects the rest | v0.2 | connection policy; cancellable multi-step operations |
| Keep one physical display | Refuses to remove the last eligible physical display | v0.2 | connection policy |
| Model safeguards | Blocks risky built-in disconnects on some Macs unless allowed | v0.2 | connection policy |
| Allow disconnecting all | Overrides the last-display safeguard | v0.2 | connection policy |
| Reconnect when none left | Restores displays when no usable one remains | v0.2 | automation gate |
| Reconnect at start and quit | Undoes app disconnects when the app starts or quits | v0.2 | reconciler |
| Persist disconnected state | Keeps app disconnects across launches when asked | Later | reconciler |
| Built-in auto-disconnect | Turns off the built-in panel when an external display connects | v0.2 | automation gate |
| Auto-disconnect exceptions | Ignores chosen displays as triggers | v0.2 | automation gate |
| Manual override pause | Suspends auto-disconnect after a manual reconnect | v0.2 | change origin |
| Re-disconnect after wake | Disconnects displays macOS brought back on wake | Later | reconciler |
| Aggressive disconnect | Retries for displays that do not stay off | Later | reconciler |
| Lid awareness | Skips built-in rules with the lid closed | v0.2 | event bus (lid); connection policy |
| Redetect displays | Asks the system to scan for displays again | v0.2 | DisplaySystem adapters |
| Reset display link | Re-establishes an external connection | Later | reserved services: link reset |
| Link reset on wake or unlock | Runs the reset automatically after those events | Later | wake pipeline: link recovery stage (reserved) |
| Adapter reset | Resets a common DisplayPort-to-HDMI converter chip | Later | reserved services: link reset |
| Sidecar connect | Lists and connects iPad displays | Later | display records (kinds reserved) |
| Dim on disconnect | Intel-only fallback for disconnect | Not planned | none |

## Arrangement, mirroring and protection

| Capability | What it does | Milestone | Core hook |
| --- | --- | --- | --- |
| Set main display | Moves the menu bar and Dock to a display | v0.2 | DisplaySystem adapters |
| Arrangement canvas | Drags displays into place with snapping | v0.2 | DisplaySystem adapters |
| Relative placement | Places a display next to another with an alignment | v0.2 | command engine: second selector |
| Mirroring | Mirrors one source to one or more targets | v0.2 | display records (relationships) |
| Stop mirroring | Ends mirroring for a source | v0.2 | command engine |
| Mirroring shortcut | Toggles mirroring from a key | v0.2 | command engine |
| Protect mode | Restores resolution and refresh after outside changes | v0.2 | reconciler (reserved) |
| Protect rotation | Restores the saved angle | v0.2 | reconciler (reserved) |
| Protect main and mirroring | Restores main status and mirror sets | v0.2 | reconciler (reserved) |
| Protect HDR and color mode | Restores HDR state and link format | v0.4 | reconciler (reserved) |
| Protect color profile | Restores the SDR and HDR profiles | v0.4 | reconciler |
| Protect connection-only rate | Restores an extra link rate after mode changes | Later | reconciler |
| Target follows app changes | Updates the saved target when the app makes a change | v0.2 | change origin |
| Restore only offered modes | Skips restores when the mode no longer exists | v0.2 | mode model |
| Enforcement loop limit | Stops repeated restores that keep failing | v0.2 | reconciler |
| Protection notices | Tells the user when a restore happened, with a mute option | v0.2 | app target |
| Ordered wake actions | Runs link reset, value restore and protection in a set order | v0.2 | reconciler |

## Groups and synchronization

| Capability | What it does | Milestone | Core hook |
| --- | --- | --- | --- |
| Display groups | Named sets of displays with their own features | Later | display records (reserved groups) |
| All-displays group | Built-in group that always exists at lowest priority | Later | display records (reserved groups) |
| Membership rules | All connected except exclusions, or an explicit list | Later | groups: membership rule (reserved) |
| Activation and priority | Activation rules, exclusivity and ordering decide active groups | Later | groups: activation and priority (reserved) |
| Brightness sync | Copies brightness changes across members | Later | change origin |
| Sync of other controls | Volume, mute, contrast, gains and custom controls | Later | change origin |
| Delta or absolute sync | Copies offsets or values, with range remapping | Later | command engine |
| Nits sync | Matches estimated luminance across members | Later | groups; brightness scale: nits mapping (reserved) |
| Sync from outside changes | Lets system and sensor changes drive sync | Later | change origin |
| Wake reconciliation | Aligns members after wake from Apple brightness sources | Later | reconciler |
| Source and target filters | Restricts which members send and receive | Later | settings scopes (reserved group) |
| One-off bypass | Skips sync for a single adjustment | Later | command engine |
| Layout rules | Keeps relative positions with anchors and orientation variants | Later | reconciler |
| Group main display | Keeps a chosen member as main | Later | reconciler |
| Apply on group change | Reapplies layout at startup or when active groups change | Later | event bus (active groups changed); wake pipeline |
| UI scale matching | Picks modes so text looks the same size on each member | Later | mode model |
| Scale matching options | Tolerance, watched and affected members, enforce on connect | Later | settings scopes (reserved group) |

## Virtual screens

| Capability | What it does | Milestone | Core hook |
| --- | --- | --- | --- |
| Create virtual screen | Makes an app-owned display from an aspect preset | v0.3 | display records (kinds reserved) |
| Matched virtual screen | Copies a display's aspect and links to it | v0.3 | display records |
| Custom aspect | Accepts any aspect ratio | v0.3 | mode model |
| Saved definition | Keeps the definition when the screen is disconnected | v0.3 | settings scopes (reserved virtual screen) |
| Connect, disconnect, discard | Creates, removes or deletes a virtual screen | v0.3 | command engine |
| Generated modes | Builds the mode list from aspect, step, limits and a cap | v0.3 | mode model |
| Custom mode list | Uses a hand-written list of sizes | v0.3 | mode model |
| Custom refresh list | Offers chosen rates up to 240 Hz | v0.3 | mode model |
| Virtual HiDPI | Offers HiDPI modes on the virtual screen | v0.3 | mode model |
| Virtual HDR | Offers HDR modes, or HDR only | v0.4 | mode model |
| Reported identity and size | Sets serial, vendor, model and diagonal | v0.3 | display records |
| Portrait definition | Swaps width and height instead of rotating | v0.3 | mode model |
| Associations | Links a virtual screen to displays with auto-connect rules | v0.3 | relationships: virtual screen association (reserved) |
| Associated mirroring | Enforces mirroring or follows orientation of the linked display | v0.3 | relationships: virtual screen association (reserved) |
| Reconnect storm guard | Pauses after repeated automatic reconnects | v0.3 | automation gate |
| Restore at launch | Reconnects saved virtual screens when the app starts | v0.3 | reconciler |
| Reconnect after wake | Recreates virtual screens after sleep | v0.3 | reconciler |
| Restore layout on connect | Puts the arrangement back after a virtual screen appears | v0.3 | reconciler |
| Disconnect on lock | Removes virtual screens while locked and restores them | Later | event bus (lock); automation gate |
| Bulk actions | Connects, disconnects, reconnects or discards all | v0.3 | command engine |
| Remove generated profile | Deletes the virtual screen's color profile on discard | v0.3 | permissions and privilege |
| Mirrored sleep workaround | Keeps mirrored virtual screens from blocking sleep | Later | reconciler |

## HDR, XDR and color

| Capability | What it does | Milestone | Core hook |
| --- | --- | --- | --- |
| HDR toggle | Turns HDR on or off for a display | v0.4 | DisplayPrivate |
| Forced HDR | Allows HDR on modes that do not advertise it | Later | DisplayPrivate |
| Night Shift off in HDR | Turns off Night Shift and True Tone in HDR and restores only what it changed | v0.4 | change origin |
| Hardware brightness in HDR | Allows hardware control while HDR is on | v0.4 | resolver |
| SDR level in HDR | Uses the system SDR brightness as part of the scale | v0.4 | brightness composition |
| Software upscaling | Raises brightness above SDR white on HDR headroom | v0.4 | brightness composition (reserved upscaling) |
| Direct XDR upscaling | Drives built-in XDR panels above SDR white | v0.4 | brightness composition (reserved upscaling) |
| Recovery after direct control | Restores saved preset, brightness and auto-brightness | v0.4 | reconciler |
| Upscaling limits | Maximum scale and visual calibration | v0.4 | brightness composition |
| Neutral key stop | Pauses key steps at 100% before upscaling | v0.4 | key engagement and targets |
| Neutral table reset | Resets color tables at neutral so HDR is not clipped | v0.4 | software dimmer |
| Upscaling readiness | Keeps HDR headroom ready to cut latency at a power cost | Later | brightness composition |
| Reference presets | Selects factory and custom presets on Apple displays | v0.4 | feature registry |
| Color profile selection | Assigns a ColorSync profile per display | v0.4 | DisplaySystem adapters |
| Profile fallback | Falls back through safe profiles when one is missing | v0.4 | DisplaySystem adapters |
| Profile favourites | Saves a few profiles per display | Later | settings scopes |
| Profile editor | Adjusts a matrix profile with live preview and saves it | Later | reserved services: color profiles |
| Profile file actions | Reveals, opens or removes profiles, with privilege where needed | Later | permissions and privilege |
| Link color mode | Chooses encoding, chroma, depth, range and HDR for the link | v0.4 | mode model (connection layer) |
| Mixed link modes | Shows link formats from other rates | Later | mode model (connection layer) |
| GPU dithering | Turns temporal dithering on or off and remembers it | v0.4 | DisplayPrivate |
| Uniformity correction | Toggles panel uniformity correction on built-ins | Later | DisplayPrivate |
| Appearance remap | Grayscale or inverted output at the framebuffer | Later | DisplayPrivate |
| System color toggles | Dark Mode, Night Shift strength and True Tone | Later | feature registry (global features); reserved services |

## Image adjustments

| Capability | What it does | Milestone | Core hook |
| --- | --- | --- | --- |
| Software contrast | Changes contrast through the color table | Later | color pipeline stage (reserved) |
| Gamma and gain | Global and per-channel gamma and gain | Later | color pipeline stage (reserved) |
| Color temperature | Warms or cools the image in software | Later | color pipeline stage (reserved) |
| Invert and grayscale | Inverts or desaturates in software | Later | color pipeline stage (reserved) |
| Quantization | Reduces color levels for effect or testing | Later | color pipeline stage (reserved) |
| Suspend adjustments | Pauses all adjustments while keeping values | Later | color pipeline: suspend |
| Reset adjustments | Returns every adjustment to neutral at once | Later | color pipeline: reset to neutral |
| LUT library | Imports, orders and exports 3D lookup tables | Later | settings scopes |
| LUT assignment | Applies lookup tables to a display after other effects | Later | color pipeline stage (reserved) |
| LUT to profile | Builds an experimental profile from a lookup table | Later | reserved services: color profiles |
| Compositor filters | Blur, sharpen, sepia and similar system filters | Later | color pipeline backends: compositor (reserved) |
| GPU overlay path | Renders adjustments in a GPU overlay at extra cost | Later | software dimmer (reserved overlay) |
| Underscan | Shrinks the image inside the panel | Later | DisplayPrivate |
| Table anomaly notices | Warns when another app changes the color table | Later | software dimmer |

## Picture-in-picture and streaming

| Capability | What it does | Milestone | Core hook |
| --- | --- | --- | --- |
| Picture-in-picture | Shows a live copy of a display in a window | Later | display records (relationships) |
| Numbered configurations | Keeps several saved setups per source | Later | settings scopes |
| Crop and transforms | Crops, rotates, flips, zooms and aligns the copy | Later | reserved services: capture pipeline |
| Window behavior | Level, title bar, shadow, lock, click-through and tabs | Later | app target |
| Auto start and recovery | Starts with the source and retries once after a failure | Later | reserved services: capture pipeline; event bus |
| Display streaming | Shows one display's content on another | Later | display records (relationships) |
| Stream presentation | Overlay or full-screen window, optionally on the lock screen | Later | app target |
| Pause, hide, stop | Controls a running stream or all streams | Later | command engine |
| Resume on connect | Restarts a stream when its target returns | Later | reconciler |
| Native mode for target | Switches the target to its native mode while streaming | Later | mode model |
| Pointer handling | Keeps the cursor out of targets and warps it on click | Later | reserved services: capture pipeline |
| Video filters | Applies filters, LUTs and HDR processing to streams | Later | reserved services: capture pipeline |
| Content streaming | Streams a chosen window or app | Later | reserved services: capture pipeline |
| Filter window | Shows a filtered live copy for inspection | Later | reserved services: capture pipeline |
| Capture permission | Tracks Screen Recording approval | Later | permission broker (reserved) |
| Frame rate cap | Limits capture frame rate to save power | Later | reserved services: capture pipeline |

## System overrides and EDID

| Capability | What it does | Milestone | Core hook |
| --- | --- | --- | --- |
| Staged overrides | Queues override changes for apply or undo | v0.3 | permissions and privilege |
| Administrator approval | Installs overrides through a helper or an admin prompt | v0.3 | permissions and privilege |
| Activation or reboot | Finishes an install by reconnecting or restarting | v0.3 | permissions and privilege |
| Model-wide warning | Lists every display an override will affect | v0.3 | settings scopes (machine-wide) |
| System name override | Changes the name macOS shows for a model | v0.3 | permissions and privilege |
| Display role override | Marks a TV as a monitor so its features work | v0.3 | permissions and privilege |
| Full reset | Removes overrides and saved system display settings, then restarts | v0.3 | permissions and privilege |
| EDID read | Reads EDID from the system or over I2C | Later | DDC transport |
| EDID decode and export | Shows decoded fields and saves the bytes | Later | probe |
| Custom EDID | Applies replacement EDID bytes to a display | Later | privileged path (reserved) |
| EDID auto-apply | Applies the saved EDID when the display appears | Later | automation gate |
| Factory EDID on quit | Restores the original EDID when the app quits | Later | recovery store; privileged path (reserved) |
| EDID write to monitor | Writes EDID into the monitor itself | Not planned | none |
| Intel EDID override | Override-file EDID on Intel Macs | Not planned | none |

## Automation and integration

| Capability | What it does | Milestone | Core hook |
| --- | --- | --- | --- |
| Shared command engine | One command path for menu, keys, CLI and actions | v0.1 | command engine |
| Hardware probe | Runs without the app to collect a report | v0.1 | CLI and IPC |
| CLI verbs | Get, set, toggle and perform on any feature | v0.2 | command engine |
| Offsets and bounds | Relative values and minimum or maximum queries | v0.2 | command engine |
| Core selectors | Tag, name, UUID, pointer, focused and main | v0.2 | selectors |
| Extended selectors | Substring, EDID fields, location, non-main and type filters | Later | selectors |
| Second target | Names a target display for mirror, placement and streams | v0.2 | command engine: second selector |
| Strict targeting | Fails on missing or ambiguous targets before any change | v0.2 | selectors |
| Per-display results | Ordered confirmed, accepted or failed entries | v0.2 | command result |
| Queries | Lists identifiers, modes and inputs as JSON | v0.2 | feature registry |
| Generated help | Builds help text from the feature list | v0.2 | feature registry |
| Running-app requirement | Talks to the app over a socket with a timeout | v0.2 | CLI and IPC |
| Integration switch | Turns external command access on or off | v0.2 | settings scopes |
| URL scheme | Runs commands from links with a token and callbacks | v0.2 | command engine |
| Shortcuts actions | Brightness, mode, input, main, connection and mirror actions | v0.2 | command engine |
| Presets | Saved setups applied with one click or shortcut | v0.2 | command engine: presets (reserved) |
| HTTP server | Accepts commands over local network HTTP with a token | Later | command engine: further surfaces (reserved) |
| Lifecycle broadcasts | Announces app launch and orderly quit | Later | event bus |
| Event hooks | Runs scripts on connect, disconnect, sleep and wake | Later | event bus |
| Feed operation | Updates a tracked value without calling the device | Later | command engine |
| Virtual screen commands | Creates and discards virtual screens from scripts | v0.3 | command engine |
| Command console | Runs commands inside the app with history | Later | command engine: further surfaces (reserved) |
| Safe mode | Skips every automatic write when Shift is held at launch | v0.1 | automation gate |

## App behavior and settings

| Capability | What it does | Milestone | Core hook |
| --- | --- | --- | --- |
| Menu bar panel | One section per display with the main controls | v0.1 | app target |
| Unavailable reasons | Keeps missing controls visible with a reason | v0.1 | feature registry |
| Item visibility | Shows items always, when expanded, or never | Later | app target |
| Remembered expansion | Keeps each display's open or closed state | Later | app target |
| Alternate presentations | Edge sidebar or detachable window | Later | app target |
| Display ordering | Main first or current first, with auto-expand | Later | app target |
| Menu bar icon | Custom symbol, hide option and status priority | Later | app target |
| Settings window | Global and per-display settings | v0.1 | app target |
| Launch at login | Reflects the real login item state | v0.1 | permission broker |
| Versioned settings | One typed document with defaults left unset | v0.1 | settings scopes |
| Export, import, reset | Whole-document backup and reset | v0.2 | settings scopes |
| Protected recovery values | Keeps hardware recovery data out of export and reset | v0.4 | recovery store |
| Timing settings | Reconfiguration delay and wake delay | v0.1 | event bus |
| Animation speed | Shortens or turns off interface animation | Later | app target |
| Dock icon policy | Shows a Dock icon only while a window is open | v0.1 | app target |
| Notifications | Notification Center, dialogs or off | Later | reserved services: user notices |
| Logging | Bounded in-app log and a verbose launch flag | v0.1 | logging |
| Updates | Checks for, offers and installs new versions | Later | reserved services: updater |
| Localization | Translated interface | Later | app target |
| VoiceOver support | Announces control states | v0.1 | app target |
| Single instance | Never starts a second copy of the app | v0.1 | CLI and IPC |
| Session awareness | Pauses automatic work while another user is active | v0.1 | automation gate |
| Status item recovery | Restores the icon if macOS removes it | Later | app target |
| Crash reporting service | Sends crash reports to a third party | Not planned | none |
| Licence and trial | Paid tier, trial and activation | Not planned | none |
| Touch layout | Larger targets for touch displays | Not planned | none |

## Hard limits and pitfalls to design around

- macOS can change a display's ID and UUID after wake, reconnect or an OS install. Settings keyed on them get lost or land on the wrong monitor.
- Identical monitors can be impossible to tell apart. Port-based matching only works on Apple silicon and breaks when cables move. Weak rules can merge two monitors into one record.
- During wake macOS can report a temporary generic display. Values and topology read in that window are not trustworthy.
- Wake is two-phase. Hardware may not accept commands right after a reconnect event, so writes need a configurable delay and a retry.
- macOS may reconnect app-disconnected displays and the built-in panel on wake, before external displays are ready.
- DDC reads and writes are independent. A failed read does not mean writes fail, and a capability report can omit features the monitor accepts.
- Docks, hubs, KVMs and adapters can pass video but block or misroute DDC. A command can reach the wrong monitor.
- Each control is independent. Volume support says nothing about mute, and mute may need its own values and command order.
- Raw ranges vary by monitor. Some older Apple displays need a raw maximum of 255, and DDC on Apple displays can cause lasting harm.
- DDC power-off and screen-off may not be reversible from software. Switching input can cut the Mac's command path to the monitor.
- DDC changes stay in the monitor after the app quits. Displayed values may be assumed, not read.
- Gamma tables combined with a custom color profile on any display can produce a black screen. Some newer chips need color tables off entirely.
- Overlay dimming leaves the cursor bright, shows in screenshots and system sheets, and costs CPU on DisplayLink when hidden from capture.
- Restoring a very low brightness after a dark wake can leave an unusable screen. Keep a restore floor and reject suspicious low readings.
- Restores can only pick modes the display still offers. Docks, KVMs and link negotiation can drop modes.
- HiDPI needs a backing surface twice the size, limited by GPU width and allocation limits. Higher refresh at the same size can silently fall back to standard density.
- Connection-only refresh rates are lost on the next mode change unless something reapplies them.
- HDR changes which brightness controls work. Fixed-brightness presets block hardware brightness, and some monitors refuse hardware brightness in HDR.
- Forced HDR and mixed link modes can corrupt or blank the image.
- Base chips such as M3 drive a limited number of external displays. Disconnecting the built-in panel does not free a display pipeline, and some built-ins need a restart to come back.
- Disconnecting must never leave the Mac without a usable physical display. Lid state, iMac built-ins and exclusive remote sessions all affect reconnection.
- System overrides apply to every unit of a model and to every user account. They need administrator approval and an activation or reboot, and resetting app settings does not remove them.
- EDID overrides can flicker, change modes and change the display's identity. Writing EDID to hardware can brick it.
- Accessibility and Input Monitoring grants often need an app restart. Screen Recording is needed for any capture, and software audio needs its own recording permission.
- Key remapping strategies leave remaps behind after a crash until the next launch.
- Nothing in the user session can act before login or under FileVault, and virtual screens vanish when the app quits.
- A request that is accepted is not the same as one that took effect. Mode, rotation and refresh changes must be read back.
- Sync and protection can loop or cascade without a change origin and a retry limit.
- The public mode list hides scaled HiDPI modes unless the display is on one. A size strip or a revert built on it loses modes the moment the display changes size. *Seen on our test monitors.*
- macOS puts its own color table back at unlock with no reconfiguration event, and a process that set a table keeps reading its own table back. Software dimming cannot be verified from inside the app. *Seen on our test monitors.*
- Programs that share a DDC channel receive each other's replies. A valid, correctly checksummed reply can be the answer to another program's question. *Seen on our test monitors.*
- A monitor can answer a read for a control it does not have, and accept writes it ignores. Only a write that reads back as the new value proves a control works. *Seen on our test monitors.*
- A sleep and wake pair is not a standby. Short display sleeps happen many times a day and the monitors keep their values, so a rule that writes on every wake writes far more often than the case it exists for. *Seen on our test monitors.*
- DDC has no change notifications. After a wake the app cannot tell a monitor that forgot a value from a user who changed it with the monitor's buttons or another utility.
- The Accessibility grant belongs to a code signature. An entry from an earlier build with the same name blocks a new grant until it is removed. *Seen on this Mac.*
