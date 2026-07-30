import Flutter
import UIKit

public class TrueFaceLivenessPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let factory = LivenessViewFactory(messenger: registrar.messenger())
    registrar.register(factory, withId: "com.trueface/trueface_liveness_view")
  }
}
