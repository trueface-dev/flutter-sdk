#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint liveness_detection.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'liveness_detection'
  s.version          = '0.0.1'
  s.summary          = 'Active + passive liveness detection for Flutter.'
  s.description      = <<-DESC
AVFoundation + Google ML Kit based liveness detection (challenge/response and
passive anti-spoofing) exposed to Flutter as a platform view.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.dependency 'GoogleMLKit/FaceDetection', '~> 7.0'
  s.platform = :ios, '15.5'

  # ML Kit ships static frameworks, so this pod must be static too.
  s.static_framework = true

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'liveness_detection_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
