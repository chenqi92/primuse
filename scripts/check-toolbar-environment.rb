#!/usr/bin/env ruby

# SwiftUI evaluates toolbar item content in its own `UIKitBarItemHost` view
# graph. That graph is sized from `willMove(toSuperview:)` while a navigation
# transition is still running, before the surrounding hosting controller's
# environment reaches it. A required `@Environment(SomeModel.self)` read in
# there therefore traps at runtime with "No Observable object of type ...
# found", instead of merely rendering late.
#
# Toolbar-hosted views in this app must take the models they need as values.
# This check walks every `.toolbar { ... }` / `@ToolbarContentBuilder` body,
# follows the views constructed inside them, and fails when any of those views
# declares a non-optional object environment read.
#
# Presentation closures (`.sheet`, `.popover`, `.navigationDestination`, ...)
# are not part of the bar item graph, so they end the walk.

ROOT = File.expand_path("..", __dir__)
SOURCE_DIRS = %w[Primuse].freeze

DECL = /
  (?:\A|\n)
  (?:public\s|private\s|internal\s|fileprivate\s)?
  (?:struct|final\sclass|class)\s+(?<name>\w+)\s*
  (?:<[^>]*>)?\s*:[^{\n]*\b(?:View|ToolbarContent|ViewModifier)\b[^{]*\{
/x

PRESENTATION = /\.(?:sheet|fullScreenCover|popover|navigationDestination|alert|
                   confirmationDialog|inspector|safeAreaInset|background|
                   overlay|contextMenu|onAppear|task)\b/x

ENVIRONMENT_OBJECT = /@Environment\((\w+)\.self\)/

def swift_files
  SOURCE_DIRS.flat_map { |dir| Dir.glob(File.join(ROOT, dir, "**", "*.swift")) }.sort
end

# Returns the substring from `text[open_index]` (a "{") through its match.
def braced_range(text, open_index)
  depth = 0
  index = open_index
  while index < text.length
    depth += 1 if text[index] == "{"
    if text[index] == "}"
      depth -= 1
      return text[open_index..index] if depth.zero?
    end
    index += 1
  end
  text[open_index..]
end

def strip_presentations(body)
  kept = +""
  cursor = 0
  while (match = PRESENTATION.match(body, cursor))
    kept << body[cursor...match.begin(0)]
    brace = body.index("{", match.end(0))
    if brace.nil? || brace - match.end(0) > 120
      cursor = match.end(0)
      next
    end
    cursor = brace + braced_range(body, brace).length
  end
  kept << body[cursor..].to_s
  kept
end

def declarations
  views = {}
  swift_files.each do |path|
    source = File.read(path)
    matches = source.to_enum(:scan, DECL).map { Regexp.last_match }
    matches.each_with_index do |match, position|
      finish = matches[position + 1]&.begin(0) || source.length
      views[match[:name]] = {
        path: path.delete_prefix("#{ROOT}/"),
        body: source[match.end(0)...finish].to_s,
      }
    end
  end
  views
end

def constructed_views(text, names)
  names.select { |name| text.match?(/(?<![\w.])#{Regexp.escape(name)}\s*\(/) }
end

def toolbar_bodies(source)
  bodies = []
  [/\.toolbar\s*(?:\([^)]*\)\s*)?\{/, /@ToolbarContentBuilder/].each do |pattern|
    source.to_enum(:scan, pattern).each do
      match = Regexp.last_match
      brace = source.index("{", match.end(0) - 1)
      bodies << braced_range(source, brace) if brace
    end
  end
  bodies
end

views = declarations
names = views.keys

hosted = {}
swift_files.each do |path|
  source = File.read(path)
  toolbar_bodies(source).each do |body|
    constructed_views(strip_presentations(body), names).each do |name|
      hosted[name] ||= ["a .toolbar body in #{path.delete_prefix("#{ROOT}/")}"]
    end
  end
end

frontier = hosted.keys
until frontier.empty?
  discovered = []
  frontier.each do |name|
    constructed_views(strip_presentations(views[name][:body]), names).each do |child|
      next if hosted.key?(child)

      hosted[child] = hosted[name] + [name]
      discovered << child
    end
  end
  frontier = discovered
end

offenders = hosted.keys.filter_map do |name|
  reads = views[name][:body].scan(ENVIRONMENT_OBJECT).flatten.uniq.sort
  next if reads.empty?

  { name: name, reads: reads, path: views[name][:path], chain: hosted[name] }
end

if offenders.empty?
  puts "toolbar environment check: #{hosted.size} toolbar-hosted views, no required environment reads"
  exit 0
end

offenders.each do |offender|
  warn "#{offender[:path]}: #{offender[:name]} reads required environment " \
       "#{offender[:reads].join(", ")} while hosted in a navigation bar item"
  warn "  reached from #{(offender[:chain] + [offender[:name]]).join(" -> ")}"
  warn "  pass these models in as values instead of reading them from the environment"
end
exit 1
