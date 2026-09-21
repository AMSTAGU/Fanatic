<p align="center">
  <img src=".github/icon.png" width="128" height="128" alt="Fanatic app icon">
</p>

<h1 align="center">Fanatic</h1>

<p align="center">
  A tiny macOS menu bar app that shows your Mac's fan spinning — at the speed it's actually spinning.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white" alt="Swift 5">
  <img src="https://img.shields.io/badge/dependencies-none-brightgreen" alt="No dependencies">
</p>

---

## Overview

Fanatic puts a small rotor in your menu bar. It turns as fast as your busiest fan: a slow drift when the Mac is idle, a visible whirl when it's working hard. Click it to open a compact panel with live system stats.

No window, no Dock icon, no helper tool, no root access. Just the rotor.

## Features

**In the menu bar**

- An animated rotor driven by live fan RPM, tinted by the menu bar itself so it always matches the system's own icons.
- A tooltip with the current fan speed.

**In the panel**

| Section | What it shows |
| --- | --- |
| **Fans** | Speed of each fan in RPM, with a gauge relative to its maximum speed |
| **CPU** | Total load, a 60-second sparkline, and the system / user / idle split |
| **Temperatures** | Peak and average per sensor group: CPU performance cores, CPU efficiency cores, GPU, chassis, battery, SSD, Wi-Fi |
| **Memory** | Usage, memory pressure, app memory, wired and compressed memory |
| **Network** | Active interface, local IP address, upload and download rates |
| **Power** | Total system power, AC input and battery rails (when available) |

Only the sensors your Mac actually exposes are shown. On Macs without a fan, such as the MacBook Air, the rotor stays still and the panel says so.

The panel also has a **launch at login** toggle and a **quit** button.

## Built to stay out of the way

A menu bar app runs all day, so Fanatic tries hard to cost next to nothing:

- **Reads the hardware directly.** Fanatic talks to the System Management Controller through IOKit and reads CPU, memory and network figures straight from the kernel. It never runs `top`, `netstat`, `powermetrics` or any other external process.
- **Does less when you're not looking.** With the panel closed, it samples only the fans, every 2 seconds, with timer leeway so macOS can group its wake-ups with other work. Temperatures, power, memory and network are only read while the panel is open, once per second.
- **Lets the render server do the animation.** The rotor spins by rotating a Core Animation layer instead of redrawing an image every frame. This dropped the animation from about 8% of a CPU core to about 0.05%.
- **Stops when the screen does.** Sampling and animation pause when the display or the Mac goes to sleep.
- **Respects Reduce Motion.** When *Reduce Motion* is turned on in Accessibility settings, the rotor stays still.

A few details in the animation:

- The rotor follows the **busiest fan**, which is the one you can hear.
- Fan speed is mapped through a curve rather than linearly. Fans spend most of their time in the bottom third of their range, so a linear mapping would make "idle" and "busy" look the same.
- The top speed is capped at 6 turns per second. The rotor has four blades, so anything faster on a 60 Hz display would start to look like it's spinning backwards.

## Requirements

- macOS 14 Sonoma or later
- Xcode 26 or later to build (the app icon uses the Icon Composer `.icon` format)

The temperature groups are labelled for Apple Silicon sensor names. Fan speed works on any Mac with a fan.

## Building from source

```sh
git clone https://github.com/AMSTAGU/Fanatic.git
cd Fanatic
open Fanatic.xcodeproj
```

Then select the **Fanatic** scheme and press <kbd>⌘</kbd> <kbd>R</kbd>. You may need to pick your own development team under **Signing & Capabilities** first.

To build from the command line without signing:

```sh
xcodebuild -project Fanatic.xcodeproj -scheme Fanatic -configuration Release \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
open build/Build/Products/Release/Fanatic.app
```

To keep it, copy `Fanatic.app` into your Applications folder.

## Sandbox and permissions

Fanatic runs inside the App Sandbox. It needs a single exception to reach the fan and temperature sensors:

```xml
<key>com.apple.security.temporary-exception.iokit-user-client-class</key>
<array>
    <string>AppleSMCClient</string>
</array>
```

Without it, the sandbox blocks the `AppleSMC` service entirely and the app has nothing to show. Access is **read-only**: Fanatic never writes to the SMC and cannot change fan speeds.

## Project structure

```
Fanatic/
├── main.swift           Entry point: builds the app without a nib
├── AppDelegate.swift    Status item, panel, launch at login, sleep and Reduce Motion handling
├── MenuBarRotor.swift   Spins the rotor in the menu bar
├── RotorGlyph.swift     Draws the rotor artwork as a template image
├── Telemetry.swift      Sampling schedule and the data model the UI reads
├── SMC.swift            Minimal read-only client for the System Management Controller
├── Sensors.swift        Fans, temperature groups and power rails, read from the SMC
├── SystemLoad.swift     CPU, memory and network, read from the kernel
├── StatsPanel.swift     The SwiftUI panel
└── AppIcon.icon         App icon (Icon Composer)
```

## Notes

- The interface is currently in French.
- SMC key names are not documented by Apple and can differ between Mac models. If a section is missing or looks wrong on your Mac, please open an issue with your model.
