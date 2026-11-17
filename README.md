# Unified AI Personal — iPhone + Core

**منتج واحد، وليس عدة تطبيقات.** تطبيق iPhone أصلي بـ SwiftUI، ونواة FastAPI واحدة، وقاعدة SQLite بنمط WAL، ومسار تعلّم صامت داخل النواة. لا توجد واجهة ويب ضمن هذا المسار، ولا توجد نواة بحث منفصلة.

## الشيفرة المعتمدة

- `ios/UnifiedAI/`: واجهة iPhone ومحوّل Speech/AVAudioEngine و`VoiceSessionCoordinator.swift`.
- `ios/VoiceInteractionAudit/Sources/VoiceInteractionCore/`: آلة حالات الصوت (Swift package)؛ **ليست** تطبيقًا صوتيًا ثانيًا.
- `ios/VoiceInteractionAudit/Tests/`: اختبارات سياسة الصوت.
- `core/app.py`: API والخادم وحفظ المحادثات والمهام والذاكرة.
- `core/learning.py`: التعلّم السلبي وتصدير الشواهد دون صلاحيات تنفيذ.
- `core/backup.py`: النسخ الاحتياطي والاستعادة.
- `tests/`: اختبارات Python. `scripts/`: أدوات اختبار Ollama والتحقق من تصدير التعلّم.
- `docs/APP_SPEC_AR.md`: مواصفات الاستخدام وقيود الإثبات.
- `docs/UNIFIED_PROJECT_MAP_AR.md`: حدود المستودعات الأربعة.

مواد الدراسة والأرشيفات ونسخ النوى التاريخية **ليست تبعيات تشغيل**؛ ولا تُستورد تلقائيًا. مصدر الشيفرة التنفيذية هو هذا المستودع.

## تشغيل النواة محليًا

يتطلب Python 3.11+، وOllama متاحًا بصورة خاصة عند اختيار مزوّد Ollama.

```sh
python -m venv .venv
source .venv/bin/activate
pip install -e ".[test]"
export AI_API_KEY="$(python -c 'import secrets; print(secrets.token_urlsafe(32))')"
export OLLAMA_MODEL="llama3.2"
uvicorn core.app:app --host 127.0.0.1 --port 8000
```

هذه واجهة API فقط؛ لا توجد صفحة محادثة في المتصفح. يجب استخدام عنوان HTTPS خاص ومفتاح API في إعدادات iPhone. لا تكشف Ollama أو الخادم للإنترنت مباشرة.

## اختبارات التطوير

```sh
python -m pytest -q
swift test --package-path ios/VoiceInteractionAudit
cd ios && xcodegen generate
```

إنشاء مشروع Xcode لا يثبت عمل التطبيق على الهاتف. بناء Simulator في CI لا يثبت Face ID أو سلوك الميكروفون أو القفل أو المقاطعات أو مشاركة الملف إلى Mac.

## معايير القبول المفتوحة

1. اختبار iPhone فعلي موقّع، مع صلاحيات Speech والميكروفون وFace ID وتبديل الشبكة.
2. إصلاح والتحقق من مخاطر دورة حياة الصوت، حفظ التسجيل، قفل الواجهة، والموافقة على تصدير البيانات التي كشفتها مراجعات PR #4.
3. اختبار HTTPS والنسخ الاحتياطي والاستعادة وتصدير التعلّم إلى Mac على الأجهزة المعنية.
4. لا تعتبر الموافقات الحالية تنفيذًا عامًا للأدوات أو توقيعًا آمنًا صادرًا من Secure Enclave.

لا يُعلن أي إصدار جاهزًا للإنتاج لمجرد نجاح اختبارات CI.
