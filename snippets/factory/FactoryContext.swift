//
//  FactoryContext.swift  (REDACTED / adapted for minimal-realtime-kit)
//  Source: OpenAIRealtimeSample/Factory/FactoryContext.swift:18-49  (host() at :43-48)
//  Host bridge source: OpenAIRealtimeSample/App/SwiftUIViewController.swift:6-10
//
//  App capabilities handed to a component builder as TYPED CLOSURES only. The model
//  passes DATA (an id + a payload); BEHAVIOR lives here, in the app, so a component can
//  call back into the app (e.g. an interactive choice) WITHOUT the model ever shipping
//  code.
//
//  `@MainActor` because builders construct `UIViewController`s and these closures touch
//  the UI; the factory's `make(_:context:)` is also `@MainActor`, so they line up.
//

import SwiftUI
import UIKit

@MainActor struct FactoryContext {
    /// Invoked when the user picks an option in an interactive component. The `String` is
    /// the chosen option's id — DATA the app maps back to behavior, so the model never
    /// ships behavior. (Only `choice` uses this in the MVP.)
    var onUserChoice: (String) -> Void

    /// Honor the system Reduce Motion setting in animated components.
    var reduceMotion: Bool

    /// When `false`, the host surface (e.g. a floating card) supplies backing/chrome and
    /// the hosted SwiftUI body renders content only. App-specific; drop if you don't have
    /// a separate card chrome layer.
    var ownsCardChrome: Bool

    init(onUserChoice: @escaping (String) -> Void = { _ in },
         reduceMotion: Bool = false,
         ownsCardChrome: Bool = true) {
        self.onUserChoice = onUserChoice
        self.reduceMotion = reduceMotion
        self.ownsCardChrome = ownsCardChrome
    }

    /// The ONE place a component body becomes a hosted card. Every builder returns
    /// `context.host(body)`: a transparent, self-sizing host. Centralizing this keeps the
    /// chrome/sizing contract in one spot — a new component is one line and can't get the
    /// hosting wrong.
    func host<Body: View>(_ body: Body) -> UIViewController {
        // If you don't use an `ownsCardChrome` SwiftUI environment key, just host `body`.
        let host = UIHostingController(rootView: body)
        host.view.backgroundColor = .clear
        host.sizingOptions = [.intrinsicContentSize]
        return host
    }
}
