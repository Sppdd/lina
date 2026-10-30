import AppKit
import SceneKit
import SwiftUI

/// Lina as a small 3D figure, built from the reference art in `media/` (Nano Banana renders, October 2026):
/// a soft-vinyl toy with a tall oval face, glossy pink cheek balls, dot eyes, tube brows, a smile with one tooth,
/// chunky clay hair with a middle part and a headband, a white sweatshirt with a rolled collar, and tiny hands
/// poking out of her hair. Her hair takes the mood's color and her face the mood's expression, like the 2D drawing.
///
/// Built from SceneKit primitives rather than the Rodin `.glb` in `media/`: that mesh has 500k triangles and no rig,
/// so it couldn't change expression, and SceneKit can't open glTF. Everything here is a few hundred triangles per part.
@MainActor
final class LinaModel {
    let scene = SCNScene()
    let camera = SCNNode()

    /// Width over height of the head-only framing, matching the 2D drawing's crop.
    static let headAspect: CGFloat = 60.0 / 62.0

    private let root = SCNNode()
    private let headPivot = SCNNode()
    private let hairMaterial = LinaModel.material(.systemPurple, rough: 0.32, coat: 0.55)
    private let bandMaterial = LinaModel.material(.systemPurple, rough: 0.3, coat: 0.4)

    private var eyes: [SCNNode] = []        // lids around the dark ovals: scaled for wide eyes and blinks, moved for "thinking"
    private var sparkles: [SCNNode] = []
    private var smileEyes: [SCNNode] = []   // ∩, for happy
    private var closedEyes: [SCNNode] = []  // ∪, for asleep or a blink drawn as lines
    private var brows: [SCNNode] = []
    private let mouth = SCNNode()
    private let tooth = SCNNode()
    private var hands: [SCNNode] = []

    private var current: (mood: Mood, head: Bool, animated: Bool)?

    init() {
        scene.background.contents = NSColor.clear
        scene.lightingEnvironment.contents = Self.environment()
        scene.lightingEnvironment.intensity = 0.8
        scene.rootNode.addChildNode(root)
        addLights()
        addCamera()
        buildBody()
        buildHead()
    }

    // MARK: Posing

    /// Shows a mood. Animated, she moves, blinks and her hands wiggle; otherwise she holds still for a picture.
    func pose(_ mood: Mood, head: Bool, animated: Bool) {
        if let current, current.mood == mood, current.head == head, current.animated == animated { return }
        let moodChanged = current?.mood != mood
        current = (mood, head, animated)

        frame(head: head)
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated && moodChanged ? 0.28 : 0
        apply(Expression.of(mood), mood: mood)
        SCNTransaction.commit()

        root.removeAllActions()
        headPivot.removeAllActions()
        eyes.forEach { $0.removeAllActions() }
        hands.forEach {
            $0.removeAllActions()
            $0.eulerAngles.z = 0
        }
        if animated {
            startMotion(mood)
        } else {
            root.eulerAngles = SCNVector3(0, -0.14, 0)
            root.position = SCNVector3Zero
            root.scale = SCNVector3(1, 1, 1)
            headPivot.eulerAngles = SCNVector3Zero
        }
    }

    private func frame(head: Bool) {
        let target = head ? SCNVector3(0, 1.64, 0) : SCNVector3(0, 1.30, 0)
        camera.position = head ? SCNVector3(0, 1.70, 4.4) : SCNVector3(0, 1.40, 7.0)
        camera.look(at: target)
    }

    private func apply(_ e: Expression, mood: Mood) {
        let hair = Self.hairColor(mood)
        hairMaterial.diffuse.contents = hair
        bandMaterial.diffuse.contents = hair.blended(withFraction: 0.28, of: .black) ?? hair

        let openEyes = e.eyes == .open || e.eyes == .wide || e.eyes == .up
        for (i, eye) in eyes.enumerated() {
            eye.isHidden = !openEyes
            let wide = e.eyes == .wide
            eye.scale = wide ? SCNVector3(1.15, 1.18, 1) : SCNVector3(1, 1, 1)
            sparkles[i].isHidden = !wide
            eye.position = e.eyes == .up ? SCNVector3(0.01, 0.022, 0) : SCNVector3Zero
        }
        smileEyes.forEach { $0.isHidden = e.eyes != .smiling }
        closedEyes.forEach { $0.isHidden = e.eyes != .closed }

        for (i, brow) in brows.enumerated() {
            // i == 0 is her right brow (viewer's left), i == 1 her left.
            let inward: CGFloat = i == 0 ? 1 : -1
            switch e.brows {
            case .calm:
                brow.position.y = 0; brow.eulerAngles.z = 0
            case .raised:
                brow.position.y = 0.03; brow.eulerAngles.z = 0
            case .tilted:
                brow.position.y = i == 1 ? 0.03 : 0
                brow.eulerAngles.z = i == 1 ? 0.16 : -0.05
            case .worried:
                brow.position.y = 0.012; brow.eulerAngles.z = 0.3 * inward
            }
        }

        mouth.geometry = Self.mouthShape(e.mouth)
        mouth.geometry?.firstMaterial = e.mouth == .oh || e.mouth == .grin ? Self.mouthInside : Self.line
        let toothAt: CGFloat? = switch e.mouth {
        case .smile: -0.04
        case .soft: -0.028
        default: nil
        }
        tooth.isHidden = toothAt == nil
        tooth.position = SCNVector3(0.04, toothAt ?? 0, 0.006)
    }

    private func startMotion(_ mood: Mood) {
        let base: CGFloat = -0.18
        root.eulerAngles = SCNVector3(0, base, 0)
        root.position = SCNVector3Zero
        root.scale = SCNVector3(1, 1, 1)

        // A slow look from side to side, always.
        let swing: CGFloat = mood == .sleeping ? 0.03 : 0.08
        let sway = SCNAction.sequence([
            .rotateTo(x: 0, y: base + swing, z: 0, duration: 2.8, usesShortestUnitArc: true),
            .rotateTo(x: 0, y: base - swing, z: 0, duration: 2.8, usesShortestUnitArc: true),
        ])
        sway.timingMode = .easeInEaseOut
        root.runAction(.repeatForever(sway))

        // How she holds her head.
        let tilt: SCNVector3 = switch mood {
        case .listening: SCNVector3(-0.06, 0, 0.13)
        case .thinking: SCNVector3(0.02, 0.12, -0.1)
        case .worried: SCNVector3(0.05, 0, 0.05)
        case .sleeping: SCNVector3(0.2, 0, 0.12)
        default: SCNVector3Zero
        }
        headPivot.runAction(.rotateTo(x: tilt.x, y: tilt.y, z: tilt.z, duration: 0.35, usesShortestUnitArc: true))
        let nodSize: CGFloat = mood == .sleeping ? 0.05 : 0.025
        let nod = SCNAction.sequence([
            .rotateBy(x: nodSize, y: 0, z: 0, duration: mood == .sleeping ? 2.4 : 1.6),
            .rotateBy(x: -nodSize, y: 0, z: 0, duration: mood == .sleeping ? 2.4 : 1.6),
        ])
        nod.timingMode = .easeInEaseOut
        headPivot.runAction(.sequence([.wait(duration: 0.35), .repeatForever(nod)]))

        // A little something on arrival.
        switch mood {
        case .found:
            root.runAction(.sequence([.scale(to: 1.07, duration: 0.12), .scale(to: 0.98, duration: 0.12), .scale(to: 1, duration: 0.1)]))
        case .happy:
            let hop = SCNAction.sequence([.moveBy(x: 0, y: 0.12, z: 0, duration: 0.16), .moveBy(x: 0, y: -0.12, z: 0, duration: 0.16)])
            hop.timingMode = .easeOut
            root.runAction(.sequence([hop, hop]))
        case .worried:
            let shake = SCNAction.sequence([.rotateBy(x: 0, y: 0.07, z: 0, duration: 0.07), .rotateBy(x: 0, y: -0.14, z: 0, duration: 0.12),
                                            .rotateBy(x: 0, y: 0.07, z: 0, duration: 0.07)])
            headPivot.runAction(.sequence([.wait(duration: 0.35), shake, shake]))
        default:
            break
        }

        // Blinks, a few seconds apart, when her eyes are open.
        let e = Expression.of(mood)
        if e.eyes == .open || e.eyes == .wide || e.eyes == .up {
            let height: CGFloat = e.eyes == .wide ? 1.18 : 1
            let blink = SCNAction.sequence([.wait(duration: 3.2, withRange: 2.4), Self.blink(height)])
            eyes.forEach { $0.runAction(.repeatForever(blink)) }
        }

        // The tiny hands in her hair wave, faster when she has news.
        let quick = mood == .found || mood == .happy || mood == .listening
        for (i, hand) in hands.enumerated() {
            let amount: CGFloat = mood == .sleeping ? 0.08 : 0.32
            let time = (quick ? 0.22 : 0.6) + Double(i % 3) * 0.07
            let wave = SCNAction.sequence([
                .rotateBy(x: 0, y: 0, z: amount, duration: time),
                .rotateBy(x: 0, y: 0, z: -amount, duration: time),
            ])
            wave.timingMode = .easeInEaseOut
            hand.runAction(.sequence([.wait(duration: Double(i) * 0.13), .repeatForever(wave)]))
        }
    }

    /// One blink: the eye squashes to a line and opens again, keeping its width. `height` is its open height.
    private static func blink(_ height: CGFloat) -> SCNAction {
        let duration: CGFloat = 0.17
        return .customAction(duration: TimeInterval(duration)) { node, elapsed in
            let t = min(1, elapsed / duration)
            let open = t < 0.4 ? 1 - t / 0.4 : (t - 0.4) / 0.6
            node.scale.y = height * (0.08 + 0.92 * open)
        }
    }

    // MARK: Expressions

    struct Expression {
        enum Eyes { case open, wide, up, smiling, closed }
        enum Brows { case calm, raised, tilted, worried }
        enum Mouth { case smile, soft, flat, oh, grin, wavy, small }
        var eyes: Eyes
        var brows: Brows
        var mouth: Mouth

        static func of(_ mood: Mood) -> Expression {
            switch mood {
            case .idle: Expression(eyes: .open, brows: .calm, mouth: .smile)
            case .listening: Expression(eyes: .wide, brows: .raised, mouth: .soft)
            case .thinking: Expression(eyes: .up, brows: .tilted, mouth: .flat)
            case .found: Expression(eyes: .wide, brows: .raised, mouth: .oh)
            case .happy: Expression(eyes: .smiling, brows: .calm, mouth: .grin)
            case .worried: Expression(eyes: .open, brows: .worried, mouth: .wavy)
            case .sleeping: Expression(eyes: .closed, brows: .calm, mouth: .small)
            }
        }
    }

    // MARK: Building her

    private static let skin = material(NSColor(srgbRed: 0.94, green: 0.75, blue: 0.66, alpha: 1), rough: 0.45, coat: 0.15)
    private static let cheek = material(NSColor(srgbRed: 0.94, green: 0.52, blue: 0.57, alpha: 1), rough: 0.18, coat: 0.9)
    private static let eye = material(NSColor(srgbRed: 0.16, green: 0.08, blue: 0.10, alpha: 1), rough: 0.12, coat: 1)
    private static let line = material(NSColor(srgbRed: 0.30, green: 0.14, blue: 0.17, alpha: 1), rough: 0.35, coat: 0.3)
    private static let mouthInside = material(NSColor(srgbRed: 0.42, green: 0.13, blue: 0.17, alpha: 1), rough: 0.3, coat: 0.3)
    private static let white = material(NSColor(srgbRed: 0.99, green: 0.98, blue: 0.97, alpha: 1), rough: 0.25, coat: 0.6)
    private static let shirt = material(NSColor(srgbRed: 0.88, green: 0.87, blue: 0.90, alpha: 1), rough: 0.6, coat: 0.1)
    private static let collar = material(NSColor(srgbRed: 0.84, green: 0.83, blue: 0.87, alpha: 1), rough: 0.5, coat: 0.2)
    private static let handSkin = material(NSColor(srgbRed: 0.93, green: 0.68, blue: 0.62, alpha: 1), rough: 0.42, coat: 0.2)

    /// The face is an ellipsoid: features sit on its surface and face outwards.
    private static let faceCenter = SCNVector3(0, 1.60, 0)
    private static let faceRadii = SCNVector3(0.385, 0.55, 0.36)

    private func buildBody() {
        let body = Self.ellipsoid(SCNVector3(0.58, 0.5, 0.34), Self.shirt)
        body.position = SCNVector3(0, 0.28, -0.06)
        root.addChildNode(body)

        let collar = SCNNode(geometry: SCNTorus(ringRadius: 0.13, pipeRadius: 0.052))
        collar.geometry?.firstMaterial = Self.collar
        collar.position = SCNVector3(0, 0.80, -0.05)
        collar.scale = SCNVector3(1.12, 1, 0.95)
        root.addChildNode(collar)

        let neck = SCNNode(geometry: SCNCylinder(radius: 0.085, height: 0.55))
        neck.geometry?.firstMaterial = Self.skin
        neck.position = SCNVector3(0, 0.98, -0.04)
        root.addChildNode(neck)

        // The head turns and nods around the top of her neck.
        headPivot.position = SCNVector3(0, 1.15, -0.03)
        root.addChildNode(headPivot)
    }

    private func buildHead() {
        let head = SCNNode()
        head.position = SCNVector3(0, -1.15, 0.03)  // children use whole-figure coordinates
        headPivot.addChildNode(head)

        let face = Self.ellipsoid(Self.faceRadii, Self.skin)
        face.position = Self.faceCenter
        head.addChildNode(face)

        for side: CGFloat in [-1, 1] {
            let ear = Self.ellipsoid(SCNVector3(0.06, 0.1, 0.075), Self.skin)
            ear.position = SCNVector3(0.395 * side, 1.58, -0.02)
            head.addChildNode(ear)

            let cheek = SCNNode(geometry: SCNSphere(radius: 0.095))
            cheek.geometry?.firstMaterial = Self.cheek
            Self.place(cheek, x: 0.245 * side, y: 1.45, lift: -0.035)
            head.addChildNode(cheek)

            // Eyes: a holder on the face; inside it a lid that wide eyes, looks and blinks move and scale;
            // inside that the oval itself. (The oval's own scale is its shape, so it's never touched.)
            let holder = SCNNode()
            Self.place(holder, x: 0.155 * side, y: 1.66, lift: -0.004)
            let lid = SCNNode()
            let oval = Self.ellipsoid(SCNVector3(0.034, 0.048, 0.021), Self.eye)
            let sparkle = SCNNode(geometry: SCNSphere(radius: 0.009))
            sparkle.geometry?.firstMaterial = Self.white
            sparkle.position = SCNVector3(0.01, 0.018, 0.016)
            lid.addChildNode(oval)
            lid.addChildNode(sparkle)
            holder.addChildNode(lid)
            let smiling = SCNNode(geometry: Self.stroked(width: 0.018, depth: 0.016) { p in
                p.move(to: CGPoint(x: -0.034, y: -0.01))
                p.addQuadLine(to: CGPoint(x: 0.034, y: -0.01), control: CGPoint(x: 0, y: 0.04))
            })
            smiling.geometry?.firstMaterial = Self.eye
            let closed = SCNNode(geometry: Self.stroked(width: 0.016, depth: 0.016) { p in
                p.move(to: CGPoint(x: -0.034, y: 0.004))
                p.addQuadLine(to: CGPoint(x: 0.034, y: 0.004), control: CGPoint(x: 0, y: -0.032))
            })
            closed.geometry?.firstMaterial = Self.eye
            holder.addChildNode(smiling)
            holder.addChildNode(closed)
            head.addChildNode(holder)
            eyes.append(lid)
            sparkles.append(sparkle)
            smileEyes.append(smiling)
            closedEyes.append(closed)

            // Brows: thin raised tubes.
            let browHolder = SCNNode()
            Self.place(browHolder, x: 0.155 * side, y: 1.79, lift: 0.002)
            let brow = SCNNode(geometry: Self.stroked(width: 0.02, depth: 0.018) { p in
                p.move(to: CGPoint(x: -0.065, y: -0.008))
                p.addQuadLine(to: CGPoint(x: 0.065, y: -0.008), control: CGPoint(x: 0, y: 0.03))
            })
            brow.geometry?.firstMaterial = Self.line
            browHolder.addChildNode(brow)
            head.addChildNode(browHolder)
            brows.append(brow)
        }

        let nose = Self.ellipsoid(SCNVector3(0.036, 0.048, 0.062), Self.skin)
        Self.place(nose, x: 0, y: 1.545, lift: -0.008)
        head.addChildNode(nose)

        let mouthHolder = SCNNode()
        Self.place(mouthHolder, x: 0, y: 1.39, lift: 0.0)
        mouthHolder.addChildNode(mouth)
        let toothBox = SCNBox(width: 0.026, height: 0.03, length: 0.014, chamferRadius: 0.008)
        toothBox.firstMaterial = Self.white
        tooth.geometry = toothBox
        mouthHolder.addChildNode(tooth)
        head.addChildNode(mouthHolder)

        buildHair(on: head)
    }

    private func buildHair(on head: SCNNode) {
        // The crown sits back, so her forehead shows under the part.
        let crown = Self.ellipsoid(SCNVector3(0.43, 0.31, 0.37), hairMaterial)
        crown.position = SCNVector3(0, 2.0, -0.13)
        head.addChildNode(crown)

        for side: CGFloat in [-1, 1] {
            // From the middle part the hair sweeps out and down to each side, high at the part, low at the temple.
            let sweep = Self.ellipsoid(SCNVector3(0.25, 0.12, 0.19), hairMaterial)
            sweep.position = SCNVector3(0.23 * side, 2.0, 0.07)
            sweep.eulerAngles.z = -0.62 * side
            head.addChildNode(sweep)

            let temple = Self.ellipsoid(SCNVector3(0.11, 0.2, 0.15), hairMaterial)
            temple.position = SCNVector3(0.37 * side, 1.83, -0.02)
            head.addChildNode(temple)
        }

        // The back: a row of fat vertical locks, like a bunch of bananas, falling to her shoulders.
        for degrees: CGFloat in [-100, -66, -33, 0, 33, 66, 100] {
            let a = degrees * .pi / 180
            let x = 0.37 * sin(a), z = -0.21 - 0.22 * cos(a)
            let lock = SCNNode(geometry: SCNCapsule(capRadius: 0.15, height: 1.1))
            lock.geometry?.firstMaterial = hairMaterial
            lock.position = SCNVector3(x, 1.42, z)
            head.addChildNode(lock)
            // Each lock ends in a rounder bulb, like the reference's bunch-of-bananas back.
            let end = Self.ellipsoid(SCNVector3(0.175, 0.2, 0.17), hairMaterial)
            end.position = SCNVector3(x * 1.06, 1.0, z)
            head.addChildNode(end)
        }

        // A headband over the top, behind the bangs.
        let band = SCNNode(geometry: Self.arcBand(from: 16, to: 164, inner: 0.92, depth: 0.07))
        band.geometry?.firstMaterial = bandMaterial
        band.position = SCNVector3(0, 1.72, -0.02)
        band.scale = SCNVector3(0.47, 0.6, 1)
        head.addChildNode(band)

        // Tiny hands poking out of her hair, three on each side.
        for side: CGFloat in [-1, 1] {
            for (y, out, depth) in [(1.60, 0.51, -0.18), (1.30, 0.54, -0.21), (1.03, 0.56, -0.19)] as [(CGFloat, CGFloat, CGFloat)] {
                let hand = Self.tinyHand()
                hand.position = SCNVector3(out * side, y, depth)
                if side < 0 { hand.eulerAngles.y = .pi }
                head.addChildNode(hand)
                hands.append(hand)
            }
        }
    }

    /// A small hand reaching out along +x from its wrist, which is the node's origin.
    private static func tinyHand() -> SCNNode {
        let hand = SCNNode()
        let arm = SCNNode(geometry: SCNCapsule(capRadius: 0.019, height: 0.08))
        arm.geometry?.firstMaterial = handSkin
        arm.eulerAngles.z = .pi / 2
        hand.addChildNode(arm)
        let palm = ellipsoid(SCNVector3(0.038, 0.04, 0.02), handSkin)
        palm.position = SCNVector3(0.055, 0, 0)
        hand.addChildNode(palm)
        for degrees: CGFloat in [-46, -16, 12, 40, 82] {
            let a = degrees * .pi / 180
            let length: CGFloat = degrees == 82 ? 0.034 : 0.048
            let finger = SCNNode(geometry: SCNCapsule(capRadius: 0.012, height: length))
            finger.geometry?.firstMaterial = handSkin
            let reach: CGFloat = 0.034 + length / 2 - 0.006
            finger.position = SCNVector3(0.055 + reach * cos(a), reach * sin(a), 0)
            finger.eulerAngles.z = a - .pi / 2
            hand.addChildNode(finger)
        }
        return hand
    }

    // MARK: Lights and camera

    private func addLights() {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 200
        ambient.light?.color = NSColor(srgbRed: 0.88, green: 0.87, blue: 1.0, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        // Key light from the front left and above, warm.
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 850
        key.light?.color = NSColor(srgbRed: 1.0, green: 0.96, blue: 0.92, alpha: 1)
        key.eulerAngles = SCNVector3(-0.55, -0.52, 0)
        scene.rootNode.addChildNode(key)

        // Rim light from behind on the right, lavender, to separate her from dark backgrounds.
        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .directional
        rim.light?.intensity = 750
        rim.light?.color = NSColor(srgbRed: 0.76, green: 0.74, blue: 1.0, alpha: 1)
        rim.eulerAngles = SCNVector3(-0.4, .pi - 0.55, 0)
        scene.rootNode.addChildNode(rim)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 220
        fill.eulerAngles = SCNVector3(0.1, 0.7, 0)
        scene.rootNode.addChildNode(fill)
    }

    private func addCamera() {
        let cam = SCNCamera()
        cam.fieldOfView = 18
        cam.projectionDirection = .vertical
        cam.zNear = 0.1
        cam.zFar = 40
        camera.camera = cam
        scene.rootNode.addChildNode(camera)
        frame(head: true)
    }

    // MARK: Helpers

    static func material(_ color: NSColor, rough: CGFloat, coat: CGFloat = 0) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = NSNumber(value: Double(rough))
        m.metalness.contents = NSNumber(value: 0.0)
        if coat > 0 {
            m.clearCoat.contents = NSNumber(value: Double(coat))
            m.clearCoatRoughness.contents = NSNumber(value: 0.12)
        }
        return m
    }

    /// Lina's hair in a mood. When she's ready it's the reference renders' violet; other moods use their color.
    static func hairColor(_ mood: Mood) -> NSColor {
        mood == .idle ? NSColor(srgbRed: 0.42, green: 0.35, blue: 0.84, alpha: 1) : mood.nsHair
    }

    private static func ellipsoid(_ radii: SCNVector3, _ material: SCNMaterial) -> SCNNode {
        let sphere = SCNSphere(radius: 1)
        sphere.segmentCount = 48
        sphere.firstMaterial = material
        let node = SCNNode(geometry: sphere)
        node.scale = radii
        return node
    }

    /// Puts a node on the face's surface at (x, y), turned to face out from it.
    private static func place(_ node: SCNNode, x: CGFloat, y: CGFloat, lift: CGFloat) {
        let r = faceRadii, c = faceCenter
        let nx = x / r.x, ny = (y - c.y) / r.y
        let z = r.z * sqrt(max(0, 1 - nx * nx - ny * ny))
        node.position = SCNVector3(x, y, c.z + z + lift)
        // The surface normal of an ellipsoid: (x/a², y/b², z/c²).
        let normal = (x: x / (r.x * r.x), y: (y - c.y) / (r.y * r.y), z: max(z, 0.01) / (r.z * r.z))
        node.eulerAngles = SCNVector3(-atan2(normal.y, normal.z), atan2(normal.x, normal.z), 0)
    }

    /// A stroked curve made solid, with rounded edges: brows, the mouth, closed eyes.
    private static func stroked(width: CGFloat, depth: CGFloat, _ build: (CGMutablePath) -> Void) -> SCNShape {
        let path = CGMutablePath()
        build(path)
        let outline = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 4)
        return solid(outline, depth: depth, chamfer: min(width, depth) * 0.4)
    }

    private static func solid(_ path: CGPath, depth: CGFloat, chamfer: CGFloat) -> SCNShape {
        let bezier = NSBezierPath(cgPath: path)
        bezier.flatness = 0.0008
        let shape = SCNShape(path: bezier, extrusionDepth: depth)
        shape.chamferRadius = chamfer
        return shape
    }

    /// Part of a ring, for the headband: angles in degrees, radius 1 outside and `inner` inside.
    private static func arcBand(from start: CGFloat, to end: CGFloat, inner: CGFloat, depth: CGFloat) -> SCNShape {
        let path = CGMutablePath()
        let a0 = start * .pi / 180, a1 = end * .pi / 180
        path.addArc(center: .zero, radius: 1, startAngle: a0, endAngle: a1, clockwise: false)
        path.addArc(center: .zero, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
        path.closeSubpath()
        return solid(path, depth: depth, chamfer: 0.012)
    }

    private static var mouths: [Expression.Mouth: SCNShape] = [:]

    private static func mouthShape(_ kind: Expression.Mouth) -> SCNShape {
        if let hit = mouths[kind] { return hit }
        let shape: SCNShape
        switch kind {
        case .smile:
            shape = stroked(width: 0.022, depth: 0.03) { p in
                p.move(to: CGPoint(x: -0.09, y: 0))
                p.addQuadLine(to: CGPoint(x: 0.09, y: 0), control: CGPoint(x: 0, y: -0.06))
            }
        case .soft:
            shape = stroked(width: 0.02, depth: 0.03) { p in
                p.move(to: CGPoint(x: -0.06, y: 0))
                p.addQuadLine(to: CGPoint(x: 0.06, y: 0), control: CGPoint(x: 0, y: -0.035))
            }
        case .flat:
            shape = stroked(width: 0.02, depth: 0.03) { p in
                p.move(to: CGPoint(x: -0.055, y: 0))
                p.addLine(to: CGPoint(x: 0.055, y: -0.006))
            }
        case .small:
            shape = stroked(width: 0.018, depth: 0.03) { p in
                p.move(to: CGPoint(x: -0.035, y: 0))
                p.addQuadLine(to: CGPoint(x: 0.035, y: 0), control: CGPoint(x: 0, y: -0.018))
            }
        case .wavy:
            shape = stroked(width: 0.02, depth: 0.03) { p in
                p.move(to: CGPoint(x: -0.08, y: -0.01))
                p.addQuadLine(to: CGPoint(x: 0, y: -0.01), control: CGPoint(x: -0.04, y: 0.025))
                p.addQuadLine(to: CGPoint(x: 0.08, y: -0.01), control: CGPoint(x: 0.04, y: -0.045))
            }
        case .oh:
            let path = CGPath(ellipseIn: CGRect(x: -0.03, y: -0.05, width: 0.06, height: 0.07), transform: nil)
            shape = solid(path, depth: 0.03, chamfer: 0.01)
        case .grin:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -0.085, y: 0))
            path.addLine(to: CGPoint(x: 0.085, y: 0))
            path.addQuadCurve(to: CGPoint(x: 0, y: -0.075), control: CGPoint(x: 0.08, y: -0.075))
            path.addQuadCurve(to: CGPoint(x: -0.085, y: 0), control: CGPoint(x: -0.08, y: -0.075))
            path.closeSubpath()
            shape = solid(path, depth: 0.03, chamfer: 0.01)
        }
        mouths[kind] = shape
        return shape
    }

    /// A soft lavender-to-night gradient for reflections, like the reference renders' backdrop.
    private static func environment() -> NSImage {
        let size = NSSize(width: 256, height: 128)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [
            NSColor(srgbRed: 0.96, green: 0.94, blue: 1.0, alpha: 1),
            NSColor(srgbRed: 0.62, green: 0.58, blue: 0.86, alpha: 1),
            NSColor(srgbRed: 0.10, green: 0.09, blue: 0.24, alpha: 1),
        ])?.draw(in: NSRect(origin: .zero, size: size), angle: -90)
        image.unlockFocus()
        return image
    }
}

private extension CGMutablePath {
    func addQuadLine(to end: CGPoint, control: CGPoint) {
        addQuadCurve(to: end, control: control)
    }
}

// MARK: - Showing her

/// Lina moving, in a SwiftUI view: SceneKit renders her at 30 frames a second while she's on screen.
struct Lina3DView: NSViewRepresentable {
    let mood: Mood
    let head: Bool

    final class Coordinator {
        var model: LinaModel?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let model = LinaModel()
        let view = SCNView(frame: .zero)
        view.scene = model.scene
        view.pointOfView = model.camera
        view.backgroundColor = .clear
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        view.allowsCameraControl = false
        view.isPlaying = true
        view.rendersContinuously = false
        model.pose(mood, head: head, animated: true)
        context.coordinator.model = model
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.model?.pose(mood, head: head, animated: true)
    }
}

/// Still pictures of Lina, rendered once per mood and size and kept: cards, tips, the menu bar.
@MainActor
enum LinaRender {
    private static var cache: [String: NSImage] = [:]
    private static let model = LinaModel()
    private static let renderer: SCNRenderer? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let r = SCNRenderer(device: device, options: nil)
        r.scene = model.scene
        r.pointOfView = model.camera
        return r
    }()

    /// Whether this Mac can draw her in 3D. Without Metal, Lina falls back to her 2D drawing.
    static var isAvailable: Bool { renderer != nil }

    /// `points` is the height on screen; the picture is rendered at twice that for Retina.
    static func image(_ mood: Mood, points: CGFloat, head: Bool) -> NSImage? {
        let key = "\(mood.rawValue)-\(Int(points))-\(head)"
        if let hit = cache[key] { return hit }
        guard let renderer else { return nil }
        model.pose(mood, head: head, animated: false)
        let aspect = head ? LinaModel.headAspect : 1
        let pixels = CGSize(width: (points * 2 * aspect).rounded(), height: (points * 2).rounded())
        let image = renderer.snapshot(atTime: 0, with: pixels, antialiasingMode: .multisampling4X)
        image.size = NSSize(width: pixels.width / 2, height: pixels.height / 2)
        cache[key] = image
        return image
    }
}
