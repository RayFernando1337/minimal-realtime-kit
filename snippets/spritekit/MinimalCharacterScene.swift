//
//  MinimalCharacterScene.swift  (minimal-realtime-kit — REDACTED snippet)
//
//  The SMALLEST believable version of the Pebbles character: ONE procedural orb body + TWO eyes.
//  It listens (draws IN), speaks (swells OUT + smiles on loud peaks), and reacts (blink, breath,
//  eased posture per state). Pure SpriteKit + Core Graphics — no sprite sheets, no assets, no
//  third-party deps, no AIProxy.
//
//  Distilled from `OpenAIRealtimeSample/Pebbles/PebblesScene.swift` (1416 lines). CUT for MVP:
//  the 9-stone cairn, per-stone springs, physics poke/tumble, drag/stack, the Pixar happy-hop,
//  the react-to-elements glance, sleep "z z z", ground shadow. See research/03 for the full map.
//
//  ── THE GOLDEN RULE (performance) ─────────────────────────────────────────────────────────────
//  Amplitude is PULLED once per frame via `levelProvider`, inside SpriteKit's own render loop.
//  It is NEVER pushed through SwiftUI @State / @Observable / UIKit updateProperties — only the
//  DISCRETE state/tone go through observation. A 60Hz signal through the view graph = per-frame
//  layout thrash. (Source: PebblesScene.swift:26,380 + StageViewController.swift:227-228.)
//

import SpriteKit
import UIKit

final class MinimalCharacterScene: SKScene {

    // MARK: Inputs

    /// INPUT B — live mic / output level, 0…1, sampled EVERY FRAME. Bind this to your meter once;
    /// do not drive it through SwiftUI. (PebblesScene.swift:26)
    var levelProvider: () -> Float = { 0 }

    /// Honor Reduce Motion: freeze breath/voice-flutter, keep only gentle eases. (PebblesScene.swift:28)
    var reduceMotion = false

    /// Optional: fired when the body is tapped (so a host can add haptics, etc.).
    var onPoke: () -> Void = {}

    // MARK: Nodes

    private let body = SKSpriteNode()
    private var leftEye = SKShapeNode()
    private var rightEye = SKShapeNode()

    // MARK: State (INPUT A, resolved to a pose)

    private var look = CharacterLook.idle

    // MARK: Clock + transient channels

    private var startTime: TimeInterval = -1
    private var lastTime: TimeInterval = 0
    private var displayedAlpha: CGFloat = 1

    // Blink: asymmetric (fast close, slow open). -1 = idle; >=0 = mid-blink age.
    private var blinkClock: TimeInterval = 0
    private var nextBlink: TimeInterval = 2.5
    private var blinkAge: TimeInterval = -1

    // Smile (happy crescent) hold, 0…1.
    private var crescentHold: CGFloat = 0
    private var eyesAreCrescent = false

    // One-shot tap squash envelope (0→1→0), laid on top of the rig so the per-frame scale can't stomp it.
    private var pokeSquashAge: TimeInterval = -1
    private var pokeSquash: CGFloat = 0

    // MARK: Geometry

    /// Authored body diameter (points) before `look.scale`. Bump to make the character bigger.
    private static let bodyDiameter: CGFloat = 200

    /// Rest center: horizontally centered, a little below middle (room for captions above).
    private var restCenter: CGPoint { CGPoint(x: size.width / 2, y: size.height * 0.45) }

    // Textures generated ONCE (no per-frame Core Graphics on the live view). (PebblesScene.swift:204-209)
    private static let bodyTexture = makeBodyTexture()
    private static let eyeTexture = makeEyeTexture()

    // Calm oval vs. happy "cheeks-up" crescent. (PebblesScene.swift:192-198)
    private static let eyeOpenPath = CGPath(ellipseIn: CGRect(x: -7, y: -8, width: 14, height: 16), transform: nil)
    private static let eyeCrescentPath: CGPath = {
        let p = CGMutablePath()
        p.addArc(center: CGPoint(x: 0, y: 7), radius: 10,
                 startAngle: .pi * 1.14, endAngle: .pi * 1.86, clockwise: false)
        return p
    }()
    private static let eyeColor = UIColor(charHex: 0x36271A)

    // MARK: Lifecycle

    override func didMove(to view: SKView) {
        backgroundColor = .clear
        scaleMode = .resizeFill
        view.preferredFramesPerSecond = 60
        if body.parent == nil { build() }
    }

    private func build() {
        body.texture = Self.bodyTexture
        body.size = CGSize(width: Self.bodyDiameter, height: Self.bodyDiameter)
        body.position = restCenter
        addChild(body)

        // A soft contact shadow grounds the orb so it doesn't float. (PebblesScene.swift:276-283)
        let shadow = SKSpriteNode(texture: Self.makeShadowTexture())
        shadow.size = CGSize(width: Self.bodyDiameter * 0.9, height: Self.bodyDiameter * 0.28)
        shadow.position = CGPoint(x: 0, y: -Self.bodyDiameter * 0.5)
        shadow.zPosition = -1
        shadow.alpha = 0.5
        body.addChild(shadow)

        leftEye  = makeEye(sign: -1); body.addChild(leftEye)
        rightEye = makeEye(sign:  1); body.addChild(rightEye)
    }

    private func makeEye(sign: CGFloat) -> SKShapeNode {
        let eye = SKShapeNode()
        eye.path = Self.eyeOpenPath
        eye.fillTexture = Self.eyeTexture     // glossy brown dome reads "wet/alive" vs flat black
        eye.fillColor = .white                // lets the texture show at full strength
        eye.strokeColor = .clear
        eye.position = CGPoint(x: sign * 24, y: -4)   // LOW eyes (just below midline) = cuter
        eye.zPosition = 10
        let catchlight = SKShapeNode(circleOfRadius: 3.4)
        catchlight.name = "catchlight"
        catchlight.fillColor = UIColor(white: 1, alpha: 0.95)
        catchlight.strokeColor = .clear
        catchlight.position = CGPoint(x: -3.5, y: 3.5)
        eye.addChild(catchlight)
        return eye
    }

    // MARK: State application (INPUT A — DISCRETE, drive from observation, NOT per frame)

    func apply(state: CharacterState, tone: CharacterTone = .neutral) {
        look = CharacterLook.make(state: state, tone: tone)
        if reduceMotion {
            look.breath = 0
            look.bounce = 0
        }
    }

    // MARK: Per-frame (THE HOT PATH)

    override func update(_ currentTime: TimeInterval) {
        if startTime < 0 { startTime = currentTime; lastTime = currentTime }
        let t = currentTime - startTime
        let dt = min(0.05, max(0, currentTime - lastTime))
        lastTime = currentTime

        // Pull live amplitude ONCE, here, off observation. (PebblesScene.swift:380)
        let amp = CGFloat(max(0, min(1, levelProvider())))

        advancePokeSquash(dt: dt)

        // Always-present life: a slow breath sinusoid. (PebblesScene.swift:381)
        let breath = look.breath > 0 ? CGFloat(sin(t * 2 * .pi / look.breath)) : 0

        // Amplitude -> scale, gated by energy: speaking swells OUT, listening draws IN.
        // (PebblesScene.swift:411-419)
        let ampScale: CGFloat
        switch look.energy {
        case .outward: ampScale = amp * 0.12 + (look.bounce > 0 ? CGFloat(abs(sin(t * 7))) * amp * 0.05 : 0)
        case .inward:  ampScale = -amp * 0.05
        case .none:    ampScale = 0
        }
        let scale = look.scale * (1 + breath * 0.02) + ampScale

        // Ease the body toward its target pose (lerp -> no jumps). (PebblesScene.swift:578-580)
        let target = CGPoint(x: restCenter.x, y: restCenter.y + look.rise + look.lean + breath * 2)
        let kPos = min(1, CGFloat(dt) * 8)
        body.position.x += (target.x - body.position.x) * kPos
        body.position.y += (target.y - body.position.y) * kPos

        // Scale with a volume-preserving squash, plus the transient tap squash. (PebblesScene.swift:572-575)
        let kScale = min(1, CGFloat(dt) * 10)
        let targetX = scale * (1 + pokeSquash * 0.10)
        let targetY = scale * look.squashY * (1 - pokeSquash * 0.18)
        body.xScale += (targetX - body.xScale) * kScale
        body.yScale += (targetY - body.yScale) * kScale

        // Wake/sleep dim. (PebblesScene.swift:384, 583)
        displayedAlpha += (look.alpha - displayedAlpha) * min(1, CGFloat(dt) * 4)
        body.alpha = displayedAlpha

        applyEyes(dt: dt, t: t, amp: amp)
    }

    /// Tap squash envelope: a smooth 0→1→0 over ~0.42s. (PebblesScene.swift:603-613)
    private func advancePokeSquash(dt: TimeInterval) {
        guard pokeSquashAge >= 0 else { return }
        pokeSquashAge += dt
        let dur: TimeInterval = 0.42
        if pokeSquashAge >= dur { pokeSquash = 0; pokeSquashAge = -1 }
        else { pokeSquash = CGFloat(sin(pokeSquashAge / dur * .pi)) }
    }

    // MARK: Eyes (they do the emotional work)

    private func applyEyes(dt: TimeInterval, t: TimeInterval, amp: CGFloat) {
        blinkClock += dt

        // Smile: sustained for the playful tone, else briefly on speaking peaks. (PebblesScene.swift:921-931)
        if look.crescentSustained {
            crescentHold = 1
        } else if look.crescentOnPeak {
            crescentHold = amp > 0.42 ? 1 : max(0, crescentHold - CGFloat(dt) / 0.45)
        } else {
            crescentHold = 0
        }
        let crescent = crescentHold > 0.15
        setEyeStyle(crescent: crescent)
        if crescent {
            for (sign, eye) in [(-1.0, leftEye), (1.0, rightEye)] {
                eye.yScale += (1 - eye.yScale) * 0.4
                eye.position.x += (CGFloat(sign) * 24 - eye.position.x) * 0.3
                eye.position.y += (3 - eye.position.y) * 0.3
            }
            return
        }

        // Openness per state. (PebblesScene.swift:947-958)
        var openY: CGFloat = 1
        var posY: CGFloat = -4
        switch look.eyes {
        case .closed: openY = 0.08
        case .half:   openY = 0.5
        case .open:   openY = 1
        case .wide:   openY = 1.18
        case .up:     openY = 1; posY = 3
        }

        // Asymmetric blink: fast close (70ms), slow open (210ms). (PebblesScene.swift:960-975)
        if look.eyes == .open || look.eyes == .wide {
            if blinkAge < 0, blinkClock > nextBlink { blinkAge = 0 }
            if blinkAge >= 0 {
                blinkAge += dt
                if blinkAge < 0.07 {
                    openY = min(openY, 1 - CGFloat(blinkAge / 0.07) * 0.92)
                } else if blinkAge < 0.28 {
                    openY = min(openY, 0.08 + CGFloat((blinkAge - 0.07) / 0.21) * 0.92)
                } else {
                    blinkAge = -1
                    nextBlink = blinkClock + Double.random(in: 2.8...5.5)
                }
            }
        }

        // Gentle idle look-around (open rest only). (PebblesScene.swift:977)
        let lookAround = (look.eyes == .open) ? CGFloat(sin(t * 0.5)) * 2 : 0

        for (sign, eye) in [(-1.0, leftEye), (1.0, rightEye)] {
            // Whisper-quiet hand-made asymmetry: right eye a hair lower/smaller. (PebblesScene.swift:984-994)
            let asymY: CGFloat = (sign > 0) ? -1 : 0
            let sizeAsym: CGFloat = (sign > 0) ? 0.96 : 1
            eye.yScale += (openY * sizeAsym - eye.yScale) * 0.4
            eye.position.x += (CGFloat(sign) * 24 + lookAround - eye.position.x) * 0.3
            eye.position.y += (posY + asymY - eye.position.y) * 0.3
        }
    }

    /// Swap eye geometry only on transition: filled oval <-> stroked crescent. (PebblesScene.swift:998-1021)
    private func setEyeStyle(crescent: Bool) {
        guard crescent != eyesAreCrescent else { return }
        eyesAreCrescent = crescent
        for eye in [leftEye, rightEye] {
            let catchlight = eye.childNode(withName: "catchlight")
            if crescent {
                eye.path = Self.eyeCrescentPath
                eye.fillColor = .clear
                eye.fillTexture = nil
                eye.strokeColor = Self.eyeColor
                eye.lineWidth = 3.4
                eye.lineCap = .round
                catchlight?.isHidden = true
            } else {
                eye.path = Self.eyeOpenPath
                eye.fillTexture = Self.eyeTexture
                eye.fillColor = .white
                eye.strokeColor = .clear
                eye.lineWidth = 0
                catchlight?.isHidden = false
            }
        }
    }

    // MARK: Tap (optional delight — fires onPoke + a transient squash)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        onPoke()
        pokeSquashAge = 0
    }

    // MARK: Procedural textures (generated once; warm "ceramic" palette from PebblesScene.swift:183-187)

    /// A round, top-lit warm-bone -> greige -> clay orb with a soft underside darkening.
    private static func makeBodyTexture() -> SKTexture {
        let dim: CGFloat = 240
        let size = CGSize(width: dim, height: dim)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let space = CGColorSpaceCreateDeviceRGB()
        let hi  = UIColor(charHex: 0xD8C8AC)
        let mid = UIColor(charHex: 0xBCAB8B)
        let lo  = UIColor(charHex: 0x9C8868)
        let shadow = UIColor(charHex: 0x4A3B28)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 10, dy: 10)
            cg.addEllipse(in: rect); cg.clip()
            // Form: light toward the top.
            if let g = CGGradient(colorsSpace: space,
                                  colors: [hi.cgColor, mid.cgColor, lo.cgColor] as CFArray,
                                  locations: [0, 0.6, 1]) {
                let start = CGPoint(x: rect.midX - rect.width * 0.12, y: rect.minY + rect.height * 0.28)
                cg.drawRadialGradient(g, startCenter: start, startRadius: 2,
                                      endCenter: CGPoint(x: rect.midX, y: rect.midY),
                                      endRadius: rect.width * 0.66, options: [.drawsAfterEndLocation])
            }
            // Underside ambient-occlusion wash (top -> bottom).
            if let ao = CGGradient(colorsSpace: space,
                                   colors: [shadow.withAlphaComponent(0).cgColor,
                                            shadow.withAlphaComponent(0.05).cgColor,
                                            shadow.withAlphaComponent(0.5).cgColor] as CFArray,
                                   locations: [0, 0.46, 1]) {
                cg.drawLinearGradient(ao, start: CGPoint(x: rect.midX, y: rect.minY),
                                      end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
            }
        }
        let tex = SKTexture(image: image); tex.filteringMode = .linear; return tex
    }

    /// A soft radial blob (white core -> transparent) for the contact shadow. (PebblesScene.swift:1260-1280)
    private static func makeShadowTexture() -> SKTexture {
        let dim: CGFloat = 160
        let size = CGSize(width: dim, height: dim)
        let format = UIGraphicsImageRendererFormat.preferred(); format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let rect = CGRect(origin: .zero, size: size)
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [UIColor(white: 0.28, alpha: 0.9).cgColor,
                                           UIColor(white: 0.28, alpha: 0).cgColor] as CFArray,
                                  locations: [0, 1]) {
                cg.drawRadialGradient(g, startCenter: CGPoint(x: rect.midX, y: rect.midY), startRadius: 1,
                                      endCenter: CGPoint(x: rect.midX, y: rect.midY),
                                      endRadius: rect.width * 0.5, options: [])
            }
        }
        let tex = SKTexture(image: image); tex.filteringMode = .linear; return tex
    }

    /// A glossy warm-brown eye dome. (PebblesScene.swift:1285-1310)
    private static func makeEyeTexture() -> SKTexture {
        let dim: CGFloat = 64
        let size = CGSize(width: dim, height: dim)
        let format = UIGraphicsImageRendererFormat.preferred(); format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let rect = CGRect(origin: .zero, size: size)
            cg.addEllipse(in: rect); cg.clip()
            let colors = [UIColor(charHex: 0x5A4026).cgColor,
                          eyeColor.cgColor,
                          UIColor(charHex: 0x231910).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: colors, locations: [0, 0.55, 1]) {
                let start = CGPoint(x: rect.midX - rect.width * 0.18, y: rect.minY + rect.height * 0.28)
                cg.drawRadialGradient(g, startCenter: start, startRadius: 1,
                                      endCenter: CGPoint(x: rect.midX, y: rect.midY),
                                      endRadius: rect.width * 0.6, options: [.drawsAfterEndLocation])
            }
        }
        let tex = SKTexture(image: image); tex.filteringMode = .linear; return tex
    }
}

// MARK: - Tiny inlined helper (copy of Theme.swift:36-45, renamed to avoid collisions)

private extension UIColor {
    convenience init(charHex hex: UInt, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}
