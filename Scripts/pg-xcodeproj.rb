#!/usr/bin/env ruby
# Edits sequel-pro.xcodeproj for the PostgreSQL work. The only supported way to touch project.pbxproj.
#
#   ruby Scripts/pg-xcodeproj.rb setup               one-time (idempotent) wiring of PostgresKit + "Postgres Tests"
#   ruby Scripts/pg-xcodeproj.rb add-app  <files...>  add sources to the "Sequel Pro" target (group Source/Postgres)
#   ruby Scripts/pg-xcodeproj.rb add-test <files...>  add sources to the "Postgres Tests" target (group PostgresTests)
#   ruby Scripts/pg-xcodeproj.rb remove   <files...>  remove files from the project (every target's build phases
#                                                     and their group); the files on disk are left alone
#
# File paths are relative to the repo root (e.g. Source/Postgres/SPPostgresFoo.m). Headers are added
# to the group only; .m/.mm/.c files are added to the target's compile sources. Idempotent.

gem 'xcodeproj', '1.28.1'
require 'xcodeproj'
require 'fileutils'

ROOT      = File.expand_path('..', __dir__)
PROJ_PATH = File.join(ROOT, 'sequel-pro.xcodeproj')
APP       = 'Sequel Pro'
TESTS     = 'Postgres Tests'
KIT_PROJ  = 'Frameworks/PostgresKit/PostgresKit.xcodeproj'
KIT_TARGET_ID  = '8DC2EF4F0486A6940098B216'
KIT_PRODUCT_ID = '8DC2EF5B0486A6940098B216'

def find_or_create_group(parent, name, path = nil)
  g = parent.children.find { |c| c.isa == 'PBXGroup' && c.display_name == name }
  unless g
    g = parent.new_group(name, path)
  end
  g
end

def add_files(project, target, group, files, compile)
  files.each do |f|
    abs = File.expand_path(f, ROOT)
    abort "No such file: #{f}" unless File.exist?(abs)
    rel = abs.sub(ROOT + '/', '')
    ref = group.files.find { |x| x.real_path.to_s == abs } || group.new_file(abs)
    ref.set_source_tree('SOURCE_ROOT')
    ref.set_path(rel)
    if compile && rel =~ /\.(m|mm|c|cpp)\z/
      unless target.source_build_phase.files_references.include?(ref)
        target.add_file_references([ref], target.name == TESTS ? '-fobjc-arc' : nil)
      end
    end
  end
end

def remove_files(project, files)
  files.each do |f|
    abs = File.expand_path(f, ROOT)
    refs = project.files.select { |x| x.real_path.to_s == abs }
    if refs.empty?
      puts "Not in the project (nothing to do): #{f}"
      next
    end
    refs.each do |ref|
      project.targets.each do |t|
        t.build_phases.each do |phase|
          next unless phase.respond_to?(:files_references)
          phase.remove_file_reference(ref) if phase.files_references.include?(ref)
        end
      end
      ref.remove_from_project
    end
  end
end

def setup(project)
  app = project.targets.find { |t| t.name == APP } or abort 'no app target'
  frameworks = project.main_group['Frameworks'] || project.main_group.new_group('Frameworks')

  # Subproject reference
  sub = frameworks.files.find { |f| f.path == KIT_PROJ }
  unless sub
    sub = frameworks.new_file(KIT_PROJ)
    sub.set_source_tree('SOURCE_ROOT')
    sub.set_path(KIT_PROJ)
    sub.name = 'PostgresKit.xcodeproj'
  end
  entry = project.root_object.project_references.find { |r| r[:project_ref] == sub }
  unless entry
    products = project.new(Xcodeproj::Project::Object::PBXGroup)
    products.name = 'Products'
    proxy = project.new(Xcodeproj::Project::Object::PBXContainerItemProxy)
    proxy.container_portal = sub.uuid
    proxy.proxy_type = '2'
    proxy.remote_global_id_string = KIT_PRODUCT_ID
    proxy.remote_info = 'PostgresKit'
    rp = project.new(Xcodeproj::Project::Object::PBXReferenceProxy)
    rp.file_type = 'wrapper.framework'
    rp.path = 'PostgresKit.framework'
    rp.remote_ref = proxy
    rp.source_tree = 'BUILT_PRODUCTS_DIR'
    products << rp
    project.root_object.project_references << { project_ref: sub, product_group: products }
    entry = project.root_object.project_references.last
  end
  kit_ref = entry[:product_group].children.find { |c| c.path == 'PostgresKit.framework' }

  # App dependency / link / embed
  unless app.dependencies.any? { |d| d.name == 'PostgresKit' }
    tp = project.new(Xcodeproj::Project::Object::PBXContainerItemProxy)
    tp.container_portal = sub.uuid
    tp.proxy_type = '1'
    tp.remote_global_id_string = KIT_TARGET_ID
    tp.remote_info = 'PostgresKit'
    dep = project.new(Xcodeproj::Project::Object::PBXTargetDependency)
    dep.name = 'PostgresKit'
    dep.target_proxy = tp
    app.dependencies << dep
  end
  unless app.frameworks_build_phase.files_references.include?(kit_ref)
    app.frameworks_build_phase.add_file_reference(kit_ref)
  end
  copy = app.copy_files_build_phases.find { |p| p.name == 'Copy Frameworks' } or abort 'no Copy Frameworks phase'
  unless copy.files_references.include?(kit_ref)
    bf = copy.add_file_reference(kit_ref)
    bf.settings = { 'ATTRIBUTES' => %w[CodeSignOnCopy RemoveHeadersOnCopy] }
  end

  # Source/Postgres group
  find_or_create_group(project.main_group['Source'], 'Postgres')

  # Test target
  tests = project.targets.find { |t| t.name == TESTS }
  unless tests
    tests = project.new_target(:unit_test_bundle, TESTS, :osx, '12.0')
    tests.add_dependency(app)
    tests.build_configurations.each do |c|
      s = c.build_settings
      s['ARCHS'] = 'arm64'
      s['ONLY_ACTIVE_ARCH'] = 'NO'
      s['MACOSX_DEPLOYMENT_TARGET'] = '12.0'
      s['PRODUCT_NAME'] = '$(TARGET_NAME)'
      s['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.sequelpro.PostgresTests'
      s['INFOPLIST_FILE'] = 'PostgresTests/Info.plist'
      s['BUNDLE_LOADER'] = '$(TEST_HOST)'
      s['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/Sequel Pro.app/Contents/MacOS/Sequel Pro'
      s['CLANG_ENABLE_OBJC_ARC'] = 'YES'
      s['GCC_PRECOMPILE_PREFIX_HEADER'] = 'NO'
      s['GCC_PREFIX_HEADER'] = ''
      s['FRAMEWORK_SEARCH_PATHS'] = ['$(inherited)', '$(BUILT_PRODUCTS_DIR)']
      s['HEADER_SEARCH_PATHS'] = ['$(inherited)', '$(SRCROOT)/Source/Postgres', '$(SRCROOT)/PostgresTests']
      s['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@loader_path/../Frameworks', '@executable_path/../Frameworks']
      s['OTHER_LDFLAGS'] = ['-framework', 'PostgresKit']
      s['CODE_SIGN_IDENTITY'] = '-'
      s['GENERATE_INFOPLIST_FILE'] = 'NO'
    end
  end
  find_or_create_group(project.main_group, 'PostgresTests')
  project.save
  write_scheme(project, app, tests)
end

def ref_xml(t, container)
  prod = t.product_reference.display_name
  <<-X
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "#{t.uuid}"
               BuildableName = "#{prod}"
               BlueprintName = "#{t.name}"
               ReferencedContainer = "container:#{container}">
            </BuildableReference>
X
end

def write_scheme(project, app, tests)
  dir = File.join(PROJ_PATH, 'xcshareddata', 'xcschemes')
  FileUtils.mkdir_p(dir)
  c = 'sequel-pro.xcodeproj'
  xml = <<-X
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "0510"
   version = "1.3">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "NO"
            buildForArchiving = "NO"
            buildForAnalyzing = "NO">
#{ref_xml(app, c)}         </BuildActionEntry>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "NO"
            buildForProfiling = "NO"
            buildForArchiving = "NO"
            buildForAnalyzing = "NO">
#{ref_xml(tests, c)}         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
#{ref_xml(tests, c)}         </TestableReference>
      </Testables>
      <MacroExpansion>
#{ref_xml(app, c)}      </MacroExpansion>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable>
#{ref_xml(app, c)}      </BuildableProductRunnable>
   </LaunchAction>
</Scheme>
X
  File.write(File.join(dir, "#{TESTS}.xcscheme"), xml)
end

cmd = ARGV.shift
project = Xcodeproj::Project.open(PROJ_PATH)
case cmd
when 'setup'
  setup(project)
when 'add-app'
  abort 'no files' if ARGV.empty?
  app = project.targets.find { |t| t.name == APP }
  add_files(project, app, find_or_create_group(project.main_group['Source'], 'Postgres'), ARGV, true)
  project.save
when 'add-test'
  abort 'no files' if ARGV.empty?
  t = project.targets.find { |x| x.name == TESTS } or abort 'run setup first'
  add_files(project, t, find_or_create_group(project.main_group, 'PostgresTests'), ARGV, true)
  project.save
when 'remove'
  abort 'no files' if ARGV.empty?
  remove_files(project, ARGV)
  project.save
else
  abort "usage: #{$0} setup | add-app <files...> | add-test <files...> | remove <files...>"
end
