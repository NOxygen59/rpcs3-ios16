// Input for the core's pad ports: game controllers (GameController framework, one PS3 port each,
// with rumble), and the on-screen pad on port 1 when no controller is connected.
//
// Event-driven: a controller or the on-screen pad pushes its state to the core when it changes,
// rather than every port being polled every frame. Only rumble is polled, and only while a
// controller that can vibrate is connected.

import CoreHaptics
import GameController
import SwiftUI

/// The on-screen pad's live state, written by its controls; each change goes straight to the core.
final class TouchPad: ObservableObject {
    private(set) var buttons: UInt64 = 0
    var left = CGPoint.zero { didSet { if left != oldValue { changed?() } } }
    var right = CGPoint.zero { didSet { if right != oldValue { changed?() } } }
    var l2: Float = 0 { didSet { if l2 != oldValue { changed?() } } }
    var r2: Float = 0 { didSet { if r2 != oldValue { changed?() } } }
    var changed: (() -> Void)?

    func set(_ button: rpcs3_ios_pad_button, _ down: Bool) {
        let next = down ? buttons | button.bit : buttons & ~button.bit
        guard next != buttons else { return }
        buttons = next
        changed?()
    }

    /// For the D-pad, which moves several bits at once.
    func replace(_ mask: UInt64, with bits: UInt64) {
        let next = (buttons & ~mask) | bits
        guard next != buttons else { return }
        buttons = next
        changed?()
    }

    func clear() {
        buttons = 0
        left = .zero
        right = .zero
        l2 = 0
        r2 = 0
    }

    var state: rpcs3_ios_pad_state {
        var s = rpcs3_ios_pad_state()
        s.connected = 1
        s.buttons = buttons
        s.left_stick_x = Float(left.x)
        s.left_stick_y = Float(left.y)
        s.right_stick_x = Float(right.x)
        s.right_stick_y = Float(right.y)
        s.left_trigger = l2
        s.right_trigger = r2
        return s
    }
}

final class InputLoop {
    let touch = TouchPad()
    private var running = false
    private var ports: [GCController] = []
    private var rumble: [ObjectIdentifier: Rumble] = [:]
    private var rumbleTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var touchConnected = false
    private var touchPort: UInt32 = 0

    /// Whether the on-screen pad is shown; it then takes the first port after the controllers.
    var touchEnabled = true { didSet { if touchEnabled != oldValue { assign() } } }

    func start() {
        guard !running else { return }
        running = true
        touch.changed = { [weak self] in
            guard let self, self.touchConnected else { return }
            Core.setPad(self.touchPort, self.touch.state)
        }
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.assign() })
        }
        assign()
    }

    /// Paused emulation needs no input and no rumble.
    func suspend() {
        rumbleTimer?.invalidate()
        rumbleTimer = nil
        rumble.values.forEach { $0.set(large: 0, small: 0) }
    }

    func resume() {
        guard running else { return }
        updateRumbleTimer()
    }

    func stop() {
        guard running else { return }
        running = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for c in ports { c.extendedGamepad?.valueChangedHandler = nil }
        ports.removeAll()
        touch.changed = nil
        touchConnected = false
        suspend()
        rumble.values.forEach { $0.stop() }
        rumble.removeAll()
        disconnect(from: 0)
    }

    /// Gives each controller a port and hooks its change handler; the on-screen pad takes port 1
    /// when there is none.
    private func assign() {
        guard running else { return }
        for c in ports { c.extendedGamepad?.valueChangedHandler = nil }
        ports = Array(GCController.controllers().filter { $0.extendedGamepad != nil }.prefix(7))
        for (index, controller) in ports.enumerated() {
            let port = UInt32(index)
            guard let pad = controller.extendedGamepad else { continue }
            pad.valueChangedHandler = { pad, _ in Core.setPad(port, Self.state(pad)) }
            Core.setPad(port, Self.state(pad))
        }
        var used = ports.count
        touchConnected = touchEnabled && used < 7
        if touchConnected {
            touchPort = UInt32(used)
            Core.setPad(touchPort, touch.state)
            used += 1
        } else {
            touch.clear()
        }
        disconnect(from: used)
        let live = Set(ports.map(ObjectIdentifier.init))
        for key in rumble.keys where !live.contains(key) { rumble.removeValue(forKey: key)?.stop() }
        updateRumbleTimer()
    }

    private func disconnect(from first: Int) {
        guard first < 7 else { return }
        var s = rpcs3_ios_pad_state()
        s.connected = 0
        for port in first..<7 { Core.setPad(UInt32(port), s) }
    }

    private func updateRumbleTimer() {
        let wanted = ports.contains { $0.haptics != nil }
        if wanted, rumbleTimer == nil {
            // 30 Hz is plenty for motors, and the timer may be coalesced with others.
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.pollRumble() }
            timer.tolerance = 0.01
            RunLoop.main.add(timer, forMode: .common)
            rumbleTimer = timer
        } else if !wanted {
            rumbleTimer?.invalidate()
            rumbleTimer = nil
        }
    }

    private func pollRumble() {
        for (index, controller) in ports.enumerated() where controller.haptics != nil {
            let (large, small) = Core.padFeedback(UInt32(index))
            let key = ObjectIdentifier(controller)
            if rumble[key] == nil {
                guard large > 0 || small > 0 else { continue }
                rumble[key] = Rumble(controller)
            }
            rumble[key]?.set(large: Float(large) / 255, small: Float(small) / 255)
        }
    }

    private static func state(_ pad: GCExtendedGamepad) -> rpcs3_ios_pad_state {
        var s = rpcs3_ios_pad_state()
        s.connected = 1
        var b: UInt64 = 0
        func on(_ input: GCControllerButtonInput?, _ button: rpcs3_ios_pad_button) {
            if input?.isPressed == true { b |= button.bit }
        }
        on(pad.dpad.up, RPCS3_IOS_PAD_BUTTON_DPAD_UP)
        on(pad.dpad.down, RPCS3_IOS_PAD_BUTTON_DPAD_DOWN)
        on(pad.dpad.left, RPCS3_IOS_PAD_BUTTON_DPAD_LEFT)
        on(pad.dpad.right, RPCS3_IOS_PAD_BUTTON_DPAD_RIGHT)
        // Positions, as on a PlayStation pad: A (bottom) is Cross, B Circle, X Square, Y Triangle.
        on(pad.buttonA, RPCS3_IOS_PAD_BUTTON_CROSS)
        on(pad.buttonB, RPCS3_IOS_PAD_BUTTON_CIRCLE)
        on(pad.buttonX, RPCS3_IOS_PAD_BUTTON_SQUARE)
        on(pad.buttonY, RPCS3_IOS_PAD_BUTTON_TRIANGLE)
        on(pad.leftShoulder, RPCS3_IOS_PAD_BUTTON_L1)
        on(pad.rightShoulder, RPCS3_IOS_PAD_BUTTON_R1)
        on(pad.leftTrigger, RPCS3_IOS_PAD_BUTTON_L2)
        on(pad.rightTrigger, RPCS3_IOS_PAD_BUTTON_R2)
        on(pad.leftThumbstickButton, RPCS3_IOS_PAD_BUTTON_L3)
        on(pad.rightThumbstickButton, RPCS3_IOS_PAD_BUTTON_R3)
        on(pad.buttonMenu, RPCS3_IOS_PAD_BUTTON_START)
        on(pad.buttonOptions, RPCS3_IOS_PAD_BUTTON_SELECT)
        on(pad.buttonHome, RPCS3_IOS_PAD_BUTTON_PS)
        s.buttons = b
        s.left_stick_x = pad.leftThumbstick.xAxis.value
        s.left_stick_y = pad.leftThumbstick.yAxis.value
        s.right_stick_x = pad.rightThumbstick.xAxis.value
        s.right_stick_y = pad.rightThumbstick.yAxis.value
        s.left_trigger = pad.leftTrigger.value
        s.right_trigger = pad.rightTrigger.value
        return s
    }
}

/// A controller's two motors, as continuous haptic players (iOS 14+ controller haptics).
private final class Rumble {
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private var last: Float = 0

    init(_ controller: GCController) {
        guard let engine = controller.haptics?.createEngine(withLocality: .default) else { return }
        self.engine = engine
        // The engine powers down while the motors are idle and restarts when they play.
        engine.isAutoShutdownEnabled = true
        try? engine.start()
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
        ], relativeTime: 0, duration: 30)
        if let pattern = try? CHHapticPattern(events: [event], parameters: []) {
            player = try? engine.makeAdvancedPlayer(with: pattern)
            player?.loopEnabled = true
        }
    }

    func set(large: Float, small: Float) {
        let level = max(large, small * 0.6)
        guard abs(level - last) > 0.02 || (level == 0 && last != 0), let player else { return }
        if last == 0, level > 0 {
            try? engine?.start()
            try? player.start(atTime: CHHapticTimeImmediate)
        }
        last = level
        if level == 0 {
            try? player.stop(atTime: CHHapticTimeImmediate)
        } else {
            try? player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: level, relativeTime: 0)], atTime: CHHapticTimeImmediate)
        }
    }

    func stop() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        engine?.stop()
    }
}

// MARK: - On-screen pad

/// The PS3 pad drawn over the game: D-pad and sticks on the left, face buttons and right stick on
/// the right, shoulders at the top corners, Select / PS / Start in the middle.
struct TouchPadOverlay: View {
    @ObservedObject var pad: TouchPad
    var opacity: Double

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 380
            ZStack {
                // Shoulders.
                VStack(spacing: 8 * s) {
                    HStack {
                        PadButton(label: "L2", size: CGSize(width: 74 * s, height: 34 * s)) { pad.set(RPCS3_IOS_PAD_BUTTON_L2, $0); pad.l2 = $0 ? 1 : 0 }
                        Spacer()
                        PadButton(label: "R2", size: CGSize(width: 74 * s, height: 34 * s)) { pad.set(RPCS3_IOS_PAD_BUTTON_R2, $0); pad.r2 = $0 ? 1 : 0 }
                    }
                    HStack {
                        PadButton(label: "L1", size: CGSize(width: 74 * s, height: 34 * s)) { pad.set(RPCS3_IOS_PAD_BUTTON_L1, $0) }
                        Spacer()
                        PadButton(label: "R1", size: CGSize(width: 74 * s, height: 34 * s)) { pad.set(RPCS3_IOS_PAD_BUTTON_R1, $0) }
                    }
                    Spacer()
                }
                .padding(.horizontal, 24 * s)
                .padding(.top, 20 * s)

                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        VStack(spacing: 16 * s) {
                            DPad(pad: pad, size: 136 * s)
                            Stick(size: 110 * s) { pad.left = $0 } press: { pad.set(RPCS3_IOS_PAD_BUTTON_L3, $0) }
                        }
                        Spacer()
                        HStack(spacing: 14 * s) {
                            PadButton(label: "SELECT", size: CGSize(width: 58 * s, height: 24 * s), font: 9 * s) { pad.set(RPCS3_IOS_PAD_BUTTON_SELECT, $0) }
                            PadButton(label: "PS", size: CGSize(width: 34 * s, height: 34 * s), font: 11 * s) { pad.set(RPCS3_IOS_PAD_BUTTON_PS, $0) }
                            PadButton(label: "START", size: CGSize(width: 58 * s, height: 24 * s), font: 9 * s) { pad.set(RPCS3_IOS_PAD_BUTTON_START, $0) }
                        }
                        .padding(.bottom, 20 * s)
                        Spacer()
                        VStack(spacing: 16 * s) {
                            FaceButtons(pad: pad, size: 150 * s)
                            Stick(size: 110 * s) { pad.right = $0 } press: { pad.set(RPCS3_IOS_PAD_BUTTON_R3, $0) }
                        }
                    }
                    .padding(.horizontal, 28 * s)
                    .padding(.bottom, 24 * s)
                }
            }
            .opacity(opacity)
        }
    }
}

/// A button that reports press and release (several can be held at once).
struct PadButton: View {
    let label: String
    var size: CGSize = CGSize(width: 52, height: 52)
    var font: CGFloat = 15
    var tint: Color = .white
    let changed: (Bool) -> Void
    @State private var down = false

    var body: some View {
        RoundedRectangle(cornerRadius: min(size.width, size.height) / 2)
            .fill(Color.black.opacity(down ? 0.55 : 0.32))
            .overlay(RoundedRectangle(cornerRadius: min(size.width, size.height) / 2).strokeBorder(tint.opacity(0.7), lineWidth: 1.5))
            .overlay(Text(label).font(.system(size: font, weight: .bold, design: .rounded)).foregroundColor(tint))
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !down { down = true; changed(true) } }
                .onEnded { _ in down = false; changed(false) })
    }
}

private struct FaceButtons: View {
    let pad: TouchPad
    let size: CGFloat

    var body: some View {
        let b = size * 0.34
        ZStack {
            PadButton(label: "△", size: CGSize(width: b, height: b), font: b * 0.45, tint: Color(red: 0.4, green: 0.9, blue: 0.75)) { pad.set(RPCS3_IOS_PAD_BUTTON_TRIANGLE, $0) }
                .offset(y: -size * 0.33)
            PadButton(label: "✕", size: CGSize(width: b, height: b), font: b * 0.42, tint: Color(red: 0.55, green: 0.7, blue: 1)) { pad.set(RPCS3_IOS_PAD_BUTTON_CROSS, $0) }
                .offset(y: size * 0.33)
            PadButton(label: "□", size: CGSize(width: b, height: b), font: b * 0.45, tint: Color(red: 0.95, green: 0.6, blue: 0.85)) { pad.set(RPCS3_IOS_PAD_BUTTON_SQUARE, $0) }
                .offset(x: -size * 0.33)
            PadButton(label: "○", size: CGSize(width: b, height: b), font: b * 0.45, tint: Color(red: 1, green: 0.45, blue: 0.45)) { pad.set(RPCS3_IOS_PAD_BUTTON_CIRCLE, $0) }
                .offset(x: size * 0.33)
        }
        .frame(width: size, height: size)
    }
}

/// The D-pad: one touch area, so a thumb can roll between directions (diagonals included).
private struct DPad: View {
    let pad: TouchPad
    let size: CGFloat
    @State private var active: Set<UInt64> = []

    var body: some View {
        ZStack {
            Image(systemName: "dpad").resizable().scaledToFit().foregroundColor(.white.opacity(0.75))
                .padding(size * 0.06)
                .background(Circle().fill(Color.black.opacity(0.3)))
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in update(v.location) }
            .onEnded { _ in update(nil) })
    }

    private func update(_ point: CGPoint?) {
        var now: Set<UInt64> = []
        if let p = point {
            let dx = p.x - size / 2, dy = p.y - size / 2
            let dead = size * 0.12
            if dy < -dead && abs(dx) < abs(dy) * 2.4 { now.insert(RPCS3_IOS_PAD_BUTTON_DPAD_UP.bit) }
            if dy > dead && abs(dx) < abs(dy) * 2.4 { now.insert(RPCS3_IOS_PAD_BUTTON_DPAD_DOWN.bit) }
            if dx < -dead && abs(dy) < abs(dx) * 2.4 { now.insert(RPCS3_IOS_PAD_BUTTON_DPAD_LEFT.bit) }
            if dx > dead && abs(dy) < abs(dx) * 2.4 { now.insert(RPCS3_IOS_PAD_BUTTON_DPAD_RIGHT.bit) }
        }
        let mask = RPCS3_IOS_PAD_BUTTON_DPAD_UP.bit | RPCS3_IOS_PAD_BUTTON_DPAD_DOWN.bit | RPCS3_IOS_PAD_BUTTON_DPAD_LEFT.bit | RPCS3_IOS_PAD_BUTTON_DPAD_RIGHT.bit
        pad.replace(mask, with: now.reduce(0, |))
        active = now
    }
}

/// An analog stick: the knob follows the thumb inside the ring; a double tap clicks it (L3 / R3).
private struct Stick: View {
    let size: CGFloat
    let moved: (CGPoint) -> Void
    let press: (Bool) -> Void
    @State private var knob = CGSize.zero

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.3)).overlay(Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 1.5))
            Circle().fill(Color.white.opacity(0.45)).frame(width: size * 0.42, height: size * 0.42).offset(knob)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                let r = size / 2
                var d = CGSize(width: v.location.x - r, height: v.location.y - r)
                let len = sqrt(d.width * d.width + d.height * d.height)
                if len > r { d = CGSize(width: d.width / len * r, height: d.height / len * r) }
                knob = d
                // Positive Y points up for the core.
                moved(CGPoint(x: d.width / r, y: -d.height / r))
            }
            .onEnded { _ in
                knob = .zero
                moved(.zero)
            })
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            press(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { press(false) }
        })
    }
}

extension rpcs3_ios_pad_button {
    var bit: UInt64 { UInt64(rawValue) }
}
