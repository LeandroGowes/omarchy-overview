import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "../../common"
import "../../common/widgets"
import "../../services"
import "."

Scope {
    id: overviewScope
    property string omarchyPath: Quickshell.env("OMARCHY_PATH")
    property var shell: null
    readonly property var appLibrary: shell ? shell.appLibrary : null
    property var manifest: null
    property var settings: ({})
    property bool opened: GlobalStates.overviewOpen

    FileView {
        id: userConfigFile
        path: (Quickshell.env("HOME") || "/home/leandro") + "/.config/omarchy/shell.json"
        watchChanges: true
        printErrors: false
        onLoaded: overviewScope.syncSettings()
        onFileChanged: reload()
    }

    // Read a single value from this plugin's inline shell.json entry, with a
    // fallback for missing/null values. Matches Omarchy Panel.setting().
    function setting(name, fallback) {
        var value = settings ? settings[name] : undefined;
        return value === undefined || value === null ? fallback : value;
    }

    function entrySettings() {
        const id = String(manifest?.id || "omarchy-overview");
        let plugins = [];
        try {
            const raw = userConfigFile.text();
            if (raw && raw.trim().length > 0) {
                const parsed = JSON.parse(raw);
                if (Array.isArray(parsed?.plugins)) {
                    plugins = parsed.plugins;
                }
            }
        } catch (e) {
            console.warn("omarchy-overview: failed to parse shell.json", e);
        }

        if (plugins.length === 0) {
            const config = shell?.shellConfig || null;
            if (Array.isArray(config?.plugins)) {
                plugins = config.plugins;
            }
        }

        for (const entry of plugins) {
            if (String(entry?.id || "") === id)
                return entry;
        }
        return settings || ({});
    }

    function syncSettings() {
        const next = entrySettings() || ({});
        settings = next;
        Config.settings = next;
    }

    onManifestChanged: syncSettings()
    onShellChanged: syncSettings()
    Component.onCompleted: syncSettings()

    Connections {
        target: overviewScope.shell
        ignoreUnknownSignals: true
        function onShellConfigChanged() {
            overviewScope.syncSettings();
        }
    }

    function open(payloadJson) {
        GlobalStates.overviewOpen = true;
    }

    function close() {
        GlobalStates.overviewOpen = false;
    }

    function toggle(payloadJson) {
        GlobalStates.overviewOpen = !GlobalStates.overviewOpen;
    }

    Variants {
        id: overviewVariants
        model: Quickshell.screens
        PanelWindow {
            id: root
            required property var modelData
            readonly property var shell: overviewScope.shell
            readonly property HyprlandMonitor monitor: Hyprland.monitorFor(root.screen)
            property bool monitorIsFocused: (Hyprland.focusedMonitor?.id == monitor?.id)
            property bool blurEnabled: Config.options.overview.effects.enableBlur
            property bool closeOnFocusLoss: Config.options.overview.closeOnFocusLoss ?? true
            screen: modelData
            visible: GlobalStates.overviewOpen

            WlrLayershell.namespace: blurEnabled ? "quickshell:overview-blur" : "quickshell:overview"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
            color: "transparent"

            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }

            HyprlandFocusGrab {
                id: grab
                windows: [root]
                property bool canBeActive: root.monitorIsFocused
                active: false
                onCleared: () => {
                    // Only the monitor that owns the grab may close the overview
                    if (root.closeOnFocusLoss && !active && canBeActive)
                        GlobalStates.overviewOpen = false;
                }
            }

            Connections {
                target: GlobalStates
                function onOverviewOpenChanged() {
                    if (GlobalStates.overviewOpen) {
                        if (overviewScope.appLibrary) overviewScope.appLibrary.refreshIcons();
                        delayedGrabTimer.start();
                        if (typeof searchInput !== "undefined" && searchInput) {
                            searchInput.text = "";
                            searchInput.forceActiveFocus();
                        }
                    }
                }
            }

            // Re-evaluate grab ownership when focused monitor changes
            Connections {
                target: Hyprland
                function onFocusedMonitorChanged() {
                    if (!GlobalStates.overviewOpen)
                        return;
                    // Transfer the grab to the newly focused monitor
                    if (root.monitorIsFocused && !grab.active) {
                        grab.active = true;
                    } else if (!root.monitorIsFocused && grab.active) {
                        grab.active = false;
                    }
                }
            }

            Timer {
                id: delayedGrabTimer
                interval: Config.options.hacks.arbitraryRaceConditionDelay
                repeat: false
                onTriggered: {
                    if (!grab.canBeActive)
                        return;
                    grab.active = GlobalStates.overviewOpen;
                }
            }

            // Keep the layershell surface full-screen so backdrop/blur are not constrained by content size.
            implicitWidth: screen.width
            implicitHeight: screen.height

            Item {
                id: keyHandler
                anchors.fill: parent
                visible: GlobalStates.overviewOpen
                focus: GlobalStates.overviewOpen
                z: 0

                Rectangle {
                    id: backdropLayer
                    anchors.fill: parent
                    visible: true
                    color: Color.launcher.scrim
                    opacity: 1
                    z: 0
                }

                MouseArea {
                    id: outsideClickCatcher
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                    enabled: root.closeOnFocusLoss && GlobalStates.overviewOpen
                    z: 0
                    onPressed: mouse => {
                        GlobalStates.overviewOpen = false;
                        mouse.accepted = true;
                    }
                }

                Keys.onPressed: event => {
                    // Forward printable characters to searchInput
                    if (event.text && event.text.length > 0 && event.text.charCodeAt(0) >= 32 && (event.key < Qt.Key_0 || event.key > Qt.Key_9)) {
                        if (searchInput) {
                            searchInput.forceActiveFocus();
                            searchInput.text += event.text;
                            event.accepted = true;
                            return;
                        }
                    }

                    // close: Escape or Enter
                    if (event.key === Qt.Key_Escape || event.key === Qt.Key_Return) {
                        GlobalStates.overviewOpen = false;
                        event.accepted = true;
                        return;
                    }

                    // Helper: compute current group bounds
                    const workspacesPerGroup = Config.options.overview.rows * Config.options.overview.columns;
                    const currentId = Hyprland.focusedMonitor?.activeWorkspace?.id ?? 1;
                    const useWorkspaceMap = Config.options.overview.useWorkspaceMap;
                    const workspaceMap = Config.options.overview.workspaceMap ?? [];
                    const focusedMonitorId = Hyprland.focusedMonitor?.id ?? root.monitor?.id ?? 0;
                    const workspaceOffset = useWorkspaceMap ? Number(workspaceMap[focusedMonitorId] ?? 0) : 0;
                    const currentGroup = Math.floor((currentId - workspaceOffset - 1) / workspacesPerGroup);
                    const minWorkspaceId = currentGroup * workspacesPerGroup + 1 + workspaceOffset;
                    const maxWorkspaceId = minWorkspaceId + workspacesPerGroup - 1;

                    const rows = Config.options.overview.rows;
                    const columns = Config.options.overview.columns;
                    const reverseColumns = Config.options.overview.orderRightLeft;
                    const reverseRows = Config.options.overview.orderBottomUp;

                    const clampedIndex = Math.max(0, Math.min(workspacesPerGroup - 1, currentId - minWorkspaceId));
                    const currentNormalRow = Math.floor(clampedIndex / columns);
                    const currentNormalColumn = clampedIndex % columns;

                    function toVisualRow(normalRow) {
                        return reverseRows ? (rows - normalRow - 1) : normalRow;
                    }

                    function toVisualColumn(normalColumn) {
                        return reverseColumns ? (columns - normalColumn - 1) : normalColumn;
                    }

                    function toNormalRow(visualRow) {
                        return reverseRows ? (rows - visualRow - 1) : visualRow;
                    }

                    function toNormalColumn(visualColumn) {
                        return reverseColumns ? (columns - visualColumn - 1) : visualColumn;
                    }

                    let targetVisualRow = toVisualRow(currentNormalRow);
                    let targetVisualColumn = toVisualColumn(currentNormalColumn);

                    let targetId = null;

                    // Arrow keys and vim-style hjkl
                    if (event.key === Qt.Key_Left || event.key === Qt.Key_H) {
                        targetVisualColumn = (targetVisualColumn - 1 + columns) % columns;
                    } else if (event.key === Qt.Key_Right || event.key === Qt.Key_L) {
                        targetVisualColumn = (targetVisualColumn + 1) % columns;
                    } else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
                        targetVisualRow = (targetVisualRow - 1 + rows) % rows;
                    } else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
                        targetVisualRow = (targetVisualRow + 1) % rows;
                    }

                    // Number keys: jump to workspace within the current group
                    // 1-9 map to positions 1-9, 0 maps to position 10
                    else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
                        const position = event.key - Qt.Key_0; // 1-9
                        if (position <= workspacesPerGroup) {
                            targetId = minWorkspaceId + position - 1;
                        }
                    } else if (event.key === Qt.Key_0) {
                        // 0 = 10th workspace in the group (if group has 10+ workspaces)
                        if (workspacesPerGroup >= 10) {
                            targetId = minWorkspaceId + 9; // 10th position = offset 9
                        }
                    }

                    if (targetId === null && (
                        event.key === Qt.Key_Left || event.key === Qt.Key_H ||
                        event.key === Qt.Key_Right || event.key === Qt.Key_L ||
                        event.key === Qt.Key_Up || event.key === Qt.Key_K ||
                        event.key === Qt.Key_Down || event.key === Qt.Key_J
                    )) {
                        const targetNormalRow = toNormalRow(targetVisualRow);
                        const targetNormalColumn = toNormalColumn(targetVisualColumn);
                        targetId = minWorkspaceId + targetNormalRow * columns + targetNormalColumn;
                    }

                    if (targetId !== null) {
                        const clampedTarget = Math.max(minWorkspaceId, Math.min(maxWorkspaceId, targetId));
			if (Hyprland.usingLua) {
				Hyprland.dispatch(`hl.dsp.focus({workspace = '${clampedTarget}'})`);
			} else {
				Hyprland.dispatch("workspace " + clampedTarget);
			}
                        event.accepted = true;
                    }
                }
            }

            ColumnLayout {
                id: columnLayout
                visible: GlobalStates.overviewOpen
                z: 1
                spacing: Style.space(14)
                anchors {
                    horizontalCenter: parent.horizontalCenter
                    top: parent.top
                    topMargin: Config.options.position.topMargin
                }

                // Search Bar ("Type-to-Search")
                Rectangle {
                    id: searchBarContainer
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: Math.min(480, (overviewLoader.item ? overviewLoader.item.implicitWidth : 1310) * 0.45)
                    Layout.preferredHeight: 38
                    radius: Style.cornerRadius
                    color: Color.launcher.background
                    border.width: searchInput.activeFocus ? Math.max(1, Style.space(1.5)) : Math.max(1, Style.space(1))
                    border.color: searchInput.activeFocus ? Color.launcher.selectedText : Color.launcher.border

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        spacing: 8

                        Text {
                            text: "\uf002"
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 13
                            color: Color.launcher.text
                            opacity: 0.65
                            Layout.alignment: Qt.AlignVCenter
                        }

                        TextInput {
                            id: searchInput
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            color: Color.launcher.text
                            font.family: Style.font.family
                            font.pixelSize: 13
                            clip: true
                            selectByMouse: true

                            Text {
                                text: "Pesquisar aplicativos e janelas..."
                                color: Color.launcher.text
                                opacity: 0.4
                                font.family: Style.font.family
                                font.pixelSize: 13
                                visible: !searchInput.text && !searchInput.inputMethodComposing
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Keys.onPressed: (event) => {
                                if (event.key === Qt.Key_Escape) {
                                    if (searchInput.text.length > 0) {
                                        searchInput.text = "";
                                        event.accepted = true;
                                    } else {
                                        GlobalStates.overviewOpen = false;
                                        event.accepted = true;
                                    }
                                    return;
                                }

                                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                    if (searchInput.text.trim().length > 0) {
                                        appGrid.launchFirstApp(false);
                                        event.accepted = true;
                                    } else {
                                        GlobalStates.overviewOpen = false;
                                        event.accepted = true;
                                    }
                                    return;
                                }

                                // If search query is empty, let 1-9 switch workspaces
                                if (searchInput.text.length === 0) {
                                    const workspacesPerGroup = Config.options.overview.rows * Config.options.overview.columns;
                                    const currentId = Hyprland.focusedMonitor?.activeWorkspace?.id ?? 1;
                                    const useWorkspaceMap = Config.options.overview.useWorkspaceMap;
                                    const workspaceMap = Config.options.overview.workspaceMap ?? [];
                                    const focusedMonitorId = Hyprland.focusedMonitor?.id ?? root.monitor?.id ?? 0;
                                    const workspaceOffset = useWorkspaceMap ? Number(workspaceMap[focusedMonitorId] ?? 0) : 0;
                                    const currentGroup = Math.floor((currentId - workspaceOffset - 1) / workspacesPerGroup);
                                    const minWorkspaceId = currentGroup * workspacesPerGroup + 1 + workspaceOffset;
                                    const maxWorkspaceId = minWorkspaceId + workspacesPerGroup - 1;

                                    if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
                                        const pos = event.key - Qt.Key_0;
                                        if (pos <= workspacesPerGroup) {
                                            const target = minWorkspaceId + pos - 1;
                                            if (Hyprland.usingLua) {
                                                Hyprland.dispatch(`hl.dsp.focus({workspace = '${target}'})`);
                                            } else {
                                                Hyprland.dispatch("workspace " + target);
                                            }
                                            event.accepted = true;
                                            return;
                                        }
                                    }

                                    const rows = Config.options.overview.rows;
                                    const columns = Config.options.overview.columns;
                                    const reverseColumns = Config.options.overview.orderRightLeft;
                                    const reverseRows = Config.options.overview.orderBottomUp;

                                    const clampedIndex = Math.max(0, Math.min(workspacesPerGroup - 1, currentId - minWorkspaceId));
                                    const currentNormalRow = Math.floor(clampedIndex / columns);
                                    const currentNormalColumn = clampedIndex % columns;

                                    let targetVisualRow = reverseRows ? (rows - currentNormalRow - 1) : currentNormalRow;
                                    let targetVisualColumn = reverseColumns ? (columns - currentNormalColumn - 1) : currentNormalColumn;

                                    if (event.key === Qt.Key_Left) {
                                        targetVisualColumn = (targetVisualColumn - 1 + columns) % columns;
                                    } else if (event.key === Qt.Key_Right) {
                                        targetVisualColumn = (targetVisualColumn + 1) % columns;
                                    } else if (event.key === Qt.Key_Up) {
                                        targetVisualRow = (targetVisualRow - 1 + rows) % rows;
                                    } else if (event.key === Qt.Key_Down) {
                                        targetVisualRow = (targetVisualRow + 1) % rows;
                                    } else {
                                        return;
                                    }

                                    const targetNormalRow = reverseRows ? (rows - targetVisualRow - 1) : targetVisualRow;
                                    const targetNormalColumn = reverseColumns ? (columns - targetVisualColumn - 1) : targetVisualColumn;
                                    const targetId = minWorkspaceId + targetNormalRow * columns + targetNormalColumn;
                                    const clampedTarget = Math.max(minWorkspaceId, Math.min(maxWorkspaceId, targetId));
                                    if (Hyprland.usingLua) {
                                        Hyprland.dispatch(`hl.dsp.focus({workspace = '${clampedTarget}'})`);
                                    } else {
                                        Hyprland.dispatch("workspace " + clampedTarget);
                                    }
                                    event.accepted = true;
                                    return;
                                }
                            }
                        }

                        Text {
                            visible: searchInput.text.length > 0
                            text: "✕"
                            font.pixelSize: 12
                            color: Color.launcher.text
                            opacity: 0.6
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: searchInput.text = ""
                            }
                        }
                    }
                }

                Loader {
                    id: overviewLoader
                    active: Config?.options.overview.enable ?? true
                    sourceComponent: OverviewWidget {
                        panelWindow: root
                        shell: overviewScope.shell
                        visible: true
                    }
                }

                AppGrid {
                    id: appGrid
                    panelWindow: root
                    shell: overviewScope.shell
                    searchQuery: searchInput.text
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: (overviewLoader.item && overviewLoader.item.implicitWidth > 0) ? overviewLoader.item.implicitWidth : implicitWidth
                    Layout.preferredHeight: implicitHeight
                }
            }
        }
    }

    IpcHandler {
        target: "overview"

        function toggle(): string {
            overviewScope.toggle("");
            return "ok";
        }
        function close(): string {
            overviewScope.close();
            return "ok";
        }
        function open(): string {
            overviewScope.open("");
            return "ok";
        }
        function state(): string {
            return GlobalStates.overviewOpen ? "open" : "closed";
        }
        function ping(): string {
            return "ok";
        }
    }
}
