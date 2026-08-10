import SwiftUI


struct SourceConnectorView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var browser = BrowserSession()

    @State private var address = ""
    @State private var sourceName = ""
    @State private var courseHint = ""
    @State private var loginMode: LoginMode = .interactive
    @State private var autoFill = false
    @State private var showCredentialSheet = false
    @State private var username = ""
    @State private var password = ""
    @State private var candidates: [AssignmentCandidate] = []
    @State private var capturedPage: CapturedPage?
    @State private var showReview = false
    @State private var notice: String?
    @State private var lastAutoFilledURL = ""

    private let credentials = KeychainCredentialStore()

    var body: some View {
        VStack(spacing: 0) {
            sourceHeader
            Divider()
            browserToolbar
            Divider()
            BrowserWebView(session: browser)
                .background(Color(nsColor: .textBackgroundColor))
            Divider()
            actionBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showCredentialSheet) {
            credentialSheet
        }
        .sheet(isPresented: $showReview) {
            CandidateReviewView(
                candidates: candidates,
                sourceName: sourceName,
                courseHint: courseHint,
                sourceURL: capturedPage?.url ?? browser.currentURL
            )
            .environmentObject(model)
        }
        .alert(
            "Source Connector",
            isPresented: Binding(
                get: { notice != nil },
                set: { if !$0 { notice = nil } }
            )
        ) {
            Button("OK") { notice = nil }
        } message: {
            Text(notice ?? "")
        }
        .onChange(of: browser.currentURL) { _, newValue in
            guard autoFill,
                  loginMode == .savedCredential,
                  newValue != lastAutoFilledURL else {
                return
            }
            lastAutoFilledURL = newValue
            Task {
                try? await fillSavedCredential(showSuccess: false)
            }
        }
    }

    private var sourceHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Secure Source Connector")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("Sign in first, then let the local model extract assignments.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("Local only", systemImage: "lock.shield.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline.weight(.semibold))
            }

            HStack {
                TextField("Source name · e.g. Canvas", text: $sourceName)
                TextField("Course hint · optional", text: $courseHint)
                Picker("Login", selection: $loginMode) {
                    ForEach(LoginMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
            }
            .textFieldStyle(.roundedBorder)

            HStack(spacing: 7) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.blue)
                Text(loginMode.help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if loginMode == .savedCredential {
                    Toggle("Auto-fill on exact origin", isOn: $autoFill)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
        .padding(20)
    }

    private var browserToolbar: some View {
        HStack(spacing: 8) {
            Button {
                browser.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!browser.webView.canGoBack)

            Button {
                browser.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!browser.webView.canGoForward)

            Button {
                browser.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }

            HStack(spacing: 7) {
                Image(
                    systemName: browser.isSecurePage
                        ? "lock.fill"
                        : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(browser.isSecurePage ? .green : .orange)

                TextField("https://your-school.example", text: $address)
                    .textFieldStyle(.plain)
                    .onSubmit { openAddress() }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))

            Button("Open") {
                openAddress()
            }
            .buttonStyle(.borderedProminent)

            if loginMode == .savedCredential {
                Menu {
                    Button("Save or replace credential") {
                        showCredentialSheet = true
                    }
                    Button("Fill on this page") {
                        Task { try? await fillSavedCredential(showSuccess: true) }
                    }
                    Divider()
                    Button("Remove saved credential", role: .destructive) {
                        removeSavedCredential()
                    }
                } label: {
                    Label("Credential", systemImage: "key.fill")
                }
            }

            if browser.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var actionBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(browser.pageTitle.isEmpty ? "No page loaded" : browser.pageTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(browser.currentURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.isParsing {
                ProgressView()
                    .controlSize(.small)
                Text("Local AI is reading this page…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                scanCurrentPage()
            } label: {
                Label("Scan Current Page", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .disabled(browser.currentURL.isEmpty || model.isParsing)
        }
        .padding(14)
    }

    private var credentialSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "key.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text("Save credential")
                        .font(.title2.bold())
                    Text(browser.currentHost ?? "Open the login website first")
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Username or email", text: $username)
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            Label(
                "Stored in macOS Keychain for this exact HTTPS origin. It is never sent to the local model.",
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") {
                    password = ""
                    showCredentialSheet = false
                }
                Spacer()
                Button("Save in Keychain") {
                    saveCredential()
                }
                .buttonStyle(.borderedProminent)
                .disabled(username.isEmpty || password.isEmpty || !browser.isSecurePage)
            }
        }
        .padding(24)
        .frame(width: 430)
    }

    private func openAddress() {
        do {
            try browser.load(address)
        } catch {
            notice = error.localizedDescription
        }
    }

    private func saveCredential() {
        guard let url = browser.webView.url else {
            notice = BrowserSessionError.invalidURL.localizedDescription
            return
        }
        do {
            try credentials.save(url: url, username: username, password: password)
            password = ""
            showCredentialSheet = false
            notice = "Credential saved in macOS Keychain."
        } catch {
            notice = error.localizedDescription
        }
    }

    private func fillSavedCredential(showSuccess: Bool) async throws {
        guard let url = browser.webView.url else {
            throw BrowserSessionError.invalidURL
        }
        do {
            guard let credential = try credentials.retrieve(url: url) else {
                if showSuccess {
                    notice = "No credential is saved for \(url.host ?? "this host")."
                }
                return
            }
            try await browser.fill(credential)
            if showSuccess {
                notice = "Username and password were filled. Review the page before signing in."
            }
        } catch {
            if showSuccess {
                notice = error.localizedDescription
            }
            throw error
        }
    }

    private func removeSavedCredential() {
        guard let url = browser.webView.url else { return }
        do {
            try credentials.remove(url: url)
            notice = "Saved credential removed. Browser session data was not deleted."
        } catch {
            notice = error.localizedDescription
        }
    }

    private func scanCurrentPage() {
        Task {
            do {
                let page = try await browser.capturePage()
                capturedPage = page
                candidates = try await model.parse(
                    page: page,
                    sourceName: sourceName.isEmpty ? (browser.currentHost ?? "Web") : sourceName,
                    courseHint: courseHint
                )
                if candidates.isEmpty {
                    notice = "The local model did not find assignments on this page."
                } else {
                    showReview = true
                }
            } catch {
                notice = error.localizedDescription
            }
        }
    }
}


struct CandidateReviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State var candidates: [AssignmentCandidate]
    let sourceName: String
    let courseHint: String
    let sourceURL: String

    var body: some View {
        NavigationStack {
            List {
                ForEach($candidates) { $candidate in
                    VStack(alignment: .leading, spacing: 9) {
                        TextField("Assignment title", text: $candidate.title)
                            .font(.headline)
                        TextField(
                            "Course",
                            text: Binding(
                                get: { candidate.courseName ?? "" },
                                set: { candidate.courseName = $0.isEmpty ? nil : $0 }
                            )
                        )
                        HStack {
                            TextField(
                                "YYYY-MM-DD",
                                text: Binding(
                                    get: { candidate.dueDate ?? "" },
                                    set: { candidate.dueDate = $0.isEmpty ? nil : $0 }
                                )
                            )
                            TextField(
                                "HH:MM",
                                text: Binding(
                                    get: { candidate.dueTime ?? "" },
                                    set: { candidate.dueTime = $0.isEmpty ? nil : $0 }
                                )
                            )
                        }
                        .textFieldStyle(.roundedBorder)

                        if let description = candidate.description, !description.isEmpty {
                            Text(description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text(candidate.confidence.capitalized)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.blue.opacity(0.12), in: Capsule())
                            if !candidate.warnings.isEmpty {
                                Label(
                                    candidate.warnings.joined(separator: " · "),
                                    systemImage: "exclamationmark.triangle"
                                )
                                .font(.caption)
                                .foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onDelete { candidates.remove(atOffsets: $0) }
            }
            .navigationTitle("Review \(candidates.count) Assignments")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        let valid = candidates.filter {
                            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        }
                        model.importCandidates(
                            valid,
                            sourceName: sourceName,
                            courseHint: courseHint,
                            sourceURL: sourceURL
                        )
                        dismiss()
                        model.selection = .all
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(candidates.isEmpty)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 520)
    }
}
