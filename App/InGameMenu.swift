// Controller navigation shared by the home screen and the in-game menu, and the in-game menu
// itself: a panel over the game (it pauses while open), opened with the ••• button or, on a
// controller, Select + Start together.

import GameController
import SwiftUI

/// Turns a controller's state into menu moves: one move per press, repeated while a direction
/// is held (after 0.38 s, then every 0.11 s), as on the console.
final class PadNavigator {
    enum Input: Equatable { case left, right, up, down, confirm, back, options }

    var handler: ((Input) -> Void)?
    private var held: Input?
    private var repeatTimer: Timer?
    private var pressed: Set<String> = []

    func feed(_ pad: GCExtendedGamepad) {
        button(pad.buttonA, "a", .confirm)
        button(pad.buttonB, "b", .back)
        button(pad.buttonY, "y", .options)
        let x = pad.dpad.xAxis.value + pad.leftThumbstick.xAxis.value
        let y = pad.dpad.yAxis.value + pad.leftThumbstick.yAxis.value
        let direction: Input? = abs(x) > 0.5 && abs(x) >= abs(y) ? (x > 0 ? .right : .left)
            : abs(y) > 0.5 ? (y > 0 ? .up : .down) : nil
        guard direction != held else { return }
        stopRepeat()
        guard let direction else { return }
        held = direction
        fire(direction)
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.38, repeats: false) { [weak self] _ in
            self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.11, repeats: true) { [weak self] _ in
                if let held = self?.held { self?.fire(held) }
            }
        }
    }

    func reset() {
        stopRepeat()
        pressed.removeAll()
    }

    /// One move when a button goes down, none while it stays down.
    private func button(_ input: GCControllerButtonInput, _ key: String, _ move: Input) {
        if input.isPressed {
            if pressed.insert(key).inserted { fire(move) }
        } else {
            pressed.remove(key)
        }
    }

    private func stopRepeat() {
        held = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func fire(_ input: Input) {
        let handler = handler
        DispatchQueue.main.async { handler?(input) }
    }
}

/// The in-game menu: what can be done without leaving the game.
struct InGameMenu: View {
    @ObservedObject var controller: EmulationController
    @Binding var showHUD: Bool
    @Binding var touchMode: Int
    @Binding var touchScale: Int
    let title: String
    let close: () -> Void
    let report: () -> Void

    @State private var selected = 0

    private struct Entry {
        let symbol: String
        let label: String
        let value: String?
        let destructive: Bool
        let action: () -> Void
    }

    private var entries: [Entry] {
        [
            Entry(symbol: "play.fill", label: "Reprendre le jeu", value: nil, destructive: false, action: close),
            Entry(symbol: "speedometer", label: "Performances à l'écran", value: showHUD ? "Affichées" : "Masquées", destructive: false) { showHUD.toggle() },
            Entry(symbol: "gamecontroller", label: "Manette tactile", value: ["Automatique", "Toujours", "Jamais"][touchMode % 3], destructive: false) { touchMode = (touchMode + 1) % 3 },
            Entry(symbol: "arrow.up.left.and.arrow.down.right", label: "Taille de la manette tactile", value: ["Petite", "Moyenne", "Grande"][touchScale % 3], destructive: false) { touchScale = (touchScale + 1) % 3 },
            Entry(symbol: "stethoscope", label: "Rapport de diagnostic", value: nil, destructive: false, action: report),
            Entry(symbol: "stop.fill", label: "Arrêter le jeu", value: nil, destructive: true) { controller.stop() },
        ]
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 22, weight: .semibold, design: .rounded)).lineLimit(2)
                Text("En pause · Manette : ✕ choisir, ○ fermer")
                    .font(.system(size: 13, design: .rounded)).foregroundColor(.white.opacity(0.6))
                    .padding(.bottom, 14)
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    Button {
                        selected = index
                        entry.action()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: entry.symbol).frame(width: 26)
                            Text(entry.label)
                            Spacer()
                            if let value = entry.value { Text(value).foregroundColor(.white.opacity(0.65)) }
                        }
                        .font(.system(size: 18, weight: index == selected ? .semibold : .regular, design: .rounded))
                        .foregroundColor(entry.destructive ? Color(red: 1, green: 0.45, blue: 0.45) : .white)
                        .padding(.horizontal, 16).padding(.vertical, 13)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(index == selected ? 0.16 : 0)))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(index == selected ? 0.35 : 0), lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .foregroundColor(.white)
            .padding(28)
            .frame(width: 420)
            .frame(maxHeight: .infinity)
            .background(.ultraThinMaterial.opacity(0.9))
            .background(Color.black.opacity(0.55))
            .transition(.move(edge: .trailing))
        }
        .onAppear {
            controller.input.menu = { input in move(input) }
        }
        .onDisappear { controller.input.menu = nil }
    }

    private func move(_ input: PadNavigator.Input) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            switch input {
            case .up: selected = max(selected - 1, 0)
            case .down: selected = min(selected + 1, entries.count - 1)
            case .confirm: entries[selected].action()
            case .back: close()
            default: break
            }
        }
    }
}
