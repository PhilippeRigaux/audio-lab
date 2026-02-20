# Audio Lab (macOS)

Realtime macOS audio router with a dynamic AU plugin chain.

![AudioLab screenshot](/Images/AudioLab_Screenshot.png)

## Apps
- `audio-lab`: CLI router utility.
- `audio-lab-ui`: native macOS app.
- `AudioLabCore`: shared CoreAudio/AU engine library.

## Build
```bash
swift build -c release
```

## Run UI
```bash
swift run audio-lab-ui
```

## CLI usage
List devices:
```bash
.build/release/audio-lab list-devices
```

List plugins (AUv3 only by default):
```bash
.build/release/audio-lab list-plugins
```

List plugins including AUv2:
```bash
.build/release/audio-lab list-plugins --allow-auv2
```

Start realtime routing:
```bash
.build/release/audio-lab realtime \
  --input-device "BlackHole 2ch" \
  --output-device "M-Track 2X2M"
```

Add plugins in CLI by ID (repeat `--plugin-id`):
```bash
.build/release/audio-lab realtime \
  --input-device "BlackHole 2ch" \
  --output-device "M-Track 2X2M" \
  --plugin-id "<plugin-id-1>" \
  --plugin-id "<plugin-id-2>"
```
