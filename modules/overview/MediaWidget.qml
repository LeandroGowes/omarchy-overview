import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Mpris
import Quickshell.Hyprland
import "../../common"
import "../../common/functions"
import "../../common/widgets"
import "../../services"

Item {
    id: root

    property var shell: null

    readonly property var mediaService: shell?.firstPartyServiceFor ? shell.firstPartyServiceFor("omarchy.media") : null
    readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []

    property var currentPlayer: null
    property int updateToken: 0

    function updateActivePlayer() {
        if (mediaService && mediaService.activePlayer) {
            currentPlayer = mediaService.activePlayer;
            updateToken++;
            return;
        }

        // Find currently playing player
        for (let i = 0; i < mprisPlayers.length; i++) {
            const p = mprisPlayers[i];
            if (p && p.isPlaying) {
                currentPlayer = p;
                updateToken++;
                return;
            }
        }

        // Fallback: first player with track metadata
        for (let i = 0; i < mprisPlayers.length; i++) {
            const p = mprisPlayers[i];
            if (p && (p.trackTitle || p.trackArtist)) {
                currentPlayer = p;
                updateToken++;
                return;
            }
        }

        currentPlayer = null;
        updateToken++;
    }

    Component.onCompleted: updateActivePlayer()
    onMprisPlayersChanged: updateActivePlayer()

    Connections {
        target: GlobalStates
        function onOverviewOpenChanged() {
            if (GlobalStates.overviewOpen) {
                root.updateActivePlayer();
            }
        }
    }

    Connections {
        target: root.mediaService
        function onActivePlayerChanged() { root.updateActivePlayer() }
        function onHasMediaChanged() { root.updateActivePlayer() }
        function onTitleChanged() { root.updateActivePlayer() }
        function onArtistChanged() { root.updateActivePlayer() }
        function onArtUrlChanged() { root.updateActivePlayer() }
    }

    Instantiator {
        model: root.mprisPlayers
        delegate: Connections {
            required property var modelData
            target: modelData
            function onIsPlayingChanged() { root.updateActivePlayer() }
            function onTrackTitleChanged() { root.updateActivePlayer() }
            function onTrackArtistChanged() { root.updateActivePlayer() }
            function onTrackArtUrlChanged() { root.updateActivePlayer() }
        }
    }

    readonly property var player: {
        updateToken; // depend on updateToken to recompute
        return currentPlayer;
    }

    readonly property bool hasMedia: player !== null && Boolean(title || artist)
    readonly property string title: {
        updateToken;
        if (mediaService && mediaService.title) return mediaService.title;
        return player?.trackTitle || "";
    }
    readonly property string artist: {
        updateToken;
        if (mediaService && mediaService.artist) return mediaService.artist;
        return player?.trackArtist || player?.identity || "";
    }
    readonly property string album: {
        updateToken;
        return player?.trackAlbum || "";
    }
    readonly property string artUrl: {
        updateToken;
        if (mediaService && mediaService.artUrl) return mediaService.artUrl;
        return player?.trackArtUrl || "";
    }
    readonly property bool isPlaying: {
        updateToken;
        return Boolean(player?.isPlaying);
    }
    readonly property bool canGoPrevious: {
        updateToken;
        return Boolean(player?.canGoPrevious);
    }
    readonly property bool canGoNext: {
        updateToken;
        return Boolean(player?.canGoNext);
    }

    function doPlayPause() {
        if (mediaService) {
            mediaService.runAction("playPause", false);
            updateActivePlayer();
            return;
        }
        if (!player) return;
        if (player.canTogglePlaying) {
            player.togglePlaying();
        } else if (player.isPlaying && player.canPause) {
            player.pause();
        } else if (!player.isPlaying && player.canPlay) {
            player.play();
        }
        updateActivePlayer();
    }

    function doNext() {
        if (mediaService) {
            mediaService.runAction("next", false);
            updateActivePlayer();
            return;
        }
        if (player && player.canGoNext) {
            player.next();
            updateActivePlayer();
        }
    }

    function doPrevious() {
        if (mediaService) {
            mediaService.runAction("previous", false);
            updateActivePlayer();
            return;
        }
        if (player && player.canGoPrevious) {
            player.previous();
            updateActivePlayer();
        }
    }

    function focusPlayerWindow() {
        if (!player) return;
        const ident = String(player.desktopEntry || player.identity || "").toLowerCase();
        const curTitle = String(root.title || "").toLowerCase();

        const windows = HyprlandData.windowList || [];
        for (let i = 0; i < windows.length; i++) {
            const win = windows[i];
            const winClass = String(win.class || "").toLowerCase();
            const winTitle = String(win.title || "").toLowerCase();

            let matches = false;
            if (ident && (winClass.includes(ident) || ident.includes(winClass))) {
                matches = true;
            } else if (curTitle.length > 2 && winTitle.includes(curTitle)) {
                matches = true;
            }

            if (matches) {
                GlobalStates.overviewOpen = false;
                const wsId = win.workspace?.id ?? 1;
                if (Hyprland.usingLua) {
                    Hyprland.dispatch(`hl.dsp.focus({ window = 'address:${win.address}' })`);
                    Hyprland.dispatch(`hl.dsp.focus({ workspace = '${wsId}' })`);
                } else {
                    Hyprland.dispatch(`focuswindow address:${win.address}`);
                    Hyprland.dispatch(`workspace ${wsId}`);
                }
                return;
            }
        }
    }

    implicitHeight: 38
    implicitWidth: hasMedia ? Math.min(320, Math.max(200, layout.implicitWidth + 20)) : 0
    height: 38
    width: implicitWidth

    Behavior on opacity {
        NumberAnimation { duration: 150; easing.type: Easing.OutQuad }
    }
    opacity: hasMedia ? 1.0 : 0.0

    Rectangle {
        id: cardBg
        anchors.fill: parent
        radius: Style.cornerRadius
        color: Color.launcher.background
        // A two-pixel outline keeps the full card edge visible over busy backdrops.
        border.width: Math.max(2, Style.space(2))
        border.color: Color.launcher.border
        clip: true

        RowLayout {
            id: layout
            anchors.fill: parent
            anchors.leftMargin: 6
            anchors.rightMargin: 8
            spacing: 8

            // Album Art or Music Glyph
            Rectangle {
                id: artContainer
                Layout.preferredWidth: 26
                Layout.preferredHeight: 26
                Layout.alignment: Qt.AlignVCenter
                radius: 6
                clip: true
                color: ColorUtils.applyAlpha(Color.launcher.selectedText, 0.12)

                Image {
                    id: albumArt
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    source: root.artUrl
                    visible: status === Image.Ready && source !== ""
                }

                Text {
                    anchors.centerIn: parent
                    visible: !albumArt.visible
                    text: "󰝚"
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 13
                    color: Color.launcher.selectedText
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.focusPlayerWindow()
                }
            }

            // Track details (title and artist)
            Item {
                id: infoContainer
                Layout.fillWidth: true
                Layout.preferredHeight: infoColumn.implicitHeight
                Layout.alignment: Qt.AlignVCenter

                ColumnLayout {
                    id: infoColumn
                    anchors.fill: parent
                    spacing: 1

                    Text {
                        text: root.title
                        font.family: Style.font.family
                        font.pixelSize: 11
                        font.bold: true
                        color: Color.launcher.text
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }

                    Text {
                        text: root.artist
                        font.family: Style.font.family
                        font.pixelSize: 10
                        color: Color.launcher.text
                        opacity: 0.65
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        visible: text.length > 0
                    }
                }

                MouseArea {
                    id: infoMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.focusPlayerWindow()
                }

                StyledToolTip {
                    extraVisibleCondition: false
                    alternativeVisibleCondition: infoMouse.containsMouse
                    text: `${root.title}\n${root.artist}${root.album ? " · " + root.album : ""}`
                }
            }

            // Playback controls
            RowLayout {
                Layout.alignment: Qt.AlignVCenter
                spacing: 2

                // Previous button
                Rectangle {
                    id: prevBtn
                    width: 24
                    height: 24
                    radius: 12
                    color: prevMouse.containsMouse ? ColorUtils.applyAlpha(Color.launcher.selectedText, 0.15) : "transparent"

                    Text {
                        anchors.centerIn: parent
                        text: "󰒮"
                        font.family: "JetBrainsMono Nerd Font"
                        font.pixelSize: 12
                        color: Color.launcher.text
                        opacity: root.canGoPrevious ? 1.0 : 0.35
                    }

                    MouseArea {
                        id: prevMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: root.canGoPrevious ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: root.doPrevious()
                    }
                }

                // Play / Pause button
                Rectangle {
                    id: playBtn
                    width: 26
                    height: 26
                    radius: 13
                    color: playMouse.containsMouse ? Color.launcher.selectedBackground : ColorUtils.applyAlpha(Color.launcher.selectedText, 0.1)

                    Behavior on scale {
                        NumberAnimation { duration: 100 }
                    }
                    scale: playMouse.pressed ? 0.92 : 1.0

                    Text {
                        anchors.centerIn: parent
                        text: root.isPlaying ? "󰏤" : "󰐊"
                        font.family: "JetBrainsMono Nerd Font"
                        font.pixelSize: 13
                        color: playMouse.containsMouse ? Color.launcher.selectedText : Color.launcher.text
                        anchors.horizontalCenterOffset: root.isPlaying ? 0 : 1
                    }

                    MouseArea {
                        id: playMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.doPlayPause()
                    }
                }

                // Next button
                Rectangle {
                    id: nextBtn
                    width: 24
                    height: 24
                    radius: 12
                    color: nextMouse.containsMouse ? ColorUtils.applyAlpha(Color.launcher.selectedText, 0.15) : "transparent"

                    Text {
                        anchors.centerIn: parent
                        text: "󰒭"
                        font.family: "JetBrainsMono Nerd Font"
                        font.pixelSize: 12
                        color: Color.launcher.text
                        opacity: root.canGoNext ? 1.0 : 0.35
                    }

                    MouseArea {
                        id: nextMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: root.canGoNext ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: root.doNext()
                    }
                }
            }
        }

        // Wheel to skip track
        MouseArea {
            anchors.fill: parent
            z: -1
            acceptedButtons: Qt.NoButton
            onWheel: (wheel) => {
                if (wheel.angleDelta.y > 0) root.doPrevious();
                else if (wheel.angleDelta.y < 0) root.doNext();
            }
        }
    }
}
