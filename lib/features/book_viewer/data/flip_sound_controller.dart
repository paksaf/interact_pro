// SPDX-License-Identifier: AGPL-3.0
//
// FlipSoundController — user-configurable page-flip sound preference
// (#273, 2026-05-20).
//
// User reported the default scipy-generated WAV (noise+800Hz decaying
// tone) sounds like an echo rather than a paper turn. Fix: bundle 4
// options (none/soft/paper/click) and let the user pick from Settings.
// Default is `soft` — pure brushed noise, no tone, the closest
// approximation of a real page turn out of the synthesised options.
//
// Persisted via SharedPreferences key `book_viewer.flip_sound`.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which page-flip sound to play. Each value maps to an asset under
/// `assets/sfx/`. See README in that folder for the audio details.
enum PageFlipSound {
  /// Off — no sound on page change. Choose this for distraction-free reading.
  none('', 'Off', 'Silent page turns'),

  /// Brushed-noise envelope, ~180ms. Closest to a real paper rustle.
  /// Default for new installs.
  soft('sfx/page_flip_soft.wav', 'Soft',
      'A short brushed-paper rustle (default)'),

  /// Two-burst paper sound, ~320ms — lift + slap with high-pass emphasis.
  /// More pronounced than soft; closer to thick-book pages.
  paper('sfx/page_flip_paper.wav', 'Paper',
      'Lift-and-slap, more pronounced'),

  /// Minimal mechanical click, ~80ms. For users who find any rustle
  /// distracting but still want haptic-like feedback.
  click('sfx/page_flip_click.wav', 'Click',
      'Short mechanical click'),

  /// Legacy default before #273. Kept available so existing users who
  /// liked it can switch back; the synthesised tone produces an
  /// echo-like quality that most reported as unpleasant.
  echo('sfx/page_flip.wav', 'Echo (legacy)',
      'Original synthesised tone — has an echo quality');

  const PageFlipSound(this.asset, this.label, this.description);

  /// Asset path passed to AudioPlayer.play(AssetSource(...)). Empty
  /// string for `none` — caller short-circuits.
  final String asset;
  final String label;
  final String description;

  bool get isEnabled => this != PageFlipSound.none;

  static PageFlipSound fromName(String? name) {
    if (name == null) return PageFlipSound.soft;
    for (final v in PageFlipSound.values) {
      if (v.name == name) return v;
    }
    return PageFlipSound.soft;
  }
}

@immutable
class FlipSoundState {
  const FlipSoundState({this.sound = PageFlipSound.soft, this.volume = 0.45});
  final PageFlipSound sound;

  /// 0..1 playback gain. Lets users who picked the louder `paper` option
  /// pull it back without disabling sound entirely.
  final double volume;

  FlipSoundState copyWith({PageFlipSound? sound, double? volume}) =>
      FlipSoundState(sound: sound ?? this.sound, volume: volume ?? this.volume);
}

class FlipSoundController extends StateNotifier<FlipSoundState> {
  FlipSoundController() : super(const FlipSoundState()) {
    _load();
  }

  static const _keySound = 'book_viewer.flip_sound';
  static const _keyVolume = 'book_viewer.flip_volume';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = FlipSoundState(
      sound: PageFlipSound.fromName(prefs.getString(_keySound)),
      volume: prefs.getDouble(_keyVolume) ?? 0.45,
    );
  }

  Future<void> setSound(PageFlipSound sound) async {
    state = state.copyWith(sound: sound);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySound, sound.name);
  }

  Future<void> setVolume(double volume) async {
    final v = volume.clamp(0.0, 1.0);
    state = state.copyWith(volume: v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyVolume, v);
  }
}

final flipSoundControllerProvider =
    StateNotifierProvider<FlipSoundController, FlipSoundState>(
  (ref) => FlipSoundController(),
);
