# Voice integration v5

The iOS app now includes a native speech adapter using AVAudioEngine and Apple's Speech framework, plus AVSpeechSynthesizer for Arabic speech output. The chat view has a tap-to-start / tap-to-stop microphone control. Only the recognized text is sent to the existing authenticated HTTPS chat endpoint; microphone audio is not uploaded by this app's code. Apple speech recognition may use on-device or network processing depending on system support and settings.

The VoiceInteractionCore package remains integrated, and its push-to-talk session state receives start, permission, stop and microphone-start events. This is a limited integration: reducer effects are not yet executed by a complete serialized effect runner, and durable utterance checkpoint events are not yet wired. Do not interpret this as a production-grade realtime voice system.

Security: microphone capture stops on app inactivity and manual lock; the app uses iOS microphone and speech permissions. Voice is not permitted to approve external actions. No persistent audio recordings are written by the adapter.

Testing: `swift test` tests the pure Swift policy package on Linux, not the iOS audio adapter. `pytest -q` tests the Python backend. An actual iPhone with Xcode is required to verify microphone, speech recognition availability, Bluetooth route changes, interruptions, TTS, and app signing.

Setup: `cd ios && xcodegen generate`, then open UnifiedAI.xcodeproj in Xcode, choose your Apple Developer team and an iPhone. Use a private HTTPS endpoint and enter the API key in the app. The app must be tested with Arabic speech permissions granted.

Next reliability milestone: connect all reducer VoiceEffect cases to an effect runner, durably checkpoint utterances before submission, and add device-level UI tests for backgrounding, denied permissions and cancellation.


## تحديث v6 — إلغاء الطلبات وحماية جلسة الصوت

- عند مغادرة التطبيق أو قفله، يُلغى طلب المحادثة المعلّق ويُوقف التسجيل والنطق.
- يُستخدم `requestGeneration` لمنع عرض إجابة قديمة بعد الإلغاء أو إنشاء محادثة جديدة.
- زر «إلغاء الإجابة» يوقف انتظار الرد محليًا. قد يستمر تنفيذ الطلب على الخادم؛ الإلغاء ليس ضمانًا لإيقاف استدلال Ollama.
- بداية تسجيل جديدة تقاطع الرد الجاري وتلغي الطلب المحلي القديم.
- اختبارات `test_ios_voice_integration.py` تتحقق من وجود هذه الوصلات في مصدر iOS؛ لا تغني عن اختبارات Xcode الفعلية.
- لا توجد محادثة WebRTC فورية في هذا الإصدار؛ المسار ما زال Speech → Text → AI → Speech.


## V30 — حدود الحماية الحالية

- يقفل التطبيق عند `scenePhase == .background` ويحجب المحتوى أثناء عدم النشاط؛ يلزم التحقق من السلوك على iPhone فعلي.
- ترتبط نتيجة التعرف المتأخرة بالمحادثة التي بدأ فيها التسجيل، فلا تُرسل إلى محادثة بديلة.
- تحمل محادثات النص `request_id` لمنع الازدواج عند Retry؛ لا يعني ذلك أن إلغاء العميل يوقف توليد النموذج على الخادم.
- لم تُوصل جميع VoiceInteractionCore effects أو durable utterance checkpoints. لا يوجد ادعاء Full-duplex أو realtime أو إلغاء صوتي مكتمل.
