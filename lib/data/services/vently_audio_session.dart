import 'package:audio_session/audio_session.dart';

/// Central audio-session routing so record → playback handoff works on iOS/Android.
///
/// Without reconfiguring after [WhisperRecorder] stops, playback often routes to
/// the earpiece (inaudible) or stays silent because the session is still in
/// `playAndRecord` capture mode.
class VentlyAudioSession {
  VentlyAudioSession._();
  static final VentlyAudioSession instance = VentlyAudioSession._();

  AudioSession? _session;

  Future<void> ensurePlayback() async {
    _session ??= await AudioSession.instance;
    await _session!.configure(
      const AudioSessionConfiguration.speech().copyWith(
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.defaultToSpeaker |
            AVAudioSessionCategoryOptions.allowBluetooth,
      ),
    );
    await _session!.setActive(true);
  }

  Future<void> ensureRecording() async {
    _session ??= await AudioSession.instance;
    await _session!.configure(
      AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.defaultToSpeaker |
            AVAudioSessionCategoryOptions.allowBluetooth,
        avAudioSessionMode: AVAudioSessionMode.spokenAudio,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          usage: AndroidAudioUsage.voiceCommunication,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
      ),
    );
    await _session!.setActive(true);
  }
}
