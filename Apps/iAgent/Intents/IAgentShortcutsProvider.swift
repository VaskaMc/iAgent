import AppIntents

/// iAgent için Türkçe App Shortcuts çağrı ifadelerini sisteme yayımlar.
struct IAgentShortcutsProvider: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .navy }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskIAgentIntent(),
            phrases: [
                "\(.applicationName) ile konuş",
                "\(.applicationName)'e sor",
                "\(.applicationName) not al"
            ],
            shortTitle: "iAgent ile Konuş",
            systemImageName: "waveform.circle.fill"
        )
    }
}
