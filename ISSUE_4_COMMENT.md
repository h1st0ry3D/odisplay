# Implementation Notes: Sleep/Shutdown Feature for Issue #4

## Feasibility Analysis

Sleep is usually possible without sudo on both macOS and Linux, but **full shutdown normally requires elevated privileges** (sudo, polkit authorization, or a desktop-session mechanism). A Go CLI can simply shell out to the platform-appropriate command.

## Platform-Specific Behavior

### macOS

- **Sleep without sudo:** `pmset sleepnow` works for the logged-in user in normal cases.
- **Shutdown without sudo:** generally no; `shutdown` requires root. Apple documents `sudo shutdown -h now` for an immediate shutdown.
- **GUI-equivalent shutdown:** you can sometimes use AppleScript/System Events, but it may prompt for authorization and is less reliable for automation.

```go
// macOS sleep, no sudo
exec.Command("pmset", "sleepnow").Run()

// macOS shutdown: requires sudo/root
exec.Command("sudo", "shutdown", "-h", "now").Run()
```

### Linux

Behavior depends on the session and distribution:

| Action | Usually works without sudo? | Typical command |
|---|---:|---|
| Sleep | Yes, in an active desktop session | `systemctl suspend` |
| Shutdown / reboot | Often yes via polkit | `systemctl poweroff` / `systemctl reboot` |
| Shutdown over SSH / headless | Usually no | `sudo systemctl poweroff` |

On a normal desktop login, `systemd-logind` + PolicyKit often permits the active local user to suspend, reboot, or power off without entering a password. Over SSH, or for another user's session, polkit commonly denies it and you need sudo or a custom polkit rule.

```go
// Linux sleep: normally no sudo for an active desktop user
exec.Command("systemctl", "suspend").Run()

// Linux shutdown: may work for an active local session, otherwise needs sudo
exec.Command("systemctl", "poweroff").Run()
```

## Practical Go Implementation

```go
package main

import (
	"fmt"
	"os"
	"os/exec"
	"runtime"
)

func sleep() error {
	if runtime.GOOS == "darwin" {
		return exec.Command("pmset", "sleepnow").Run()
	}
	return exec.Command("systemctl", "suspend").Run()
}

func shutdown() error {
	if runtime.GOOS == "darwin" {
		// Requires root/sudo in most setups.
		return exec.Command("sudo", "shutdown", "-h", "now").Run()
	}
	// May work without sudo for an active local desktop session.
	return exec.Command("systemctl", "poweroff").Run()
}

func main() {
	var err error
	switch os.Args[1] {
	case "sleep":
		err = sleep()
	case "shutdown":
		err = shutdown()
	default:
		fmt.Fprintln(os.Stderr, "usage: powerctl sleep|shutdown")
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
```

## Passwordless Shutdown Configuration

### Linux Approach
For a self-hosted/Linux box, the cleanest non-sudo route is a narrowly scoped **polkit rule** allowing a specific user or group to call `systemctl poweroff`, rather than giving the binary broad sudo rights. Alternatively, use a dedicated systemd service with `sudo` configured only for that exact command.

### macOS Limitation
There is no equally clean passwordless equivalent for `shutdown`; scheduled shutdowns via `pmset` also require root to configure.

## Recommendation for odisplay

For the Omarchy input source switcher feature:
1. Implement sleep without sudo (reliable on both platforms)
2. For shutdown:
   - **macOS:** Require sudo or document the limitation
   - **Linux:** Try `systemctl poweroff` first; fall back to sudo if needed or document polkit setup
3. Add configuration options to enable/disable each action
4. Provide clear user feedback when privileges are insufficient
