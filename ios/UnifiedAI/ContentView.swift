import SwiftUI
import UIKit

struct ContentView: View {
    @AppStorage("serverURL") private var serverURL = ""
    @AppStorage("sessionID") private var sessionID = ""
    @State private var apiKey = ""
    @State private var input = ""
    @State private var provider = "ollama"
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
    @State private var notice = ""
    @State private var showSettings = false
    @State private var showMemories = false
    @State private var showSessions = false
    @State private var confirmConversationDeletion = false
    @State private var sessionSearch = ""
    @State private var exportedConversationURL: URL?
    @State private var recentSessions: [ConversationSummary] = []
    @State private var personalMemories: [PersonalMemory] = []
    @State private var newMemory = ""
    @StateObject private var voice = NativeVoiceService()
    @StateObject private var voicePolicy = VoicePolicyController()
    @Environment(\.scenePhase) private var scenePhase

    private var client: APIClient {
        APIClient(server: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
                  key: SecretStore.load() ?? "")
    }

    var body: some View {
        NavigationStack {
            Group {
                if !unlocked {
                    VStack(spacing: 18) {
                        Image(systemName: "lock.shield").font(.system(size: 55))
                        Text("مساعدك الشخصي").font(.title2.bold())
                        Button("فتح باستخدام Face ID أو رمز الجهاز") {
                            Task { unlocked = await DeviceLock.authenticate() }
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
                    guard unlocked, !busy, scenePhase == .active else { return }
                    input = text
                    startSend(speakAnswer: true)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    cancelPendingChat()
                    voice.stopAll()
                    voicePolicy.appBecameInactive()
                    clearExportFile()
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
            .sheet(isPresented: $showMemories) { memorySheet }
            .sheet(isPresented: $showSessions) { sessionsSheet }
            .toolbar {
                if unlocked {
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
        .environment(\\.layoutDirection, .rightToLeft)
        .task {
            unlocked = await DeviceLock.authenticate()
            if unlocked && !sessionID.isEmpty && SecretStore.load() != nil {
                await loadHistory()
            }
        }
    }

    private var settings: some View {
        Form {
            Section("الخادم الشخصي") {
                Button("فحص اتصال الخادم وقاعدة البيانات") {
                    Task {
                        do {
                            let result = try await client.readiness()
                            serverStatus = result.status == "ready" ? "الخادم وقاعدة البيانات جاهزان" : "حالة الخادم: \\(result.status)"
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
                    sessionID = item.id
                    insights = nil
                    messages = []
                    input = ""
                    showSessions = false
                    Task { await loadHistory() }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.id == sessionID ? "المحادثة الحالية" : "محادثة محفوظة")
                        Text("\(item.message_count) رسالة • \(Date(timeIntervalSince1970: TimeInterval(item.created_at)), style: .date)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
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
                        Text("\\(insights.message_count) رسالة")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(insights.suggestions, id: \\.self) { suggestion in
                                Button(suggestion) { input = suggestion }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                            }
                        }
                    }
                    .environment(\\.layoutDirection, .rightToLeft)
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
            if voice.recording {
                Text(voice.transcript.isEmpty ? "أستمع إليك..." : voice.transcript)
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
        let generation = UUID()
        requestGeneration = generation
        chatTask = Task { await send(speakAnswer: speakAnswer, generation: generation) }
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
            let answer = try await client.send(session: currentSession, message: text, provider: provider)
            try Task.checkCancellation()
            guard requestGeneration == generation, unlocked, scenePhase == .active else { return }
            messages.append(ChatMessage(role: "user", content: text))
            messages.append(ChatMessage(role: "assistant", content: answer))
            input = ""
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
