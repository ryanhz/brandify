import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FocusChart") {
      registrar.register(FocusChartFactory(), withId: focusChartViewType)
    }
  }
}

// The native view lives in this file so the Xcode project needs no new entries.

/// Keep in sync with `focusChartViewType` in lib/main.dart.
let focusChartViewType = "brandify_example/focus_chart"

class FocusChartFactory: NSObject, FlutterPlatformViewFactory {
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?)
    -> FlutterPlatformView
  {
    return FocusChartPlatformView(frame: frame)
  }
}

class FocusChartPlatformView: NSObject, FlutterPlatformView {
  private let chart: FocusChartView
  init(frame: CGRect) {
    chart = FocusChartView(frame: frame)
    super.init()
  }
  func view() -> UIView { chart }
}

/// A weekly bar chart drawn by Core Graphics: a native view (PlatformView)
/// inside the Flutter UI. Widget-test renderers can't draw it; a capture of
/// the real screen can. Static on purpose, so screenshots are deterministic.
class FocusChartView: UIView {
  private let hours: [CGFloat] = [3.5, 5, 2.5, 6, 4.5, 1.5, 2]
  private let days = ["M", "T", "W", "T", "F", "S", "S"]

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    contentMode = .redraw
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func draw(_ rect: CGRect) {
    guard let ctx = UIGraphicsGetCurrentContext() else { return }
    let w = bounds.width, h = bounds.height
    let space = CGColorSpaceCreateDeviceRGB()

    ctx.saveGState()
    UIBezierPath(roundedRect: bounds, cornerRadius: 20).addClip()
    let cardColors = [rgb(0x2E5BFF), rgb(0x8E2DE2)] as CFArray
    if let g = CGGradient(colorsSpace: space, colors: cardColors, locations: [0, 1]) {
      ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
    }
    ctx.restoreGState()

    let pad: CGFloat = 16
    ("24.5 h focused this week" as NSString).draw(
      at: CGPoint(x: pad, y: pad),
      withAttributes: [.font: UIFont.boldSystemFont(ofSize: 15), .foregroundColor: UIColor.white])
    ("Native view · UIKit Core Graphics" as NSString).draw(
      at: CGPoint(x: pad, y: pad + 20),
      withAttributes: [
        .font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.white.withAlphaComponent(0.7),
      ])

    let top = pad + 48, bottom = h - pad - 18
    let slot = (w - 2 * pad) / CGFloat(hours.count)
    let barW = slot * 0.45
    let maxH = hours.max() ?? 1
    let label: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.white.withAlphaComponent(0.8),
    ]
    let barColors = [rgb(0xFFFFFF), rgb(0xB8C6FF)] as CFArray
    let barGradient = CGGradient(colorsSpace: space, colors: barColors, locations: [0, 1])
    for (i, v) in hours.enumerated() {
      let cx = pad + slot * (CGFloat(i) + 0.5)
      let track = CGRect(x: cx - barW / 2, y: top, width: barW, height: bottom - top)
      UIColor.white.withAlphaComponent(0.2).setFill()
      UIBezierPath(roundedRect: track, cornerRadius: barW / 2).fill()

      let y = bottom - (bottom - top) * v / maxH
      let filled = CGRect(x: cx - barW / 2, y: y, width: barW, height: bottom - y)
      ctx.saveGState()
      UIBezierPath(roundedRect: filled, cornerRadius: barW / 2).addClip()
      if let g = barGradient {
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
      }
      ctx.restoreGState()

      let day = days[i] as NSString
      let size = day.size(withAttributes: label)
      day.draw(at: CGPoint(x: cx - size.width / 2, y: h - pad - size.height), withAttributes: label)
    }
  }

  private func rgb(_ hex: Int) -> CGColor {
    UIColor(
      red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255, alpha: 1
    ).cgColor
  }
}
