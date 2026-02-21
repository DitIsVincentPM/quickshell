import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/**
 * Home Assistant sidebar tab.
 * Shows light bubbles (with brightness/colour) and camera feeds.
 * An edit mode lets the user pick which entities are visible.
 * Configure via Config.options.sidebar.homeAssistant.
 */
Item {
    id: root
    property real padding: 8

    // Config shortcuts
    readonly property string haUrl: Config.options.sidebar.homeAssistant.url
    readonly property string haToken: Config.options.sidebar.homeAssistant.token
    readonly property bool cfgShowBrightness: Config.options.sidebar.homeAssistant.showBrightness
    readonly property bool cfgShowColor: Config.options.sidebar.homeAssistant.showColor
    readonly property bool cfgShowCameras: Config.options.sidebar.homeAssistant.showCameras
    readonly property bool cfgShowClimate: Config.options.sidebar.homeAssistant.showClimate

    // State
    property bool editMode: false
    // All discovered entities (populated by fetchStates)
    property var allLights: []    // [{entity_id, friendly_name, state, brightness, color_temp, hs_color}]
    property var allCameras: []   // [{entity_id, friendly_name, visible}]
    property var allClimate: []   // [{entity_id, friendly_name, state, current_temp, target_temp, min_temp, max_temp, hvac_modes}]
    property string errorMessage: ""
    property bool loading: false

    // Derived: only the entities the user chose to show (empty visibleEntities = show all)
    property var visibleEntities: Config.options.sidebar.homeAssistant.visibleEntities

    // Lights sorted by entityOrder config (falls back to alphabetical)
    readonly property var orderedLights: {
        var order = Config.options.sidebar.homeAssistant.entityOrder;
        var lights = root.allLights.slice();
        if (order.length === 0) return lights;
        lights.sort(function(a, b) {
            var ai = order.indexOf(a.entity_id);
            var bi = order.indexOf(b.entity_id);
            if (ai === -1) ai = 1e9;
            if (bi === -1) bi = 1e9;
            if (ai !== bi) return ai - bi;
            return a.friendly_name.localeCompare(b.friendly_name);
        });
        return lights;
    }

    // Sections for the normal view: either one section per configured group + one "Other"
    // section for ungrouped lights, or a single unnamed section with all lights.
    readonly property var lightSections: {
        var groups = Config.options.sidebar.homeAssistant.entityGroups;
        var lights = root.orderedLights;
        if (!groups || groups.length === 0) {
            return [{ name: "", lights: lights }];
        }
        var used = {};
        var sections = [];
        for (var g = 0; g < groups.length; g++) {
            var grp = groups[g];
            var grpLights = [];
            for (var e = 0; e < (grp.entities || []).length; e++) {
                var eid = grp.entities[e];
                used[eid] = true;
                for (var li = 0; li < lights.length; li++) {
                    if (lights[li].entity_id === eid) { grpLights.push(lights[li]); break; }
                }
            }
            sections.push({ name: grp.name || "", lights: grpLights });
        }
        // Ungrouped lights
        var others = [];
        for (var li2 = 0; li2 < lights.length; li2++) {
            if (!used[lights[li2].entity_id]) others.push(lights[li2]);
        }
        if (others.length > 0) sections.push({ name: qsTr("Other"), lights: others });
        return sections;
    }

    function isEntityVisible(eid) {
        if (root.visibleEntities.length === 0) return true;
        return root.visibleEntities.indexOf(eid) !== -1;
    }

    function setEntityVisible(eid, visible) {
        var current = Config.options.sidebar.homeAssistant.visibleEntities.slice();
        // If list is empty = "show all", seed it with everything minus the one being hidden
        if (current.length === 0 && !visible) {
            var all = root.allLights.concat(root.allCameras).concat(root.allClimate).map(function(e){ return e.entity_id; });
            current = all.filter(function(id){ return id !== eid; });
        } else {
            var idx = current.indexOf(eid);
            if (visible && idx === -1) current.push(eid);
            else if (!visible && idx !== -1) current.splice(idx, 1);
        }
        Config.options.sidebar.homeAssistant.visibleEntities = current;
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

    function cameraProxyUrl(entityId) {
        return root.haUrl.replace(/\/$/, "")
            + "/api/camera_proxy/" + entityId
            + "?access_token=" + root.haToken
            + "&t=" + Date.now();
    }

    /** Fetch all entity states. */
    function fetchStates() {
        if (root.haToken.length === 0 || root.haUrl.length === 0) {
            root.errorMessage = qsTr("Configure Home Assistant URL and token in settings.");
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
                    var climates = [];
                    var cfgLights = Config.options.sidebar.homeAssistant.lightEntities;
                    var cfgCams  = Config.options.sidebar.homeAssistant.cameraEntities;
                    var cfgClimates = Config.options.sidebar.homeAssistant.climateEntities;
                    for (var i = 0; i < all.length; i++) {
                        var entity = all[i];
                        var eid = entity.entity_id;
                        var attrs = entity.attributes || {};
                        if (eid.startsWith("light.")) {
                            if (cfgLights.length === 0 || cfgLights.indexOf(eid) !== -1) {
                                lights.push({
                                    entity_id: eid,
                                    friendly_name: attrs.friendly_name || eid,
                                    state: entity.state,
                                    brightness: attrs.brightness != null ? Math.round(attrs.brightness / 255 * 100) : 0,
                                    supports_color: attrs.supported_color_modes
                                        ? (attrs.supported_color_modes.indexOf("hs") !== -1 || attrs.supported_color_modes.indexOf("rgb") !== -1)
                                        : false,
                                    supports_brightness: attrs.supported_color_modes
                                        ? attrs.supported_color_modes.indexOf("onoff") === -1
                                        : true,
                                    hs_color: attrs.hs_color || null
                                });
                            }
                        } else if (eid.startsWith("camera.")) {
                            if (cfgCams.length === 0 || cfgCams.indexOf(eid) !== -1) {
                                cameras.push({
                                    entity_id: eid,
                                    friendly_name: attrs.friendly_name || eid
                                });
                            }
                        } else if (eid.startsWith("climate.")) {
                            if (cfgClimates.length === 0 || cfgClimates.indexOf(eid) !== -1) {
                                var hvacModes = attrs.hvac_modes || [];
                                var nonOffModes = hvacModes.filter(function(m) { return m !== "off"; });
                                var heatMode = hvacModes.indexOf("heat") !== -1 ? "heat"
                                    : nonOffModes.length > 0 ? nonOffModes[0] : null;
                                if (heatMode === null) continue; // device only supports off — skip
                                climates.push({
                                    entity_id: eid,
                                    friendly_name: attrs.friendly_name || eid,
                                    state: entity.state,
                                    current_temp: attrs.current_temperature != null ? attrs.current_temperature : null,
                                    target_temp: attrs.temperature != null ? attrs.temperature : 20,
                                    min_temp: attrs.min_temp != null ? attrs.min_temp : 7,
                                    max_temp: attrs.max_temp != null ? attrs.max_temp : 35,
                                    heat_mode: heatMode
                                });
                            }
                        }
                    }
                    lights.sort(function(a, b) { return a.friendly_name.localeCompare(b.friendly_name); });
                    cameras.sort(function(a, b) { return a.friendly_name.localeCompare(b.friendly_name); });
                    climates.sort(function(a, b) { return a.friendly_name.localeCompare(b.friendly_name); });
                    root.allLights = lights;
                    root.allCameras = cameras;
                    root.allClimate = climates;
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
        // Optimistic update – keep new state immediately; poll timer will sync later
        var newState = (currentState === "on") ? "off" : "on";
        var updated = root.allLights.slice();
        for (var i = 0; i < updated.length; i++) {
            if (updated[i].entity_id === entityId) {
                var copy = Object.assign({}, updated[i]);
                copy.state = newState;
                updated[i] = copy;
                break;
            }
        }
        root.allLights = updated;
        var xhr = new XMLHttpRequest();
        var svc = (currentState === "on") ? "turn_off" : "turn_on";
        xhr.open("POST", root.apiUrl("/services/light/" + svc));
        xhr.setRequestHeader("Authorization", root.authHeader());
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                if (xhr.status !== 200 && xhr.status !== 201)
                    root.errorMessage = qsTr("Failed to control light (HTTP %1).").arg(xhr.status);
            }
        };
        xhr.send(JSON.stringify({ entity_id: entityId }));
    }

    /** Set brightness for a light (0–100). */
    function setLightBrightness(entityId, pct) {
        // Optimistic update
        var updated = root.allLights.slice();
        for (var i = 0; i < updated.length; i++) {
            if (updated[i].entity_id === entityId) {
                var copy = Object.assign({}, updated[i]);
                copy.brightness = pct;
                updated[i] = copy;
                break;
            }
        }
        root.allLights = updated;
        var xhr = new XMLHttpRequest();
        xhr.open("POST", root.apiUrl("/services/light/turn_on"));
        xhr.setRequestHeader("Authorization", root.authHeader());
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.send(JSON.stringify({ entity_id: entityId, brightness_pct: pct }));
    }

    /** Set hue/saturation colour for a light (hue 0-360, sat 0-100). */
    function setLightColor(entityId, hue, sat) {
        // Optimistic update
        var updated = root.allLights.slice();
        for (var i = 0; i < updated.length; i++) {
            if (updated[i].entity_id === entityId) {
                var copy = Object.assign({}, updated[i]);
                copy.hs_color = [hue, sat];
                updated[i] = copy;
                break;
            }
        }
        root.allLights = updated;
        var xhr = new XMLHttpRequest();
        xhr.open("POST", root.apiUrl("/services/light/turn_on"));
        xhr.setRequestHeader("Authorization", root.authHeader());
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.send(JSON.stringify({ entity_id: entityId, hs_color: [hue, sat] }));
    }

    /** Toggle a climate entity on/off. */
    function toggleClimate(entityId, currentState, heatMode) {
        var newState = (currentState !== "off") ? "off" : (heatMode || "heat");
        var updated = root.allClimate.slice();
        for (var i = 0; i < updated.length; i++) {
            if (updated[i].entity_id === entityId) {
                var copy = Object.assign({}, updated[i]);
                copy.state = newState;
                updated[i] = copy;
                break;
            }
        }
        root.allClimate = updated;
        var xhr = new XMLHttpRequest();
        xhr.open("POST", root.apiUrl("/services/climate/set_hvac_mode"));
        xhr.setRequestHeader("Authorization", root.authHeader());
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                if (xhr.status !== 200 && xhr.status !== 201)
                    root.errorMessage = qsTr("Failed to control climate (HTTP %1).").arg(xhr.status);
            }
        };
        xhr.send(JSON.stringify({ entity_id: entityId, hvac_mode: newState }));
    }

    /** Set target temperature for a climate entity. */
    function setClimateTemperature(entityId, temp) {
        var updated = root.allClimate.slice();
        for (var i = 0; i < updated.length; i++) {
            if (updated[i].entity_id === entityId) {
                var copy = Object.assign({}, updated[i]);
                copy.target_temp = temp;
                updated[i] = copy;
                break;
            }
        }
        root.allClimate = updated;
        var xhr = new XMLHttpRequest();
        xhr.open("POST", root.apiUrl("/services/climate/set_temperature"));
        xhr.setRequestHeader("Authorization", root.authHeader());
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                if (xhr.status !== 200 && xhr.status !== 201)
                    root.errorMessage = qsTr("Failed to set temperature (HTTP %1).").arg(xhr.status);
            }
        };
        xhr.send(JSON.stringify({ entity_id: entityId, temperature: temp }));
    }

    /** Move an entity up/down in the custom order. */
    function moveEntity(entityId, direction) {
        var order = Config.options.sidebar.homeAssistant.entityOrder.slice();
        // Seed order from lights only (cameras are not reorderable)
        if (order.length === 0) {
            order = root.allLights.map(function(e) { return e.entity_id; });
        }
        var idx = order.indexOf(entityId);
        if (idx === -1) {
            order.push(entityId);
            idx = order.length - 1;
        }
        var newIdx = idx + direction;
        if (newIdx < 0 || newIdx >= order.length) return;
        var tmp = order[idx];
        order[idx] = order[newIdx];
        order[newIdx] = tmp;
        Config.options.sidebar.homeAssistant.entityOrder = order;
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

    onHaTokenChanged: { if (root.haToken.length > 0) root.fetchStates(); }
    onHaUrlChanged:   { if (root.haToken.length > 0) root.fetchStates(); }

    // -----------------------------------------------------------------------
    // UI
    // -----------------------------------------------------------------------

    ColumnLayout {
        anchors {
            fill: parent
            margins: root.padding
        }
        spacing: root.padding

        // ── Header row (title + edit button) ──────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 4

            StyledText {
                Layout.fillWidth: true
                text: root.editMode ? qsTr("Edit entities") : qsTr("Home")
                font.pixelSize: Appearance.font.pixelSize.normal
                color: Appearance.colors.colOnLayer1
            }

            // Refresh button
            RippleButton {
                visible: !root.editMode
                implicitWidth: 32
                implicitHeight: 32
                buttonRadius: Appearance.rounding.full
                onClicked: root.fetchStates()
                contentItem: MaterialSymbol {
                    anchors.centerIn: parent
                    text: "refresh"
                    iconSize: Appearance.font.pixelSize.larger
                    color: Appearance.colors.colSubtext
                }
            }

            // Edit / done button
            RippleButton {
                implicitWidth: 32
                implicitHeight: 32
                buttonRadius: Appearance.rounding.full
                toggled: root.editMode
                onClicked: root.editMode = !root.editMode
                contentItem: MaterialSymbol {
                    anchors.centerIn: parent
                    text: root.editMode ? "check" : "edit"
                    iconSize: Appearance.font.pixelSize.larger
                    color: root.editMode ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                }
            }
        }

        // ── Error ─────────────────────────────────────────────────────────
        StyledText {
            visible: root.errorMessage.length > 0
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: root.errorMessage
            color: Appearance.colors.colError
        }

        // ── Loading ───────────────────────────────────────────────────────
        StyledText {
            id: loadingText
            Layout.fillWidth: true
            opacity: (root.loading && root.errorMessage.length === 0) ? 1.0 : 0.0
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("Fetching…")
            color: Appearance.colors.colSubtext
            Behavior on opacity {
                NumberAnimation { duration: 150 }
            }
        }

        // ── Token not set ─────────────────────────────────────────────────
        StyledText {
            visible: root.haToken.length === 0 && !root.loading && root.errorMessage.length === 0
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("Set sidebar.homeAssistant.token in settings to connect.")
            color: Appearance.colors.colSubtext
        }

        // ── Main scrollable content ───────────────────────────────────────
        StyledFlickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: mainColumn.implicitHeight
            clip: true

            ColumnLayout {
                id: mainColumn
                width: parent.width
                spacing: root.padding

                // ── EDIT MODE: list all entities with visibility toggles + reorder ──
                Repeater {
                    model: root.editMode ? root.allClimate.concat(root.orderedLights).concat(root.allCameras) : []
                    delegate: Rectangle {
                        id: editRow
                        required property var modelData
                        required property int index
                        Layout.fillWidth: true
                        implicitWidth: mainColumn.width
                        implicitHeight: editRowLayout.implicitHeight + 12
                        radius: Appearance.rounding.small
                        color: Appearance.colors.colLayer2

                        RowLayout {
                            id: editRowLayout
                            anchors {
                                verticalCenter: parent.verticalCenter
                                left: parent.left
                                right: parent.right
                                margins: 10
                            }
                            spacing: 8

                            // Up / Down reorder buttons (lights only)
                            ColumnLayout {
                                visible: editRow.modelData.entity_id.startsWith("light.")
                                spacing: 0
                                RippleButton {
                                    implicitWidth: 22
                                    implicitHeight: 18
                                    buttonRadius: Appearance.rounding.small
                                    onClicked: root.moveEntity(editRow.modelData.entity_id, -1)
                                    contentItem: MaterialSymbol {
                                        anchors.centerIn: parent
                                        text: "arrow_drop_up"
                                        iconSize: Appearance.font.pixelSize.normal
                                        color: Appearance.colors.colSubtext
                                    }
                                }
                                RippleButton {
                                    implicitWidth: 22
                                    implicitHeight: 18
                                    buttonRadius: Appearance.rounding.small
                                    onClicked: root.moveEntity(editRow.modelData.entity_id, 1)
                                    contentItem: MaterialSymbol {
                                        anchors.centerIn: parent
                                        text: "arrow_drop_down"
                                        iconSize: Appearance.font.pixelSize.normal
                                        color: Appearance.colors.colSubtext
                                    }
                                }
                            }

                            MaterialSymbol {
                                text: editRow.modelData.entity_id.startsWith("light.")
                                    ? "lightbulb"
                                    : editRow.modelData.entity_id.startsWith("climate.")
                                        ? "thermostat"
                                        : "videocam"
                                iconSize: Appearance.font.pixelSize.larger
                                color: Appearance.colors.colSubtext
                            }
                            StyledText {
                                Layout.fillWidth: true
                                text: editRow.modelData.friendly_name
                                elide: Text.ElideRight
                                color: Appearance.colors.colOnLayer1
                            }
                            StyledSwitch {
                                checked: root.isEntityVisible(editRow.modelData.entity_id)
                                onClicked: root.setEntityVisible(editRow.modelData.entity_id, !root.isEntityVisible(editRow.modelData.entity_id))
                            }
                        }
                    }
                }

                // ── NORMAL MODE: Climate / Heater cards (shown at the top) ──────
                Repeater {
                    model: (!root.editMode && root.cfgShowClimate)
                        ? root.allClimate.filter(function(e) { return root.isEntityVisible(e.entity_id); })
                        : []
                    delegate: ClimateCard {
                        required property var modelData
                        Layout.fillWidth: true
                        entityData: modelData
                        onToggleRequested: root.toggleClimate(modelData.entity_id, modelData.state, modelData.heat_mode)
                        onTemperatureRequested: (temp) => root.setClimateTemperature(modelData.entity_id, temp)
                    }
                }

                // ── NORMAL MODE: Lights grouped by section ───────────────────────
                Repeater {
                    model: root.editMode ? [] : root.lightSections
                    delegate: ColumnLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: root.padding / 2

                        // Group header (only shown when name is non-empty)
                        StyledText {
                            visible: modelData.name.length > 0
                            text: modelData.name
                            font.pixelSize: Appearance.font.pixelSize.small
                            color: Appearance.colors.colSubtext
                            Layout.topMargin: root.padding / 2
                        }

                        GridLayout {
                            Layout.fillWidth: true
                            columns: 2
                            columnSpacing: root.padding / 2
                            rowSpacing: root.padding / 2

                            Repeater {
                                // Only include visible entities so hidden ones don't create empty grid cells
                                model: modelData.lights.filter(function(e) { return root.isEntityVisible(e.entity_id); })
                                delegate: LightBubble {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    Layout.alignment: Qt.AlignTop
                                    entityData: modelData
                                    showBrightness: root.cfgShowBrightness
                                    showColor: root.cfgShowColor
                                    onToggleRequested: root.toggleLight(modelData.entity_id, modelData.state)
                                    onBrightnessRequested: (pct) => root.setLightBrightness(modelData.entity_id, pct)
                                    onColorRequested: (h, s) => root.setLightColor(modelData.entity_id, h, s)
                                }
                            }
                        }
                    }
                }

                // ── NORMAL MODE: Cameras ─────────────────────────────────
                ColumnLayout {
                    visible: !root.editMode && root.cfgShowCameras && root.allCameras.length > 0
                    Layout.fillWidth: true
                    spacing: root.padding

                    StyledText {
                        text: qsTr("Cameras")
                        font.pixelSize: Appearance.font.pixelSize.normal
                        color: Appearance.colors.colOnLayer1
                    }

                    Repeater {
                        model: root.allCameras
                        delegate: ColumnLayout {
                            id: camDelegate
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: 4
                            visible: root.isEntityVisible(camDelegate.modelData.entity_id)

                            StyledText {
                                text: camDelegate.modelData.friendly_name
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
                                    id: camImage
                                    anchors.fill: parent
                                    fillMode: Image.PreserveAspectCrop
                                    cache: false
                                    asynchronous: true
                                    // Use access_token query param – supported by HA camera_proxy
                                    source: root.haToken.length > 0 && root.isEntityVisible(camDelegate.modelData.entity_id)
                                        ? root.cameraProxyUrl(camDelegate.modelData.entity_id)
                                        : ""

                                    Timer {
                                        interval: Config.options.sidebar.homeAssistant.pollInterval
                                        running: root.haToken.length > 0 && root.isEntityVisible(camDelegate.modelData.entity_id)
                                        repeat: true
                                        onTriggered: {
                                            var u = root.cameraProxyUrl(camDelegate.modelData.entity_id);
                                            camImage.source = "";
                                            camImage.source = u;
                                        }
                                    }
                                }

                                StyledText {
                                    anchors.centerIn: parent
                                    visible: camImage.status !== Image.Ready
                                    text: camImage.status === Image.Loading
                                        ? qsTr("Loading…")
                                        : qsTr("No feed")
                                    color: Appearance.colors.colSubtext
                                }
                            }
                        }
                    }
                }

                // Spacer
                Item { implicitHeight: root.padding }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Light bubble component
    // -----------------------------------------------------------------------
    component LightBubble: Rectangle {
        id: bubble

        property var entityData: ({})
        property bool showBrightness: true
        property bool showColor: true

        signal toggleRequested()
        signal brightnessRequested(real pct)
        signal colorRequested(real hue, real sat)

        readonly property bool isOn: entityData.state === "on"
        readonly property color activeColor: Qt.hsla(
            (entityData.hs_color ? entityData.hs_color[0] / 360 : 0.1),
            (entityData.hs_color ? entityData.hs_color[1] / 100 * 0.7 : 0.7),
            0.5, 1.0)

        radius: Appearance.rounding.normal
        color: bubble.isOn
            ? Qt.rgba(bubble.activeColor.r, bubble.activeColor.g, bubble.activeColor.b, 0.22)
            : Appearance.colors.colLayer2
        implicitHeight: bubbleCol.implicitHeight + 16

        Behavior on color {
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
        }

        // Tap the whole card to toggle
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: bubble.toggleRequested()
        }

        ColumnLayout {
            id: bubbleCol
            anchors {
                left: parent.left
                right: parent.right
                verticalCenter: parent.verticalCenter
                margins: 8
            }
            spacing: 6

            // Top row: icon  name  brightness%  switch
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                MaterialSymbol {
                    text: bubble.isOn ? "lightbulb" : "lightbulb_outline"
                    iconSize: Appearance.font.pixelSize.larger
                    fill: bubble.isOn ? 1 : 0
                    color: bubble.isOn ? bubble.activeColor : Appearance.colors.colSubtext

                    Behavior on color {
                        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    text: bubble.entityData.friendly_name || ""
                    elide: Text.ElideRight
                    color: Appearance.colors.colOnLayer1
                }

                StyledText {
                    visible: bubble.isOn && bubble.entityData.brightness > 0
                    text: (bubble.entityData.brightness || 0) + "%"
                    color: Appearance.colors.colSubtext
                    font.pixelSize: Appearance.font.pixelSize.small
                }

                StyledSwitch {
                    checked: bubble.isOn
                    onClicked: bubble.toggleRequested()
                }
            }

            // Brightness slider
            Loader {
                active: bubble.showBrightness && bubble.isOn && bubble.entityData.supports_brightness
                Layout.fillWidth: true
                sourceComponent: RowLayout {
                    spacing: 6
                    MaterialSymbol {
                        text: "brightness_medium"
                        iconSize: Appearance.font.pixelSize.small
                        color: Appearance.colors.colSubtext
                    }
                    StyledSlider {
                        Layout.fillWidth: true
                        from: 1
                        to: 100
                        value: bubble.entityData.brightness || 1
                        configuration: StyledSlider.Configuration.XS
                        onPressedChanged: {
                            if (!pressed) bubble.brightnessRequested(Math.round(value));
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onPressed: (e) => e.accepted = false
                        }
                    }
                }
            }

            // Colour picker (hue + saturation gradient strips)
            Loader {
                active: bubble.showColor && bubble.isOn && bubble.entityData.supports_color
                Layout.fillWidth: true
                sourceComponent: ColumnLayout {
                    spacing: 5

                    // Hue strip
                    Rectangle {
                        id: hueStrip
                        Layout.fillWidth: true
                        height: 14
                        radius: height / 2
                        clip: true

                        // Local drag state (0–1); syncs from entityData when not dragging
                        property real hue: bubble.entityData.hs_color
                            ? bubble.entityData.hs_color[0] / 360
                            : 0

                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0/6; color: Qt.hsla(0/6, 1, 0.5, 1) }
                            GradientStop { position: 1/6; color: Qt.hsla(1/6, 1, 0.5, 1) }
                            GradientStop { position: 2/6; color: Qt.hsla(2/6, 1, 0.5, 1) }
                            GradientStop { position: 3/6; color: Qt.hsla(3/6, 1, 0.5, 1) }
                            GradientStop { position: 4/6; color: Qt.hsla(4/6, 1, 0.5, 1) }
                            GradientStop { position: 5/6; color: Qt.hsla(5/6, 1, 0.5, 1) }
                            GradientStop { position: 6/6; color: Qt.hsla(0, 1, 0.5, 1) }
                        }

                        // Handle
                        Rectangle {
                            x: Math.max(0, Math.min(hueStrip.width - width, hueStrip.hue * hueStrip.width - width / 2))
                            anchors.verticalCenter: parent.verticalCenter
                            width: 6
                            height: parent.height + 4
                            radius: Appearance.rounding.full
                            color: "white"
                            border.width: 1.5
                            border.color: Qt.rgba(0, 0, 0, 0.4)
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            function applyX(x) {
                                hueStrip.hue = Math.max(0, Math.min(1, x / hueStrip.width));
                            }
                            onPressed:          (e) => applyX(e.x)
                            onPositionChanged:  (e) => { if (pressed) applyX(e.x) }
                            onReleased: {
                                bubble.colorRequested(
                                    Math.round(hueStrip.hue * 360),
                                    bubble.entityData.hs_color ? bubble.entityData.hs_color[1] : 85
                                );
                            }
                        }
                    }

                    // Saturation strip
                    Rectangle {
                        id: satStrip
                        Layout.fillWidth: true
                        height: 14
                        radius: height / 2
                        clip: true

                        // Local drag state (0–1); syncs from entityData when not dragging
                        property real sat: bubble.entityData.hs_color
                            ? bubble.entityData.hs_color[1] / 100
                            : 0.85
                        readonly property real hue: bubble.entityData.hs_color
                            ? bubble.entityData.hs_color[0] / 360
                            : hueStrip.hue

                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: Qt.hsla(satStrip.hue, 0,    0.8, 1) }
                            GradientStop { position: 1.0; color: Qt.hsla(satStrip.hue, 1,    0.5, 1) }
                        }

                        // Handle
                        Rectangle {
                            x: Math.max(0, Math.min(satStrip.width - width, satStrip.sat * satStrip.width - width / 2))
                            anchors.verticalCenter: parent.verticalCenter
                            width: 6
                            height: parent.height + 4
                            radius: Appearance.rounding.full
                            color: "white"
                            border.width: 1.5
                            border.color: Qt.rgba(0, 0, 0, 0.4)
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            function applyX(x) {
                                satStrip.sat = Math.max(0, Math.min(1, x / satStrip.width));
                            }
                            onPressed:          (e) => applyX(e.x)
                            onPositionChanged:  (e) => { if (pressed) applyX(e.x) }
                            onReleased: {
                                bubble.colorRequested(
                                    bubble.entityData.hs_color ? bubble.entityData.hs_color[0] : Math.round(hueStrip.hue * 360),
                                    Math.round(satStrip.sat * 100)
                                );
                            }
                        }
                    }
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Climate / heater card component
    // -----------------------------------------------------------------------
    component ClimateCard: Rectangle {
        id: climateCard

        property var entityData: ({})

        signal toggleRequested()
        signal temperatureRequested(real temp)

        readonly property bool isOn: entityData.state !== "off" && entityData.state !== undefined
        readonly property color warmColor: Qt.hsla(0.07, 0.9, 0.55, 1.0)  // orange-amber

        radius: Appearance.rounding.normal
        color: climateCard.isOn
            ? Qt.rgba(warmColor.r, warmColor.g, warmColor.b, 0.18)
            : Appearance.colors.colLayer2
        implicitHeight: climateCol.implicitHeight + 16

        Behavior on color {
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
        }

        ColumnLayout {
            id: climateCol
            anchors {
                left: parent.left
                right: parent.right
                verticalCenter: parent.verticalCenter
                margins: 10
            }
            spacing: 8

            // Top row: flame icon  name  current temp  switch
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                MaterialSymbol {
                    text: climateCard.isOn ? "local_fire_department" : "thermostat"
                    iconSize: Appearance.font.pixelSize.larger
                    fill: climateCard.isOn ? 1 : 0
                    color: climateCard.isOn ? climateCard.warmColor : Appearance.colors.colSubtext

                    Behavior on color {
                        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    text: climateCard.entityData.friendly_name || ""
                    elide: Text.ElideRight
                    color: Appearance.colors.colOnLayer1
                }

                // Current temperature badge (if available)
                StyledText {
                    visible: climateCard.entityData.current_temp != null
                    text: climateCard.entityData.current_temp != null
                        ? climateCard.entityData.current_temp.toFixed(1) + "°"
                        : ""
                    color: Appearance.colors.colSubtext
                    font.pixelSize: Appearance.font.pixelSize.small
                }

                StyledSwitch {
                    checked: climateCard.isOn
                    onClicked: climateCard.toggleRequested()
                }
            }

            // Temperature control row (only when on)
            RowLayout {
                visible: climateCard.isOn
                Layout.fillWidth: true
                spacing: 6

                MaterialSymbol {
                    text: "thermometer"
                    iconSize: Appearance.font.pixelSize.small
                    color: climateCard.warmColor
                }

                // Decrease button
                RippleButton {
                    implicitWidth: 28
                    implicitHeight: 28
                    buttonRadius: Appearance.rounding.full
                    onClicked: {
                        var newTemp = Math.max(
                            climateCard.entityData.min_temp,
                            Math.round((climateCard.entityData.target_temp - 0.5) * 2) / 2
                        );
                        climateCard.temperatureRequested(newTemp);
                    }
                    contentItem: MaterialSymbol {
                        anchors.centerIn: parent
                        text: "remove"
                        iconSize: Appearance.font.pixelSize.normal
                        color: Appearance.colors.colSubtext
                    }
                }

                // Target temperature display
                StyledText {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: climateCard.entityData.target_temp != null
                        ? climateCard.entityData.target_temp.toFixed(1) + "°C"
                        : "—"
                    font.pixelSize: Appearance.font.pixelSize.normal
                    color: climateCard.warmColor
                }

                // Increase button
                RippleButton {
                    implicitWidth: 28
                    implicitHeight: 28
                    buttonRadius: Appearance.rounding.full
                    onClicked: {
                        var newTemp = Math.min(
                            climateCard.entityData.max_temp,
                            Math.round((climateCard.entityData.target_temp + 0.5) * 2) / 2
                        );
                        climateCard.temperatureRequested(newTemp);
                    }
                    contentItem: MaterialSymbol {
                        anchors.centerIn: parent
                        text: "add"
                        iconSize: Appearance.font.pixelSize.normal
                        color: Appearance.colors.colSubtext
                    }
                }
            }
        }
    }
}
