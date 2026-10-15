import SwiftTUI

/// Oilbird's six roles, expressed as the framework's semantic roles.
///
/// The roles were already the design system: a screen names what a span MEANS
/// and never picks a colour. That survives the move, and improves — a semantic
/// role resolves through the host theme at render time, so the same screen
/// adapts to a light terminal, a dark one, and a high-contrast one, where the
/// old eight-colour SGR codes were fixed.
///
/// The palette used to be held to eight-colour SGR. The rule now is stronger:
/// a screen may name a role and may not name a `Color`.
/// ⚠ `AnyShapeStyle`, not `some ShapeStyle`. Two opaque types never unify, so
/// `failed ? Role.bad : Role.note` does not compile — and that expression is
/// the whole point of naming roles.
public enum Role {
    /// Text the reader will type. Commands, keys, menu rows.
    public static let action = AnyShapeStyle(.link)
    /// Text the reader may skip. Provenance, detail.
    public static let note = AnyShapeStyle(.muted)
    /// Look here.
    public static let attn = AnyShapeStyle(.warning)
    /// It worked, and the verdict when it is good.
    public static let good = AnyShapeStyle(.success)
    /// It did not.
    public static let bad = AnyShapeStyle(.danger)
    /// Everything else.
    public static let body = AnyShapeStyle(.primary)
}
