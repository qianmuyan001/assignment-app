import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers


/// Posted after a restore has replaced the database and attachments on disk.
///
/// The app root listens for it and rebuilds its data stack, so the restored
/// data becomes visible without asking the user to relaunch by hand.
extension Notification.Name {
    static let assignmentDataDidRestore = Notification.Name("assignmentApp.dataDidRestore")
}


// MARK: - Export document

/// A `.assignmentbackup` package handed to the system save panel.
///
/// The backup format is a directory, so the document is backed by a directory
/// `FileWrapper`. The wrapper is built at write time and read lazily, which
/// keeps a backup with large attachments from being loaded into memory all at
/// once.
struct BackupPackageDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.folder] }

    let packageURL: URL

    init(packageURL: URL) {
        self.packageURL = packageURL
    }

    init(configuration: ReadConfiguration) throws {
        // The app never opens a package through the document system; this
        // exists so the type round-trips if the system ever hands one back.
        packageURL = configuration.file.filename
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: packageURL, options: [])
    }
}


// MARK: - Row model

/// A package found in the app's `Backups` folder, described from its manifest.
struct BackupPackageItem: Identifiable, Equatable {
    let url: URL
    let name: String
    let createdAtUTC: String
    let schemaVersion: Int32
    let databaseByteSize: Int64
    let attachmentCount: Int
    let packageByteSize: Int64
    let createdByVersion: String

    var id: URL { url }

    /// `nil` when the manifest timestamp cannot be parsed; the raw string is
    /// then shown instead of a formatted date.
    var createdDate: Date? {
        BackupPackageItem.isoFormatter.date(from: createdAtUTC)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}


/// Whether a stored package still passes its own manifest checks.
enum BackupPackageIntegrity: Equatable {
    case unknown
    case verifying
    case verified
    case failed(String)
}


// MARK: - Model

/// Owns every file operation behind the Data & Backup page.
///
/// The model talks to `BackupCoordinator` only. It never touches the live
/// database through the repositories, and it never reads the real user
/// database for tests — the test suite constructs the coordinator against a
/// temporary directory.
@MainActor
final class BackupCenterModel: ObservableObject {
    @Published private(set) var items: [BackupPackageItem] = []
    @Published private(set) var integrity: [URL: BackupPackageIntegrity] = [:]
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var restoreReview: BackupPreflight?
    @Published var restoreOutcome: BackupRestoreOutcome?
    @Published var exportDocument: BackupPackageDocument?
    @Published var isExporting = false
    @Published var isImporting = false

    let coordinator: BackupCoordinator?

    private let fileManager = FileManager.default

    init(databasePath: String) {
        // An empty or non-existent path means the local database never opened,
        // in which case there is nothing to back up or restore into. The page
        // still renders so the reason can be explained in place.
        let url = URL(fileURLWithPath: databasePath, isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else {
            coordinator = nil
            return
        }
        coordinator = BackupCoordinator(databaseURL: url)
    }

    // MARK: Listing

    func refresh() {
        guard let coordinator else { return }
        coordinator.pruneTemporaryDirectories()

        let root = coordinator.backupsRoot
        let children = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        items = children
            .filter { $0.pathExtension == BackupLayout.packageExtension }
            .compactMap { BackupPackageItem.describe($0, fileManager: fileManager) }
            .sorted { lhs, rhs in
                // Newest first; the name carries a UTC timestamp so plain
                // string ordering already matches chronological order.
                lhs.name > rhs.name
            }

        // Drop verification results for packages that no longer exist.
        let known = Set(items.map(\.url))
        integrity = integrity.filter { known.contains($0.key) }
    }

    // MARK: Create

    func createBackup() {
        guard let coordinator else {
            errorMessage = L10n.tr("The local database is unavailable, so no backup operation can run.")
            return
        }
        run {
            let package = try coordinator.createBackup(in: coordinator.backupsRoot)
            statusMessage = L10n.tr(
                "Backup “%@” was created.",
                package.lastPathComponent
            )
        }
    }

    // MARK: Verify

    func verify(_ item: BackupPackageItem) {
        guard let coordinator else { return }
        integrity[item.url] = .verifying
        do {
            _ = try coordinator.preflight(package: item.url)
            integrity[item.url] = .verified
            statusMessage = L10n.tr(
                "“%@” passed every check in the manifest.",
                item.name
            )
        } catch {
            integrity[item.url] = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func integrity(of item: BackupPackageItem) -> BackupPackageIntegrity {
        integrity[item.url] ?? .unknown
    }

    // MARK: Export

    func beginExport(_ item: BackupPackageItem) {
        exportDocument = BackupPackageDocument(packageURL: item.url)
        isExporting = true
    }

    func finishExport(result: Result<URL, Error>) {
        isExporting = false
        exportDocument = nil
        switch result {
        case .success(let url):
            statusMessage = L10n.tr("Backup exported to “%@”.", url.lastPathComponent)
        case .failure(let error):
            // A user cancellation is not an error worth reporting.
            errorMessage = error.localizedDescription
        }
    }

    /// Copies a package inside the app's own `Backups` folder.
    ///
    /// Unlike the system save panel this path is fully under the app's control,
    /// and `BackupCoordinator.export` guarantees it never replaces an existing
    /// item of the same name.
    func saveCopyInBackups(_ item: BackupPackageItem) {
        guard let coordinator else { return }
        run {
            let copy = try coordinator.export(package: item.url, to: coordinator.backupsRoot)
            statusMessage = L10n.tr("A copy was saved as “%@”.", copy.lastPathComponent)
        }
    }

    // MARK: Import

    /// Copies a user-chosen package into the app before inspecting it.
    ///
    /// The copy happens inside the security scope granted by the picker; the
    /// user's own file is then never the thing being restored from.
    func importPackage(from source: URL) {
        guard let coordinator else {
            errorMessage = L10n.tr("The local database is unavailable, so no backup operation can run.")
            return
        }
        let secured = source.startAccessingSecurityScopedResource()
        defer { if secured { source.stopAccessingSecurityScopedResource() } }

        run {
            let staged = try coordinator.stageExternalPackage(source)
            let preflight = try coordinator.preflight(package: staged)
            statusMessage = L10n.tr(
                "“%@” was imported and passed its checks. Review it below before restoring.",
                staged.lastPathComponent
            )
            restoreReview = preflight
        }
    }

    // MARK: Restore

    func requestRestore(_ item: BackupPackageItem) {
        guard let coordinator else { return }
        do {
            restoreReview = try coordinator.preflight(package: item.url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Replaces the live data with the reviewed package.
    ///
    /// `canReopenDatabase` is `false` because the running app still holds open
    /// SQLite connections to the file being replaced. On POSIX those handles
    /// keep the previous inode alive, so the restored files are safe — but the
    /// app keeps showing the old data until its data stack is rebuilt, which
    /// `assignmentDataDidRestore` triggers.
    func confirmRestore() {
        guard let coordinator, let review = restoreReview else { return }
        run {
            let outcome = try coordinator.restore(
                package: review.packageURL,
                canReopenDatabase: false
            )
            restoreReview = nil
            restoreOutcome = outcome
            statusMessage = nil
            NotificationCenter.default.post(name: .assignmentDataDidRestore, object: nil)
        }
    }

    func dismissRestoreReview() {
        restoreReview = nil
    }

    func dismissRestoreOutcome() {
        restoreOutcome = nil
    }

    // MARK: Support

    var isDatabaseAvailable: Bool { coordinator != nil }

    /// Runs a throwing operation with shared busy, error and refresh handling.
    ///
    /// A failure here leaves the live data untouched by construction: the
    /// coordinator stages and verifies everything in a temporary directory and
    /// only swaps at the end, so an error thrown before that point cannot have
    /// modified the database or the attachments.
    private func run(_ operation: () throws -> Void) {
        isWorking = true
        errorMessage = nil
        defer {
            isWorking = false
            refresh()
        }
        do {
            try operation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}


extension BackupPackageItem {
    /// Reads the manifest of one package.
    ///
    /// Packages without a readable manifest are skipped rather than shown with
    /// blank values — an unreadable manifest means the package is not a backup
    /// this build can reason about.
    static func describe(_ url: URL, fileManager: FileManager) -> BackupPackageItem? {
        let manifestURL = BackupLayout.manifestURL(in: url)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(BackupManifest.self, from: data) else {
            return nil
        }
        return BackupPackageItem(
            url: url,
            name: url.lastPathComponent,
            createdAtUTC: manifest.createdAtUTC,
            schemaVersion: manifest.schemaVersion,
            databaseByteSize: manifest.databaseByteSize,
            attachmentCount: manifest.attachmentCount,
            packageByteSize: Self.packageSize(of: url, fileManager: fileManager),
            createdByVersion: "\(manifest.appVersion) (\(manifest.buildNumber))"
        )
    }

    /// Total bytes of every regular file inside the package.
    private static func packageSize(of url: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }
}


// MARK: - Page

/// The "Data & Backup" page: create, verify, export, import and restore.
struct BackupCenterView: View {
    let databaseLocation: String
    let onReload: () -> Void

    @StateObject private var model: BackupCenterModel

    init(databaseLocation: String, onReload: @escaping () -> Void) {
        self.databaseLocation = databaseLocation
        self.onReload = onReload
        _model = StateObject(wrappedValue: BackupCenterModel(databasePath: databaseLocation))
    }

    var body: some View {
        Form {
            explanation
            createSection
            listSection
            importSection
            locationSection
        }
        .formStyle(.grouped)
        .navigationTitle("Data & Backup")
        .overlay(alignment: .center) {
            if model.isWorking {
                ProgressView()
                    .controlSize(.large)
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("backup-working")
            }
        }
        .task { model.refresh() }
        .safeAreaInset(edge: .bottom) {
            statusBar
        }
        .fileExporter(
            isPresented: $model.isExporting,
            document: model.exportDocument,
            contentType: .folder,
            defaultFilename: model.exportDocument?.packageURL.lastPathComponent ?? "Backup"
        ) { result in
            model.finishExport(result: result)
        }
        .fileImporter(
            isPresented: $model.isImporting,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                model.importPackage(from: url)
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $model.restoreReview) { review in
            BackupRestoreReviewSheet(preflight: review) {
                model.dismissRestoreReview()
            } onRestore: {
                model.confirmRestore()
            }
        }
        .alert(
            L10n.tr("Restore Finished"),
            isPresented: Binding(
                get: { model.restoreOutcome != nil },
                set: { if !$0 { model.dismissRestoreOutcome() } }
            )
        ) {
            Button("OK") {
                model.dismissRestoreOutcome()
                onReload()
            }
        } message: {
            Text(restoreOutcomeMessage)
        }
        .alert(
            L10n.tr("Backup Problem"),
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: Sections

    private var explanation: some View {
        Section {
            Text("A backup is a folder that holds the whole database and every attachment. It is written by this device and can be restored only by this app.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var createSection: some View {
        Section("Create") {
            Button {
                model.createBackup()
            } label: {
                Label("Create Backup", systemImage: "plus.circle.fill")
            }
            .disabled(!model.isDatabaseAvailable || model.isWorking)
            .accessibilityIdentifier("backup-create")

            if !model.isDatabaseAvailable {
                Text("The local database is unavailable, so no backup operation can run.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var listSection: some View {
        Section("Backups on This Device") {
            if model.items.isEmpty {
                Text("No backups yet. Create one to capture the database and every attachment.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("backup-empty")
            } else {
                ForEach(model.items) { item in
                    BackupPackageRow(
                        item: item,
                        integrity: model.integrity(of: item),
                        isWorking: model.isWorking,
                        onVerify: { model.verify(item) },
                        onExport: { model.beginExport(item) },
                        onSaveCopy: { model.saveCopyInBackups(item) },
                        onRestore: { model.requestRestore(item) }
                    )
                }
            }
        }
    }

    private var importSection: some View {
        Section("Import") {
            Button {
                model.isImporting = true
            } label: {
                Label("Import a Backup…", systemImage: "square.and.arrow.down")
            }
            .disabled(!model.isDatabaseAvailable || model.isWorking)
            .accessibilityIdentifier("backup-import")

            Text("The package is copied into the app and checked before anything is replaced. Your current data is backed up automatically first.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var locationSection: some View {
        Section("Location") {
            LabeledContent("Database") {
                Text(databaseLocation)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Status

    private var statusBar: some View {
        VStack {
            if let status = model.statusMessage {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
                    .accessibilityIdentifier("backup-status")
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.statusMessage)
    }

    private var restoreOutcomeMessage: String {
        guard let outcome = model.restoreOutcome else { return "" }
        let summary = outcome.summary
        let counts = L10n.tr(
            "%1$lld tasks, %2$lld courses, %3$lld exams, %4$lld attachments.",
            summary.taskCount,
            summary.courseCount,
            summary.examCount,
            summary.attachmentCount
        )
        let safety = L10n.tr(
            "The previous data was saved to “%@”.",
            outcome.safetyBackupURL.lastPathComponent
        )
        let restart = outcome.requiresRestart
            ? L10n.tr("The app has reopened the restored database.")
            : L10n.tr("The restored data is already loaded.")
        return [counts, safety, restart].joined(separator: "\n\n")
    }
}


// MARK: - Row

private struct BackupPackageRow: View {
    let item: BackupPackageItem
    let integrity: BackupPackageIntegrity
    let isWorking: Bool
    let onVerify: () -> Void
    let onExport: () -> Void
    let onSaveCopy: () -> Void
    let onRestore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.name)
                .font(.headline)
                .textSelection(.enabled)

            LabeledContent("Created") {
                Text(createdText)
            }
            LabeledContent("Schema") {
                Text("v\(item.schemaVersion)")
            }
            LabeledContent("Size") {
                Text(Int64(item.packageByteSize).formatted(.byteCount(style: .file)))
            }
            LabeledContent("Attachments") {
                Text("\(item.attachmentCount)")
            }
            LabeledContent("Created by") {
                Text(item.createdByVersion)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Integrity") {
                integrityLabel
            }

            HStack(spacing: 12) {
                Button("Verify", systemImage: "checkmark.shield", action: onVerify)
                Button("Export…", systemImage: "square.and.arrow.up", action: onExport)
                Button("Restore…", systemImage: "arrow.uturn.left", action: onRestore)
                    .buttonStyle(.borderedProminent)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isWorking)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityIdentifier("backup-item")
    }

    private var createdText: String {
        guard let date = item.createdDate else { return item.createdAtUTC }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var integrityLabel: some View {
        switch integrity {
        case .unknown:
            return Text("Not checked").foregroundStyle(.secondary)
        case .verifying:
            return Text("Checking…").foregroundStyle(.secondary)
        case .verified:
            return Text("Verified").foregroundStyle(.green)
        case .failed(let detail):
            return Text(detail).foregroundStyle(.red)
        }
    }

    private var accessibilitySummary: String {
        let state: String
        switch integrity {
        case .unknown: state = L10n.tr("Not checked")
        case .verifying: state = L10n.tr("Checking…")
        case .verified: state = L10n.tr("Verified")
        case .failed(let detail): state = detail
        }
        return L10n.tr(
            "%1$@, created %2$@, schema %3$lld, %4$lld attachments, integrity %5$@",
            item.name,
            createdText,
            item.schemaVersion,
            item.attachmentCount,
            state
        )
    }
}


// MARK: - Restore review

/// Lets a preflight result drive the review sheet without giving the model
/// type a second responsibility.
extension BackupPreflight: Identifiable {
    var id: URL { packageURL }
}

/// Shows what a package contains and what restoring it will do, and makes the
/// user confirm before anything is replaced.
struct BackupRestoreReviewSheet: View {
    let preflight: BackupPreflight
    let onCancel: () -> Void
    let onRestore: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Package") {
                    LabeledContent("File") {
                        Text(preflight.packageURL.lastPathComponent)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Created") {
                        Text(preflight.manifest.createdAtUTC)
                    }
                    LabeledContent("Schema") {
                        Text("v\(preflight.manifest.schemaVersion)")
                    }
                    LabeledContent("Database") {
                        Text(Int64(preflight.manifest.databaseByteSize)
                            .formatted(.byteCount(style: .file)))
                    }
                    LabeledContent("Created by") {
                        Text("\(preflight.manifest.appVersion) (\(preflight.manifest.buildNumber))")
                    }
                }

                Section("To Be Restored") {
                    LabeledContent("Tasks") { Text("\(preflight.summary.taskCount)") }
                    LabeledContent("Completed") { Text("\(preflight.summary.completedTaskCount)") }
                    LabeledContent("Courses") { Text("\(preflight.summary.courseCount)") }
                    LabeledContent("Meetings") { Text("\(preflight.summary.meetingCount)") }
                    LabeledContent("Exams") { Text("\(preflight.summary.examCount)") }
                    LabeledContent("Attachments") { Text("\(preflight.summary.attachmentCount)") }
                }

                Section {
                    Text("Your current data is backed up first. The restore copies the package into a temporary folder, verifies it there, and only then replaces the database and attachments. If any step fails, nothing is replaced.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("How It Works")
                } footer: {
                    Text("Restoring replaces every task, course, exam and attachment on this device.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Review Restore")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .accessibilityIdentifier("backup-restore-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Restore") { onRestore() }
                        .accessibilityIdentifier("backup-restore-confirm")
                }
            }
        }
    }
}
