Pod::Spec.new do |s|
  s.name             = 'v2ray_flutter'
  s.version          = '0.0.1'
  s.summary          = 'V2Ray plugin for Flutter with native iOS support'
  s.description      = <<-DESC
V2Ray plugin for Flutter supporting iOS and macOS platforms with native performance.
                       DESC
  s.homepage         = 'https://github.com/megav'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'MegaV' => 'support@megav.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'
  s.platform = :ios, '14.0'

  # XCFramework bundled with the plugin
  s.vendored_frameworks = 'Frameworks/Libv2ray.xcframework'
  s.xcconfig = { 'OTHER_LDFLAGS' => '-framework Libv2ray' }

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end

