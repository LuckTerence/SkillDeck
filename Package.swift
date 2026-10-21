// swift-tools-version: 5.9
// SkillDeck — Native macOS Agent Skills Manager
// This is the Swift Package Manager project configuration file, similar to Go's go.mod or Python's pyproject.toml

import PackageDescription

let package = Package(
    name: "SkillDeck",

    // When a SwiftPM package contains localized resources (e.g. `*.lproj/Localizable.strings`),
    // SwiftPM requires declaring a default localization.
    //
    // We set English as the default because:
    // - it is our primary development language
    // - it provides the fallback strings when a key is missing in other locales
    defaultLocalization: "en",

    // Specify minimum platform: macOS 14 (Sonoma), because we use the @Observable macro (new feature in macOS 14+)
    platforms: [.macOS(.v14)],

    // External dependencies, similar to Go modules or pip install
    dependencies: [
        // Yams: YAML parser library for Swift, used to parse SKILL.md frontmatter
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),

        // Apple's official Markdown parsing library, used to render the body of SKILL.md
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.7.3"),

    ],

    targets: [
        // Main application target (executable), similar to Go's main package
        .executableTarget(
            name: "SkillDeck",
            dependencies: [
                "Yams",
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Sources/SkillDeck",
             // resources array tells SPM to bundle specified files into Bundle.module
             // .process optimizes based on file type (e.g., PNG compression), .copy copies as is
             // .icns files need to use .copy to preserve original format, as SPM doesn't recognize .icns type
             resources: [
                .copy("Resources/AppIcon.icns"),
                .process("Resources/Localizations"),
                .copy("Resources/AgentIcons"),
                .copy("Resources/SidebarIcons"),
             ]
         ),

        // Unit test target, similar to Go's _test.go files
        .testTarget(
            name: "SkillDeckTests",
            dependencies: ["SkillDeck"],
            path: "Tests/SkillDeckTests"
        ),
    ]
)
