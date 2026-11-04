// swift-tools-version: 6.2
import PackageDescription

// SlipwayKit : toute la logique de Slipway, découpée en modules.
// - SlipwayCoeur    : protocole binaire, géométrie, machine à états, outils (Foundation seule, testable sous Linux).
// - SlipwaySecurite : appairage, dérivation de clés, scellement (CryptoKit sur macOS, swift-crypto sous Linux).
// - SlipwayMoteur   : orchestration pure (session + canal chiffré + interfaces vers les adaptateurs).
// - SlipwayMac      : adaptateurs macOS (CGEventTap, CGEventPost, Network.framework, NSPasteboard…).
//
// Dépendance tierce : swift-crypto (Apple, Apache-2.0), UNIQUEMENT sous Linux, pour tester SlipwaySecurite
// sans CryptoKit. Sur macOS le manifeste ne la déclare pas du tout : aucune dépendance téléchargée.

#if os(Linux)
let dependances: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.1.1"),
]
let dependancesSecurite: [Target.Dependency] = ["SlipwayCoeur", .product(name: "Crypto", package: "swift-crypto")]
#else
let dependances: [Package.Dependency] = []
let dependancesSecurite: [Target.Dependency] = ["SlipwayCoeur"]
#endif

let package = Package(
    name: "SlipwayKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SlipwayCoeur", targets: ["SlipwayCoeur"]),
        .library(name: "SlipwaySecurite", targets: ["SlipwaySecurite"]),
        .library(name: "SlipwayMoteur", targets: ["SlipwayMoteur"]),
        .library(name: "SlipwayMac", targets: ["SlipwayMac"]),
    ],
    dependencies: dependances,
    targets: [
        .target(name: "SlipwayCoeur"),
        .target(name: "SlipwaySecurite", dependencies: dependancesSecurite),
        .target(name: "SlipwayMoteur", dependencies: ["SlipwayCoeur", "SlipwaySecurite"]),
        .target(name: "SlipwayMac", dependencies: ["SlipwayCoeur", "SlipwaySecurite", "SlipwayMoteur"]),
        .testTarget(name: "SlipwayCoeurTests", dependencies: ["SlipwayCoeur"]),
        .testTarget(name: "SlipwaySecuriteTests", dependencies: ["SlipwaySecurite", "SlipwayCoeur"]),
        .testTarget(name: "SlipwayMoteurTests", dependencies: ["SlipwayMoteur", "SlipwaySecurite", "SlipwayCoeur"]),
        .testTarget(name: "SlipwayMacTests", dependencies: ["SlipwayMac", "SlipwayCoeur"]),
    ],
    swiftLanguageModes: [.v6]
)
