# TelegramCallTweak 📞

A runtime dylib tweak for **Telegram** and **Swiftgram** (iOS) that enhances voice/video call behavior — force built-in microphone routing, share audio-only during screen sharing, and independently control mic and media volumes in real time.

---

## Features

### 🎙️ Force Built-in Microphone
Telegram tends to switch to Bluetooth headphone mics automatically when they're connected. This toggle forces the call to always use the iPhone's built-in microphone — useful when you want your earbuds for listening but your phone mic for speaking.

### 🖥️ Share Audio Only
During a screen share, this option blacks out all video frames while still transmitting system audio. The other participants hear your screen audio but see a black/blank screen instead of your display.

### 🔊 Independent Volume Controls
Two separate sliders let you control:
- **Microphone Voice Volume** — scale your mic input up or down (0–200%)
- **Screen Media Volume** — scale the screen audio mixed into the call (0–200%)

Both are applied in real time — no need to restart the call.

---

## Compatibility

| App | Status |
|-----|--------|
| Swiftgram (iOS) | ✅ Tested |
| Telegram (iOS) | ✅ Should work (same codebase) |

> Requires a jailbroken device (Dopamine, palera1n, etc.) or TrollStore for dylib injection.

---

## Installation

### Build from source

**Prerequisites:**
- [Theos](https://theos.dev/docs/installation) installed at `~/theos`
- Xcode + iOS SDK

```bash
git clone https://github.com/oceanondawave/TelegramCallTweak
cd TelegramCallTweak
export THEOS=~/theos
make package FINALPACKAGE=1
```

The compiled `.deb` will be in the `packages/` directory (gitignored — build locally).

### Inject the dylib

After building, inject `TelegramCallTweak.dylib` into the Telegram/Swiftgram process using your preferred tool (e.g. `insert_dylib`, Orion, or a Substrate-compatible tweak manager).

---

## Usage

1. Open **Swiftgram** or **Telegram**
2. Go to **Settings**
3. Tap the **📞 Tweak** button (floating pill button below the Edit button)
4. Configure your preferences:
   - Toggle **Force Built-in Mic** to lock the mic to the iPhone's internal microphone
   - Toggle **Share Audio Only** to share audio without exposing your screen visually
   - Drag the **volume sliders** to adjust mic and screen audio levels independently
5. All changes take effect immediately (no call restart needed for volumes and audio-only mode)

---

## How It Works

| Hook | Purpose |
|------|---------|
| `AudioUnitRender` (DYLD interpose) | Mixes screen audio into the WebRTC mic buffer in real time |
| `OngoingCallThreadLocalContextVideoCapturer` | Intercepts video frames and clears them to black when audio-only mode is active |
| `OngoingCallThreadLocalContextWebrtc` | Captures outgoing screen audio data to mix into the call |
| `AVAudioSession` | Overrides mic routing to force built-in microphone |
| `UIViewController` swizzle | Injects the floating settings button on the Settings tab |

---

## Settings Behavior

| Setting | ON | OFF |
|---------|-----|-----|
| Force Built-in Mic | Always uses iPhone mic | System picks mic (Bluetooth, etc.) |
| Share Audio Only | Video frames → black screen | Full screen share (video + audio) |
| Mic Volume | Scales mic input (default 100%) | — |
| Media Volume | Scales screen audio (default 100%) | — |

> Settings are persisted to a shared app group plist and survive app restarts.

---

## Author

**[@oceanondawave](https://github.com/oceanondawave)**

---

## License

MIT
