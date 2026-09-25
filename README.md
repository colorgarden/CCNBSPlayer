# CCNBSPlayer

A [CC:Tweaked](https://tweaked.cc/) music player that decodes
[Note Block Studio](https://noteblock.studio/) (`.nbs`) songs and plays them
in-game on the `speaker` peripheral.

> **Status: work in progress.** The repository has been initialised and the
> implementation is being built. Nothing is installable yet - this README will
> be expanded with install and usage instructions once the player is written.

## What it will do

- Decode `.nbs` files across all published format versions (legacy v0 through
  v6), including layers, note velocities/panning/pitch, custom instruments and
  loop metadata.
- Play the song by scheduling Minecraft's native note-block timbres through
  `speaker.playNote` / `speaker.playSound` - no audio samples are bundled, and
  no audio download is required.
- Analyse a song on load and warn about things the player cannot reproduce
  faithfully, such as notes outside the native two-octave range (which need an
  extended-range resource pack) or songs that need more speakers than are
  attached.
- Distribute notes across multiple attached speakers when a song has more
  simultaneous notes than one speaker allows per tick.

## What it will not do

- It does not bundle or play PCM/DFPWM audio samples.
- It does not play custom instruments carried inside `.nbs` files.
- Version 1 does not support seeking or looped playback.
- It does not modify Minecraft, the server, or install resource packs for you.

## Requirements (planned)

- A CC:Tweaked computer with at least one attached `speaker` peripheral.
- HTTP enabled if you want to install or update via `wget`.

## License

MIT - see [LICENSE](LICENSE). Third-party attributions are listed in
[NOTICE](NOTICE).
