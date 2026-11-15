# Unified AI Core

نواة تجريبية مستقلة مستوحاة من أفكار مستودعي kimi وchat-GBT. ليست نسخة منهما ولا تدعي تكامل Open Design.

## المتطلبات
- Python 3.11+
- Ollama مثبت ويعمل محليًا
- نموذج متاح محليًا، مثل llama3.2

## التشغيل
```bash
python -m venv .venv
source .venv/bin/activate
pip install -e ".[test]"
ollama pull llama3.2
ollama serve
```
في نافذة طرفية ثانية:
```bash
export AI_API_KEY="$(python -c 'import secrets; print(secrets.token_urlsafe(32))')"
export OLLAMA_MODEL=llama3.2
uvicorn core.app:app --host 127.0.0.1 --port 8000
```
على Windows PowerShell:
```powershell
$env:AI_API_KEY = python -c "import secrets; print(secrets.token_urlsafe(32))"
$env:OLLAMA_MODEL = "llama3.2"
uvicorn core.app:app --host 127.0.0.1 --port 8000
```
افتح http://127.0.0.1:8000 وأدخل قيمة AI_API_KEY. لا تخزن المفتاح في المتصفح.
إذا كان Ollama يعمل بالفعل، لا تشغّل نسخة ثانية منه.

## الاختبارات
```bash
pytest -q
```

## API
- GET /health
- POST /sessions
- GET /sessions/{session_id}/messages
- POST /chat
- POST /approvals
- GET /approvals
- POST /approvals/{approval_id}/decision
- GET /audit

كل المسارات عدا / و /health تتطلب ترويسة X-API-Key.

## Langflow (اختياري)
اضبط LANGFLOW_URL و LANGFLOW_FLOW_ID و LANGFLOW_API_KEY إن لزم. استخدم مزود langflow من الواجهة.
قد تختلف صيغة مخرجات Langflow بين الإصدارات وأنواع الـFlows؛ اختبرها وعدل محول الاستجابة عند الحاجة.

## حدود الأمان
- مناسب للتطوير المحلي فقط، وليس جاهزًا للنشر العام.
- مفتاح API واحد مشترك؛ لا يوجد حساب مستخدم مستقل أو عزل متعدد المستأجرين.
- الموافقات لا تنفذ أي أدوات: هي سجل قرارات فقط.
- لا توجد ذاكرة دلالية أو RAG بعد؛ يوجد تاريخ محادثة محدود لكل جلسة.
- لا توجد آلية تصدير فعلي، رغم وجود نوع طلب موافقة باسم export_session.
- لا يوجد تشفير لقاعدة البيانات أو HTTPS مدمج.
- لا تعرّض الخادم أو Ollama أو Langflow للإنترنت دون بوابة أمان مناسبة.
- لا تضف أسرارًا إلى المستودع؛ احتفظ بها في متغيرات البيئة.

## خطة التطوير
1. إثبات تشغيل Ollama وقياس استجابة المحادثة.
2. اختبار تدفق Langflow بإصداره الفعلي، مع حالات الفشل.
3. إضافة حسابات مستخدمين وتفويض جلسات لكل مستخدم.
4. بناء طبقة أدوات آمنة بصلاحيات وموافقات مرتبطة بالتنفيذ.
5. إضافة ذاكرة دلالية مع سياسات حذف واحتفاظ.
6. اختبار Open Design كتكامل مستقل، لا كاعتماد أساسي.
7. إعداد HTTPS وإدارة أسرار ومراقبة واختبارات أمنية قبل النشر.


## iPhone / Apple Developer
راجع `ios/README.md` لإنشاء تطبيق SwiftUI شخصي عبر XcodeGen، مع Keychain وقفل الجهاز واتصال HTTPS.


## الإصدار الشخصي v2

أضيفت واجهة إدارة الذاكرة اليدوية في iOS ونقاط API: `GET/POST /memories` و`PUT/DELETE /memories/{id}`. البحث عبر `GET /memories?q=...`. جميعها تتطلب `X-API-Key`. الذاكرة ليست استرجاعًا دلاليًا ولا تُرسل تلقائيًا إلى النموذج. راجع `ROADMAP.md` للمقارنة بين Mac والخادم الخاص ومهام الأمان والاختبار.

## الإصدار الشخصي v3 — ذاكرة مرتبطة بالسؤال
- يتم البحث عن كلمات من رسالة المستخدم داخل المعلومات المحفوظة يدويًا؛ وتُرسل بحد أقصى خمس معلومات مطابقة إلى النموذج.
- البحث نصي بسيط وليس RAG دلاليًا، ولا يضمن استدعاء كل معلومة ذات صلة. المعلومات ليست تعليمات موثوقة.
- احذف أي معلومة من واجهة iOS أو API لمنع إدراجها في الطلبات اللاحقة.
- الذاكرة ليست مشفرة داخل SQLite؛ احمِ جهاز الخادم وقرصه.

## النسخ الاحتياطي المشفر
ثبت الاعتماديات بـ `pip install -e ".[test]"` ثم:
```bash
python -m core.backup backup --file ./backup.uai
```
أدخل كلمة مرور قوية لا تقل عن 12 حرفًا. تُنشأ نسخة SQLite متسقة وتُشفّر باستخدام AES-256-GCM ومفتاح مشتق عبر scrypt. لا تحفظ كلمة المرور داخل المستودع.
لاستعادة النسخة: أوقف الخادم، وتأكد أن ملف قاعدة البيانات الهدف غير موجود، ثم:
```bash
python -m core.backup restore --file ./backup.uai --database ./data/restored.sqlite3
```
تحقق من البيانات المستعادة قبل تغيير `DB_PATH`. الاستعادة لا تستبدل ملفًا موجودًا. اختبر الاستعادة دوريًا.

## الاتصال الآمن على آيفون
تطبيق SwiftUI يرفض HTTP. استخدم HTTPS عبر شبكة خاصة مثل Tailscale أو عبر بوابة TLS موثوقة.
لا تفتح Ollama أو Langflow أو FastAPI مباشرة للإنترنت. لا تتضمن هذه الحزمة إعداد VPN تلقائيًا.
توقيع Apple Developer وبناء Xcode والتحقق من Face ID على جهاز فعلي لم تُختبر في هذه البيئة.

## الاختبارات
```bash
pytest -q
```
تشمل اختبارات الذاكرة ذات الصلة، عدم إدراج الذاكرة غير المطابقة، تشفير النسخ الاحتياطية، كلمة مرور خاطئة، وكشف العبث.


## الإصدار v7 — حماية التشغيل وCI

- حد أقصى لطلبين متزامنين إلى مزود النموذج، وانتظار 3 ثوانٍ للحصول على مكان متاح.
- مهلة 100 ثانية لرد المزود، وحد أقصى 50,000 حرف للرد المخزن.
- رؤوس حماية للمتصفح ومنع التخزين المؤقت لاستجابات الخادم.
- اختبارات إضافية لحالات المهلة والرد المفرط، وعدم تخزين محادثة فاشلة.
- GitHub Actions لاختبارات Python وSwift، ومحاولة بناء iOS غير الموقعة على macOS.
- لم يتم تنفيذ بناء iOS على Mac في بيئة التطوير الحالية، ولا التوقيع أو النشر على GitHub.
- إلغاء طلب iOS محليًا لا يوقف بالضرورة عملية التوليد على الخادم.
- يستخدم الخادم مفتاحًا واحدًا؛ لا تعرضه على الإنترنت دون TLS وبوابة وصول خاصة.


## v8 — حذف المحادثة نهائيًا

- `DELETE /sessions/{session_id}` يتطلب مفتاح API ويزيل المحادثة ورسائلها وموافقاتها في معاملة SQLite واحدة.
- زر «حذف المحادثة من الخادم» في واجهة iPhone يرسل طلب الحذف، ثم يمسح العرض المحلي بعد نجاحه.
- عند اكتمال استدلال متأخر بعد حذف الجلسة، يرجع الخادم 404 ولا يعيد إنشاء الرسائل.
- لا يمسح حذف الجلسة سجلات التدقيق أو النسخ الاحتياطية المشفرة السابقة. هذه نقطة مهمة لسياسة الاحتفاظ بالبيانات.
- تحقق محليًا: `python -m pytest -q` و`cd ios/VoiceInteractionAudit && swift test`.
- بناء Xcode والتوقيع واختبارات الصوت الحقيقية غير متاحة في بيئة Linux هذه.


## v9 — سجل المحادثات

- `GET /sessions` يتطلب `X-API-Key` ويعرض آخر 100 جلسة ومعرّفاتها وعدد رسائلها دون محتوى الرسائل.
- زر سجل المحادثات في iOS يتيح اختيار جلسة سابقة واسترجاع رسائلها.
- تم التحقق محليًا من 14 اختبار Python و38 اختبار Swift على Linux.
- لم يتم التحقق من بناء Xcode أو تشغيل التطبيق على iPhone فعلي.


## v10 — تصدير المحادثة
أضيف مسار `GET /sessions/{session_id}/export` المحمي بمفتاح API لتنزيل JSON يحتوي على الرسائل وتوقيتاتها فقط. لا يتضمن ذاكرة المستخدم أو سجلات التدقيق أو المحادثات الأخرى. تُمنع استعادة محادثة محذوفة. لا ترسل ملفات التصدير إلى أطراف أخرى دون مراجعتها.

## النشر على GitHub
لا تضع رمز GitHub الشخصي في محادثة أو ملف مشروع. بعد تثبيت GitHub CLI على جهازك:
```bash
gh auth login
git init
git add .
git commit -m "Unified AI Personal v10"
git branch -M main
gh repo create unified-ai-personal --private --source=. --remote=origin --push
```
إذا كان المستودع موجودًا، استخدم `git remote add origin URL` ثم ادفع فرعًا منفصلًا للمراجعة. لا تنفذ `git push --force` على المستودع الرئيسي.


## v11 — مشاركة المحادثة من iPhone

- أصبح زر «تجهيز تصدير المحادثة» يجلب JSON من API المحمي، ثم يظهر زر المشاركة عبر iOS.
- يُكتب ملف المشاركة في مجلد مؤقت مع `completeFileProtection`، ويُحذف عند قفل التطبيق أو انتقاله للخلفية أو بدء محادثة جديدة.
- أصلح الإصدار تسلسلات `\\(variable)` المزدوجة في ملفات Swift التي كانت تمنع الاستيفاء الصحيح للسلاسل.
- اختبارات Python: 18 ناجحة؛ Swift Core: 38 ناجحة على Linux. لم يجرِ بناء التطبيق على Xcode.
- لا تضع مفاتيح GitHub أو Apple Developer في المستودع أو المحادثة.


## v12 — تحسين سياق المحادثة
يحافظ الخادم على رسالة المستخدم الحالية عند قص السجل الطويل، ويُسلسل الرسائل السابقة بصيغة JSON؛ تُفضل أحدث الرسائل ضمن الميزانية. هذه طبقة تقليل مخاطر وليست ضمانًا ضد حقن التعليمات.


## v13 — Readiness

`GET /health/ready` يتطلب `X-API-Key` ويتحقق من سلامة قاعدة البيانات عبر SQLite `PRAGMA quick_check(1)`، ويعيد HTTP 503 عند تعذر الوصول إليها. هذا الفحص لا يختبر اتصال Ollama/Langflow الفعلي. اختبارات Python: 23، واختبارات Swift Core: 38 على Linux.


## v14 — البحث في المحادثات

- مسار `GET /sessions/search?q=...&limit=20` محمي بمفتاح API، ويبحث حرفيًا في نص الرسائل دون إرجاع محتواها.
- واجهة iPhone تعرض حقل بحث وزر استعادة القائمة الكاملة.
- حدود البحث: 2–100 حرف، 1–50 نتيجة؛ `%` و`_` رموز حرفية.
- الاختبارات: Python ‏25/25 وSwift Core ‏38/38 على Linux. لم يتم بناء تطبيق iOS في Xcode.


## v15 — تأكيد حذف المحادثة
- أضيف مربع تأكيد قبل الحذف النهائي في واجهة iOS، مع خيار الإلغاء وتنبيه عن النسخ الاحتياطية وسجلات التدقيق.
- يتحقق الحذف من أن التطبيق مفتوح وفي الواجهة، وينظف ملف JSON المؤقت.
- Python: 28 اختبارًا ناجحًا؛ Swift Core: 38 اختبارًا ناجحًا على Linux.
- بناء iOS الفعلي على Xcode لم يُتحقق منه بعد.


## v16 — Prompt safety
- Serialize memory notes as JSON data, not plain text.
- Preserve current message; reject impossible prompt budgets explicitly.
- Retain newest history first, display selected history chronologically.
- 32 Python tests and 38 Swift Core tests passed on Linux; iOS/Xcode unverified.


## v17 — Limits and context recovery

- Skip oversized history records while retaining shorter older records that fit the prompt budget.
- Bound single-conversation JSON exports to 10,000 messages and 10 MB of UTF-8 message text; return HTTP 413 if exceeded.
- Python: 34 tests passed; Swift core: 38 tests passed on Linux. iOS app build on Xcode is unverified.


## v18 — حماية النقل وتصفح سجل الرسائل

- واجهة `GET /sessions/{session_id}/messages/page?after_id=0&limit=50` تعيد `messages`, `next_after_id`, `has_more`، بحد أقصى 100 رسالة، مع مصادقة API.
- عميل iOS يستخدم جلسة شبكة مؤقتة ويرفض تحويلات HTTP التلقائية لمنع تسريب مفتاح API إلى وجهات إعادة التوجيه.
- أضيف اختبارا تكامل جديدان؛ 36 اختبار Python ناجحًا و38 اختبار Swift Core ناجحًا على Linux.
- تطبيق iOS ما زال يستخدم واجهة السجل الكامل؛ ربطه بالتحميل التدريجي عمل لاحق.
- لم يتم بناء التطبيق على Xcode أو اختباره على جهاز iPhone، ولم يُرفع إلى GitHub.


## v19 — iOS paged history and readiness UI

- `APIClient.messagePage` connects to authenticated cursor-based message history.
- The conversation screen initially loads 50 messages and offers a button to load additional batches.
- Stale asynchronous page responses are ignored after session changes, lock, or cursor changes.
- Settings now offers an authenticated server/database readiness check.
- Tests: 39 Python tests, 38 Swift VoiceInteractionCore tests on Linux.
- iOS SwiftUI compilation and real-device behavior remain unverified; no GitHub push was performed.


## v20 — اقتراحات متابعة ذكية خاصة

- واجهة محمية `GET /sessions/{session_id}/insights` تعرض إحصاءات المحادثة واقتراحات متابعة بالعربية أو الإنجليزية.
- لا تتصل واجهة الاقتراحات بمزوّد AI؛ الاقتراحات ناتجة عن قواعد محددة، ولا تُعيد نص الرسائل.
- واجهة iOS تعرض الاقتراحات كأزرار تضع نص الاقتراح في خانة الإدخال دون إرساله تلقائيًا.
- تُرفض الجلسات غير الموجودة ويجب تقديم مفتاح API؛ ولا تُعرض اقتراحات بعد تبديل المحادثة أو قفل التطبيق.
- الاختبارات: 42 Python ناجحة و38 Swift Core ناجحة على Linux. لم يُبنَ تطبيق SwiftUI على Xcode ولم يُختبر على جهاز فعلي.
