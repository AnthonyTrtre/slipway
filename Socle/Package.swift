// swift-tools-version: 6.2
import PackageDescription

// Copie embarquée du socle des apps maison (journal, barre de menus, ouverture à la connexion) :
// le dépôt de Slipway se compile seul.
let package = Package(
    name: "Socle",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SocleCore", targets: ["SocleCore"]),
        .library(name: "SocleBarreDeMenus", targets: ["SocleBarreDeMenus"]),
    ],
    targets: [
        .target(name: "SocleCore"),
        .target(name: "SocleBarreDeMenus", dependencies: ["SocleCore"]),
        .testTarget(name: "SocleCoreTests", dependencies: ["SocleCore"]),
    ]
)
