import Flutter
import UIKit

public class LivenessDetectionPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let factory = LivenessViewFactory(messenger: registrar.messenger())
    registrar.register(factory, withId: "com.liveness/liveness_view")
  }
}
