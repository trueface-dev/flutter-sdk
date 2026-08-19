#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint trueface_liveness.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'trueface_liveness'
  s.version          = '0.2.4'
  s.summary          = 'Active + passive liveness detection for Flutter.'
  s.description      = <<-DESC
AVFoundation + Apple Vision based liveness detection (challenge/response and
passive anti-spoofing) exposed to Flutter as a platform view.
                       DESC
  s.homepage         = 'https://trueface.dev'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'TrueFace' => 'email@truface.dev' }
  s.source           = { :path => '.' }
  s.source_files = 'trueface_liveness/Sources/trueface_liveness/**/*.swift'
  s.dependency 'Flutter'
  # iOS face detection uses Apple's built-in Vision framework (no third-party
  # dependency); Vision exposes face pitch on iOS 15+.
  s.platform = :ios, '15.0'
  s.frameworks = 'AVFoundation', 'Vision', 'CoreImage'

  s.prepare_command = <<-CMD
    if [ -f ../../ios-sdk/build/TrueFaceLiveness.xcframework.zip ]; then
      cp ../../ios-sdk/build/TrueFaceLiveness.xcframework.zip .
    else
      curl -L -o TrueFaceLiveness.xcframework.zip https://github.com/trueface-dev/ios-artifact/releases/download/v0.2.6/TrueFaceLiveness.xcframework.zip
    fi
    unzip -o TrueFaceLiveness.xcframework.zip
    rm TrueFaceLiveness.xcframework.zip
  CMD

  s.vendored_frameworks = 'TrueFaceLiveness.xcframework'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
  s.resource_bundles = {
    'trueface_liveness_privacy' => ['trueface_liveness/Sources/trueface_liveness/PrivacyInfo.xcprivacy']
  }
end
