Pod::Spec.new do |spec|
    spec.name                 = 'KontextVideoSDK'
    spec.version              = '0.1.0'
    spec.summary              = 'Kontext.so Video SDK'
    spec.description          = <<-DESC
    The official Swift SDK for Kontext.so video ads (overlay, pause and linear) in video-first iOS apps.
                                DESC
    spec.homepage             = 'https://github.com/kontextso/sdk-swift-video'
    spec.license              = { :type => 'Apache-2.0', :file => 'LICENSE' }
    spec.author               = { 'Kontext.so' => 'support@kontext.so' }

    spec.swift_version        = '5.9'
    spec.platform             = :ios, '14.0'

    spec.source               = { :git => 'https://github.com/kontextso/sdk-swift-video.git', :tag => spec.version.to_s }
    spec.source_files         = 'Sources/KontextVideoSDK/**/*.swift'
    spec.resource_bundles     = { 'KontextVideoSDKPrivacy' => ['Sources/KontextVideoSDK/PrivacyInfo.xcprivacy'] }
    spec.frameworks           = 'UIKit', 'WebKit', 'AVFoundation', 'AVKit', 'AdSupport', 'AppTrackingTransparency'

    # Pre-1.0 KontextKit: pin exact, the same version sdk-swift uses. Once KontextKit hits 1.0, switch to `~> 1.0`.
    spec.dependency 'KontextKit', '0.1.0'
end
