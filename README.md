# Juice

Battery levels for a Logitech MX Master 3S mouse and Bose QuietComfort Ultra headphones, in the macOS menu bar.

![How Juice works](docs/how-it-works.svg)

## What you get

- **Menu bar:** one item shows an icon and a percentage for each connected device. When a device disconnects, its part fades out and the item closes up. When it reconnects, the item opens and the part fades back in.
- **Dropdown:** click the item to see both devices, their levels, and whether they are charging.
- **Low battery alert:** one notification when a device reaches 20%. The alert can fire again once the device has charged past 25%.

## Install

You need an Apple silicon Mac on macOS 26 or later, with Xcode's command line tools (Swift 6.2).

```sh
make install
```

This builds Juice, signs it, copies it to `/Applications`, and launches it.

On first launch macOS asks for Bluetooth access and Juice asks to send notifications. Allow both. To start Juice with your Mac, tick **Open at Login** in the dropdown.

## Use your own device names

Juice finds each device by its Bluetooth name. The defaults are `MX Master 3S` and `Atom`. Change them, then relaunch Juice:

```sh
defaults write ai.pivotstudio.juice mouseName "MX Master 3S"
defaults write ai.pivotstudio.juice headphonesName "Atom"
```

After you rename or re-pair the headphones, clear the address Juice saved for them:

```sh
defaults delete ai.pivotstudio.juice headphonesAddress
```

## How it works

**Mouse.** The MX Master 3S reports its battery through the standard Bluetooth LE battery service. Juice reads it directly and re-reads it every minute.

**Headphones.** macOS does not report the Bose battery anywhere, so Juice asks the headphones itself. It uses the same protocol as the Bose app (called BMAP) over a Bluetooth serial connection, and asks again every 2 minutes. The message format comes from the open-source [bosectl](https://github.com/aaronsb/bosectl) project.

**Disconnects.** A device going away is normal, not an error. It leaves the menu bar and Juice waits. Juice notices the headphones return when they show up as an audio device, and connects a second later. If that connection fails, Juice retries after 2 seconds and doubles the wait each time, up to 5 minutes.

Juice only talks to the headphones while they are already connected to this Mac, so it never pulls them away from your phone.

## Check that it is working

```sh
make probe
```

This prints one reading per device as JSON. It exits with an error if either device has no reading.

To see each step of the headphones connection:

```sh
JUICE_TRACE=1 ~/Library/Caches/JuiceBuild/Juice.app/Contents/MacOS/Juice --probe
```

## Limitations

- **Second display.** With more than one display, only the menu bar on the display you are working on shows the smooth fade. On the other displays macOS draws its own copy of the item, and that copy changes in steps.

## For developers

```sh
make test     # tests for the Bose message decoder
make app      # build the signed app without installing it
make clean    # remove build output
```

Build output goes to `~/Library/Caches/JuiceBuild`. The source of the diagram is `docs/how-it-works.excalidraw`, which opens in [Excalidraw](https://excalidraw.com).

Three things about macOS shaped the code:

- **macOS animates the menu bar itself.** When a menu bar item changes width, macOS slides the item's content from its old left edge to its new one. Changing the width more than once per transition restarts that slide and stutters. Juice therefore fades a device out at a fixed width with Core Animation, changes the width once, and lets macOS do the slide. The mouse sits on the left, so when it comes or goes the whole item fades out, resizes, and fades back in; otherwise the headphones would jump sideways.
- **macOS can report the headphones as disconnected when they are not.** On macOS 27.2, listing paired Bluetooth devices makes the system report these headphones as disconnected for the rest of that process. Juice instead treats them as connected while they appear as an audio device, and looks up their Bluetooth address in a separate short-lived process (`Juice --resolve-address <name>`).
- **macOS loses track of the mouse.** It lists the mouse as a power source but drops it from that list for long stretches while the mouse stays connected. Juice uses that list only for the charging flag.
