#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint v2ray_flutter.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'v2ray_flutter'
  s.version          = '0.0.1'
  s.summary          = 'V2Ray Flutter plugin with native static library.'
  s.description      = <<-DESC
V2Ray Flutter plugin with embedded static library for macOS.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }

  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.14'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'OTHER_LDFLAGS' => '$(inherited) -force_load $(PODS_TARGET_SRCROOT)/Classes/libv2ray.a -lresolv'
  }
  s.frameworks = 'Foundation', 'Security', 'SystemConfiguration'
  s.swift_version = '5.0'

  # Include static library
  s.vendored_libraries = 'Classes/libv2ray.a'

  # Include V2Ray resources (geo data files)
  # s.resources = 'Resources/v2ray/*'  # Disabled - geo files not needed for simple VLESS config

  # Exclude Go files and static library from source compilation (handled by vendored_libraries)
  s.exclude_files = ['Classes/**/*.go', 'Classes/libv2ray.a']
end
