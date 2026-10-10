# Odisplay

Switch a monitor between USB-C, DisplayPort and HDMI from the Omarchy bar, and take the Logitech
keyboard and mouse with you when you do.

![the panel](preview.png)

The bar icon is only a front end. It runs one program, [odisplay-cli][cli], which owns the order of
operations: the monitor moves first, and the keyboard and mouse only move once it has. This panel
cannot reorder that, because it never sees the individual commands.

## Install

The plugin needs `odisplay`, and there is no fallback: without it the buttons do nothing and the
panel says so.

**1. Build the CLI.** It is a single Go binary with no dependencies outside the standard library:

```bash
git clone https://github.com/h1st0ry3D/odisplay-cli
cd odisplay-cli
go build -o ~/.local/bin/odisplay ./cmd/odisplay
```

`/usr/local/bin` works too if you prefer a system-wide install. The panel looks in `/usr/local/bin`
first and `~/.local/bin` second, so either is found without configuring anything.

**2. Check the machine is ready.** This runs nothing that touches hardware:

```bash
odisplay doctor
```

**3. Install the plugin.** It is not in the Omarchy marketplace yet. Clone it and link it in:

```bash
git clone <this-repo> "$HOME/github/odisplay"

# Relative target, so the link survives a different username or home directory.
ln -sfn ../../../github/odisplay "$HOME/.config/omarchy/plugins/h1st0ry3d.odisplay"

omarchy bar put h1st0ry3d.odisplay --section right
omarchy restart shell
```

Adjust the number of `../` segments if you clone somewhere else, or replace the link with an
absolute path if you prefer.

Rename the symlink and the `id` in `manifest.json`, `moduleName` and `ipcTarget` if you fork it
under your own name.

### Reinstall after changing the CLI

```bash
cd ~/github/odisplay-cli && go build -o ~/.local/bin/odisplay ./cmd/odisplay
omarchy restart shell
```

## Use

Click the bar icon, then click an input. One tap sends the command.

Right-click the bar icon to pick which ddcutil display the commands go to (see
[The display number](#the-display-number)).

Right-click an input instead of clicking it to rename it.

The panel shows what `odisplay` said, in one line, with the reason underneath when it went wrong.
That result line is session only, and closing the panel clears it: a failure stays on screen until
the next switch unless the panel is closed, and the panel is what you close to reach the display
menu, so it would sit there indefinitely. Reopening starts on a clean line.

## Settings

One file, owned by `odisplay`:

```
$XDG_CONFIG_HOME/odisplay/odisplay.json     # ~/.config/odisplay/odisplay.json
```

```json
{
  "version": 1,
  "display": 1,
  "inputs": [
    { "key": "usbc", "name": "Laptop", "vcp": 27, "host": "0" },
    { "key": "dp",   "name": "Mac Mini", "vcp": 15, "host": "2" },
    { "key": "hdmi", "name": "PC", "vcp": 17, "host": "3" }
  ],
  "devices": ["MX Keys S", "LIFT VERTICAL ERGONOMIC MOUSE"]
}
```

The panel reads it and asks `odisplay` to change it. It never writes the file itself, so there is
one writer that also validates what it is given. You can edit it by hand too, and the panel picks
the change up the next time you open it.

From a terminal:

```bash
odisplay list                              # show what is configured
odisplay set name dp "Mac Mini"            # rename a button
odisplay set host dp 2                     # set the Easy-Switch channel
odisplay set display 2                     # set the ddcutil display number
odisplay path                              # print the config file's location
```

A file that will not parse is refused rather than replaced with the defaults, because a typo there
means the wrong display number and the wrong hosts.

### Which monitor this was built for

**Dell S2725DC**, 27-inch QHD, model number `61815`.

| Panel button | VCP `0x60` value | Where the value comes from |
|---|---|---|
| DisplayPort | `0x0f` (15) | Advertised in the EDID as `DisplayPort-1` |
| HDMI | `0x11` (17) | Advertised in the EDID as `HDMI-1` |
| USB-C | `0x1b` (27) | **Not in the advertised list.** Found by testing. |

Two things about that table are worth knowing before you trust it on a different panel.

`ddcutil capabilities` reports the input feature like this on an S2725DC:

```
Feature: 60 (Input Source)
   Values:
      1b: Unrecognized value
      0f: DisplayPort-1
      11: HDMI-1
```

**For another monitor**, run `ddcutil capabilities` and read the values under `Feature: 60`, then
put them in the `inputs` list in the config file. Values differ between manufacturers. `vcp` is
stored as a plain decimal number: 15, 17, 27.

### Naming an input

Right-click an input instead of clicking it. The button becomes a text field holding whatever name
that input currently has. Enter saves it, Escape throws the edit away, and clicking away counts as
saving.

A name is a label and nothing else. The VCP value each button sends still comes from `vcp` in the
config, and there is no way to edit it from the panel, so a name cannot change what a click does.
Empty the field and press Enter to go back to the built-in label.

## Moving the keyboard and mouse with the display

The small button on the right of each row picks which Easy-Switch channel the Logitech keyboard and
mouse move to when you click that input. It reads `off`, `1`, `2` or `3`, and each click steps to
the next one. `off` leaves the devices where they are. The setting is per input and is remembered.

Hovering the button says what the value means, since the label alone is terse.

With a channel set, one click does both things, in this order:

1. `ddcutil setvcp 60 <value> --display <n>` — the monitor moves.
2. `solaar config <name> change-host <n>` — once per device, keyboard first, mouse last.

**The display moves first on purpose.** If the `ddcutil` call fails the devices are left alone, so a
failed switch never leaves you looking at one machine with the keyboard and mouse attached to
another. The devices move only once the monitor has actually moved, and the sequence stops at the
first device that fails, so the keyboard and mouse never end up split across two machines.

`odisplay` reports which of those happened, through its exit code, and the panel shows it in words:

| Exit | What it means | Where your keyboard is |
|---|---|---|
| 0 | Done | Where you sent it |
| 1 | Settings or usage problem | Unchanged |
| 2 | The display did not move, so the devices were left alone | Still here |
| 3 | The display moved but the devices did not | Gone; use the channel button |
| 4 | A program is not installed | Depends on which one |

This needs [Solaar](https://pwr-solaar.github.io/Solaar/), which nothing else here depends on:

```bash
omarchy pkg add solaar
```

### Set the device names

Solaar matches a device by the exact name `solaar show` prints, and that name is not guessable. The
same Lift is `LIFT VERTICAL ERGONOMIC MOUSE` on one unit and `LIFT For Business` on another. Run:

```bash
solaar show
```

and put your names in the `devices` list in the config file, keyboard first and mouse last. A name
that does not match is reported as an error rather than quietly doing nothing.

### Watch out for this

**Host 2 on the keyboard and host 2 on the mouse can be different machines.** The channel names come
from whatever paired the devices, so a keyboard paired with one machine and a mouse paired with
another will each go where they were paired. If they disagree, set them to the same number on a
machine that both are paired with.

### Before you use it

- **Both sides need the channel paired first.** Software only selects a host that is already
  paired; it cannot pair a new one. Pair with the switch on the device, once.
- **The command has to run on the machine the devices are currently on.** After the switch, this
  machine loses them until the other side switches back.
- **Try it without the mouse first.** Set one input's channel while the other two are `off`, or set
  the channel to a machine you can reach by hand. The panel cannot undo this once it has happened:
  once the mouse has moved the pointer is on the other machine, so you cannot click back.

### Try it before you trust it

`odisplay` can print every command it would run without running any of them:

```bash
odisplay switch dp --dry-run
```

```
Mac Mini, to linux, would run:
/usr/bin/ddcutil setvcp 60 0x0f --display 1
/usr/bin/solaar config 'MX Keys S' change-host 2
/usr/bin/solaar config 'LIFT VERTICAL ERGONOMIC MOUSE' change-host 2
```

## Before you switch to an empty input

Switching to an input with nothing plugged into it can blank the screen, and many monitors stop
answering DDC/CI once they lose the signal. When that happens these buttons cannot bring the
display back and you have to use the monitor's own controls.

A single tap sends the command, so confirm each cable carries a signal first.

## The display number

`odisplay` runs:

```bash
ddcutil setvcp 60 <value> --display <n>
```

`n` is ddcutil's own index from `ddcutil detect`, not the connector name Hyprland uses, and it
changes between reboots. Right-click the bar icon and pick one of the four numbers: the entry with
the tick is the one in use, and the choice is stored, so it comes back after a restart.

**Check this number before trusting the buttons.** It is positional, so a laptop panel sitting in
the list ahead of your monitor pushes it up by one:

```bash
odisplay doctor
```

```
displays (the config says 1):
* display 1  card1-eDP-1   This is a laptop display.  Laptop displays do not support DDC/CI.
  display 2  card2-DP-6    DELL S2725DC

display 1 cannot be switched: This is a laptop display.  Laptop displays do not support DDC/CI.
Every switch will quietly do nothing, and the devices will still move.
Display 2 (card2-DP-6) can be. Set it with `odisplay set display 2`.
```

That second line is the failure worth being careful about. A display number that points at the wrong
display makes every switch a no-op while the devices still move, which is how you lose a keyboard
with nothing obviously having gone wrong.

A number that has moved is the most common failure here, so when `odisplay` reports the display as
missing the panel says so and points back at this menu.

## Requirements

- **Omarchy**, with Hyprland. Tested on Hyprland 0.56.2 and Omarchy's current `qs.Ui` component
  set.
- **[odisplay-cli][cli]**, at `/usr/local/bin/odisplay` or `~/.local/bin/odisplay`. Required. The
  panel reports it missing rather than doing nothing quietly.
- **`ddcutil`**, at `/usr/bin/ddcutil`. Tested with 2.2.7. On Arch: `omarchy pkg add ddcutil`.
- **`solaar`**, at `/usr/bin/solaar`, only if you use the Easy-Switch buttons. On Arch:
  `omarchy pkg add solaar`. Without it the display switching still works, and the panel reports
  that Solaar is missing instead of moving anything.
- **Write access to the monitor's I2C bus.** Omarchy's udev rules grant this to the active user on
  DDC-capable displays. Check yours with:

  ```bash
  ddcutil detect     # find your monitor, then read the I2C bus on its own Display block
  getfacl /dev/i2c-19  # does that bus list your user?
  ```

  `ddcutil detect` prints a bus for every connector it finds, including the laptop panel, so use
  the one in the same block as your monitor's model number.

  `odisplay` runs `ddcutil` as your own user and has no privilege escalation. If the bus is not
  writable, the panel reports ddcutil's error and nothing is sent.
- A DisplayPort or HDMI connection. **VRR (FreeSync) works over DisplayPort only**, so switching to
  HDMI disables FreeSync no matter how Hyprland is configured.

## Design notes

- The panel runs one program. It does not know that ddcutil and Solaar exist, so it cannot put the
  monitor move after the device moves, and it cannot grow a second copy of the rule that says the
  monitor goes first.
- Every change goes through `odisplay`, which is the only writer of the config file. The panel
  reads the file and asks for it to be changed.
- Commands are built as argv arrays and run without a shell, so a device name with spaces in it is
  one argument and a name with a quote in it cannot become a second command.
- Children run with a fixed `PATH=/usr/bin:/bin` and an environment of their own, so nothing in your
  session can change what a program name resolves to.
- Each call has a timeout, because ddcutil can hang when an I2C adapter goes away underneath it and
  Solaar waits on a device that may be asleep. 8 seconds for the display, 10 for each device.
- ddcutil's output is capped at 4 KB in the panel and 64 KB in `odisplay`, so a runaway child cannot
  grow either one without limit.
- Output is stripped of `<`, `>` and `&` before it reaches a label the shell renders itself, and its
  line breaks become spaces so a wrapped message does not read as one run-together word.
- A failed switch says what happened in the panel's own words and keeps `odisplay`'s explanation
  underneath it, rather than showing an exit code on its own. The first line is followed by a colon
  and the rest by a full stop, so a wrapped message reads as one sentence. Picking a display from the
  menu clears that failure, since the failure is what pointed at the menu.
- The panel checks for `odisplay` at startup and says where it looked if it is not there, rather than
  failing on the first click.
- A change is shown on the button before `odisplay` has been asked, and the file is re-read
  afterwards, so a refused change cannot stay on screen as though it took.
- The bar glyph is `U+F26C` (`fa-tv`) in JetBrainsMono Nerd Font, and the panel's column headers
  reuse it over the input buttons and `U+F11C` over the Easy-Switch ones. Icon names in a merged
  icon font are not guessable from the codepoint: `U+F26A` looks like a "tv" but draws a crescent,
  and `U+F245` is named `mouse_pointer` but draws an arrow rather than a mouse.

## License

MIT

[cli]: https://github.com/h1st0ry3D/odisplay-cli