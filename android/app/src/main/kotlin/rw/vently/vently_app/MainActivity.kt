package rw.vently.vently_app

// FlutterFragmentActivity, not FlutterActivity: local_auth shows the system
// biometric prompt through androidx.biometric.BiometricPrompt, which needs a
// FragmentActivity to attach to. On a plain FlutterActivity the plugin throws
// "no_fragment_activity" the first time somebody tries to unlock a chat, which
// is a crash you only find on a real device.
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity: FlutterFragmentActivity()
