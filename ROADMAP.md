# Unified AI Personal — خطة التطوير

## المرحلة 1 — مكتملة برمجيًا
- FastAPI + SQLite + Ollama وموصل Langflow اختياري
- جلسات المحادثة وسجل التدقيق والموافقات غير التنفيذية
- واجهة SwiftUI، مفتاح API في Keychain، قفل الجهاز
- ذاكرة يدوية: إنشاء/عرض/بحث/تعديل/حذف عبر API
- واجهة iOS لإضافة/عرض/حذف الذاكرة

## المرحلة 2 — قبل الاستخدام خارج الشبكة المحلية
- تشغيل HTTPS بشهادة موثوقة عبر شبكة VPN خاصة أو reverse proxy مضبوط
- إضافة حدود معدل الطلبات ونسخ احتياطي مشفر مع اختبار الاستعادة
- اختبار البناء في Xcode على جهاز آيفون حقيقي
- اختبار Ollama وLangflow فعليًا، ومعالجة انقطاع الشبكة

## المرحلة 3 — لاحقًا
- استرجاع ذاكرة دلالية بموافقة المستخدم قبل إرسالها للنموذج
- تصدير واستيراد مشفر للبيانات
- تنفيذ أدوات آمن بموافقات مقيدة بنطاق وصلاحيات واضحة

## مقارنة التشغيل
| الخيار | مناسب متى | القيد |
| --- | --- | --- |
| Mac يعمل دائمًا | تملك Mac وموارد كافية وتريد أقل كلفة تشغيل إضافية | يحتاج بقاء الجهاز متصلًا |
| خادم خاص VPS | تريد الوصول المستمر من أي مكان | تشغيل نماذج محلية كبيرة يحتاج GPU أو مزود نماذج منفصل |
| Mac + VPN خاص | الاستخدام الشخصي والخصوصية | تحتاج إعداد VPN وتوفر الجهاز |

## الخصوصية والأمان
- التطبيق لمستخدم واحد ولا يحتوي تسجيل حسابات.
- لا تفتح منفذ Ollama أو Langflow للإنترنت مباشرة.
- SQLite غير مشفر على مستوى التطبيق؛ استخدم تشفير القرص ونسخًا احتياطية مشفرة.
- الذاكرة الجديدة لا تدخل تلقائيًا في سياق النموذج.
- Face ID يحمي واجهة التطبيق، وليس بديلًا عن مصادقة الخادم.
- لم يُختبر المشروع بعد على Xcode أو جهاز iPhone.


## المتبقي للتحقق على الأجهزة
- تشغيل GitHub Actions على المستودع الفعلي ومراجعة أي أخطاء Xcode.
- التوقيع بحساب Apple Developer واختبار iPhone فعلي.
- اختبار تبديل الشبكة وانقطاع الصوت ومقاطعة المساعد.
- اختبار Ollama وLangflow على خادم حقيقي، ومراقبة زمن الاستجابة.
- تحسين سياسة إلغاء استدلال الخادم ودمج تأثيرات VoiceInteractionCore بالكامل.


## v10
- [x] تصدير محادثة منفردة بصيغة JSON مع حماية مفتاح API.
- [x] اختبار عزل البيانات ورفض الطلبات غير المصرح بها وحذف المحادثة.
- [ ] بناء iOS على macOS والتحقق من التوقيع والنطق والتسجيل على جهاز حقيقي.
- [ ] ربط إجراءات محرك السياسات الصوتية بجميع أحداث التسجيل والاستدلال.
- [ ] رفع المستودع عبر اتصال GitHub مخول بالكتابة.


## حالة v11
- [x] مشاركة تصدير محادثة واحدة من واجهة iOS.
- [x] منع بقاء ملف التصدير المؤقت بعد القفل أو مغادرة التطبيق.
- [x] إصلاح استيفاء النصوص في Swift.
- [x] تشغيل اختبارات Python وSwift Core.
- [ ] بناء iOS في Xcode على macOS.
- [ ] اختبار مشاركة الملف فعليًا على iPhone.
- [ ] رفع المشروع إلى GitHub من خلال أداة كتابة مخوّلة أو Git محلي.


## v12
- [x] حفظ الرسالة الحالية عند طول المحادثة.
- [x] ترتيب الأحدث أولًا عند اختيار سياق محدود.
- [x] اختبارات خاصة لتنسيق السجل وحجم السياق.
- [ ] بناء التطبيق على Xcode واختبار الصوت على iPhone.
- [ ] رفع GitHub عبر اتصال مخوّل بالكتابة.


## v13
- [x] فحص جاهزية محمي لقاعدة البيانات
- [x] اختبارات المصادقة وفشل قاعدة البيانات
- [x] اختبارات Python وSwift Core
- [ ] اختبار Xcode وiPhone فعلي
- [ ] نشر GitHub بصلاحية كتابة متاحة


## v14
- [x] بحث نصي مصادق عليه داخل المحادثات.
- [x] واجهة بحث SwiftUI.
- [x] اختبارات بحث وحماية المدخلات.
- [ ] بناء Xcode واختبار واجهة البحث على iPhone.
- [ ] رفع المستودع باستخدام اتصال GitHub بصلاحية كتابة.


## v15
- [x] تأكيد الحذف النهائي من واجهة iOS.
- [x] تنظيف ملف التصدير قبل الحذف.
- [x] اختبارات Python وSwift Core.
- [ ] بناء Xcode واختبار الحذف على آيفون فعلي.


## v16
- [x] Prompt context integrity and regression tests.
- [ ] Xcode build and iPhone end-to-end test.
- [ ] GitHub push with authorized repository write integration.

## v17 status
- [x] Prompt context recovery for oversized history turns.
- [x] Bounded conversation export and regression tests.
- [ ] Xcode build and physical iPhone verification.
- [ ] Authorized GitHub push.


## v18
- [x] واجهة سجل رسائل بصفحات ومؤشر إدراج مستقر.
- [x] رفض HTTP redirects في طلبات iOS التي تحمل مفتاح API.
- [x] اختبارات المصادقة والحدود وحذف المحادثات.
- [ ] توصيل واجهة iOS بالتحميل التدريجي.
- [ ] بناء Xcode واختبار iPhone فعلي.


## v19
- [x] Connect iOS conversation view to cursor pagination.
- [x] Add authenticated server readiness control to iOS settings.
- [x] Add static iOS integration checks.
- [ ] Build with Xcode on macOS and verify iOS SDK compatibility.
- [ ] Verify pagination scrolling and UI on physical iPhone.
- [ ] Run end-to-end Ollama/Langflow tests against private server.


## v20
- [x] اقتراحات متابعة مبنية على سياق آخر رسالة مستخدم، دون طلب نموذج إضافي.
- [x] عدّاد رسائل وأدوار المحادثة.
- [x] عرض الاقتراحات في iOS مع تحقق من جلسة المستخدم.
- [x] اختبارات المصادقة، الخصوصية، الاقتراحات، وتكامل مصدر iOS.
- [ ] تحقق Xcode من SwiftUI على macOS وiPhone.
- [ ] رفع النسخة إلى GitHub عبر اتصال يدعم الكتابة.


## v21
- [x] تسمية المحادثات وتثبيتها عبر API وSwiftUI.
- [x] ترحيل قاعدة بيانات موجودة واختبارات حماية API.
- [x] اختبارات Python وSwift Core.
- [ ] اختبار SwiftUI داخل Xcode وعلى iPhone فعلي.
- [ ] إضافة اختبارات UI تلقائية للتسمية والتثبيت.

## v22
- [x] واجهة وكيل داخل التطبيق مرتبطة بخادم API.
- [x] خطة، معاينة، تأكيد، إلغاء، انتهاء صلاحية، حماية من التكرار.
- [x] اختبار عمليات التسمية والتثبيت والمصادقة.
- [ ] ربط أدوات أخرى بقائمة صلاحيات لكل إجراء (الذاكرة، المهام، القوائم).
- [ ] ربط تخطيط اللغة الطبيعية بالنموذج مع تحقق مستقل من المخرجات.
- [ ] فحص بناء SwiftUI على Xcode واختبار واجهة الوكيل على جهاز حقيقي.


## v23 status
- [x] Task board server CRUD with session isolation.
- [x] Agent task creation with explicit preview and approval.
- [x] iOS task board screen and API integration.
- [x] Python integration tests and Swift Core tests.
- [ ] Full Xcode compile and physical iPhone testing.
- [ ] Richer UI component actions with a typed, permission-scoped tool registry.
- [ ] Live voice-to-agent tool integration and comprehensive device E2E.
- [ ] Final cinematic theme after functionality and usability validation.


## v24
- [x] إكمال المهام وإعادة فتحها بأوامر الوكيل بعد الموافقة.
- [x] منع المطابقة الغامضة وتكرار التنفيذ وتجاوز نطاق المحادثة.
- [x] اختبارات تكامل جديدة.
- [ ] توسيع طبقة أوامر التنقل الآمن بين شاشات التطبيق.
- [ ] اختبار واجهة SwiftUI داخل Xcode على iPhone.


## V30 — التثبيت وإثبات التشغيل
- [x] إصلاح setuptools وأمر التثبيت النظيف وقفل اعتماديات CI.
- [x] فصل أصول الويب واختبار CSP في متصفح Chromium حقيقي.
- [x] فرض حد الجسم أثناء القراءة، بما في ذلك chunked requests.
- [x] تحديث cryptography وإضافة فحص pip-audit.
- [x] منع ازدواج المحادثة عبر request_id وحجز المحاولة في SQLite.
- [x] ربط قرارات الوكيل بـsession_id وقفل iOS عند الخلفية.
- [x] اختبار HTTP فعلي للحفظ وإعادة التشغيل والاستعادة مع مزود اختباري محلي.
- [ ] تشغيل GitHub Actions على المستودع الفعلي وإغلاق أي فشل ظاهر.
- [ ] بناء SwiftUI على macOS ثم Xcode Cloud وTestFlight على iPhone.
- [ ] اختبار Ollama أو Langflow الحقيقي وقياس الاستجابة وانقطاع الشبكة.
- [ ] اختبار الميكروفون والمقاطعات وBluetooth وFace ID على الجهاز الفعلي.
- [ ] توصيل VoiceInteractionCore effects وdurable checkpoints قبل أي ادعاء صوتي متقدم.
