import SwiftUI

/// The "Уведомления и звук" section of the Settings tab. Three parameters — показ / звук / громкость —
/// with a general default that applies to every type, plus a per-type "Настроить отдельно" override that
/// reveals the same three controls for that one type (Завершение / Запрос разрешения / Вопрос агента).
///
/// A top-level view, so it observes `LocalizationManager` directly (CLAUDE.md l10n rule 4) — its stored
/// inputs don't change on a language switch, so SwiftUI would otherwise leave the `L(...)` labels stale.
struct NotificationSettingsView: View {
    @ObservedObject var notif: NotificationSettings
    @ObservedObject private var loc = LocalizationManager.shared

    /// The imported-sound library, mirrored into local state so the menus + list refresh after an
    /// import/removal without re-reading disk on every redraw.
    @State private var customs: [CustomSound] = CustomSounds.load()
    /// Inline (not modal) import error — an `.alert` is unreliable on a borderless non-activating panel,
    /// so a dismissible red banner (same idiom as `claudeMissingNote`) is used instead.
    @State private var importError: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            caption(L("notif.general.caption"))
            if let err = importError { errorBanner(err) }

            // General defaults (inherited by every type that isn't set apart).
            showRow(L("notif.show"), $notif.generalShow)
            soundRow(L("notif.sound"), current: notif.generalSound, volume: notif.generalVolume) { notif.setGeneralSound($0) }
            volumeRow(L("notif.volume"), $notif.generalVolume)

            // Per-type overrides.
            subHeader(L("notif.byType"))
            caption(L("notif.byType.hint"))
            ForEach(NotifType.allCases) { typeBlock($0) }

            // Imported custom sounds — audition + remove.
            if !customs.isEmpty { customsList }
        }
        .onAppear { reloadCustoms() }
    }

    // MARK: - Per-type block

    @ViewBuilder
    private func typeBlock(_ t: NotifType) -> some View {
        let overridden = notif.isOverridden(t)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.localizedName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.textPrimary)
                    if !overridden {
                        Text(L("notif.type.inherits"))
                            .font(.system(size: 10))
                            .foregroundStyle(DS.textTertiary)
                    }
                }
                Spacer(minLength: 8)
                Text(L("notif.type.override"))
                    .font(.system(size: 10))
                    .foregroundStyle(DS.textTertiary)
                switchToggle(overrideBinding(t))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if overridden {
                VStack(spacing: 0) {
                    showRow(L("notif.show"), showBinding(t))
                    soundRow(L("notif.sound"), current: notif.sound(for: t), volume: notif.effectiveVolume(t)) { notif.setSound($0, for: t) }
                    volumeRow(L("notif.volume"), volumeBinding(t))
                }
                .padding(.leading, 12)   // indent so the overridden controls read as belonging to the type
            }
        }
    }

    // MARK: - Rows

    private func showRow(_ label: String, _ binding: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            rowLabel(label)
            Spacer(minLength: 8)
            switchToggle(binding)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func soundRow(_ label: String, current: SoundRef, volume: Double, onPick: @escaping (SoundRef) -> Void) -> some View {
        HStack(spacing: 8) {
            rowLabel(label)
            Spacer(minLength: 8)
            previewButton(current, volume: volume)
            soundMenu(current: current, volume: volume, onPick: onPick)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func volumeRow(_ label: String, _ binding: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            rowLabel(label, width: 96)
            Slider(value: binding, in: 0...1)
            Text("\(Int((binding.wrappedValue * 100).rounded()))%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(DS.textSecondary)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Sound menu + preview

    private func soundMenu(current: SoundRef, volume: Double, onPick: @escaping (SoundRef) -> Void) -> some View {
        Menu {
            ForEach(SoundCatalog.presets) { p in
                Button(p.name) { pick(p.ref, volume, onPick) }
            }
            if !customs.isEmpty {
                Divider()
                ForEach(customs) { c in
                    Button(c.displayName) { pick(.custom(c.id), volume, onPick) }
                }
            }
            Divider()
            Button(L("notif.sound.silent")) { pick(.silent, volume, onPick) }
            Button(L("notif.import.choose")) { importCustom(volume, onPick) }
        } label: {
            Text(SoundCatalog.displayName(for: current, customs: customs))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.textTertiary)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func previewButton(_ ref: SoundRef, volume: Double) -> some View {
        Button { SoundPlayer.shared.preview(ref, volume: volume) } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 9))
                .foregroundStyle(ref == .silent ? DS.textTertiary : DS.textSecondary)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.neutralBtn))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(ref == .silent)
        .help(L("notif.preview.help"))
    }

    // MARK: - Imported custom sounds

    private var customsList: some View {
        VStack(spacing: 0) {
            subHeader(L("notif.customs.title"))
            ForEach(customs) { c in
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.textTertiary)
                    Text(c.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // The library isn't tied to one channel, so audition each imported sound at a fixed
                    // reference volume — never inaudible just because the general volume happens to be low.
                    previewButton(.custom(c.id), volume: 1.0)
                    Button { removeCustom(c) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help(L("notif.customs.remove"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Actions

    private func pick(_ ref: SoundRef, _ volume: Double, _ onPick: (SoundRef) -> Void) {
        onPick(ref)
        // Pick = hear: audition the chosen sound immediately at this channel's volume (the "послушать
        // сразу" ask). Silence is a no-op.
        if ref != .silent { SoundPlayer.shared.preview(ref, volume: volume) }
    }

    private func importCustom(_ volume: Double, _ onPick: @escaping (SoundRef) -> Void) {
        guard let url = SoundImporter.presentOpenPanel() else { return }
        switch SoundImporter.importSound(from: url) {
        case .success(let sound):
            customs = CustomSounds.load()
            importError = nil
            onPick(.custom(sound.id))
            SoundPlayer.shared.preview(.custom(sound.id), volume: volume)
        case .failure(let err):
            importError = err.message
        }
    }

    private func removeCustom(_ c: CustomSound) {
        CustomSounds.remove(id: c.id)
        notif.customSoundRemoved(c.id)   // repoint any channel that pointed at it
        customs = CustomSounds.load()
    }

    /// Reconcile the library against disk when the panel appears: drop any entry whose file was deleted
    /// out-of-band (so it stops showing as a selectable, silently-broken sound) and repoint channels that
    /// referenced it. Cheap — a handful of `fileExists` checks — and only writes when something changed.
    private func reloadCustoms() {
        let missing = CustomSounds.load().filter {
            !FileManager.default.fileExists(atPath: CustomSounds.fileURL(for: $0).path)
        }
        for m in missing {
            CustomSounds.remove(id: m.id)
            notif.customSoundRemoved(m.id)
        }
        customs = CustomSounds.load()
    }

    // MARK: - Per-type bindings
    //
    // Selecting among the SwiftUI-synthesized `$notif.…` bindings by type. These are the framework's own
    // ObservedObject bindings (correct under Swift 6 strict concurrency), not hand-rolled closures.

    private func overrideBinding(_ t: NotifType) -> Binding<Bool> {
        switch t {
        case .done:       return $notif.doneOverride
        case .permission: return $notif.permissionOverride
        case .question:   return $notif.questionOverride
        }
    }
    private func showBinding(_ t: NotifType) -> Binding<Bool> {
        switch t {
        case .done:       return $notif.doneShow
        case .permission: return $notif.permissionShow
        case .question:   return $notif.questionShow
        }
    }
    private func volumeBinding(_ t: NotifType) -> Binding<Double> {
        switch t {
        case .done:       return $notif.doneVolume
        case .permission: return $notif.permissionVolume
        case .question:   return $notif.questionVolume
        }
    }

    // MARK: - Small building blocks

    private func rowLabel(_ text: String, width: CGFloat? = nil) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(DS.textSecondary)
            .frame(width: width, alignment: .leading)
    }

    private func switchToggle(_ binding: Binding<Bool>) -> some View {
        Toggle("", isOn: binding)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(DS.green)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(DS.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
    }

    /// A mono sub-divider ("ПО ТИПАМ" / "СВОИ ЗВУКИ") — the `GroupHeader` idiom, lighter than a full
    /// `SettingsSectionHeader` so the notification section reads as one group with inner divisions.
    private func subHeader(_ text: String) -> some View {
        HStack(spacing: 7) {
            Text(text)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(DS.textTertiary)
            DS.line.frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(DS.redText)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(DS.redText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { importError = nil } label: {
                Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(DS.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
