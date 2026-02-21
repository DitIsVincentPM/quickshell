import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/**
 * Home Assistant sidebar tab.
 * Shows office lights (with toggle) and camera feeds.
 * Configure via Config.options.sidebar.homeAssistant: url, token,
 * lightEntities, cameraEntities, pollInterval.
 */
Item {
    id: root
    property real padding: 8

    // Config shortcuts
    readonly property string haUrl: Config.options.sidebar.homeAssistant.url
    readonly property string haToken: Config.options.sidebar.homeAssistant.token

    // State
    property var lightStates: []   // [{entity_id, friendly_name, state, brightness}]
    property var cameraEntities: [] // [{entity_id, friendly_name}]
    property string errorMessage: ""
    property bool loading: false

    // Helper: build a camera proxy URL for this entity.
    // Note: QML's Image element cannot set custom HTTP headers, so the
    // long-lived access token is passed as a query parameter. HA's camera
    // proxy endpoint explicitly supports this via ?access_token= for clients
    // that cannot set an Authorization header. Users should consider creating
    // a dedicated read-only token for camera access.
    function cameraProxyUrl(entityId) {
        return root.haUrl.replace(/\/$/, "")
            + "/api/camera_proxy/" + entityId
            + "?access_token=" + root.haToken
            + "&t=" + Date.now();
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function apiUrl(path) {
        return root.haUrl.replace(/\/$/, "") + "/api" + path;
    }

    function authHeader() {
        return "Bearer " + root.haToken;
    }

    /** Fetch all entity states and populate lightStates / cameraEntities. */
    function fetchStates() {
        if (root.haToken.length === 0 || root.haUrl.length === 0) {
            root.errorMessage = qsTr("Configure Home Assistant URL and token in config.");
            return;
        }
        root.loading = true;
        root.errorMessage = "";
        var xhr = new XMLHttpRequest();
        xhr.open("GET", root.apiUrl("/states"));
        xhr.setRequestHeader("Authorization", root.authHeader());
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            root.loading = false;
            if (xhr.status === 200) {
                try {
                    var all = JSON.parse(xhr.responseText);
                    var lights = [];
                    var cameras = [];
                    var cfgLights = Config.options.sidebar.homeAssistant.lightEntities;
                    var cfgCams  = Config.options.sidebar.homeAssistant.cameraEntities;
                    for (var i = 0; i < all.length; i++) {
                        var entity = all[i];
                        var eid = entity.entity_id;
                        if (eid.startsWith("light.")) {
                            if (cfgLights.length === 0 || cfgLights.indexOf(eid) !== -1) {
                                lights.push({
                                    entity_id: eid,
                                    friendly_name: (entity.attributes && entity.attributes.friendly_name) ? entity.attributes.friendly_name : eid,
                                    state: entity.state,
                                    brightness: (entity.attributes && entity.attributes.brightness != null) ? Math.round(entity.attributes.brightness / 255 * 100) : 0
                                });
                            }
                        } else if (eid.startsWith("camera.")) {
                            if (cfgCams.length === 0 || cfgCams.indexOf(eid) !== -1) {
                                cameras.push({
                                    entity_id: eid,
                                    friendly_name: (entity.attributes && entity.attributes.friendly_name) ? entity.attributes.friendly_name : eid
                                });
                            }
                        }
                    }
                    lights.sort(function(a, b) { return a.friendly_name.localeCompare(b.friendly_name); });
                    cameras.sort(function(a, b) { return a.friendly_name.localeCompare(b.friendly_name); });
                    root.lightStates = lights;
                    root.cameraEntities = cameras;
                } catch (e) {
                    root.errorMessage = qsTr("Failed to parse response: ") + e;
                }
            } else if (xhr.status === 401) {
                root.errorMessage = qsTr("Unauthorized – check your access token.");
            } else {
                root.errorMessage = qsTr("Request failed (HTTP %1).").arg(xhr.status);
            }
        };
        xhr.send();
    }

    /** Toggle a light entity on/off. */
    function toggleLight(entityId, currentState) {
        var service = (currentState === "on") ? "turn_off" : "turn_on";
        var xhr = new XMLHttpRequest();
        xhr.open("POST", root.apiUrl("/services/light/" + service));
        xhr.setRequestHeader("Authorization", root.authHeader());
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                if (xhr.status === 200 || xhr.status === 201) {
                    root.fetchStates();
                } else {
                    root.errorMessage = qsTr("Failed to control light (HTTP %1).").arg(xhr.status);
                }
            }
        };
        xhr.send(JSON.stringify({ entity_id: entityId }));
    }

    // -----------------------------------------------------------------------
    // Auto-poll
    // -----------------------------------------------------------------------

    Timer {
        id: pollTimer
        interval: Config.options.sidebar.homeAssistant.pollInterval
        running: root.haToken.length > 0
        repeat: true
        triggeredOnStart: true
        onTriggered: root.fetchStates()
    }

    onHaTokenChanged: {
        if (root.haToken.length > 0) root.fetchStates();
    }
    onHaUrlChanged: {
        if (root.haToken.length > 0) root.fetchStates();
    }

    // -----------------------------------------------------------------------
    // UI
    // -----------------------------------------------------------------------

    ColumnLayout {
        anchors {
            fill: parent
            margins: root.padding
        }
        spacing: root.padding

        // Error / empty state
        StyledText {
            visible: root.errorMessage.length > 0
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: root.errorMessage
            color: Appearance.colors.colError
        }

        // Loading indicator
        StyledText {
            visible: root.loading && root.errorMessage.length === 0
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("Loading…")
            color: Appearance.colors.colSubtext
        }

        // Token not configured
        StyledText {
            visible: root.haToken.length === 0 && !root.loading && root.errorMessage.length === 0
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("Set sidebar.homeAssistant.token in your config to connect.")
            color: Appearance.colors.colSubtext
        }

        // ── Lights section ────────────────────────────────────────────────
        StyledText {
            visible: root.lightStates.length > 0
            text: qsTr("Lights")
            font.pixelSize: Appearance.font.pixelSize.normal
            color: Appearance.colors.colOnLayer1
        }

        StyledFlickable {
            id: lightsFlickable
            visible: root.lightStates.length > 0
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(lightsColumn.implicitHeight, 220)
            contentHeight: lightsColumn.implicitHeight
            clip: true

            ColumnLayout {
                id: lightsColumn
                width: lightsFlickable.width
                spacing: 4

                Repeater {
                    model: root.lightStates

                    delegate: Rectangle {
                        id: lightRow
                        required property var modelData
                        Layout.fillWidth: true
                        implicitWidth: lightsColumn.width
                        implicitHeight: lightRowLayout.implicitHeight + 12
                        radius: Appearance.rounding.small
                        color: lightRow.modelData.state === "on"
                               ? Qt.rgba(Appearance.colors.colPrimary.r, Appearance.colors.colPrimary.g, Appearance.colors.colPrimary.b, 0.18)
                               : Appearance.colors.colLayer2

                        Behavior on color {
                            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                        }

                        RowLayout {
                            id: lightRowLayout
                            anchors {
                                verticalCenter: parent.verticalCenter
                                left: parent.left
                                right: parent.right
                                margins: 8
                            }
                            spacing: 8

                            MaterialSymbol {
                                text: lightRow.modelData.state === "on" ? "lightbulb" : "lightbulb_outline"
                                iconSize: Appearance.font.pixelSize.larger
                                color: lightRow.modelData.state === "on"
                                       ? Appearance.colors.colPrimary
                                       : Appearance.colors.colSubtext
                            }

                            StyledText {
                                Layout.fillWidth: true
                                text: lightRow.modelData.friendly_name
                                elide: Text.ElideRight
                                color: Appearance.colors.colOnLayer1
                            }

                            StyledText {
                                visible: lightRow.modelData.state === "on" && lightRow.modelData.brightness > 0
                                text: lightRow.modelData.brightness + "%"
                                color: Appearance.colors.colSubtext
                                font.pixelSize: Appearance.font.pixelSize.small
                            }

                            StyledSwitch {
                                checked: lightRow.modelData.state === "on"
                                onClicked: root.toggleLight(lightRow.modelData.entity_id, lightRow.modelData.state)
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleLight(lightRow.modelData.entity_id, lightRow.modelData.state)
                        }
                    }
                }
            }
        }

        // ── Cameras section ───────────────────────────────────────────────
        StyledText {
            visible: root.cameraEntities.length > 0
            text: qsTr("Cameras")
            font.pixelSize: Appearance.font.pixelSize.normal
            color: Appearance.colors.colOnLayer1
        }

        Repeater {
            model: root.cameraEntities

            delegate: ColumnLayout {
                id: cameraDelegate
                required property var modelData
                Layout.fillWidth: true
                spacing: 4

                StyledText {
                    text: cameraDelegate.modelData.friendly_name
                    color: Appearance.colors.colSubtext
                    font.pixelSize: Appearance.font.pixelSize.small
                }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: width * 9 / 16
                    radius: Appearance.rounding.small
                    color: Appearance.colors.colLayer2
                    clip: true

                    Image {
                        id: cameraImage
                        anchors.fill: parent
                        fillMode: Image.PreserveAspectFit
                        cache: false

                        // HA camera_proxy accepts ?access_token= for clients that
                        // cannot set Authorization headers (such as QML Image).
                        source: root.haToken.length > 0
                            ? root.cameraProxyUrl(cameraDelegate.modelData.entity_id)
                            : ""

                        Timer {
                            interval: Config.options.sidebar.homeAssistant.pollInterval
                            running: root.haToken.length > 0
                            repeat: true
                            onTriggered: {
                                cameraImage.source = "";
                                cameraImage.source = root.cameraProxyUrl(cameraDelegate.modelData.entity_id);
                            }
                        }
                    }

                    StyledText {
                        anchors.centerIn: parent
                        visible: cameraImage.status !== Image.Ready
                        text: cameraImage.status === Image.Loading ? qsTr("Loading…") : qsTr("No feed")
                        color: Appearance.colors.colSubtext
                    }
                }
            }
        }

        // Spacer
        Item { Layout.fillHeight: true }
    }
}
