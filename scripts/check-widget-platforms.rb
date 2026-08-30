#!/usr/bin/env ruby

require "fileutils"
require "json"
require "open3"
require "set"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
SPEC_PATH = File.join(ROOT, "project.yml")
PROJECT_PATH = File.join(ROOT, "Primuse.xcodeproj")
EXPECTED_XCODEGEN_VERSION = "2.45.3"
WIDGET_TARGET = "PrimuseWidgetExtension"
WIDGET_BUNDLE_ID = "com.welape.yuanyin.widget"
APP_GROUP = "group.com.welape.yuanyin"
INTERACTIVE_WIDGET_INTENTS = %w[
  PrimusePlayPauseIntent
  PrimusePreviousIntent
  PrimuseNextIntent
  PrimuseShuffleAllIntent
  PrimuseSetRepeatModeIntent
  PrimuseSetLikedIntent
].freeze

def fail_check(message)
  warn "Widget platform check failed: #{message}"
  exit 1
end

def expect(condition, message)
  fail_check(message) unless condition
end

def yes?(value)
  value == true || value.to_s == "YES"
end

def capture!(*command, input: nil)
  stdout, stderr, status = Open3.capture3(*command, stdin_data: input.to_s)
  return stdout if status.success?

  details = [stdout, stderr].reject(&:empty?).join("\n").strip
  fail_check("#{command.join(" ")} failed#{details.empty? ? "" : ":\n#{details}"}")
rescue Errno::ENOENT
  fail_check("required command not found: #{command.first}")
end

def plist(path)
  JSON.parse(capture!("/usr/bin/plutil", "-convert", "json", "-o", "-", path))
end

def dependency(target, dependency_name)
  Array(target["dependencies"]).find do |entry|
    entry.is_a?(Hash) && entry["target"] == dependency_name
  end
end

def target_configurations(objects, target)
  list = objects.fetch(target.fetch("buildConfigurationList"))
  Array(list["buildConfigurations"]).map { |identifier| objects.fetch(identifier) }
end

def embedded_product?(objects, host_target, product_reference)
  Array(host_target["buildPhases"]).any? do |phase_identifier|
    phase = objects.fetch(phase_identifier)
    next false unless phase["isa"] == "PBXCopyFilesBuildPhase"
    next false unless phase["dstSubfolderSpec"].to_s == "13"

    Array(phase["files"]).any? do |build_file_identifier|
      objects.fetch(build_file_identifier)["fileRef"] == product_reference
    end
  end
end

def target_dependency?(objects, host_target, target_identifier)
  Array(host_target["dependencies"]).any? do |dependency_identifier|
    objects.fetch(dependency_identifier)["target"] == target_identifier
  end
end

def compare_generated_project!
  version_output = capture!("xcodegen", "--version")
  version = version_output[/\d+\.\d+\.\d+/]
  expect(
    version == EXPECTED_XCODEGEN_VERSION,
    "xcodegen #{EXPECTED_XCODEGEN_VERSION} is required, got #{version || version_output.strip}"
  )

  Dir.mktmpdir("primuse-widget-xcodegen-", "/private/tmp") do |directory|
    FileUtils.touch(File.join(directory, ".metadata_never_index"))
    # Keep the same relative project layout so XcodeGen emits byte-identical
    # group paths and UUIDs. Directories containing generated plists or
    # entitlements use cheap APFS copy-on-write clones; all other sources are
    # symlinked. Keep generated output paths in this set before XcodeGen grows
    # another on-disk output type.
    temporary_spec = YAML.load_file(SPEC_PATH)
    temporary_spec_path = File.join(directory, "project.yml")
    FileUtils.cp(SPEC_PATH, temporary_spec_path)
    generated_info_paths = temporary_spec.fetch("targets").values.map do |target|
      target.dig("info", "path")
    end.compact.to_set
    generated_entitlement_paths = temporary_spec.fetch("targets").values.map do |target|
      target.dig("entitlements", "path")
    end.compact.to_set
    generated_output_directories = (generated_info_paths + generated_entitlement_paths)
      .map { |path| path.split("/").first }
      .to_set
    capture!(
      "/bin/cp", "-cR",
      *generated_output_directories.sort.map { |entry| File.join(ROOT, entry) },
      directory
    )
    Dir.children(ROOT).each do |entry|
      next if [".git", "Primuse.xcodeproj", "project.yml"].include?(entry) || generated_output_directories.include?(entry)

      source = File.join(ROOT, entry)
      destination = File.join(directory, entry)
      FileUtils.ln_s(source, destination)
    end
    capture!(
      "xcodegen", "generate", "--no-env", "--quiet",
      "--spec", temporary_spec_path,
      "--project", directory,
      "--project-root", directory
    )
    generated_project = File.join(directory, "Primuse.xcodeproj")
    relative_files = ["project.pbxproj"]
    relative_files.concat(
      Dir.glob(File.join(generated_project, "xcshareddata/xcschemes/*.xcscheme"))
        .map { |path| path.delete_prefix("#{generated_project}/") }
    )
    controlled_schemes = Dir.glob(File.join(PROJECT_PATH, "xcshareddata/xcschemes/*.xcscheme"))
      .map { |path| path.delete_prefix("#{PROJECT_PATH}/") }
    expect(
      relative_files.sort == (["project.pbxproj"] + controlled_schemes).sort,
      "generated and controlled shared scheme sets differ"
    )

    changed = relative_files.reject do |relative_path|
      generated_path = File.join(generated_project, relative_path)
      controlled_path = File.join(PROJECT_PATH, relative_path)
      File.file?(controlled_path) && File.binread(generated_path) == File.binread(controlled_path)
    end
    expect(
      changed.empty?,
      "generated project is stale (#{changed.join(", ")}); run xcodegen generate --spec project.yml --project-root ."
    )
    stale_plists = generated_info_paths.reject do |relative_path|
      generated_path = File.join(directory, relative_path)
      controlled_path = File.join(ROOT, relative_path)
      File.file?(controlled_path) && File.binread(generated_path) == File.binread(controlled_path)
    end
    expect(
      stale_plists.empty?,
      "generated Info.plist files are stale (#{stale_plists.to_a.sort.join(", ")}); run xcodegen generate --spec project.yml --project-root ."
    )
  end
end

def check_project_graph!
  project = plist(File.join(PROJECT_PATH, "project.pbxproj"))
  objects = project.fetch("objects")
  targets = objects.select { |_identifier, object| object["isa"] == "PBXNativeTarget" }
  target_by_name = targets.each_with_object({}) do |(identifier, object), result|
    result[object["name"]] = [identifier, object]
  end
  widget_identifier, widget = target_by_name.fetch(WIDGET_TARGET) do
    fail_check("generated project has no #{WIDGET_TARGET} target")
  end
  product = objects.fetch(widget.fetch("productReference"))
  expect(widget["productType"] == "com.apple.product-type.app-extension", "Widget product type is not an app extension")
  expect(product["path"].to_s.end_with?(".appex"), "Widget product is not an .appex bundle")

  %w[Primuse PrimuseMac].each do |host_name|
    _host_identifier, host = target_by_name.fetch(host_name) do
      fail_check("generated project has no #{host_name} target")
    end
    expect(
      target_dependency?(objects, host, widget_identifier),
      "#{host_name} does not depend on #{WIDGET_TARGET}"
    )
    expect(
      embedded_product?(objects, host, widget.fetch("productReference")),
      "#{host_name} does not embed #{WIDGET_TARGET} in PlugIns"
    )
  end

  target_configurations(objects, widget).each do |configuration|
    name = configuration.fetch("name")
    settings = configuration.fetch("buildSettings")
    platforms = settings.fetch("SUPPORTED_PLATFORMS", "").to_s.split.to_set
    expect(
      Set.new(%w[iphoneos iphonesimulator macosx]).subset?(platforms),
      "#{WIDGET_TARGET} #{name} does not support iOS and macOS"
    )
    expect(settings["SDKROOT"] == "auto", "#{WIDGET_TARGET} #{name} SDKROOT must be auto")
    expect(yes?(settings["SKIP_INSTALL"]), "#{WIDGET_TARGET} #{name} SKIP_INSTALL must be YES")
    expect(settings["PRODUCT_BUNDLE_IDENTIFIER"] == WIDGET_BUNDLE_ID, "#{WIDGET_TARGET} #{name} bundle identifier is wrong")
    expect(
      settings["CODE_SIGN_ENTITLEMENTS[sdk=macosx*]"] == "Config/PrimuseWidgetExtension-macOS.entitlements",
      "#{WIDGET_TARGET} #{name} has the wrong macOS entitlements"
    )
    expect(
      settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"].to_s.split.include?("PRIMUSE_WIDGET_EXTENSION"),
      "#{WIDGET_TARGET} #{name} must define PRIMUSE_WIDGET_EXTENSION"
    )
    expect(
      settings["LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]"].to_s.include?("@executable_path/../../../../Frameworks"),
      "#{WIDGET_TARGET} #{name} is missing the macOS host-framework runpath"
    )
    expect(
      settings["SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD"] == "NO",
      "#{WIDGET_TARGET} #{name} must build a native Mac extension"
    )
  end
end

def check_spec!
  spec = YAML.load_file(SPEC_PATH)
  targets = spec.fetch("targets")
  widget = targets.fetch(WIDGET_TARGET)
  destinations = Array(widget["supportedDestinations"]).to_set
  expect(destinations == Set.new(%w[iOS macOS]), "#{WIDGET_TARGET} supportedDestinations must be exactly iOS and macOS")
  expect(!widget.key?("platform"), "#{WIDGET_TARGET} must not pin platform to iOS")
  expect(yes?(widget.dig("settings", "base", "SKIP_INSTALL")), "#{WIDGET_TARGET} SKIP_INSTALL must be YES")
  expect(widget.dig("settings", "base", "PRODUCT_BUNDLE_IDENTIFIER") == WIDGET_BUNDLE_ID, "#{WIDGET_TARGET} bundle identifier is wrong")
  expect(
    widget.dig("info", "properties", "NSExtension", "NSExtensionPointIdentifier") == "com.apple.widgetkit-extension",
    "#{WIDGET_TARGET} must declare the WidgetKit extension point"
  )
  expect(
    widget.dig("settings", "base", "CODE_SIGN_ENTITLEMENTS") == "Config/PrimuseWidgetExtension.entitlements",
    "#{WIDGET_TARGET} has the wrong iOS entitlements"
  )
  expect(
    widget.dig("settings", "base", "CODE_SIGN_ENTITLEMENTS[sdk=macosx*]") == "Config/PrimuseWidgetExtension-macOS.entitlements",
    "#{WIDGET_TARGET} has the wrong macOS entitlements"
  )
  expect(
    widget.dig("settings", "base", "SWIFT_ACTIVE_COMPILATION_CONDITIONS").to_s.split.include?("PRIMUSE_WIDGET_EXTENSION"),
    "#{WIDGET_TARGET} must define PRIMUSE_WIDGET_EXTENSION"
  )
  expect(
    widget.dig("settings", "base", "LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]").to_s.include?("@executable_path/../../../../Frameworks"),
    "#{WIDGET_TARGET} is missing the macOS host-framework runpath"
  )
  %w[iOS macOS].each do |platform|
    deployment_target = spec.dig("options", "deploymentTarget", platform).to_s
    expect(!deployment_target.empty?, "#{platform} deployment target must be defined globally")
  end

  %w[Primuse PrimuseMac].each do |host_name|
    widget_dependency = dependency(targets.fetch(host_name), WIDGET_TARGET)
    expect(widget_dependency && widget_dependency["embed"] == true, "#{host_name} must depend on and embed #{WIDGET_TARGET}")
    expect(
      spec.dig("schemes", host_name, "build", "targets").key?(WIDGET_TARGET),
      "#{host_name} scheme must build #{WIDGET_TARGET}"
    )
  end

  mac_widget_entitlements = plist(File.join(ROOT, "Config/PrimuseWidgetExtension-macOS.entitlements"))
  mac_app_entitlements = plist(File.join(ROOT, targets.fetch("PrimuseMac").dig("settings", "base", "CODE_SIGN_ENTITLEMENTS")))
  ios_widget_entitlements = plist(File.join(ROOT, "Config/PrimuseWidgetExtension.entitlements"))
  ios_app_entitlements = plist(File.join(ROOT, targets.fetch("Primuse").dig("settings", "base", "CODE_SIGN_ENTITLEMENTS")))
  expect(mac_widget_entitlements["com.apple.security.app-sandbox"] == true, "macOS Widget must enable App Sandbox")
  [mac_widget_entitlements, mac_app_entitlements, ios_widget_entitlements, ios_app_entitlements].each do |entitlements|
    groups = Array(entitlements["com.apple.security.application-groups"])
    expect(groups.include?(APP_GROUP), "host and Widget entitlements must share #{APP_GROUP}")
  end
end

def check_interactive_controls!
  source = File.read(File.join(ROOT, "PrimuseWidgetExtension/NowPlayingWidget.swift"))
  INTERACTIVE_WIDGET_INTENTS.each do |intent|
    expect(source.include?(intent), "Now Playing Widget is missing interactive #{intent}")
  end
  expect(source.scan("Button(intent:").length >= 5, "Now Playing controls must use AppIntent buttons")
  expect(source.include?("Toggle(isOn:"), "Now Playing like control must use an AppIntent toggle")
end

def check_interactive_intent_metadata!(extension_path)
  metadata_paths = Dir.glob(File.join(extension_path, "**/Metadata.appintents/extract.actionsdata"))
  expect(metadata_paths.length == 1, "Widget must contain exactly one AppIntent metadata payload")
  actions = JSON.parse(File.read(metadata_paths.first)).fetch("actions")
  INTERACTIVE_WIDGET_INTENTS.each do |intent|
    action = actions[intent]
    expect(action, "Widget AppIntent metadata is missing #{intent}")
    expect(action["openAppWhenRun"] == false, "#{intent} must run without opening the app")
    expect(
      Array(action["systemProtocols"]).include?("com.apple.link.systemProtocol.AudioStarting"),
      "#{intent} must remain an AudioPlaybackIntent"
    )
  end
end

def signed_entitlements(path)
  stdout, stderr, status = Open3.capture3(
    "/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", path
  )
  fail_check("could not read signed entitlements from #{path}: #{stderr.strip}") unless status.success?
  fail_check("#{path} has no readable signed entitlements") if stdout.empty?
  JSON.parse(capture!("/usr/bin/plutil", "-convert", "json", "-o", "-", "-", input: stdout))
end

def verify_local_dependency_closure!(root_binary, search_roots)
  queue = [root_binary]
  visited = Set.new
  strong_linked_paths = Set.new
  until queue.empty?
    binary = queue.shift
    canonical_binary = File.realpath(binary)
    next if visited.include?(canonical_binary)

    visited << canonical_binary
    build_info = capture!("xcrun", "vtool", "-show-build", binary)
    platforms = build_info.scan(/^\s*platform\s+(\S+)/).flatten
    expect(
      !platforms.empty? && platforms.all? { |platform| platform == "MACOS" },
      "Mac Widget dependency contains a non-macOS slice: #{binary} (#{platforms.join(", ")})"
    )
    install_names = capture!("/usr/bin/otool", "-D", binary).lines.drop(1)
      .map(&:strip)
      .reject(&:empty?)
      .to_set
    linked_libraries = capture!("/usr/bin/otool", "-L", binary).lines.drop(1).map do |line|
      path = line.strip.split(" ").first
      [path, line.include?(", weak)")] if path
    end.compact
    linked_libraries.select { |path, _weak| path.start_with?("@rpath/", "@loader_path/", "@executable_path/") }.each do |linked_path, weak|
      next if install_names.include?(linked_path)

      candidates = if linked_path.start_with?("@rpath/")
        relative_path = linked_path.delete_prefix("@rpath/")
        search_roots.map { |root| File.join(root, relative_path) }
      elsif linked_path.start_with?("@loader_path/")
        [File.expand_path(linked_path.delete_prefix("@loader_path/"), File.dirname(binary))]
      else
        [File.expand_path(linked_path.delete_prefix("@executable_path/"), File.dirname(root_binary))]
      end
      resolved = candidates.find { |candidate| File.file?(candidate) }
      next if weak && !resolved

      expect(
        resolved,
        "Mac Widget local dependency cannot be resolved: #{linked_path} (from #{binary})"
      )
      strong_linked_paths << linked_path unless weak
      queue << resolved
    end
  end
  strong_linked_paths
end

def check_mac_product!(app_path)
  app_path = File.expand_path(app_path)
  extension_path = File.join(app_path, "Contents/PlugIns/PrimuseWidgetExtension.appex")
  expect(File.directory?(extension_path), "Mac app does not contain Contents/PlugIns/PrimuseWidgetExtension.appex")
  app_info = plist(File.join(app_path, "Contents/Info.plist"))
  extension_info = plist(File.join(extension_path, "Contents/Info.plist"))
  expect(extension_info["CFBundleIdentifier"] == WIDGET_BUNDLE_ID, "Mac Widget bundle identifier is wrong")
  expect(extension_info["DTPlatformName"] == "macosx", "embedded Widget is not a native macOS product")
  expect(Array(extension_info["CFBundleSupportedPlatforms"]).include?("MacOSX"), "Mac Widget does not declare MacOSX support")
  expect(
    extension_info.dig("NSExtension", "NSExtensionPointIdentifier") == "com.apple.widgetkit-extension",
    "embedded Mac extension is not a WidgetKit extension"
  )
  expect(extension_info["CFBundleVersion"] == app_info["CFBundleVersion"], "Mac host and Widget build versions differ")
  check_interactive_intent_metadata!(extension_path)

  executable = File.join(extension_path, "Contents/MacOS", extension_info.fetch("CFBundleExecutable"))
  load_commands = capture!("/usr/bin/otool", "-l", executable)
  linked_libraries = capture!("/usr/bin/otool", "-L", executable)
  debug_dylib = "@rpath/#{File.basename(executable)}.debug.dylib"
  if linked_libraries.include?(debug_dylib)
    expect(
      load_commands.match?(/^\s*path @executable_path \(offset \d+\)$/),
      "Mac Widget binary is missing the Debug dylib LC_RPATH"
    )
  end
  expect(
    load_commands.include?("@executable_path/../Frameworks"),
    "Mac Widget binary is missing the extension-framework LC_RPATH"
  )
  expect(load_commands.include?("@executable_path/../../../../Frameworks"), "Mac Widget binary is missing the host-framework LC_RPATH")
  strong_linked_paths = verify_local_dependency_closure!(
    executable,
    [
      File.dirname(executable),
      File.join(extension_path, "Contents/Frameworks"),
      File.join(app_path, "Contents/Frameworks"),
    ]
  )
  expect(strong_linked_paths.any? { |path| path.include?("PrimuseKit.framework/") }, "Mac Widget does not strongly link PrimuseKit through @rpath")
  expect(strong_linked_paths.any? { |path| path.include?("GRDB") }, "Mac Widget dependency closure does not strongly link GRDB through @rpath")

  capture!("/usr/bin/codesign", "--verify", "--deep", "--strict", app_path)
  capture!("/usr/bin/codesign", "--verify", "--deep", "--strict", extension_path)
  app_entitlements = signed_entitlements(app_path)
  widget_entitlements = signed_entitlements(extension_path)
  expect(widget_entitlements["com.apple.security.app-sandbox"] == true, "signed Mac Widget is missing App Sandbox")
  [app_entitlements, widget_entitlements].each do |entitlements|
    expect(
      Array(entitlements["com.apple.security.application-groups"]).include?(APP_GROUP),
      "signed Mac host and Widget must share #{APP_GROUP}"
    )
  end
  puts "Mac Widget product check passed: #{extension_path}"
end

def check_ios_product!(app_path)
  app_path = File.expand_path(app_path)
  extension_path = File.join(app_path, "PlugIns/PrimuseWidgetExtension.appex")
  expect(File.directory?(extension_path), "iOS app does not contain PlugIns/PrimuseWidgetExtension.appex")
  app_info = plist(File.join(app_path, "Info.plist"))
  extension_info = plist(File.join(extension_path, "Info.plist"))
  expect(extension_info["CFBundleIdentifier"] == WIDGET_BUNDLE_ID, "iOS Widget bundle identifier is wrong")
  expect(
    extension_info.dig("NSExtension", "NSExtensionPointIdentifier") == "com.apple.widgetkit-extension",
    "embedded iOS extension is not a WidgetKit extension"
  )
  platform_name = extension_info["DTPlatformName"]
  expect(%w[iphoneos iphonesimulator].include?(platform_name), "embedded iOS Widget has the wrong platform")
  supported_platform = platform_name == "iphonesimulator" ? "iPhoneSimulator" : "iPhoneOS"
  expect(
    Array(extension_info["CFBundleSupportedPlatforms"]).include?(supported_platform),
    "iOS Widget does not declare #{supported_platform} support"
  )
  expect(extension_info["CFBundleVersion"] == app_info["CFBundleVersion"], "iOS host and Widget build versions differ")
  check_interactive_intent_metadata!(extension_path)
  puts "iOS Widget product check passed: #{extension_path}"
end

mac_app = nil
ios_app = nil
until ARGV.empty?
  option = ARGV.shift
  case option
  when "--mac-app"
    mac_app = ARGV.shift || fail_check("--mac-app requires a path")
  when "--ios-app"
    ios_app = ARGV.shift || fail_check("--ios-app requires a path")
  else
    fail_check("unknown option: #{option}")
  end
end

Dir.chdir(ROOT) do
  check_spec!
  compare_generated_project!
  check_project_graph!
  check_interactive_controls!
  check_mac_product!(mac_app) if mac_app
  check_ios_product!(ios_app) if ios_app
end

puts "Widget platform check passed"
