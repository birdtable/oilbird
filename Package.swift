// swift-tools-version: 6.2
//
// ⚠ 6.2 and not 6.0, for one setting: `defaultIsolation`, which arrived in
// 6.2 and is what lets the AppKit target say "main actor" once instead of a
// hundred times. The Command Line Tools and CI are both on 6.3, so the floor
// costs nothing; it is raised deliberately rather than drifted into.
import PackageDescription

let package = Package(
    name: "Oilbird",
    // ⚠ macOS 15, raised from 14. SwiftTUI's vendored signal handling uses
    // `Atomic` and `Mutex` from the Synchronization module, which shipped in
    // the macOS 15 SDK and do not back-deploy. Verified by building against
    // 14 and reading the errors, not by trusting the manifest's declaration.
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OilbirdKit", targets: ["OilbirdKit"]),
        // The GUI product is deliberately NOT named "Oilbird": macOS is
        // case-insensitive, so a product named "Oilbird" and the CLI's
        // "oilbird" would both write .build/debug/oilbird, and
        // Sources/Oilbird and Sources/oilbird would be one directory.
        // It is renamed on the way into Oilbird.app/Contents/MacOS.
        .executable(name: "OilbirdApp", targets: ["OilbirdApp"]),
        .executable(name: "oilbird", targets: ["OilbirdCLI"]),
        .executable(name: "oilbird-mcp", targets: ["OilbirdMCP"]),
    ],
    dependencies: [
        // The terminal UI. `SwiftTUICLI` is not optional packaging detail: on
        // macOS `import SwiftTUI` re-exports the WEB host, so `RenderOnce` —
        // the one-shot, owns-nothing renderer every non-interactive verb uses
        // — is invisible without it.
        .package(url: "https://github.com/SwiftTUI/swift-tui", .upToNextMinor(from: "0.13.0")),
        .package(url: "https://github.com/SwiftTUI/swift-tui-charts", .upToNextMinor(from: "0.13.1")),
        // SwiftLint, as a COMMAND plugin and never a build-tool one. A
        // build-tool plugin runs on every `swift build`, which would put a
        // linter between a person and their compile errors and add a rebuild
        // of the linter itself to a clean checkout. This way `make swiftlint`
        // asks for it and nothing else does.
        //
        // Prebuilt binaries rather than swiftlint's own package: that one
        // pulls SwiftSyntax and compiles for several minutes on a clean
        // machine. Homebrew is not an option: the Command Line Tools are the
        // whole toolchain.
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.65.1"),
    ],
    targets: [
        // The bottom layer. Foundation only, depends on nothing. The compiler
        // holds this one: the target declares no dependency.
        .target(name: "OilbirdModel", swiftSettings: [.swiftLanguageMode(.v6)]),

        // The domains (see domains.yaml). No UI framework — but note the compiler does NOT
        // enforce that (AppKit is in the SDK and a library target may import
        // it), so the `targets` gate is the actual enforcement.
        .target(name: "OilbirdCore", dependencies: ["OilbirdModel"],
                resources: [.copy("Resources/manifest.json"), .copy("Resources/sonarqube-tokens.txt")],
                swiftSettings: [.swiftLanguageMode(.v6)]),

        // The barrel and the verb registry. The only thing a client imports.
        .target(name: "OilbirdKit",
                dependencies: [
                    "OilbirdCore",
                    .product(name: "SwiftTUI", package: "swift-tui"),
                    .product(name: "SwiftTUICLI", package: "swift-tui"),
                    .product(name: "SwiftTUIArguments", package: "swift-tui"),
                    .product(name: "SwiftTUICharts", package: "swift-tui-charts"),
                ],
                swiftSettings: [.swiftLanguageMode(.v6)]),

        // Composition only: the domain logic it shows lives in OilbirdKit.
        //
        // ⚠ `defaultIsolation(MainActor.self)` rather than `@MainActor` on a
        // hundred declarations. This is an AppKit app: every view, every
        // controller and every `NSFont` here only ever touches the main
        // thread, and saying so once is the honest model. Annotating them one
        // at a time would say the same thing in a hundred places and get one
        // of them wrong.
        .executableTarget(name: "OilbirdApp", dependencies: ["OilbirdKit"],
                          swiftSettings: [
                            .swiftLanguageMode(.v6),
                            .defaultIsolation(MainActor.self),
                          ]),

        .executableTarget(name: "OilbirdCLI", dependencies: ["OilbirdKit"],
                          swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "OilbirdMCP", dependencies: ["OilbirdKit"],
                          swiftSettings: [.swiftLanguageMode(.v6)]),

        // Drives the browser for the PTY journey. Never shipped: `make app`
        // copies `oilbird` and `oilbird-mcp` by name.
        .executableTarget(name: "oilbird-browse-fixture", dependencies: ["OilbirdKit"],
                path: "Sources/OilbirdBrowseFixture",
                swiftSettings: [.swiftLanguageMode(.v6)]),

        // The gates. A library so the suites can reach them, and a command
        // that is argv and an exit code -- `K-2`, held by the gates
        // themselves. It depends on NOTHING: every gate reads the repository
        // as text, so no gate can be made green by the code it checks.
        .target(name: "OilbirdChecks", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "oilbird-checks", dependencies: ["OilbirdChecks"],
                path: "Sources/OilbirdChecksCLI",
                swiftSettings: [.swiftLanguageMode(.v6)]),

        // XCTest and swift-testing ship with Xcode, not the Command Line Tools,
        // so `swift test` cannot run there: the suites are an executable with a
        // small harness. Do not "modernise" this without checking it still runs.
        .executableTarget(name: "oilbird-tests",
                dependencies: [
                    "OilbirdKit",
                    .product(name: "SwiftTUICLI", package: "swift-tui"),
                    .product(name: "SwiftTUIArguments", package: "swift-tui"),
                ],
                          path: "Tests/OilbirdKitTests",
                          swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
