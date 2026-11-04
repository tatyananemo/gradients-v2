import SwiftUI
import UIKit

struct SettingsSheet: View {
    @Binding var appTheme: GradientAppTheme
    @Binding var gradientColor: GradientColorPreset

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Настройки")
                .font(.system(size: 24, weight: .bold, design: .rounded))

            VStack(alignment: .leading, spacing: 8) {
                Text("Тема")
                    .font(.system(size: 13, weight: .medium))
                V2ThemePicker(selection: $appTheme)
                    .frame(height: 32)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Цвет градиента")
                    .font(.system(size: 13, weight: .medium))

                HStack(spacing: 9) {
                    ForEach(GradientColorPreset.allCases) { colorPreset in
                        Button {
                            gradientColor = colorPreset
                        } label: {
                            VStack(spacing: 5) {
                                Circle()
                                    .fill(colorPreset.swatch)
                                    .frame(width: 28, height: 28)
                                    .overlay(
                                        Circle()
                                            .stroke(.white.opacity(gradientColor == colorPreset ? 0.95 : 0.28), lineWidth: gradientColor == colorPreset ? 3 : 1)
                                    )
                                    .shadow(color: colorPreset.swatch.opacity(0.30), radius: 8, x: 0, y: 3)

                                Text(colorPreset.title)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

        }
        .padding(.top, 34)
        .padding(.horizontal, 22)
        .padding(.bottom, 22)
    }
}

private struct V2ThemePicker: UIViewRepresentable {
    @Binding var selection: GradientAppTheme

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: GradientAppTheme.allCases.map(\.title))
        control.accessibilityLabel = "Тема"
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        let index = selection == .light ? 0 : 1
        // Live background updates must not reset a segment while a finger is tracking it.
        if !control.isTracking && control.selectedSegmentIndex != index {
            control.selectedSegmentIndex = index
        }
    }

    final class Coordinator: NSObject {
        var selection: Binding<GradientAppTheme>
        init(selection: Binding<GradientAppTheme>) { self.selection = selection }
        @objc func changed(_ control: UISegmentedControl) {
            selection.wrappedValue = control.selectedSegmentIndex == 0 ? .light : .dark
        }
    }
}
