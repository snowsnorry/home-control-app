import SwiftUI

struct HueSceneSettings: View {
    var store: HomeStore
    private var selected: Set<String> { Set(store.configuration.hue?.selectedSceneIDs ?? []) }
    private var groups: [String] {
        var seen: Set<String> = []
        return store.scenes.compactMap { seen.insert($0.groupID).inserted ? $0.groupID : nil }
    }
    private var missing: [String] { selected.subtracting(Set(store.scenes.map(\.id))).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Scenes").font(.headline)
            Text("Choose which Hue scenes appear in the device panel. Nothing is selected automatically.")
                .font(.caption).foregroundStyle(.secondary)
            if store.hueState != .online {
                Text("Reconnect your Hue Bridge to update the available scenes.").font(.caption).foregroundStyle(.secondary)
            } else if store.scenes.isEmpty {
                Text("No scenes found on this bridge.").foregroundStyle(.secondary)
            }
            ForEach(groups, id: \.self) { groupID in
                let scenes = store.scenes.filter { $0.groupID == groupID }
                VStack(alignment: .leading, spacing: 8) {
                    Text(scenes.first?.groupName ?? "").font(.subheadline.bold())
                    ForEach(scenes) { scene in
                        Toggle(isOn: Binding(get: { selected.contains(scene.id) }, set: { store.setSceneVisible(scene.id, visible: $0) })) {
                            Text(scene.name)
                        }.toggleStyle(.checkbox)
                            .accessibilityLabel(Text("Show \(scene.name) in \(scene.groupName) in the panel"))
                    }
                }
            }
            if !missing.isEmpty, store.hueState == .online {
                Text("Unavailable scenes").font(.subheadline.bold())
                ForEach(missing, id: \.self) { id in
                    HStack {
                        Text("Removed scene").foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove from panel") { store.setSceneVisible(id, visible: false) }
                    }
                }
            }
        }
    }
}
