#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates STTLocalApp.xcodeproj from the Swift sources in STTLocalApp/.
# Run: ruby generate_project.rb

require 'xcodeproj'
require 'fileutils'
require 'pathname'

ROOT = Pathname.new(__dir__).expand_path
PROJECT_PATH = ROOT.join('STTLocalApp.xcodeproj')
SWIFTPM_RESOLVED_PATH = PROJECT_PATH.join('project.xcworkspace', 'xcshareddata', 'swiftpm', 'Package.resolved')
APP_NAME = 'STTLocalApp'
TEST_APP_NAME = 'STTLocalAppTests'
BUNDLE_ID = 'com.local.STTLocalApp'
TEST_BUNDLE_ID = 'com.local.STTLocalAppTests'
DEPLOYMENT_TARGET = '14.0'

# Wipe and recreate the project so re-runs are idempotent.
resolved_package_content = SWIFTPM_RESOLVED_PATH.read if SWIFTPM_RESOLVED_PATH.exist?
FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH)
project.root_object.attributes['LastUpgradeCheck'] = '1620'

# --- Target --------------------------------------------------------------
target = project.new_target(
  :application,
  APP_NAME,
  :osx,
  DEPLOYMENT_TARGET,
  nil,
  :swift
)

test_target = project.new_target(
  :unit_test_bundle,
  TEST_APP_NAME,
  :osx,
  DEPLOYMENT_TARGET,
  nil,
  :swift
)
test_target.add_dependency(target)

# Build settings (both Debug + Release)
target.build_configurations.each do |cfg|
    s = cfg.build_settings
    s['PRODUCT_BUNDLE_IDENTIFIER']             = BUNDLE_ID
    s['PRODUCT_NAME']                          = '$(TARGET_NAME)'
    s['MACOSX_DEPLOYMENT_TARGET']              = DEPLOYMENT_TARGET
    s['SWIFT_VERSION']                         = '5.0'
    s['SWIFT_EMIT_LOC_STRINGS']                = 'YES'
    s['ENABLE_PREVIEWS']                       = 'YES'
    s['GENERATE_INFOPLIST_FILE']               = 'NO'
    s['INFOPLIST_FILE']                        = 'STTLocalApp/App/Info.plist'
    s['CODE_SIGN_ENTITLEMENTS']                = 'STTLocalApp/STTLocalApp.entitlements'
    s['CODE_SIGN_STYLE']                       = 'Automatic'
    s['CODE_SIGN_IDENTITY']                    = '-'   # ad-hoc; replace with Developer ID for distribution
    s['ENABLE_HARDENED_RUNTIME']               = 'YES'
    s['DEVELOPMENT_TEAM']                      = ''
    s['ASSETCATALOG_COMPILER_APPICON_NAME']    = 'AppIcon'
    s['ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME'] = 'AccentColor'
    s['CURRENT_PROJECT_VERSION']               = '1'
    s['MARKETING_VERSION']                     = '0.1.0'
    s['DEAD_CODE_STRIPPING']                   = 'YES'
    s['COMBINE_HIDPI_IMAGES']                  = 'YES'
    s['ENABLE_USER_SCRIPT_SANDBOXING']         = 'YES'
    s['LD_RUNPATH_SEARCH_PATHS']               = '$(inherited) @executable_path/../Frameworks'
    s['SWIFT_STRICT_CONCURRENCY']              = 'minimal'
    s['ENABLE_TESTABILITY']                    = 'YES' if cfg.name == 'Debug'
end

test_target.build_configurations.each do |cfg|
  s = cfg.build_settings
  s['TEST_HOST']                 = '$(BUILT_PRODUCTS_DIR)/STTLocalApp.app/Contents/MacOS/STTLocalApp'
  s['BUNDLE_LOADER']             = '$(TEST_HOST)'
  s['PRODUCT_BUNDLE_IDENTIFIER'] = TEST_BUNDLE_ID
  s['SWIFT_VERSION']             = '5.0'
  s['MACOSX_DEPLOYMENT_TARGET']  = DEPLOYMENT_TARGET
  s['GENERATE_INFOPLIST_FILE']   = 'YES'
end

# Project-level settings
project.build_configurations.each do |cfg|
  s = cfg.build_settings
  s['MACOSX_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  s['SWIFT_VERSION']            = '5.0'
  s['ALWAYS_SEARCH_USER_PATHS'] = 'NO'
  s['CLANG_ANALYZER_NONNULL']   = 'YES'
end

# --- File groups & sources ----------------------------------------------
app_group = project.new_group(APP_NAME, APP_NAME)
SUBGROUPS = %w[App Panel UI Speech Hotkey State].freeze

subgroup_for = {}
SUBGROUPS.each do |name|
  sub = app_group.new_group(name, name)
  subgroup_for[name] = sub
  Dir.glob(ROOT.join('STTLocalApp', name, '*.swift')).sort.each do |swift_path|
    filename = File.basename(swift_path)
    file_ref = sub.new_reference(filename)
    file_ref.last_known_file_type = 'sourcecode.swift'
    target.add_file_references([file_ref])
  end
end

tests_group = project.new_group(TEST_APP_NAME, TEST_APP_NAME)
Dir.glob(ROOT.join(TEST_APP_NAME, '*.swift')).sort.each do |swift_path|
  filename = File.basename(swift_path)
  file_ref = tests_group.new_reference(filename)
  file_ref.last_known_file_type = 'sourcecode.swift'
  test_target.add_file_references([file_ref])
end

# Resources: Assets.xcassets
assets_ref = app_group.new_reference('Assets.xcassets')
assets_ref.last_known_file_type = 'folder.assetcatalog'
target.resources_build_phase.add_file_reference(assets_ref)

# Info.plist (must NOT be in build phase; only INFOPLIST_FILE setting)
info_ref = subgroup_for['App'].new_reference('Info.plist')
info_ref.last_known_file_type = 'text.plist.xml'

# Entitlements (also reference-only, not in build phase)
ent_ref = app_group.new_reference('STTLocalApp.entitlements')
ent_ref.last_known_file_type = 'text.plist.entitlements'

# --- Swift Package Manager dependencies ---------------------------------
def add_spm_dep(project, target, url:, requirement:, product:)
  pkg_ref = project.root_object.package_references.find { |ref| ref.repositoryURL == url }

  unless pkg_ref
    pkg_ref = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
    pkg_ref.repositoryURL = url
    pkg_ref.requirement   = requirement
    project.root_object.package_references << pkg_ref
  end

  product_ref = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product_ref.package      = pkg_ref
  product_ref.product_name = product
  target.package_product_dependencies ||= []
  target.package_product_dependencies << product_ref

  # Wire into Frameworks build phase so the linker sees it.
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = product_ref
  target.frameworks_build_phase.files << build_file
end

add_spm_dep(
  project, target,
  url: 'https://github.com/argmaxinc/WhisperKit.git',
  requirement: { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => '0.9.0' },
  product: 'WhisperKit'
)

add_spm_dep(
  project, test_target,
  url: 'https://github.com/argmaxinc/WhisperKit.git',
  requirement: { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => '0.9.0' },
  product: 'WhisperKit'
)

add_spm_dep(
  project, target,
  url: 'https://github.com/sindresorhus/KeyboardShortcuts.git',
  requirement: { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => '2.0.0' },
  product: 'KeyboardShortcuts'
)

# --- Save ---------------------------------------------------------------
project.save

if resolved_package_content
  FileUtils.mkdir_p(SWIFTPM_RESOLVED_PATH.dirname)
  SWIFTPM_RESOLVED_PATH.write(resolved_package_content)
end

scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(target, test_target, launch_target: true)
scheme.save_as(PROJECT_PATH, APP_NAME, true)

puts "Generated #{PROJECT_PATH.relative_path_from(ROOT)}"
