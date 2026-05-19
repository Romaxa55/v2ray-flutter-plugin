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
  # 2026-05-19: -lresolv обязателен — Go runtime (внутри Libv2ray.xcframework)
  # использует libresolv (res_9_ninit/nsearch/nclose) для DNS resolver.
  # Без явной линковки linker падает с "Undefined symbol: _res_9_ninit" и т.д.
  # macOS podspec уже имел -lresolv (см. macos/v2ray_flutter.podspec), iOS был
  # пропущен — фикс симметризует.
  s.xcconfig = { 'OTHER_LDFLAGS' => '-framework Libv2ray -lresolv' }

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end

