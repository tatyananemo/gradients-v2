import GradientsKit
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = BiosensorScreen()
        self.window = window
        window.makeKeyAndVisible()
    }
}

private enum Instruction {
    static let connection = "Устанавливаем защищенное соединение. Водите пальцем в разных частях экрана"
    #if CONTEST_INSTRUCTION_2
    static let active = """
    Создаем уникальный ключ
    для подписи. Водите пальцем
    в разных частях экрана
    """

    #else
    static let active = connection
    #endif
}

@MainActor
private final class BiosensorScreen: UIViewController {
    private var biosensor: GradientViewController?
    private weak var instructionLabel: UILabel?
    private let resetButton = UIButton(configuration: .glass())

    override var prefersStatusBarHidden: Bool { false }
    override var prefersHomeIndicatorAutoHidden: Bool { false }
    override var preferredStatusBarStyle: UIStatusBarStyle {
        traitCollection.userInterfaceStyle == .dark ? .lightContent : .darkContent
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (screen: BiosensorScreen, _) in
            screen.applySystemAppearance()
        }

        do {
            let component = try GradientViewController(theme: systemTheme)
            biosensor = component
            addChild(component)
            let surface = component.view!
            surface.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(surface)
            NSLayoutConstraint.activate([
                surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                surface.topAnchor.constraint(equalTo: view.topAnchor),
                surface.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            component.didMove(toParent: self)
            configureApprovedSDKOverlays(in: surface)
        } catch {
            let label = UILabel()
            label.text = "Не удалось запустить биосенсор"
            label.textAlignment = .center
            label.numberOfLines = 0
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
                label.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
                label.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24)
            ])
            NSLog("Biosensor initialization failed: %@", String(describing: error))
        }

        configureResetButton()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applySystemAppearance()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Keep the approved caption position unless the system bottom inset requires more room.
        if let label = instructionLabel {
            let safeBottom = view.safeAreaLayoutGuide.layoutFrame.maxY - 16
            let bottom = label.convert(label.bounds, to: view).maxY
            if bottom > safeBottom {
                label.frame.origin.y -= bottom - safeBottom
            }
        }
    }

    private var systemTheme: GradientTheme {
        traitCollection.userInterfaceStyle == .dark ? .yellowDark : .yellowLight
    }

    private func applySystemAppearance() {
        if let biosensor, biosensor.theme != systemTheme {
            biosensor.theme = systemTheme
        }
        setNeedsStatusBarAppearanceUpdate()
    }

    private func configureApprovedSDKOverlays(in surface: UIView) {
        // The frozen SDK supplies its own counter, caption and adaptive readability backing.
        // Replace just the caption string and hide the two packaged demo controls in this host.
        let demoControls = surface.subviews.compactMap { $0 as? UIButton }.filter {
            $0.accessibilityLabel == "Сбросить" || $0.accessibilityLabel == "Настройки"
        }
        for button in demoControls {
            button.isHidden = true
            for backdrop in surface.subviews where backdrop is UIVisualEffectView && backdrop.frame == button.frame {
                backdrop.isHidden = true
            }
        }
        guard let label = surface.subviews.compactMap({ $0 as? UILabel }).first(where: {
            $0.attributedText?.string == Instruction.connection
        }), let original = label.attributedText else { return }
        instructionLabel = label
        if Instruction.active != original.string {
            let attributes = original.attributes(at: 0, effectiveRange: nil)
            label.attributedText = NSAttributedString(string: Instruction.active, attributes: attributes)
        }
    }

    private func configureResetButton() {
        var configuration = UIButton.Configuration.glass()
        configuration.image = UIImage(
            systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        )
        configuration.baseForegroundColor = .label
        configuration.cornerStyle = .capsule
        resetButton.configuration = configuration
        resetButton.accessibilityLabel = "Сбросить биосенсор"
        resetButton.accessibilityIdentifier = "biosensor.reset"
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        resetButton.addTarget(self, action: #selector(resetBiosensor), for: .touchUpInside)
        view.addSubview(resetButton)
        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            resetButton.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 16),
            resetButton.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: 3),
            resetButton.widthAnchor.constraint(equalToConstant: 44),
            resetButton.heightAnchor.constraint(equalTo: resetButton.widthAnchor)
        ])
    }

    @objc private func resetBiosensor() {
        guard let biosensor else { return }
        // Cancel any active finger before clearing progress and the touch trail.
        biosensor.pauseRendering()
        biosensor.reset(animated: false)
        biosensor.resumeRendering()
    }
}
