#!/usr/bin/env ruby

require "json"
require "open3"
require "pathname"
require "set"

ROOT = Pathname(__dir__).parent.freeze
SUPPORTED_LOCALES = %w[en de fr ja ko zh-Hans zh-Hant].freeze
NON_ENGLISH_LOCALES = (SUPPORTED_LOCALES - ["en"]).freeze

REQUIRED_APP_LOCALIZATION_KEYS = [
  "ai_primuse_relay_enabled",
  "ai_primuse_relay_consent_required",
  "ai_primuse_relay_footer",
  "ai_primuse_relay_name",
  "ai_primuse_relay_ready",
  "ai_primuse_relay_section",
  "ai_primuse_relay_unsupported",
  "insecure_http_continue",
  "insecure_http_warning_message %@",
  "insecure_http_warning_title"
].freeze

RESOURCE_GROUPS = [
  ["Primuse Localizable.strings", ROOT / "Primuse/Resources", "Localizable.strings", false],
  ["PrimuseKit Localizable.strings", ROOT / "PrimuseKit/Sources/PrimuseKit/Resources", "Localizable.strings", true],
  ["Primuse InfoPlist.strings", ROOT / "Primuse/Resources", "InfoPlist.strings", true],
  ["Widget InfoPlist.strings", ROOT / "PrimuseWidgetExtension/Resources", "InfoPlist.strings", true],
  ["Watch InfoPlist.strings", ROOT / "PrimuseWatch/Resources", "InfoPlist.strings", true],
  ["Watch widget InfoPlist.strings", ROOT / "PrimuseWatchWidgets/Resources", "InfoPlist.strings", true]
].freeze

IDENTICAL_VALUE_PREFIXES = %w[
  home_
  tag_editor_lyrics_
  drime_
  cloud_permission_
  fnmusic_
  radio_
  update_banner_
].freeze

IDENTICAL_VALUE_KEYS = %w[
  tag_editor_footer
  source_quick_sync
  source_deep_scan
  shuffle_all
  sidebar_all_songs
  sidebar_liked_songs
  ext.tv.radio.play
  ext.tv.radio.stop
  ext.tv.radio.stationCount
  src.subtitle.fnMusic
  src.subtitle.daoliyu
].freeze

IDENTICAL_VALUE_GLOBAL_ALLOWLIST = %w[
  radio_batch_entry_file
].freeze

JAPANESE_TRANSLATION_REQUIRED_PREFIXES = %w[
  ai_
  search_ai_
].freeze

IDENTICAL_VALUE_ALLOWLIST = {
  "de" => %w[
    drime_token_section
    fnmusic_connection_fnconnect
    fnmusic_fnid
    home_dashboard_title
    home_mode_radio
    home_radio_wall_badge
    radio_title
  ],
  "fr" => %w[
    drime_token_section
    fnmusic_connection_fnconnect
    fnmusic_fnid
    home_dashboard_title
    home_mode_radio
    radio_title
    radio_stations_count
    home_pipeline_sources
    home_sources_title
    ext.tv.radio.stationCount
  ],
  "ja" => %w[
    drime_token_section
    fnmusic_connection_fnconnect
    fnmusic_fnid
    home_dashboard_title
  ],
  "ko" => %w[
    drime_token_section
    fnmusic_connection_fnconnect
    fnmusic_fnid
    home_dashboard_title
  ],
  "zh-Hans" => %w[
    drime_token_section
    fnmusic_connection_fnconnect
    fnmusic_fnid
  ],
  "zh-Hant" => %w[
    drime_token_section
    fnmusic_connection_fnconnect
    fnmusic_fnid
  ]
}.transform_values(&:freeze).freeze

LOCALIZED_ERROR_ROOTS = %w[
  Primuse
  PrimuseKit/Sources
  PrimuseTV
  PrimuseWatch
  PrimuseWidgetExtension
  PrimuseActivityExtension
].freeze

PMSTRING_SOURCE_ROOTS = %w[
  Primuse
  PrimuseKit/Sources
  PrimuseTV
  PrimuseWatch
  PrimuseWatchWidgets
  PrimuseWidgetExtension
  PrimuseActivityExtension
  PrimuseTopShelf
].freeze

HAN_LITERAL_ALLOWLIST = {
  "Primuse/Services/Intents/PrimuseAppIntents.swift" => [
    /用 .*applicationName/
  ],
  "Primuse/App/PlayMediaIntentHandler.swift" => [
    /用 .*applicationName/
  ],
  "PrimuseKit/Sources/PrimuseKit/LyricsTextTools.swift" => [
    /作词|作曲|编曲|填词|制作人|混音|母带|和声|吉他|贝斯|鼓|键盘|弦乐|录音|出品|发行|策划|统筹|演唱|原唱|翻唱/
  ],
  "PrimuseKit/Sources/PrimuseKit/SharedConstants.swift" => [
    /未知|未知标题|未知標題|未知歌曲|无标题|無標題/
  ],
  "Primuse/Services/Metadata/Scrapers/ScraperTypes.swift" => [
    /酷狗|网易云|QQ ?音乐|咪咕|千千/
  ],
  "Primuse/Views/Components/CachedArtworkView.swift" => [
    /\["music", "音乐"/
  ],
  "Primuse/Views/Settings/DuplicateSongsView.swift" => [
    /百度网盘|群晖|阿里云盘|本地文件|"本地"/
  ],
  "Primuse/Views/Mac/MacSettingsView.swift" => [
    /"猿"/
  ],
  "Primuse/Views/Mac/Theme/PrimuseTheme.swift" => [
    /与设计稿/
  ],
  "PrimuseTV/Model/TVStore.swift" => [
    /"飞牛音乐"/
  ],
  "PrimuseTV/Views/TVLibraryView.swift" => [
    /case all = "全部"/
  ],
  "Primuse/Services/Sources/CloudDrive/CloudDriveBase.swift" => [
    /\["music", "音乐"/
  ],
  "Primuse/Services/Sources/SynologyScanner.swift" => [
    /"音乐"/
  ],
  "Primuse/Services/Sources/NetworkDiscoveryService.swift" => [
    /"飞牛音乐"/
  ],
  "Primuse/Services/Sources/SourceManager.swift" => [
    /"登录"|"密码"|"超时"|"不存在"|"不可达"|"拒绝"|"限流"/
  ],
  "Primuse/Views/NowPlaying/NowPlayingView.swift" => [
    /"音箱"|"群晖"/
  ],
  "Primuse/Views/NowPlaying/ImmersiveStageScenery.swift" => [
    /"猿音"|"猿音 · PRIMUSE"|"PRIMUSE \/ 猿音"|音乐在此刻铺满整个空间|让声音拥有自己的光与形状|猿音，让聆听成为一场演出/
  ],
  "Primuse/Views/NowPlaying/ImmersivePlayerView.swift" => [
    /"未知", "未知艺术家", "未知专辑"/
  ],
  "Primuse/Views/Mac/MacImmersivePlayerView.swift" => [
    /"未知", "未知艺术家", "未知专辑"/
  ],
  "PrimuseTV/Views/TVImmersivePlayerView.swift" => [
    /"未知", "未知标题", "未知艺术家", "未知专辑"/
  ],
  "Primuse/Views/Sources/BrowserChrome.swift" => [
    /"网络"|"联网"|"连接"|"权限"|"不可达"|"超时"/
  ]
}.transform_values(&:freeze).freeze

def load_strings(path)
  output, error, status = Open3.capture3(
    "/usr/bin/plutil", "-convert", "json", "-o", "-", path.to_s
  )
  raise "#{path.relative_path_from(ROOT)}: #{error.strip}" unless status.success?

  JSON.parse(output)
end

def localization_paths(root, file_name)
  SUPPORTED_LOCALES.to_h do |locale|
    [locale, root / "#{locale}.lproj" / file_name]
  end
end

def format_signature(value)
  value
    .gsub("%%", "")
    .scan(/%(?:\d+\$)?[-+0 #']*\d*(?:\.\d+)?(lld|llu|ld|lu|d|i|u|f|g|@)/)
    .flatten
    .sort
end

def check_resource_group(name, root, file_name, exact_english_parity, failures)
  paths = localization_paths(root, file_name)
  missing_files = paths.reject { |_locale, path| path.file? }.keys
  unless missing_files.empty?
    failures << "#{name}: missing locales: #{missing_files.join(', ')}"
    return
  end

  values = paths.transform_values { |path| load_strings(path) }
  union = values.values.reduce(Set.new) { |keys, dictionary| keys | dictionary.keys.to_set }

  values.each do |locale, dictionary|
    next if locale == "en" && !exact_english_parity

    missing = union - dictionary.keys.to_set
    extra = dictionary.keys.to_set - union
    failures << "#{name} #{locale}: missing keys: #{missing.to_a.sort.join(', ')}" unless missing.empty?
    failures << "#{name} #{locale}: unexpected keys: #{extra.to_a.sort.join(', ')}" unless extra.empty?
  end

  english = values.fetch("en")
  values.each do |locale, dictionary|
    next if locale == "en"

    dictionary.each do |key, value|
      next unless english.key?(key)

      expected = format_signature(english.fetch(key))
      actual = format_signature(value)
      if expected != actual
        failures << "#{name} #{locale}: placeholder mismatch for #{key.inspect}: " \
                    "expected #{expected.inspect}, got #{actual.inspect}"
      end
    end

    dictionary.each do |key, value|
      next unless english[key] == value
      next unless IDENTICAL_VALUE_KEYS.include?(key) ||
                  IDENTICAL_VALUE_PREFIXES.any? { |prefix| key.start_with?(prefix) }
      next if IDENTICAL_VALUE_GLOBAL_ALLOWLIST.include?(key)
      next if IDENTICAL_VALUE_ALLOWLIST.fetch(locale, []).include?(key)

      failures << "#{name} #{locale}: untranslated value for #{key.inspect}"
    end

    if locale == "ja"
      dictionary.each do |key, value|
        next unless JAPANESE_TRANSLATION_REQUIRED_PREFIXES.any? { |prefix| key.start_with?(prefix) }
        next if value.match?(/[\p{Hiragana}\p{Katakana}\p{Han}]/)

        failures << "#{name} ja: missing Japanese translation for #{key.inspect}"
      end
    end
  end
end

def localized_error_literals(path)
  lines = path.readlines
  findings = []

  lines.each_index do |index|
    next unless lines[index].match?(/\bvar\s+errorDescription\s*:\s*String\?/)

    depth = 0
    started = false
    lines[index, 60].each_with_index do |line, offset|
      opens = line.count("{")
      closes = line.count("}")
      started ||= opens.positive?
      depth += opens - closes if started

      stripped = line.strip
      literal_probe = stripped.gsub('""', "")
      localization_argument = stripped.match?(/\A"[a-zA-Z0-9_. %@-]+",?\z/)
      if literal_probe.include?('"') &&
         !localization_argument &&
         !stripped.include?("String(localized:") &&
         !stripped.include?("PMString(") &&
         !stripped.start_with?("//")
        findings << [index + offset + 1, stripped]
      end

      break if started && depth <= 0
    end
  end

  findings
end

def hard_coded_han_literals(path)
  relative = path.relative_path_from(ROOT).to_s
  allowlist = HAN_LITERAL_ALLOWLIST.fetch(relative, [])
  findings = []

  path.readlines.each_with_index do |line, index|
    stripped = line.strip
    next if stripped.start_with?("//")
    next if stripped.include?("plog(")

    # Removing the comment suffix also makes URL literals incomplete, so they
    # cannot be mistaken for user-facing text by the string-literal matcher.
    code = line.split("//", 2).first
    literals = code.scan(/"(?:\\.|[^"\\])*"/).select { |literal| literal.match?(/\p{Han}/) }
    next if literals.empty?
    next if allowlist.any? { |pattern| line.match?(pattern) }

    findings << [index + 1, literals.join(", ")]
  end

  findings
end

def decode_swift_string_literal(raw)
  return nil if raw.include?("\\(")

  JSON.parse(%("#{raw}"))
rescue JSON::ParserError
  nil
end

def source_literal_matches(path, pattern)
  source = path.read
  matches = []

  source.to_enum(:scan, pattern).each do
    match = Regexp.last_match
    line_start = source.rindex("\n", match.begin(0)) || -1
    line_end = source.index("\n", match.begin(0)) || source.length
    next if source[(line_start + 1)...line_end].lstrip.start_with?("//")

    key = decode_swift_string_literal(match[1])
    next unless key

    line = source[0...match.begin(0)].count("\n") + 1
    matches << [key, line]
  end

  matches
end

def check_app_source_localization_coverage(dictionaries, failures)
  usages = Hash.new do |hash, key|
    hash[key] = { locales: Set.new, locations: Set.new }
  end

  explicit_patterns = [
    /\bLz\(\s*"((?:\\.|[^"\\])*)"/,
    /\bString\(\s*localized:\s*"((?:\\.|[^"\\])*)"/
  ].freeze
  localized_literal_pattern = /\A[a-z][a-z0-9_.]*\z/
  opaque_key_pattern = /\A[a-z0-9]+(?:[_.][a-z0-9]+)+\z/
  swiftui_key_pattern = /\b(?:Text|Toggle|Picker|Button|Label)\(\s*"((?:\\.|[^"\\])*)"/
  mac_component_pattern = /\b(?:MacSTRow|MacSTSection)\(\s*"((?:\\.|[^"\\])*)"/
  mac_button_pattern = /\bMacSTButton\(\s*title:\s*"((?:\\.|[^"\\])*)"/

  (ROOT / "Primuse").glob("**/*.swift").sort.each do |path|
    explicit_patterns.each do |pattern|
      source_literal_matches(path, pattern).each do |key, line|
        required = key.match?(opaque_key_pattern) ? SUPPORTED_LOCALES : NON_ENGLISH_LOCALES
        usages[key][:locales].merge(required)
        usages[key][:locations] << "#{path.relative_path_from(ROOT)}:#{line}"
      end
    end

    source_literal_matches(path, swiftui_key_pattern).each do |key, line|
      next unless key.match?(localized_literal_pattern)

      required = key.match?(opaque_key_pattern) ? SUPPORTED_LOCALES : NON_ENGLISH_LOCALES
      usages[key][:locales].merge(required)
      usages[key][:locations] << "#{path.relative_path_from(ROOT)}:#{line}"
    end

    [mac_component_pattern, mac_button_pattern].each do |pattern|
      source_literal_matches(path, pattern).each do |key, line|
        next if key.empty?

        required = key.match?(opaque_key_pattern) ? SUPPORTED_LOCALES : NON_ENGLISH_LOCALES
        usages[key][:locales].merge(required)
        usages[key][:locations] << "#{path.relative_path_from(ROOT)}:#{line}"
      end
    end
  end

  usages.sort.each do |key, usage|
    missing = usage[:locales].reject { |locale| dictionaries.fetch(locale).key?(key) }.sort
    next if missing.empty?

    failures << "Primuse source localization key #{key.inspect}: missing locales: " \
                "#{missing.join(', ')} (#{usage[:locations].to_a.sort.first})"
  end
end

def check_pmstring_source_localization_coverage(dictionaries, failures)
  usages = Hash.new { |hash, key| hash[key] = Set.new }
  pattern = /\bPMString\(\s*"((?:\\.|[^"\\])*)"/

  PMSTRING_SOURCE_ROOTS.each do |relative_root|
    (ROOT / relative_root).glob("**/*.swift").sort.each do |path|
      source_literal_matches(path, pattern).each do |key, line|
        usages[key] << "#{path.relative_path_from(ROOT)}:#{line}"
      end
    end
  end

  usages.sort.each do |key, locations|
    missing = SUPPORTED_LOCALES.reject { |locale| dictionaries.fetch(locale).key?(key) }
    next if missing.empty?

    failures << "PrimuseKit PMString key #{key.inspect}: missing locales: " \
                "#{missing.join(', ')} (#{locations.to_a.sort.first})"
  end
end

failures = []
RESOURCE_GROUPS.each do |name, root, file_name, exact_english_parity|
  check_resource_group(name, root, file_name, exact_english_parity, failures)
end

app_localizations = localization_paths(ROOT / "Primuse/Resources", "Localizable.strings")
  .transform_values { |path| load_strings(path) }
check_app_source_localization_coverage(app_localizations, failures)

kit_localizations = localization_paths(
  ROOT / "PrimuseKit/Sources/PrimuseKit/Resources",
  "Localizable.strings"
).transform_values { |path| load_strings(path) }
check_pmstring_source_localization_coverage(kit_localizations, failures)

localization_paths(ROOT / "Primuse/Resources", "Localizable.strings").each do |locale, path|
  next unless path.file?

  dictionary = load_strings(path)
  missing = REQUIRED_APP_LOCALIZATION_KEYS.reject { |key| dictionary.key?(key) }
  unless missing.empty?
    failures << "Primuse Localizable.strings #{locale}: missing required keys: #{missing.join(', ')}"
  end
end

LOCALIZED_ERROR_ROOTS.each do |relative_root|
  (ROOT / relative_root).glob("**/*.swift").sort.each do |path|
    next unless path.read.include?("LocalizedError")

    localized_error_literals(path).each do |line, literal|
      failures << "#{path.relative_path_from(ROOT)}:#{line}: hard-coded LocalizedError text: #{literal}"
    end
  end
end

LOCALIZED_ERROR_ROOTS.each do |relative_root|
  (ROOT / relative_root).glob("**/*.swift").sort.each do |path|
    hard_coded_han_literals(path).each do |line, literals|
      failures << "#{path.relative_path_from(ROOT)}:#{line}: hard-coded Han text: #{literals}"
    end
  end
end

if failures.empty?
  puts "Localization check passed for #{SUPPORTED_LOCALES.join(', ')}."
  exit 0
end

warn failures.join("\n")
exit 1
