import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "../../common"
import "../../common/functions"
import "../../common/widgets"
import "../../services"

Item {
    id: root
    required property var panelWindow
    property var shell: null
    property var overviewScope: null
    property var dragGhost: null

    readonly property var runningWindows: HyprlandData.windowList || []

    FileView {
        id: userConfigFile
        path: (Quickshell.env("HOME") || "/home/leandro") + "/.config/omarchy/shell.json"
        watchChanges: true
        atomicWrites: true
        printErrors: false
        onLoaded: {
            root.syncFromConfigFile();
        }
        onFileChanged: reload()
    }

    property var favoriteApps: {
        const fromConfig = Config.options.overview.favoriteApps;
        if (Array.isArray(fromConfig)) return fromConfig;
        return [
            "com.microsoft.vscode", "google-chrome", "microsoft-edge",
            "com.mitchellh.ghostty", "foot", "org.gnome.nautilus",
            "chatgpt", "steam", "localsend", "mpv"
        ];
    }

    function syncFromConfigFile() {
        try {
            const raw = userConfigFile.text();
            if (!raw || raw.trim().length === 0) return;
            const parsed = JSON.parse(raw);
            if (!Array.isArray(parsed?.plugins)) return;
            for (let p of parsed.plugins) {
                if (p && p.id === "omarchy-overview" && Array.isArray(p.favoriteApps)) {
                    root.favoriteApps = p.favoriteApps;
                    Config.options.overview.favoriteApps = p.favoriteApps;
                    break;
                }
            }
        } catch (e) {
            console.warn("[AppGrid] failed to parse shell.json", e);
        }
    }

    Connections {
        target: Config.options.overview
        function onFavoriteAppsChanged() {
            if (Array.isArray(Config.options.overview.favoriteApps)) {
                root.favoriteApps = Config.options.overview.favoriteApps;
            }
        }
    }

    function isFavoriteApp(app) {
        if (!app) return false;
        const targetId = normalizeId(app.id);
        return root.favoriteApps.some(f => normalizeId(f) === targetId);
    }

    function toggleFavorite(appId) {
        if (!appId) return;
        const cleanId = String(appId).replace(/\.desktop$/, "").trim();
        const normTarget = cleanId.toLowerCase();
        let parsed = null;
        try {
            const raw = userConfigFile.text();
            if (raw && raw.trim().length > 0) {
                parsed = JSON.parse(raw);
            }
        } catch (e) {
            console.warn("[AppGrid] failed to parse shell.json", e);
        }
        if (!parsed || typeof parsed !== "object") return;
        if (!Array.isArray(parsed.plugins)) parsed.plugins = [];

        let targetPlugin = null;
        for (let p of parsed.plugins) {
            if (p && p.id === "omarchy-overview") {
                targetPlugin = p;
                break;
            }
        }
        if (!targetPlugin) {
            targetPlugin = { id: "omarchy-overview" };
            parsed.plugins.push(targetPlugin);
        }

        let currentFavorites = Array.isArray(targetPlugin.favoriteApps) ? [...targetPlugin.favoriteApps] : [
            "com.microsoft.vscode", "google-chrome", "microsoft-edge",
            "com.mitchellh.ghostty", "foot", "org.gnome.nautilus",
            "chatgpt", "steam", "localsend", "mpv"
        ];

        const idx = currentFavorites.findIndex(f => String(f).toLowerCase().replace(/\.desktop$/, "").trim() === normTarget);
        if (idx >= 0) {
            currentFavorites.splice(idx, 1);
            console.log("[AppGrid] Desafixado dos favoritos:", cleanId);
        } else {
            currentFavorites.push(cleanId);
            console.log("[AppGrid] Adicionado aos favoritos:", cleanId);
        }

        targetPlugin.favoriteApps = currentFavorites;

        // Persist to ~/.config/omarchy/shell.json
        userConfigFile.setText(JSON.stringify(parsed, null, 2) + "\n");

        // Immediately update in-memory state
        root.favoriteApps = currentFavorites;
        Config.settings = Object.assign({}, targetPlugin);
        Config.options.overview.favoriteApps = currentFavorites;

        if (overviewScope && typeof overviewScope.syncSettings === "function") {
            overviewScope.syncSettings();
        }
    }

    function startAppDrag(app, tileItem, mouse) {
        if (!dragGhost) return;
        GlobalStates.draggedApp = app;
        dragGhost.draggedApp = app;
        dragGhost.sourceGrid = root;
        const mapped = tileItem.mapToItem(dragGhost.parent, mouse.x, mouse.y);
        dragGhost.x = mapped.x - dragGhost.width / 2;
        dragGhost.y = mapped.y - dragGhost.height / 2;
        dragGhost.Drag.active = true;
    }

    function updateAppDrag(tileItem, mouse) {
        if (!dragGhost || !dragGhost.Drag.active) return;
        const mapped = tileItem.mapToItem(dragGhost.parent, mouse.x, mouse.y);
        dragGhost.x = mapped.x - dragGhost.width / 2;
        dragGhost.y = mapped.y - dragGhost.height / 2;
    }

    function finishAppDrag(app) {
        if (!dragGhost) return;
        dragGhost.Drag.drop();
        dragGhost.Drag.active = false;

        const targetWs = GlobalStates.hoveredWorkspaceId;
        GlobalStates.hoveredWorkspaceId = -1;
        GlobalStates.draggedApp = null;

        if (targetWs > 0 && app) {
            root.launchAppOnWorkspace(app, targetWs);
        }

        dragGhost.draggedApp = null;
        dragGhost.sourceGrid = null;
    }

    function launchAppOnWorkspace(app, targetWorkspace, newInstance = false) {
        if (!app || !targetWorkspace || targetWorkspace < 1) return;
        GlobalStates.overviewOpen = false;
        const desktopId = String(app.id || "");
        const runningWin = root.findRunningWindow(app);

        if (!newInstance && runningWin && runningWin.address) {
            if (Hyprland.usingLua) {
                Hyprland.dispatch(`hl.dsp.window.move({workspace = '${targetWorkspace}', follow = true, window = 'address:${runningWin.address}'})`);
                Hyprland.dispatch(`hl.dsp.focus({ window = 'address:${runningWin.address}' })`);
                Hyprland.dispatch(`hl.dsp.focus({workspace = '${targetWorkspace}'})`);
            } else {
                Hyprland.dispatch(`movetoworkspace ${targetWorkspace}, address:${runningWin.address}`);
                Hyprland.dispatch(`focuswindow address:${runningWin.address}`);
                Hyprland.dispatch(`workspace ${targetWorkspace}`);
            }
            return;
        }

        const launchCmd = `uwsm-app -- gtk-launch ${desktopId}`;
        if (Hyprland.usingLua) {
            Hyprland.dispatch(`hl.dsp.exec_cmd("[workspace ${targetWorkspace}] ${launchCmd}")`);
            Hyprland.dispatch(`hl.dsp.focus({workspace = '${targetWorkspace}'})`);
        } else {
            Hyprland.dispatch(`exec [workspace ${targetWorkspace}] ${launchCmd}`);
            Hyprland.dispatch(`workspace ${targetWorkspace}`);
        }
    }

    function normalizeId(id) {
        return String(id || "").toLowerCase().replace(/\.desktop$/, "").trim();
    }

    function isWindowMatchingApp(win, app) {
        if (!win || !app) return false;
        const appId = normalizeId(app.id);
        const winClass = String(win.class || "").toLowerCase();
        const winInitialClass = String(win.initialClass || "").toLowerCase();

        if (winClass === appId || winInitialClass === appId) return true;
        if (winClass.indexOf(appId) >= 0 || appId.indexOf(winClass) >= 0) return true;

        const appName = String(app.name || "").toLowerCase();
        if (appName.length > 2 && (winClass.indexOf(appName) >= 0 || winInitialClass.indexOf(appName) >= 0)) return true;

        const appIcon = String(app.icon || "").toLowerCase();
        if (appIcon.length > 2 && (winClass.indexOf(appIcon) >= 0 || winInitialClass.indexOf(appIcon) >= 0)) return true;

        return false;
    }

    function findRunningWindow(app) {
        for (let i = 0; i < runningWindows.length; i++) {
            if (isWindowMatchingApp(runningWindows[i], app)) {
                return runningWindows[i];
            }
        }
        return null;
    }

    function isAppRunning(app) {
        return findRunningWindow(app) !== null;
    }

    property string searchQuery: ""

    readonly property var allApps: {
        const raw = DesktopEntries.applications.values || [];
        const filtered = [];
        const seen = new Set();
        const ignored = new Set([
            "avahi-discover", "bssh", "bvnc", "lstopo", "qv4l2", "qvidcap",
            "uuctl", "fcitx5-configtool", "system-config-printer", "cups",
            "jconsole-java17-openjdk", "jshell-java17-openjdk", "limine-snapper-restore",
            "gcr-prompter", "gcr-viewer", "user-dirs-update-gtk", "fcitx5-wayland-launcher",
            "gnome-disk-image-mounter", "gnome-disk-image-writer", "nautilus-autorun-software",
            "org.freedesktop.xwayland", "org.quickshell", "voxtype-configure", "peazip-add-to-archive", "peazip-extract"
        ]);

        for (let i = 0; i < raw.length; i++) {
            const app = raw[i];
            if (!app || app.noDisplay === true || app.hidden === true) continue;
            const id = normalizeId(app.id);
            if (ignored.has(id)) continue;
            if (!app.name || !app.icon) continue;
            if (seen.has(id)) continue;
            seen.add(id);
            filtered.push(app);
        }

        // Pinned / favorite apps from config
        const configuredPinned = root.favoriteApps;
        const pinned = configuredPinned.map(normalizeId);

        filtered.sort((a, b) => {
            const idA = normalizeId(a.id);
            const idB = normalizeId(b.id);
            const pinA = pinned.indexOf(idA);
            const pinB = pinned.indexOf(idB);
            if (pinA !== -1 && pinB !== -1) return pinA - pinB;
            if (pinA !== -1) return -1;
            if (pinB !== -1) return 1;
            return String(a.name || "").localeCompare(String(b.name || ""));
        });

        return filtered;
    }

    readonly property var appEntries: {
        const q = String(searchQuery || "").trim().toLowerCase();
        if (!q) return allApps;
        return allApps.filter(app => {
            const name = String(app.name || "").toLowerCase();
            const id = String(app.id || "").toLowerCase();
            const comment = String(app.comment || "").toLowerCase();
            return name.includes(q) || id.includes(q) || comment.includes(q);
        });
    }

    function launchFirstApp(newInstance = false) {
        if (appEntries.length > 0) {
            launchApp(appEntries[0], newInstance);
            return true;
        }
        return false;
    }

    function resolveIcon(icon) {
        const value = `${icon ?? ""}`.trim();
        if (value.length === 0)
            return Quickshell.iconPath("application-x-executable", true);
        if (value.startsWith("file://") || value.startsWith("image://") || value.startsWith("qrc:/"))
            return value;
        if (value.startsWith("/"))
            return `file://${value}`;
        const themed = Quickshell.iconPath(value, true);
        if (themed.length > 0)
            return themed;
        return Quickshell.iconPath("application-x-executable", true);
    }

    function launchApp(app, newInstance) {
        GlobalStates.overviewOpen = false;
        const desktopId = String(app.id || "");
        const runningWin = findRunningWindow(app);

        if (!newInstance && runningWin && runningWin.address) {
            if (Hyprland.usingLua) {
                Hyprland.dispatch(`hl.dsp.focus({ window = 'address:${runningWin.address}' })`);
            } else {
                Hyprland.dispatch(`focuswindow address:${runningWin.address}`);
            }
            return;
        }

        const launchCmd = `uwsm-app -- gtk-launch ${desktopId}`;
        if (Hyprland.usingLua) {
            Hyprland.dispatch(`hl.dsp.exec_cmd("${launchCmd}")`);
        } else {
            Hyprland.dispatch(`exec ${launchCmd}`);
        }
    }

    implicitWidth: Math.min((panelWindow?.screen?.width ?? 1536) - 120, 1310) + Appearance.sizes.elevationMargin * 2
    implicitHeight: 96 + Appearance.sizes.elevationMargin * 2

    StyledRectangularShadow {
        target: dockBackground
    }

    Rectangle {
        id: dockBackground
        anchors.fill: parent
        anchors.margins: Appearance.sizes.elevationMargin
        radius: Style.cornerRadius
        color: Color.launcher.background
        border.width: Math.max(1, Style.space(2))
        border.color: Color.launcher.border
        clip: true

        Flickable {
            id: flickable
            anchors.fill: parent
            anchors.margins: Style.space(6)
            contentWidth: Math.max(width, appRow.implicitWidth)
            contentHeight: height
            flickableDirection: Flickable.HorizontalFlick
            boundsBehavior: Flickable.StopAtBounds
            clip: true

            WheelHandler {
                target: null
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: event => {
                    const delta = event.angleDelta.y || event.angleDelta.x;
                    if (!delta) return;
                    flickable.contentX = Math.max(0, Math.min(flickable.contentWidth - flickable.width, flickable.contentX - delta * 0.8));
                    event.accepted = true;
                }
            }

            StyledText {
                visible: root.appEntries.length === 0
                anchors.centerIn: parent
                text: `Nenhum aplicativo encontrado para "${root.searchQuery}"`
                font.family: Style.font.family
                font.pixelSize: 13
                color: Color.launcher.text
                opacity: 0.6
            }

            Row {
                id: appRow
                visible: root.appEntries.length > 0
                spacing: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                leftPadding: Style.space(8)
                rightPadding: Style.space(8)
                x: Math.max(0, (flickable.width - implicitWidth) / 2)

                Repeater {
                    model: root.appEntries
                    delegate: Rectangle {
                        id: appTile
                        required property var modelData
                        required property int index
                        readonly property var app: modelData
                        readonly property bool running: root.isAppRunning(app)
                        readonly property bool isFavorite: root.isFavoriteApp(app)
                        readonly property bool isSelected: (root.searchQuery.trim().length > 0 && index === 0)
                        property bool hovered: appMouseArea.containsMouse || isSelected
                        property point dragStartPos: Qt.point(0, 0)
                        property bool isDragging: false
                        property bool wasDragging: false

                        width: 76
                        height: 80
                        radius: 12
                        color: hovered ? Color.launcher.selectedBackground : "transparent"
                        border.width: isSelected ? Math.max(1, Style.space(1.5)) : 0
                        border.color: isSelected ? Color.launcher.selectedText : "transparent"

                        Behavior on scale {
                            NumberAnimation { duration: 150; easing.type: Easing.OutQuad }
                        }
                        scale: hovered ? 1.08 : 1.0

                        // Interactive Star button (click or Ctrl+click tile to toggle)
                        Rectangle {
                            id: starBadge
                            anchors.top: parent.top
                            anchors.right: parent.right
                            anchors.topMargin: 2
                            anchors.rightMargin: 2
                            width: 22
                            height: 22
                            radius: 11
                            color: starMouseArea.containsMouse ? Color.launcher.selectedBackground : "transparent"
                            visible: appTile.isFavorite || appTile.hovered
                            z: 10

                            Text {
                                anchors.centerIn: parent
                                text: appTile.isFavorite ? "★" : "☆"
                                font.pixelSize: 13
                                color: appTile.isFavorite ? Color.accent : Color.launcher.text
                                opacity: appTile.isFavorite ? (appTile.hovered ? 1.0 : 0.85) : (starMouseArea.containsMouse ? 0.9 : 0.45)
                            }

                            MouseArea {
                                id: starMouseArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                acceptedButtons: Qt.LeftButton
                                onClicked: (mouse) => {
                                    root.toggleFavorite(appTile.app.id);
                                    mouse.accepted = true;
                                }
                            }
                        }

                        Column {
                            anchors.centerIn: parent
                            spacing: Style.space(3)
                            width: parent.width

                            Item {
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: 40
                                height: 40

                                Image {
                                    id: appIconImg
                                    anchors.fill: parent
                                    fillMode: Image.PreserveAspectFit
                                    asynchronous: true
                                    source: root.resolveIcon(app.icon)
                                    sourceSize.width: 40 * Screen.devicePixelRatio
                                    sourceSize.height: 40 * Screen.devicePixelRatio
                                }
                            }

                            // Running indicator dot
                            Item {
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: 6
                                height: 5

                                Rectangle {
                                    anchors.centerIn: parent
                                    visible: appTile.running
                                    width: 5
                                    height: 5
                                    radius: 2.5
                                    color: Color.launcher.selectedText
                                }
                            }

                            StyledText {
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: parent.width - 8
                                text: app.name || ""
                                font.family: Style.font.family
                                font.pixelSize: 11
                                color: appTile.hovered ? Color.launcher.selectedText : Color.launcher.text
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                        }

                        MouseArea {
                            id: appMouseArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: appTile.isDragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                            preventStealing: appTile.isDragging

                            onPressed: (mouse) => {
                                if (mouse.button === Qt.LeftButton) {
                                    appTile.dragStartPos = Qt.point(mouse.x, mouse.y);
                                    appTile.isDragging = false;
                                    appTile.wasDragging = false;
                                }
                            }

                            onPositionChanged: (mouse) => {
                                if (mouse.buttons & Qt.LeftButton) {
                                    if (!appTile.isDragging) {
                                        const dx = mouse.x - appTile.dragStartPos.x;
                                        const dy = mouse.y - appTile.dragStartPos.y;
                                        if (Math.abs(dx) > 8 || Math.abs(dy) > 8) {
                                            appTile.isDragging = true;
                                            appTile.wasDragging = true;
                                            root.startAppDrag(appTile.app, appTile, mouse);
                                        }
                                    } else {
                                        root.updateAppDrag(appTile, mouse);
                                    }
                                }
                            }

                            onReleased: (mouse) => {
                                if (appTile.isDragging) {
                                    appTile.isDragging = false;
                                    root.finishAppDrag(appTile.app);
                                }
                            }

                            onClicked: (mouse) => {
                                if (appTile.wasDragging) {
                                    appTile.wasDragging = false;
                                    return;
                                }
                                const isCtrl = (mouse.modifiers & Qt.ControlModifier) !== 0;
                                console.log("[AppGrid] Clicked:", appTile.app.id, "button:", mouse.button, "modifiers:", mouse.modifiers, "isCtrl:", isCtrl);
                                if (isCtrl) {
                                    root.toggleFavorite(appTile.app.id);
                                    mouse.accepted = true;
                                    return;
                                }
                                const newInstance = (mouse.button === Qt.RightButton || mouse.button === Qt.MiddleButton);
                                root.launchApp(appTile.app, newInstance);
                            }

                            StyledToolTip {
                                extraVisibleCondition: false
                                alternativeVisibleCondition: appMouseArea.containsMouse
                                text: {
                                    const favHint = appTile.isFavorite
                                        ? "★ Favorito fixado (Ctrl + Clique ou clique na estrela para desafixar)"
                                        : "Ctrl + Clique ou clique na estrela para fixar nos favoritos";
                                    const runHint = appTile.running
                                        ? "Em execução (clique para alternar)"
                                        : "Clique para abrir";
                                    const dragHint = "Arraste para um espaço para abrir nele";
                                    const desc = app.comment ? `${app.comment}\n` : "";
                                    return `${app.name || "App"}\n${desc}${runHint}\n${dragHint}\n${favHint}`;
                                }
                            }
                        }
                    }
                }
            }
        }

        // Left gradient fade when scrolled
        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 28
            visible: flickable.contentX > 4
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: Color.launcher.background }
                GradientStop { position: 1.0; color: "transparent" }
            }
            z: 2
        }

        // Right gradient fade when more content available
        Rectangle {
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 28
            visible: flickable.contentWidth > flickable.width && flickable.contentX < (flickable.contentWidth - flickable.width - 4)
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 1.0; color: Color.launcher.background }
            }
            z: 2
        }
    }
}
