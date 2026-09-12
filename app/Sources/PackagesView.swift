import SwiftUI

/// A package manager that runs on the phone rather than in the guest.
///
/// Cydia inside the guest works, but barely: it blocks its own main thread
/// while dpkg unpacks, and at a few frames a second that is long enough for
/// iOS to kill it — which also kills whatever was installing. Here the
/// browsing and the downloading happen on the phone, where the network is real
/// and nothing is watching a clock, and only the finished `.deb` goes in.
struct PackagesView: View {
    @ObservedObject var model: VMModel
    @StateObject private var store = RepoStore()
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var sources = false
    @State private var downloading: String?
    @State private var complaint: String?

    /// Repositories hold tens of thousands of packages and a list that long is
    /// slower to draw than it is to scroll. Until something is typed, this is a
    /// window onto the index, not the whole of it.
    private var shown: [RepoPackage] {
        let all = store.packages
        guard !query.isEmpty else { return Array(all.prefix(200)) }
        let needle = query.lowercased()
        return all.filter {
            $0.name.lowercased().contains(needle) || $0.id.lowercased().contains(needle)
        }
        .prefix(200)
        .map { $0 }
    }

    var body: some View {
        NavigationStack {
            List {
                if case .loading(let who) = store.state {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(L("Читаю %@…", who)).foregroundStyle(.secondary)
                    }
                }
                if case .failed(let why) = store.state {
                    Text(why).font(.footnote).foregroundStyle(.orange)
                }
                if let downloading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(L("Качаю %@…", downloading)).foregroundStyle(.secondary)
                    }
                }
                if let complaint {
                    Text(complaint).font(.footnote).foregroundStyle(.red)
                }

                ForEach(shown) { package in
                    Button { install(package) } label: { row(package) }
                        .buttonStyle(.plain)
                        .disabled(downloading != nil || model.transfer?.isRunning == true)
                }

                if store.packages.isEmpty, store.state == .idle {
                    Text(L("Пусто. Потяните вниз, чтобы прочитать источники."))
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: L("Поиск пакета"))
            .refreshable { await store.refresh() }
            .navigationTitle(L("Менеджер пакетов"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Закрыть")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { sources = true } label: { Image(systemName: "list.bullet") }
                }
            }
            .sheet(isPresented: $sources) { SourcesView(store: store) }
            .task { if store.packages.isEmpty { await store.refresh() } }
        }
    }

    private func row(_ package: RepoPackage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(package.name).font(.body)
                Spacer()
                Text(package.version).font(.caption).foregroundStyle(.secondary)
            }
            if !package.summary.isEmpty {
                Text(package.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(package.repo.host ?? "").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    /// Downloads here, installs there. The sheet closes on the way, because the
    /// installing is shown by the same banner as every other transfer.
    private func install(_ package: RepoPackage) {
        guard let url = package.url else { return }
        complaint = nil
        downloading = package.name

        Task {
            defer { downloading = nil }
            do {
                let (file, response) = try await URLSession.shared.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    complaint = L("Репозиторий не отдал файл (%d).",
                                  (response as? HTTPURLResponse)?.statusCode ?? 0)
                    return
                }
                // Named after the package: dpkg does not care, but the banner
                // and the log do, and `CFNetworkDownload_xxx.tmp` tells nobody
                // anything.
                let named = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(package.id)_\(package.version).deb")
                try? FileManager.default.removeItem(at: named)
                try FileManager.default.moveItem(at: file, to: named)

                dismiss()
                model.installDEB(named)
            }
            catch {
                complaint = error.localizedDescription
            }
        }
    }
}

/// The list of repositories, which is the only state this screen keeps.
private struct SourcesView: View {
    @ObservedObject var store: RepoStore
    @Environment(\.dismiss) private var dismiss
    @State private var adding = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField(L("https://адрес.репозитория/"), text: $adding)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        Button(L("Добавить")) {
                            let url = adding.trimmingCharacters(in: .whitespaces)
                            guard !url.isEmpty, !store.repos.contains(where: { $0.url == url }) else { return }
                            store.repos.append(Repo(url: url))
                            adding = ""
                        }
                        .disabled(adding.isEmpty)
                    }
                } footer: {
                    Text(L("Читаются указатели `Packages` и `Packages.gz`. Источники на `.bz2` или `.zst` не поддерживаются: распаковщиков для них в iOS нет."))
                }

                Section(L("Источники")) {
                    ForEach(store.repos) { repo in
                        Text(repo.url).font(.callout)
                    }
                    .onDelete { store.repos.remove(atOffsets: $0) }
                }
            }
            .navigationTitle(L("Источники"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Готово")) { dismiss() }
                }
            }
        }
    }
}
