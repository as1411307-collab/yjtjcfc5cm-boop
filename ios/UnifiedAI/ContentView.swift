import SwiftUI
import UIKit

struct ContentView: View {
    @AppStorage("serverURL") private var serverURL = ""
    @AppStorage("sessionID") private var sessionID = ""
    @State private var apiKey = ""
    @State private var input = ""
    @State private var voiceReplyPending = false
    @State private var provider = "ollama"
    @AppStorage("reviewVoiceTranscript") private var reviewVoiceTranscript = true
    @State private var messages: [ChatMessage] = []
    @State private var historyCursor = 0
    @State private var hasMoreHistory = false
    @State private var loadingHistory = false
    @State private var serverStatus = ""
    @State private var insights: ConversationInsights?
    @State private var unlocked = false
    @State private var busy = false
    @State private var chatTask: Task<Void, Never>?
    @State private var requestGeneration = UUID()
    @State private var retryRequestID: String?
    @State private var retryFingerprint = ""
    @State private var voiceSessionID = ""
    @State private var notice = ""
    @State private var showAgent = false
    @State private var showTaskBoard = false
    @State private var boardTasks: [BoardTask] = []
    @State private var boardTaskTitle = ""
    @State private var agentCommand = ""
    @State private var agentPlan: AgentPlan?
    @State private var agentBusy = false
    @State private var localNavigationPlan: LocalNavigationAction?
    @State private var pendingNavigation: LocalNavigationAction?
    @State private var navigationFilter = "all"
    @State private var showSettings = false
    @State private var showMemories = false
    @State private var showSessions = false
    @State private var confirmConversationDeletion = false
    @State private var sessionSearch = ""
    @State private var exportedConversationURL: URL?
    @State private var recentSessions: [ConversationSummary] = []
    @State private var editingSession: ConversationSummary?
    @State private var editedTitle = ""
    @State private var personalMemories: [PersonalMemory] = []
    @State private var newMemory = ""
    @StateObject private var voice = NativeVoiceService()
    @StateObject private var voicePolicy = VoicePolicyController()
    @Environment(\.scenePhase) private var scenePhase

    private var client: APIClient {
        APIClient(server: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
                  key: SecretStore.load() ?? "")
    }

    @MainActor
    private func authenticateUnlock() async {
        let authenticated = await DeviceLock.authenticate()
        guard scenePhase == .active else {
            unlocked = false
            return
        }
        unlocked = authenticated
    }

    var body: some View {
        NavigationStack {
            Group {
                if !unlocked {
                    VStack(spacing: 18) {
                        Image(systemName: "lock.shield").font(.system(size: 55))
                        Text("مساعدك الشخصي").font(.title2.bold())
                        Button("فتح باستخدام Face ID أو رمز الجهاز") {
                            Task { await authenticateUnlock() }
                        }.buttonStyle(.borderedProminent)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if SecretStore.load() == nil || serverURL.isEmpty || showSettings {
                    settings
                } else {
                    conversation
                }
            }
            .navigationTitle("Unified AI")
            .onAppear {
                voice.onFinalTranscript = { text in
                    guard unlocked, !busy, scenePhase == .active, voiceSessionID == sessionID else { return }
                    input = text
                    voiceReplyPending = reviewVoiceTranscript
                    if !reviewVoiceTranscript { startSend(speakAnswer: true) }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    cancelPendingChat()
                    voice.stopAll()
                    voicePolicy.appBecameInactive()
                    clearExportFile()
                }
                if phase == .background {
                    agentPlan = nil
                    unlocked = false
                }
            }
            .confirmationDialog(
                "هل تريد حذف المحادثة نهائيًا من الخادم؟",
                isPresented: $confirmConversationDeletion,
                titleVisibility: .visible
            ) {
                Button("حذف المحادثة نهائيًا", role: .destructive) {
                    Task { await eraseCurrentConversation() }
                }
                Button("إلغاء", role: .cancel) {}
            } message: {
                Text("سيُحذف سجل هذه المحادثة من قاعدة البيانات. قد تبقى نسخ سابقة في النسخ الاحتياطية وسجلات التدقيق.")
            }
            .sheet(isPresented: $showAgent, onDismiss: { performPendingNavigation() }) { agentSheet }
            .sheet(isPresented: $showTaskBoard) { taskBoardSheet }
            .sheet(isPresented: $showMemories) { memorySheet }
            .sheet(isPresented: $showSessions) { sessionsSheet }
            .toolbar {
                if unlocked {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showTaskBoard = true
                            Task { await loadBoardTasks() }
                        } label: {
                            Label("المهام", systemImage: "checklist")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showAgent = true } label: {
                            Label("الوكيل", systemImage: "wand.and.stars")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showSettings.toggle() } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showSessions = true; Task { await loadSessions() } } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showMemories = true; Task { await loadMemories() } } label: {
                            Image(systemName: "brain.head.profile")
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button("قفل") { cancelPendingChat(); clearExportFile(); voice.stopAll(); voicePolicy.stopSession(); unlocked = false }
                    }
                }
            }
            .alert("تنبيه", isPresented: Binding(get: { !notice.isEmpty }, set: { if !$0 { notice = "" } })) {
                Button("حسنًا") { notice = "" }
            } message: { Text(notice) }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .task {
            await authenticateUnlock()
            if unlocked && !sessionID.isEmpty && SecretStore.load() != nil {
                await loadHistory()
            }
        }
        .overlay {
            if scenePhase != .active {
                ZStack {
                    Color(.systemBackground).ignoresSafeArea()
                    VStack(spacing: 12) {
                        Image(systemName: "lock.shield").font(.system(size: 44))
                        Text("المحتوى محمي")
                    }
                }
                .accessibilityLabel("المحتوى محمي أثناء عدم نشاط التطبيق")
            }
        }
    }

    private var agentSheet: some View {
        NavigationStack {
            Form {
                Group {
                    Text("الوكيل التفاعلي")
                        .font(.headline)
                    Text("أوامر التنقل: افتح المهام، افتح الإعدادات، افتح المحادثات، افتح الذاكرة، اعرض المهام غير المنجزة. وأوامر تعديل البيانات تتطلب موافقة الخادم.")
                        .font(.footnote)
                    TextField("اكتب أمرًا واضحًا", text: $agentCommand)
                        .textInputAutocorrectionDisabled()
                    Button("معاينة الأمر") {
                        Task { await previewAgentCommand() }
                    }
                    .disabled(agentBusy || sessionID.isEmpty || agentCommand.isEmpty)
                }
                if let localNavigationPlan {
                    Section("معاينة التنقل داخل التطبيق") {
                        Text(localNavigationPlan.description)
                        Button("تنفيذ التنقل") { executeLocalNavigation() }
                        Button("إلغاء", role: .cancel) { localNavigationPlan = nil }
                    }
                }
                if let agentPlan {
                    Section("معاينة قبل التنفيذ") {
                        Text(agentPlan.action == "rename_session" ? "تغيير عنوان المحادثة" : (agentPlan.action == "create_task" ? "إضافة مهمة إلى لوحة العمل" : (agentPlan.action == "set_task_status" ? "تحديث حالة المهمة" : (agentPlan.action == "delete_task" ? "حذف مهمة من لوحة العمل" : "تغيير تثبيت المحادثة"))))
                        ForEach(agentPlan.payload.keys.filter { $0 != "task_id" && !$0.hasPrefix("_") }.sorted(), id: \.self) { key in
                            if let value = agentPlan.payload[key] {
                                LabeledContent(key, value: value.display)
                            }
                        }
                        Button("تأكيد وتنفيذ") {
                            Task { await decideAgent(execute: true) }
                        }
                        .disabled(agentBusy)
                        Button("إلغاء الأمر", role: .cancel) {
                            Task { await decideAgent(execute: false) }
                        }
                        .disabled(agentBusy)
                    }
                }
            }
            .navigationTitle("الوكيل")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("إغلاق") { showAgent = false }
                }
            }
        }
    }

    private func previewAgentCommand() async {
        guard unlocked, scenePhase == .active, !sessionID.isEmpty else { return }
        agentBusy = true
        defer { agentBusy = false }
        agentPlan = nil
        localNavigationPlan = nil
        if let navigation = LocalNavigationAction.parse(agentCommand) {
            localNavigationPlan = navigation
            return
        }
        do {
            agentPlan = try await client.planAgentAction(session: sessionID, command: agentCommand)
        } catch {
            notice = error.localizedDescription
        }
    }

    private func executeLocalNavigation() {
        guard unlocked, scenePhase == .active, let action = localNavigationPlan else { return }
        localNavigationPlan = nil
        pendingNavigation = action
        showAgent = false
    }

    private func performPendingNavigation() {
        guard let action = pendingNavigation else { return }
        pendingNavigation = nil
        guard unlocked, scenePhase == .active else { return }
        switch action {
        case .tasks:
            navigationFilter = "all"
            showTaskBoard = true
            Task { await loadBoardTasks() }
        case .incompleteTasks:
            navigationFilter = "incomplete"
            showTaskBoard = true
            Task { await loadBoardTasks() }
        case .sessions:
            showSessions = true
            Task { await loadSessions() }
        case .memories:
            showMemories = true
            Task { await loadMemories() }
        case .settings:
            showSettings = true
        }
    }

    private func decideAgent(execute: Bool) async {
        guard unlocked, scenePhase == .active, let plan = agentPlan else { return }
        guard plan.session_id == sessionID else {
            agentPlan = nil
            _ = try? await client.decideAgentAction(planID: plan.plan_id, session: plan.session_id, execute: false)
            notice = "تغيرت المحادثة؛ أُلغيت المعاينة القديمة دون تنفيذ"
            return
        }
        agentBusy = true
        defer { agentBusy = false }
        do {
            let result = try await client.decideAgentAction(planID: plan.plan_id, session: sessionID, execute: execute)
            agentPlan = nil
            if result.status == "executed" {
                await loadSessions()
                await loadBoardTasks()
                notice = "تم تنفيذ الأمر بنجاح"
            } else {
                notice = result.status == "expired" ? "انتهت صلاحية الأمر" : "تم إلغاء الأمر"
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    private var taskBoardSheet: some View {
        NavigationStack {
            Form {
                Section("مهمة جديدة") {
                    TextField("اسم المهمة", text: $boardTaskTitle)
                    Button("إضافة") {
                        Task { await addBoardTask() }
                    }
                    .disabled(sessionID.isEmpty || boardTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("مهام المحادثة") {
                    Picker("عرض المهام", selection: $navigationFilter) {
                        Text("الكل").tag("all")
                        Text("غير المنجزة").tag("incomplete")
                        Text("المنجزة").tag("done")
                    }
                    .pickerStyle(.segmented)
                    if sessionID.isEmpty {
                        Text("ابدأ محادثة أولاً").foregroundStyle(.secondary)
                    }
                    ForEach(boardTasks.filter { navigationFilter == "all" || (navigationFilter == "done" ? $0.done : !$0.done) }) { task in
                        HStack {
                            Button {
                                Task { await changeBoardTask(task, done: !task.done) }
                            } label: {
                                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                            }
                            .buttonStyle(.plain)
                            Text(task.title)
                                .strikethrough(task.done)
                            Spacer()
                            Button(role: .destructive) {
                                Task { await deleteBoardTask(task) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("لوحة المهام")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("إغلاق") { showTaskBoard = false }
                }
            }
        }
    }

    private func loadBoardTasks() async {
        guard unlocked, scenePhase == .active, !sessionID.isEmpty else {
            boardTasks = []
            return
        }
        let selected = sessionID
        do {
            let loaded = try await client.boardTasks(session: selected)
            guard unlocked, sessionID == selected, scenePhase == .active else { return }
            boardTasks = loaded
        } catch {
            notice = error.localizedDescription
        }
    }

    private func addBoardTask() async {
        guard unlocked, scenePhase == .active, !sessionID.isEmpty else { return }
        let selected = sessionID
        do {
            try await client.addBoardTask(session: selected, title: boardTaskTitle)
            guard unlocked, sessionID == selected else { return }
            boardTaskTitle = ""
            await loadBoardTasks()
        } catch {
            notice = error.localizedDescription
        }
    }

    private func changeBoardTask(_ task: BoardTask, done: Bool) async {
        guard unlocked, scenePhase == .active, !sessionID.isEmpty else { return }
        let selected = sessionID
        do {
            try await client.updateBoardTask(session: selected, task: task.id, done: done)
            guard unlocked, sessionID == selected else { return }
            await loadBoardTasks()
        } catch {
            notice = error.localizedDescription
        }
    }

    private func deleteBoardTask(_ task: BoardTask) async {
        guard unlocked, scenePhase == .active, !sessionID.isEmpty else { return }
        let selected = sessionID
        do {
            try await client.deleteBoardTask(session: selected, task: task.id)
            guard unlocked, sessionID == selected else { return }
            await loadBoardTasks()
        } catch {
            notice = error.localizedDescription
        }
    }

    private var settings: some View {
        Form {
            Section("الخادم الشخصي") {
                Button("فحص اتصال الخادم وقاعدة البيانات") {
                    Task {
                        do {
                            let result = try await client.readiness()
                            serverStatus = result.status == "ready" ? "الخادم وقاعدة البيانات جاهزان" : "حالة الخادم: \(result.status)"
                        } catch {
                            serverStatus = error.localizedDescription
                        }
                    }
                }
                if !serverStatus.isEmpty {
                    Text(serverStatus).font(.footnote)
                }
                TextField("https://your-private-server.example", text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("مفتاح API", text: $apiKey)
                Button("حفظ الإعدادات") {
                    guard URL(string: serverURL)?.scheme == "https" else {
                        notice = "استخدم رابط HTTPS صالحًا"; return
                    }
                    if !apiKey.isEmpty && !SecretStore.save(apiKey) {
                        notice = "تعذر حفظ المفتاح في Keychain"; return
                    }
                    guard SecretStore.load() != nil else {
                        notice = "أدخل مفتاح API"; return
                    }
                    apiKey = ""
                    showSettings = false
                }
                Button("حذف مفتاح الوصول", role: .destructive) {
                    SecretStore.clear()
                    sessionID = ""
                    insights = nil
                historyCursor = 0
                hasMoreHistory = false
                    messages = []
                }
            }
            Section {
                Text("لا تضع Ollama مباشرة على الإنترنت. استخدم HTTPS عبر بوابة خاصة مع مصادقة.")
                    .font(.footnote)
            }
        }
    }

    private var memorySheet: some View {
        NavigationStack {
            Form {
                Section("إضافة معلومة بإرادتك") {
                    TextField("معلومة تريد تذكرها", text: $newMemory, axis: .vertical)
                        .lineLimit(2...4)
                    Button("حفظ المعلومة") {
                        Task {
                            do {
                                try await client.addMemory(newMemory)
                                newMemory = ""
                                await loadMemories()
                            } catch { notice = error.localizedDescription }
                        }
                    }.disabled(newMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("ذاكرتي") {
                    ForEach(personalMemories) { memory in
                        HStack {
                            Text(memory.content)
                            Spacer()
                            Button(role: .destructive) {
                                Task {
                                    do {
                                        try await client.deleteMemory(memory.id)
                                        await loadMemories()
                                    } catch { notice = error.localizedDescription }
                                }
                            } label: { Image(systemName: "trash") }
                        }
                    }
                }
                Section {
                    Text("تُستخدم المعلومات التي تحفظها فقط عند وجود كلمات مرتبطة بسؤالك، ويمكنك حذفها في أي وقت.")
                        .font(.footnote)
                }
            }
            .navigationTitle("الذاكرة الشخصية")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("إغلاق") { showMemories = false }
                }
            }
        }
    }

    private var sessionsSheet: some View {
        NavigationStack {
            List(recentSessions) { item in
                Button {
                    cancelPendingChat()
                    voice.stopAll()
                    voicePolicy.stopSession()
                    agentPlan = nil
                    localNavigationPlan = nil
                    sessionID = item.id
                    insights = nil
                    messages = []
                    input = ""
                    showSessions = false
                    Task { await loadHistory() }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title.isEmpty ? (item.id == sessionID ? "المحادثة الحالية" : "محادثة محفوظة") : item.title)
                        if item.pinned { Label("مثبتة", systemImage: "pin.fill").font(.caption) }
                        Text("\(item.message_count) رسالة • \(Date(timeIntervalSince1970: TimeInterval(item.created_at)), style: .date)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button {
                        Task {
                            do {
                                try await client.updateSession(item.id, title: item.title, pinned: !item.pinned)
                                await loadSessions()
                            } catch { notice = error.localizedDescription }
                        }
                    } label: {
                        Label(item.pinned ? "إلغاء التثبيت" : "تثبيت", systemImage: "pin")
                    }
                    Button {
                        editedTitle = item.title
                        editingSession = item
                    } label: {
                        Label("تسمية", systemImage: "pencil")
                    }
                }
            }
            .alert("تسمية المحادثة", isPresented: Binding(
                get: { editingSession != nil },
                set: { if !$0 { editingSession = nil } }
            )) {
                TextField("عنوان المحادثة", text: $editedTitle)
                Button("حفظ") {
                    guard let item = editingSession else { return }
                    editingSession = nil
                    Task {
                        do {
                            try await client.updateSession(item.id, title: String(editedTitle.prefix(80)), pinned: item.pinned)
                            await loadSessions()
                        } catch { notice = error.localizedDescription }
                    }
                }
                Button("إلغاء", role: .cancel) { editingSession = nil }
            }
            .safeAreaInset(edge: .top) {
                HStack {
                    TextField("ابحث في نص المحادثات", text: $sessionSearch)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                    Button("بحث") {
                        Task { await searchConversations() }
                    }
                    .disabled(sessionSearch.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                    Button("الكل") {
                        sessionSearch = ""
                        Task { await loadSessions() }
                    }
                }
                .padding()
            }
            .navigationTitle("المحادثات السابقة")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("إغلاق") { showSessions = false }
                }
            }
        }
    }

    private func searchConversations() async {
        let query = sessionSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return }
        do {
            let result = try await client.searchSessions(query)
            guard sessionSearch.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            recentSessions = result
        } catch { notice = error.localizedDescription }
    }

    private func loadSessions() async {
        do { recentSessions = try await client.sessions() }
        catch { notice = error.localizedDescription }
    }

    private func loadMemories() async {
        do { personalMemories = try await client.memories() }
        catch { notice = error.localizedDescription }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            Picker("المزوّد", selection: $provider) {
                Text("Ollama").tag("ollama")
                Text("Langflow").tag("langflow")
            }.pickerStyle(.segmented).padding()
            if hasMoreHistory {
                Button(loadingHistory ? "جارٍ تحميل الرسائل…" : "تحميل المزيد من السجل") {
                    Task { await loadNextHistoryPage() }
                }
                .disabled(loadingHistory)
                .padding(.horizontal)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            HStack {
                                if message.role == "user" { Spacer(minLength: 35) }
                                Text(message.content)
                                    .padding(12)
                                    .background(message.role == "user" ? Color.blue.opacity(0.18) : Color.gray.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                    .textSelection(.enabled)
                                if message.role != "user" { Spacer(minLength: 35) }
                            }.id(message.id)
                        }
                    }.padding()
                }.onChange(of: messages.count) { _, _ in
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            if let insights, !insights.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("اقتراحات ذكية للمتابعة", systemImage: "sparkles")
                            .font(.footnote.bold())
                        Spacer()
                        Text("\(insights.message_count) رسالة")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(insights.suggestions, id: \.self) { suggestion in
                                Button(suggestion) { input = suggestion }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                            }
                        }
                    }
                    .environment(\.layoutDirection, .rightToLeft)
                    Text("اقتراحات محلية بالقواعد، لا ترسل بيانات لخدمة إضافية.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }
            HStack(spacing: 10) {
                TextField("اكتب رسالتك", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                Button {
                    startSend()
                } label: {
                    if busy { ProgressView() } else { Image(systemName: "paperplane.fill") }
                }
                .disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)
            }.padding()
            HStack(spacing: 14) {
                Button {
                    Task { await toggleVoice() }
                } label: {
                    Label(voice.recording ? "إنهاء التسجيل وإرسال" : "التحدث بالعربية",
                          systemImage: voice.recording ? "stop.circle.fill" : "mic.fill")
                }
                .buttonStyle(.borderedProminent)
                
                if !reviewVoiceTranscript && voice.speaking {
                    Text("يمكنك إيقاف الصوت دون إلغاء المهمة")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if busy {
                    Button("إلغاء الإجابة") { cancelPendingChat() }
                        .buttonStyle(.bordered)
                }
                if voice.speaking {
                    Button("إيقاف النطق") { voice.stopSpeech() }
                        .buttonStyle(.bordered)
                }
            }
            .padding(.bottom, 8)
            Toggle("مراجعة الكلام قبل الإرسال", isOn: $reviewVoiceTranscript)
                .font(.footnote)
                .padding(.horizontal)
            if voice.recording {
                Text(voice.transcript.isEmpty ? "أستمع إليك حتى تنهي كلامك..." : voice.transcript)
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            }
            if let error = voice.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal)
            }
            HStack {
                if !sessionID.isEmpty {
                HStack {
                    Button("تجهيز تصدير المحادثة") {
                        Task { await prepareExport() }
                    }
                    if let exportedConversationURL {
                        ShareLink(item: exportedConversationURL) {
                            Label("مشاركة JSON", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .font(.footnote)
                .padding(.bottom, 8)
            }
            Button("محادثة جديدة") {
                    cancelPendingChat()
                    voice.stopAll()
                    voicePolicy.stopSession()
                    agentPlan = nil
                    localNavigationPlan = nil
                    retryRequestID = nil
                    retryFingerprint = ""
                    sessionID = ""
                    insights = nil
                historyCursor = 0
                hasMoreHistory = false
                    messages = []
                }
                Button("حذف المحادثة من الخادم", role: .destructive) {
                    confirmConversationDeletion = true
                }
                .disabled(sessionID.isEmpty)
            }
            .font(.footnote)
            .padding(.bottom, 8)
        }
    }

    private func eraseCurrentConversation() async {
        guard unlocked, scenePhase == .active, !sessionID.isEmpty else { return }
        cancelPendingChat()
        clearExportFile()
        voice.stopAll()
        voicePolicy.stopSession()
        let deleting = sessionID
        do {
            try await client.deleteSession(deleting)
            guard sessionID == deleting else { return }
            sessionID = ""
            insights = nil
            agentPlan = nil
            retryRequestID = nil
            retryFingerprint = ""
            historyCursor = 0
            hasMoreHistory = false
            messages = []
            input = ""
        } catch {
            notice = error.localizedDescription
        }
    }

    private func loadHistory() async {
        let selectedSession = sessionID
        guard !selectedSession.isEmpty, unlocked else { return }
        historyCursor = 0
        hasMoreHistory = false
        messages = []
        await loadNextHistoryPage(for: selectedSession)
    }

    private func loadNextHistoryPage(for selectedSession: String? = nil) async {
        guard !loadingHistory, unlocked else { return }
        let selected = selectedSession ?? sessionID
        guard !selected.isEmpty, selected == sessionID else { return }
        loadingHistory = true
        defer { loadingHistory = false }
        do {
            let cursor = historyCursor
            let page = try await client.messagePage(session: selected, afterID: cursor)
            guard unlocked, sessionID == selected, historyCursor == cursor, scenePhase == .active else { return }
            messages.append(contentsOf: page.messages.map {
                ChatMessage(role: $0.role, content: $0.content)
            })
            historyCursor = page.next_after_id
            hasMoreHistory = page.has_more
            await refreshInsights(for: selected)
        } catch is CancellationError {
            return
        } catch {
            guard unlocked, sessionID == selected else { return }
            notice = error.localizedDescription
        }
    }

    private func toggleVoice() async {
        if voice.recording {
            voice.stopRecording(submit: true)
            voicePolicy.releaseToTalk()
        } else {
            cancelPendingChat()
            voice.stopSpeech()
            voiceSessionID = sessionID
            voicePolicy.configureConnected(true)
            let permitted = await voice.authorize()
            voicePolicy.updateMicrophonePermission(permitted)
            guard permitted else { return }
            voicePolicy.startSession()
            voicePolicy.pressToTalk()
            if await voice.start(), let token = voicePolicy.state.sessionID {
                voicePolicy.receiveProviderEvent(.microphoneDidStart, sessionID: token)
            } else {
                voicePolicy.stopSession()
            }
        }
    }

    private func clearExportFile() {
        if let exportedConversationURL {
            try? FileManager.default.removeItem(at: exportedConversationURL)
        }
        exportedConversationURL = nil
    }

    private func prepareExport() async {
        guard unlocked, !sessionID.isEmpty else { return }
        do {
            let exporting = sessionID
            let data = try await client.exportSession(exporting)
            guard unlocked, sessionID == exporting, scenePhase == .active else { return }
            clearExportFile()
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("conversation-\(UUID().uuidString).json")
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            exportedConversationURL = file
        } catch {
            notice = error.localizedDescription
        }
    }

    private func cancelPendingChat() {
        requestGeneration = UUID()
        chatTask?.cancel()
        chatTask = nil
        busy = false
        voice.stopSpeech()
    }

    private func refreshInsights(for selected: String) async {
        guard unlocked, scenePhase == .active, sessionID == selected else { return }
        do {
            let result = try await client.insights(session: selected)
            guard unlocked, scenePhase == .active, sessionID == selected else { return }
            insights = result
        } catch {
            // Suggestions are optional; chat remains usable without them.
            insights = nil
        }
    }

    private func startSend(speakAnswer: Bool = false) {
        guard !busy else { return }
        let shouldSpeak = speakAnswer || voiceReplyPending
        voiceReplyPending = false
        let generation = UUID()
        requestGeneration = generation
        chatTask = Task { await send(speakAnswer: shouldSpeak, generation: generation) }
    }

    private func send(speakAnswer: Bool, generation: UUID) async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        busy = true
        defer {
            if requestGeneration == generation {
                busy = false
                chatTask = nil
            }
        }
        do {
            let currentSession: String
            if sessionID.isEmpty {
                currentSession = try await client.newSession()
                try Task.checkCancellation()
                guard requestGeneration == generation, unlocked else { return }
                sessionID = currentSession
            } else {
                currentSession = sessionID
            }
            let selectedProvider = provider
            let fingerprint = "\(currentSession)\u{1F}\(selectedProvider)\u{1F}\(text)"
            let requestID: String
            if retryFingerprint == fingerprint, let savedID = retryRequestID {
                requestID = savedID
            } else {
                requestID = UUID().uuidString
            }
            retryFingerprint = fingerprint
            retryRequestID = requestID
            let answer = try await client.send(session: currentSession, message: text, provider: selectedProvider, requestID: requestID)
            try Task.checkCancellation()
            guard requestGeneration == generation, unlocked, scenePhase == .active else { return }
            messages.append(ChatMessage(role: "user", content: text))
            messages.append(ChatMessage(role: "assistant", content: answer))
            input = ""
            retryRequestID = nil
            retryFingerprint = ""
            if speakAnswer { voice.speak(answer) }
            await refreshInsights(for: currentSession)
        } catch is CancellationError {
            return
        } catch {
            guard requestGeneration == generation else { return }
            notice = error.localizedDescription
        }
    }
}
