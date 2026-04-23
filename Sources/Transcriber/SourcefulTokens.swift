import SwiftUI

/// Sourceful design-system palette.
///
/// Mirrors `globals.css` in `srcful-design-system`:
///   paper  = page default
///   cream  = editorial spread body
///   ink    = hero + closing dark spreads
///   signal = the single accent (orange)
///
/// Tokens follow the "one ground, one accent, no gradients / no glows"
/// rule. Add new colors here, not inline — keeps the brand consistent
/// as the app grows.
enum SourcefulColor {
    static let paper  = Color(red: 0xFA / 255, green: 0xFA / 255, blue: 0xF7 / 255) // #FAFAF7
    static let cream  = Color(red: 0xF5 / 255, green: 0xF2 / 255, blue: 0xE1 / 255) // #F5F2E1
    static let ink    = Color(red: 0x0A / 255, green: 0x0A / 255, blue: 0x0A / 255) // #0A0A0A
    static let signal = Color(red: 0xE8 / 255, green: 0x5D / 255, blue: 0x1F / 255) // #E85D1F  signal-500
}
