import Foundation
import PathKit
import ProjectSpec
import XcodeProj
import XcodeGenCore
import SwiftCLI

struct SourceFile {
    let path: Path
    let fileReference: PBXFileElement
    let buildFile: PBXBuildFile
    let buildPhase: BuildPhaseSpec?
}

class SourceGenerator {

    var rootGroups: Set<PBXFileElement> = []
    private let projectDirectory: Path?
    private var fileReferencesByPath: [String: PBXFileElement] = [:]
    private var groupsByPath: [Path: PBXGroup] = [:]
    private var tmpVariantGroups: [PBXVariantGroup] = []
    private var localPackageGroup: PBXGroup?

    private let project: Project
    let pbxProj: PBXProj

    private var defaultExcludedFiles = [
        ".DS_Store",
    ]
    private let defaultExcludedExtensions = [
        "orig",
    ]

    private(set) var knownRegions: Set<String> = []

    init(project: Project, pbxProj: PBXProj, projectDirectory: Path?) {
        self.project = project
        self.pbxProj = pbxProj
        self.projectDirectory = projectDirectory
    }

    private func resolveGroupPath(_ path: Path, isTopLevelGroup: Bool) -> String {
        if isTopLevelGroup, let relativePath = try? path.relativePath(from: projectDirectory ?? project.basePath).string {
            return relativePath
        } else {
            return path.lastComponent
        }
    }

    @discardableResult
    func addObject<T: PBXObject>(_ object: T, context: String? = nil) -> T {
        pbxProj.add(object: object)
        object.context = context
        return object
    }

    func createLocalPackage(path: Path, group: Path?) throws {
        var pbxGroup: PBXGroup?
        
        if let location = group {
            let fullLocationPath = project.basePath + location
            pbxGroup = getGroup(path: fullLocationPath, mergingChildren: [], createIntermediateGroups: true, hasCustomParent: false, isBaseGroup: true)
        }
        
        if localPackageGroup == nil && group == nil {
            let groupName = project.options.localPackagesGroup ?? "Packages"
            localPackageGroup = addObject(PBXGroup(sourceTree: .sourceRoot, name: groupName))
            rootGroups.insert(localPackageGroup!)
        }
        
        let absolutePath = project.basePath + path.normalize()
        
        // Get the local package's relative path from the project root
        let fileReferencePath = try? absolutePath.relativePath(from: projectDirectory ?? project.basePath).string

        let fileReference = addObject(
            PBXFileReference(
                sourceTree: .sourceRoot,
                name: absolutePath.lastComponent,
                lastKnownFileType: "folder",
                path: fileReferencePath
            )
        )
        if let pbxGroup = pbxGroup {
            pbxGroup.children.append(fileReference)
        } else {
            localPackageGroup!.children.append(fileReference)
        }
    }

    /// Collects an array complete of all `SourceFile` objects that make up the target based on the provided `TargetSource` definitions.
    ///
    /// - Parameters:
    ///   - targetType: The type of target that the source files should belong to.
    ///   - sources: The array of sources defined as part of the targets spec.
    ///   - buildPhases: A dictionary containing any build phases that should be applied to source files at specific paths in the event that the associated `TargetSource` didn't already define a `buildPhase`. Values from this dictionary are used in cases where the project generator knows more about a file than the spec/filesystem does (i.e if the file should be treated as the targets Info.plist and so on).
    func getAllSourceFiles(targetType: PBXProductType, sources: [TargetSource], buildPhases: [Path : BuildPhaseSpec]) throws -> [SourceFile] {
        try sources.flatMap { try getSourceFiles(targetType: targetType, targetSource: $0, buildPhases: buildPhases) }
    }

    // get groups without build files. Use for Project.fileGroups
    func getFileGroups(path: String) throws {
        _ = try getSourceFiles(targetType: .none, targetSource: TargetSource(path: path), buildPhases: [:])
    }

    func getFileType(path: Path) -> FileType? {
        if let fileExtension = path.extension {
            return project.options.fileTypes[fileExtension] ?? FileType.defaultFileTypes[fileExtension]
        } else {
            return nil
        }
    }

    func generateSourceFile(targetType: PBXProductType, targetSource: TargetSource, path: Path, fileReference: PBXFileElement? = nil, buildPhases: [Path: BuildPhaseSpec]) -> SourceFile {
        let fileReference = fileReference ?? fileReferencesByPath[path.string.lowercased()]!
        var settings: [String: Any] = [:]
        let fileType = getFileType(path: path)
        var attributes: [String] = targetSource.attributes + (fileType?.attributes ?? [])
        var chosenBuildPhase: BuildPhaseSpec?
        var compilerFlags: String = ""
        let assetTags: [String] = targetSource.resourceTags + (fileType?.resourceTags ?? [])

        let headerVisibility = targetSource.headerVisibility ?? .public

        if let buildPhase = targetSource.buildPhase {
            chosenBuildPhase = buildPhase
        } else if resolvedTargetSourceType(for: targetSource, at: path) == .folder {
            chosenBuildPhase = .resources
        } else if let buildPhase = buildPhases[path] {
            chosenBuildPhase = buildPhase
        } else {
            chosenBuildPhase = getDefaultBuildPhase(for: path, targetType: targetType)
        }

        if chosenBuildPhase == .headers && targetType == .staticLibrary {
            // Static libraries don't support the header build phase
            // For public headers they need to be copied
            if headerVisibility == .public {
                chosenBuildPhase = .copyFiles(BuildPhaseSpec.CopyFilesSettings(
                    destination: .productsDirectory,
                    subpath: "include/$(PRODUCT_NAME)",
                    phaseOrder: .preCompile
                ))
            } else {
                chosenBuildPhase = nil
            }
        }

        if chosenBuildPhase == .headers {
            if headerVisibility != .project {
                // Xcode doesn't write the default of project
                attributes.append(headerVisibility.settingName)
            }
        }

        if let flags = fileType?.compilerFlags {
            compilerFlags += flags.joined(separator: " ")
        }

        if !targetSource.compilerFlags.isEmpty {
            if !compilerFlags.isEmpty {
                compilerFlags += " "
            }
            compilerFlags += targetSource.compilerFlags.joined(separator: " ")
        }

        if chosenBuildPhase == .sources && !compilerFlags.isEmpty {
            settings["COMPILER_FLAGS"] = compilerFlags
        }

        if !attributes.isEmpty {
            settings["ATTRIBUTES"] = attributes
        }
        
        if chosenBuildPhase == .resources && !assetTags.isEmpty {
            settings["ASSET_TAGS"] = assetTags
        }

        let buildFile = PBXBuildFile(file: fileReference, settings: settings.isEmpty ? nil : settings)
        return SourceFile(
            path: path,
            fileReference: fileReference,
            buildFile: buildFile,
            buildPhase: chosenBuildPhase
        )
    }

    func getContainedFileReference(path: Path) -> PBXFileElement {
        let createIntermediateGroups = project.options.createIntermediateGroups

        let parentPath = path.parent()
        let fileReference = getFileReference(path: path, inPath: parentPath)
        let parentGroup = getGroup(
            path: parentPath,
            mergingChildren: [fileReference],
            createIntermediateGroups: createIntermediateGroups,
            hasCustomParent: false,
            isBaseGroup: true
        )

        if createIntermediateGroups {
            createIntermediaGroups(for: parentGroup, at: parentPath)
        }
        return fileReference
    }

    func getFileReference(path: Path, inPath: Path, name: String? = nil, sourceTree: PBXSourceTree = .group, lastKnownFileType: String? = nil) -> PBXFileElement {
        let fileReferenceKey = path.string.lowercased()
        if let fileReference = fileReferencesByPath[fileReferenceKey] {
            return fileReference
        } else {
            let fileReferencePath = (try? path.relativePath(from: inPath)) ?? path
            var fileReferenceName: String? = name ?? fileReferencePath.lastComponent
            if fileReferencePath.string == fileReferenceName {
                fileReferenceName = nil
            }
            let lastKnownFileType = lastKnownFileType ?? Xcode.fileType(path: path)

            if path.extension == "xcdatamodeld" {
                let versionedModels = (try? path.children()) ?? []

                // Sort the versions alphabetically
                let sortedPaths = versionedModels
                    .filter { $0.extension == "xcdatamodel" }
                    .sorted { $0.string.localizedStandardCompare($1.string) == .orderedAscending }

                let modelFileReferences =
                    sortedPaths.map { path in
                        addObject(
                            PBXFileReference(
                                sourceTree: .group,
                                lastKnownFileType: "wrapper.xcdatamodel",
                                path: path.lastComponent
                            )
                        )
                    }
                // If no current version path is found we fall back to alphabetical
                // order by taking the last item in the sortedPaths array
                let currentVersionPath = findCurrentCoreDataModelVersionPath(using: versionedModels) ?? sortedPaths.last
                let currentVersion: PBXFileReference? = {
                    guard let indexOf = sortedPaths.firstIndex(where: { $0 == currentVersionPath }) else { return nil }
                    return modelFileReferences[indexOf]
                }()
                let versionGroup = addObject(XCVersionGroup(
                    currentVersion: currentVersion,
                    path: fileReferencePath.string,
                    sourceTree: sourceTree,
                    versionGroupType: "wrapper.xcdatamodel",
                    children: modelFileReferences
                ))
                fileReferencesByPath[fileReferenceKey] = versionGroup
                return versionGroup
            } else {
                // For all extensions other than `xcdatamodeld`
                let fileReference = addObject(
                    PBXFileReference(
                        sourceTree: sourceTree,
                        name: fileReferenceName,
                        lastKnownFileType: lastKnownFileType,
                        path: fileReferencePath.string
                    )
                )
                fileReferencesByPath[fileReferenceKey] = fileReference
                return fileReference
            }
        }
    }

    /// returns a default build phase for a given path. This is based off the filename
    private func getDefaultBuildPhase(for path: Path, targetType: PBXProductType) -> BuildPhaseSpec? {
        if let buildPhase = getFileType(path: path)?.buildPhase {
            return buildPhase
        }
        if let fileExtension = path.extension {
            switch fileExtension {
            case "modulemap":
                guard targetType == .staticLibrary else { return nil }
                return .copyFiles(BuildPhaseSpec.CopyFilesSettings(
                    destination: .productsDirectory,
                    subpath: "include/$(PRODUCT_NAME)",
                    phaseOrder: .preCompile
                ))
            default:
                return .resources
            }
        }
        return nil
    }

    /// Create a group or return an existing one at the path.
    /// Any merged children are added to a new group or merged into an existing one.
    private func getGroup(path: Path, name: String? = nil, mergingChildren children: [PBXFileElement], createIntermediateGroups: Bool, hasCustomParent: Bool, isBaseGroup: Bool) -> PBXGroup {
        let groupReference: PBXGroup

        if let cachedGroup = groupsByPath[path] {
            var cachedGroupChildren = cachedGroup.children
            for child in children {
                // only add the children that aren't already in the cachedGroup
                // Check equality by path and sourceTree because XcodeProj.PBXObject.== is very slow.
                if !cachedGroupChildren.contains(where: { $0.name == child.name && $0.path == child.path && $0.sourceTree == child.sourceTree }) {
                    cachedGroupChildren.append(child)
                    child.parent = cachedGroup
                }
            }
            cachedGroup.children = cachedGroupChildren
            groupReference = cachedGroup
        } else {

            // lives outside the project base path
            let isOutOfBasePath = !path.absolute().string.contains(project.basePath.absolute().string)

            // whether the given path is a strict parent of the project base path
            // e.g. foo/bar is a parent of foo/bar/baz, but not foo/baz
            let isParentOfBasePath = isOutOfBasePath && ((try? path.isParent(of: project.basePath)) == true)

            // has no valid parent paths
            let isRootPath = (isBaseGroup && isOutOfBasePath && isParentOfBasePath) || path.parent() == project.basePath

            // is a top level group in the project
            let isTopLevelGroup = !hasCustomParent && ((isBaseGroup && !createIntermediateGroups) || isRootPath || isParentOfBasePath)

            let groupName = name ?? path.lastComponent

            let groupPath = resolveGroupPath(path, isTopLevelGroup: hasCustomParent || isTopLevelGroup)

            let group = PBXGroup(
                children: children,
                sourceTree: .group,
                name: groupName != groupPath ? groupName : nil,
                path: groupPath
            )
            groupReference = addObject(group)
            groupsByPath[path] = groupReference

            if isTopLevelGroup {
                rootGroups.insert(groupReference)
            }
        }
        return groupReference
    }

    /// Creates a variant group or returns an existing one at the path
    // TODO: nameに変えたい
    private func getVariantGroup(path: Path) -> PBXVariantGroup {
        
//        Term.stdout.print("@@@ getVariantGroup :: \(path)")
        
        let variantGroup: PBXVariantGroup
        if let cachedGroup = tmpVariantGroups.first(where: { $0.name == path.lastComponent }) {
            variantGroup = cachedGroup
        } else {
            let group = PBXVariantGroup(
                sourceTree: .group,
                name: path.lastComponent
            )
            variantGroup = addObject(group)
            tmpVariantGroups.append(variantGroup)
        }
        return variantGroup
    }

    /// Collects all the excluded paths within the targetSource
    private func getSourceMatches(targetSource: TargetSource, patterns: [String]) -> Set<Path> {
        let rootSourcePath = project.basePath + targetSource.path

        return Set(
            patterns.parallelMap { pattern in
                guard !pattern.isEmpty else { return [] }
                return Glob(pattern: "\(rootSourcePath)/\(pattern)")
                    .map { Path($0) }
                    .map {
                        guard $0.isDirectory else {
                            return [$0]
                        }

                        return (try? $0.recursiveChildren()) ?? []
                    }
                    .reduce([], +)
            }
            .reduce([], +)
        )
    }

    /// Checks whether the path is not in any default or TargetSource excludes
    func isIncludedPath(_ path: Path, excludePaths: Set<Path>, includePaths: SortedArray<Path>) -> Bool {
        return !defaultExcludedFiles.contains(where: { path.lastComponent == $0 })
            && !(path.extension.map(defaultExcludedExtensions.contains) ?? false)
            && !excludePaths.contains(path)
            // If includes is empty, it's included. If it's not empty, the path either needs to match exactly, or it needs to be a direct parent of an included path.
            && (includePaths.value.isEmpty || _isIncludedPathSorted(path, sortedPaths: includePaths))
    }
    
    private func _isIncludedPathSorted(_ path: Path, sortedPaths: SortedArray<Path>) -> Bool {
        guard let idx = sortedPaths.firstIndex(where: { $0 >= path }) else { return false }
        let foundPath = sortedPaths.value[idx]
        return foundPath.description.hasPrefix(path.description)
    }


    /// Gets all the children paths that aren't excluded
    private func getSourceChildren(targetSource: TargetSource, dirPath: Path, excludePaths: Set<Path>, includePaths: SortedArray<Path>) throws -> [Path] {
        try dirPath.children()
            .filter {
                if $0.isDirectory {
                    let children = try $0.children()

                    if children.isEmpty {
                        return project.options.generateEmptyDirectories
                    }

                    return !children
                        .filter { self.isIncludedPath($0, excludePaths: excludePaths, includePaths: includePaths) }
                        .isEmpty
                } else if $0.isFile {
                    return self.isIncludedPath($0, excludePaths: excludePaths, includePaths: includePaths)
                } else {
                    return false
                }
            }
    }

    /// creates all the source files and groups they belong to for a given targetSource
    
    /*
     groupの中に下記がある。
     - source
     - groups
     
     例えば下記のような関係性
     - Test1(Group/PBXGroup)
     - Test2(Group/PBXGroup)
     - Test3(Group/PBXGroup)
     - hoge.lproj(Group/PBXVarientGroup)
     - Tes1.swift(source/FileReference)
     - Tes2.swift(source/FileReference))
     - Tes3.swift(source/FileReference))
     - Tes4.swift(source/FileReference))
     それが戻り値として -> (sourceFiles: [SourceFile], groups: [PBXGroup]) の形で表されている。
     
     下記3種類
     // 普通のグループ(.lprojがついてない)
     // 普通のグループ(.lprojがついている)
     // ファイル
     */
    private func getGroupSources(
        targetType: PBXProductType,
        targetSource: TargetSource,
        path: Path,
        isBaseGroup: Bool,
        hasCustomParent: Bool,
        excludePaths: Set<Path>,
        includePaths: SortedArray<Path>,
        buildPhases: [Path: BuildPhaseSpec]
    ) throws -> (sourceFiles: [SourceFile], groups: [PBXGroup]) {

        // fileもディレクトリ(group)も含んだもの
        /*
         F8862F1E27EFE24E00EC8E14 /* App */ = {
             isa = PBXGroup;
             children = (
                 F8862F1F27EFE24E00EC8E14 /* AppDelegate.swift */,
                 F8862F2127EFE24E00EC8E14 /* SceneDelegate.swift */,
                 F885EB5227F03A9900029CDF /* SupportingFile */,
                 F8862F7B27EFF44500EC8E14 /* Resource */,
                 F8862F6C27EFF28A00EC8E14 /* Interface */,
                 F8862F5827EFE56B00EC8E14 /* Coordinator */,
                 F8862F5F27EFF10D00EC8E14 /* Domain */,
                 F8862F6227EFF13500EC8E14 /* ServiceClient */,
                 F8862F6227EFF13500EC8E14 /* Hoge.lproj */,
             );
             path = App;
             sourceTree = "<group>";
         };
         */
        let children: [Path] = try getSourceChildren(targetSource: targetSource, dirPath: path, excludePaths: excludePaths, includePaths: includePaths)

        let createIntermediateGroups: Bool = targetSource.createIntermediateGroups ?? project.options.createIntermediateGroups
                
        // MARK: - not localized
        
        let nonLocalizedChildren = children.filter { $0.extension != "lproj" }

        /*
         ディレクトリと、ファイルを分解
         */
        
        /*
         上の例でいくと下記のfilePathsは
         F8862F1E27EFE24E00EC8E14 /* App */ = {
             isa = PBXGroup;
             children = (
                 F8862F1F27EFE24E00EC8E14 /* AppDelegate.swift */,
                 F8862F2127EFE24E00EC8E14 /* SceneDelegate.swift */,
                 ⭕️F885EB5227F03A9900029CDF /* SupportingFile */,
                 ⭕️F8862F7B27EFF44500EC8E14 /* Resource */,
                 ⭕️F8862F6C27EFF28A00EC8E14 /* Interface */,
                 ⭕️F8862F5827EFE56B00EC8E14 /* Coordinator */,
                 ⭕️F8862F5F27EFF10D00EC8E14 /* Domain */,
                 ⭕️F8862F6227EFF13500EC8E14 /* ServiceClient */,
                 F8862F6227EFF13500EC8E14 /* Hoge.lproj */,
             );
             path = App;
             sourceTree = "<group>";
         };
         */
        
        let directories = nonLocalizedChildren
            .filter {
                if let fileType = getFileType(path: $0) {
                    return !fileType.file
                } else {
                    return $0.isDirectory && !Xcode.isDirectoryFileWrapper(path: $0)
                }
            }

        /*
         上の例でいくと下記のfilePathsは
         F8862F1E27EFE24E00EC8E14 /* App */ = {
             isa = PBXGroup;
             children = (
                 ⭕️F8862F1F27EFE24E00EC8E14 /* AppDelegate.swift */,
                 ⭕️F8862F2127EFE24E00EC8E14 /* SceneDelegate.swift */,
                 F885EB5227F03A9900029CDF /* SupportingFile */,
                 F8862F7B27EFF44500EC8E14 /* Resource */,
                 F8862F6C27EFF28A00EC8E14 /* Interface */,
                 F8862F5827EFE56B00EC8E14 /* Coordinator */,
                 F8862F5F27EFF10D00EC8E14 /* Domain */,
                 F8862F6227EFF13500EC8E14 /* ServiceClient */,
                 F8862F6227EFF13500EC8E14 /* Hoge.lproj */,
             );
             path = App;
             sourceTree = "<group>";
         };
         */
        let filePaths = nonLocalizedChildren
            .filter {
                if let fileType = getFileType(path: $0) {
                    return fileType.file
                } else {
                    return $0.isFile || $0.isDirectory && Xcode.isDirectoryFileWrapper(path: $0)
                }
            }
        // fileReferenceをgroupChildrenに持っておく
        // ⭕️F8862F1F27EFE24E00EC8E14 /* AppDelegate.swift */,
        // ⭕️F8862F2127EFE24E00EC8E14 /* SceneDelegate.swift */,
        var groupChildren: [PBXFileElement] = filePaths.map { getFileReference(path: $0, inPath: path) }
        
        // sourceFileも作成しておく
        // sourceFileはPBXBuildFile(pbxprojでいうと下記)で必要になりそう
        /*
         Begin PBXBuildFile section
         ...
         F8862F2027EFE24E00EC8E14 /* AppDelegate.swift in Sources */ = {isa = PBXBuildFile; fileRef = F8862F1F27EFE24E00EC8E14 /* AppDelegate.swift */; };
         F8862F2227EFE24E00EC8E14 /* SceneDelegate.swift in Sources */ = {isa = PBXBuildFile; fileRef = F8862F2127EFE24E00EC8E14 /* SceneDelegate.swift */; };
         */
        var allSourceFiles: [SourceFile] = filePaths.map {
            generateSourceFile(targetType: targetType, targetSource: targetSource, path: $0, buildPhases: buildPhases)
        }
        
        var groups: [PBXGroup] = []

        // fileでないディレクトリをfor文で回す
        for path in directories {
            /*
             下記あたりがinputとして入れられる
             ⭕️F885EB5227F03A9900029CDF /* SupportingFile */,
             ⭕️F8862F7B27EFF44500EC8E14 /* Resource */,
             ⭕️F8862F6C27EFF28A00EC8E14 /* Interface */,
             ⭕️F8862F5827EFE56B00EC8E14 /* Coordinator */,
             ⭕️F8862F5F27EFF10D00EC8E14 /* Domain */,
             ⭕️F8862F6227EFF13500EC8E14 /* ServiceClient */,
             */
            let subGroups = try getGroupSources(
                targetType: targetType,
                targetSource: targetSource,
                path: path,
                isBaseGroup: false,
                hasCustomParent: false,
                excludePaths: excludePaths,
                includePaths: includePaths,
                buildPhases: buildPhases
            )

            guard !subGroups.sourceFiles.isEmpty || project.options.generateEmptyDirectories else {
                continue
            }

            // このメソッドで受け取ったpathのその下のsourceFilesを、allSourceFilesに入れる
            /*
             このメソッドで受け取ったpath: Test1
             その下のfile: test1.swift, test2.swift test3.swift
             - Test1/test1.swift
             - Test1/test2.swift
             - Test1/test3.swift
             */
            allSourceFiles += subGroups.sourceFiles

            if let firstGroup = subGroups.groups.first {
                /*
                 groupChildrenにはまだファイルしか入ってないが
                 - Tes1.swift(source/FileReference)
                 - Tes2.swift(source/FileReference))
                 
                 subGroups = try getGroupSources で取得したsubGroups.groups.first に、
                下記の、ものに相当するfileReferenceがあるので、groupChildrenに追加していると思われる
                 - Test1(Group/PBXGroup)
                 - Test2(Group/PBXGroup)
                 - Test3(Group/PBXGroup)
                 
                PBXGroupはchilrenを持ち、fileとpbxgroupそのものを持つ必要がある。
                 groupchildren変数にfileRefrenceを突っ込むようなので、それに相当するfirstGroupを入れる
                 */
                groupChildren.append(firstGroup)
                
                /*
                 ここのsubGroups.groupsにあるものは、path直下に限らず、path以降の全てのGroupみたいだということ
                 例えば下記のような構造があって、MiwaLibを現在pathとして受け取っていた場合、
                 ⭕️の他に、🙆‍♂️もsubgroupsとして受け取れる
                 /MiwaLib⭕️
                 ├── AssetDbManager.swift
                 ├── MiwaRobot.swift
                 ├── Utils.swift
                 ├── ble⭕️
                 │   ├── BleCentral.swift
                 │   ├── hoge1🙆‍♂️
                 │   │    ├── hoge1.swift
                 │   ├── hoge2🙆‍♂️
                 │   │    ├── hoge2.swift
                 ├── command⭕️
                 │   ├── ComTask.swift
                 │   ├── DeviceCertificationTask.swift
                 │   ├── RegisterAdminTask.swift
                 │   └── TestTask.swift
                 ├── data⭕️
                 │   └── miwa.realm
                 ├── model⭕️
                 │   ├── BleGattData.swift
                 └── operation⭕️
                 ├── Queue.swift
                 ├── SimpleOperation.swift
                 └── Threads.swift
                 */
                groups += subGroups.groups
            } else if project.options.generateEmptyDirectories {
                groups += subGroups.groups
            }
        }
        
        // MARK: - localized
        
        // MARK: - localized 新規
        
        /*
         やること
         1. localized file の実態を作成（PBXBuildFile）
         2. PBXVarientGroupの作成
         3. PBXGroupの作成 or ChildrenにAppend, PBXSourceBuildPhase用のPBXBuildFileの作成
         4. 上記の、 "PBXSourceBuildPhase用のPBXBuildFile" をもとに、PBXSourceBuildPhaseを作成orFilesにAppend
         （多分やらなくて良い）5. PBXNativeTarget
         */
        
        // 対象のローカライズディレクトリの確認
        /*
         Base.lproj
         - Akerun.strings(1)
          -> enとjaの探索始める
          -> 見つけたFile全てを作成して、そのファイルをもとにPBXVarientGroup作成
          -> PBXVarientGroupからPBXSourceBuildPhaseに紐付けるPBXBuildFileを作成する
          -> それをBuildPhaseに追加
         - Akerun2.strings(2) -> enとjaの探索始める
         - Akerun3.strings(3) -> enとjaの探索始める
         
         en.lproj
         - Akerun.strings (4) -> enとjaの探索始めて、既に作成したBuildFileないか(knowFileTypeがtext.plist.stringsで、名前が同じもの)確認
         - Akerun2.strings (5) -> enとjaの探索始めて、既に作成したBuildFileないか(knowFileTypeがtext.plist.stringsで、名前が同じもの)確認
         - Akerun3.strings (4) -> enとjaの探索始めて、既に作成したBuildFileないか(knowFileTypeがtext.plist.stringsで、名前が同じもの)確認
         ja.lproj
         - Akerun.strings
         - Akerun2.strings
         - Akerun3.strings
         
         ==
         
         
         
         */
            
        let newLocalisedDirectories = children
            .filter { $0.extension == "lproj" }
        
        do {
            try newLocalisedDirectories.forEach { localizedDir in
                                
                try localizedDir.children()
                    .filter { self.isIncludedPath($0, excludePaths: excludePaths, includePaths: includePaths) }
                    .sorted()
                    .forEach { localizedDirChildPath in

                        let variantGroup = getVariantGroup(path: localizedDirChildPath)

                        if groupChildren.contains(where: { $0.name == variantGroup.name }) == false {
                            groupChildren.append(variantGroup)
                        }

                        let sourceFile = generateSourceFile(targetType: targetType,
                                                            targetSource: targetSource,
                                                            path: localizedDirChildPath,
                                                            fileReference: variantGroup,
                                                            buildPhases: buildPhases)
                        allSourceFiles.append(sourceFile)
                        
                        let fileReference = getFileReference(
                            path: localizedDirChildPath,
                            inPath: path,
                            name: localizedDir.lastComponentWithoutExtension
                        )
                                                
                        variantGroup.children.append(fileReference)
                    }
            }
        } catch {
            
        }
                
        knownRegions.formUnion(newLocalisedDirectories.map { $0.lastComponentWithoutExtension })
        
        /*
        // MARK: - localized 既存
        /*
         上の例でいくと下記のfilePathsは
         F8862F1E27EFE24E00EC8E14 /* App */ = {
             isa = PBXGroup;
             children = (
                 F8862F1F27EFE24E00EC8E14 /* AppDelegate.swift */,
                 F8862F2127EFE24E00EC8E14 /* SceneDelegate.swift */,
                 F885EB5227F03A9900029CDF /* SupportingFile */,
                 F8862F7B27EFF44500EC8E14 /* Resource */,
                 F8862F6C27EFF28A00EC8E14 /* Interface */,
                 F8862F5827EFE56B00EC8E14 /* Coordinator */,
                 F8862F5F27EFF10D00EC8E14 /* Domain */,
                 F8862F6227EFF13500EC8E14 /* ServiceClient */,
                 ⭕️F8862F6227EFF13500EC8E14 /* Hoge.lproj */,
             );
             path = App;
             sourceTree = "<group>";
         };
         */
        let localisedDirectories = children
            .filter { $0.extension == "lproj" }

        // find the base localised directory
        
        /*
         baseのローカライズファイルが、一つにしかない前提となっている
         */
        let baseLocalisedDirectory: Path? = {
            func findLocalisedDirectory(by languageId: String) -> Path? {
                localisedDirectories.first { $0.lastComponent == "\(languageId).lproj" }
            }
            return findLocalisedDirectory(by: "Base") ??
                findLocalisedDirectory(by: NSLocale.canonicalLanguageIdentifier(from: project.options.developmentLanguage ?? "en"))
        }()

        knownRegions.formUnion(localisedDirectories.map { $0.lastComponentWithoutExtension })

        // create variant groups of the base localisation first
        var baseLocalisationVariantGroups: [PBXVariantGroup] = []

        /*
         Base.lproj内を探索し、下記を行いそう
         1. varientGroupの作成
         2. Base.lproj内のファイルのみ、sourceFileを作成
         */
        if let baseLocalisedDirectory = baseLocalisedDirectory {
            let filePaths = try baseLocalisedDirectory.children()
                .filter { self.isIncludedPath($0, excludePaths: excludePaths, includePaths: includePaths) }
                .sorted()
            for filePath in filePaths {
                let variantGroup = getVariantGroup(path: filePath)
                // fileRefrenceを追加
                
                /*
                 variantGroupもfileReferenceになるので、groupChildrenに追加
                 */
                groupChildren.append(variantGroup)
                baseLocalisationVariantGroups.append(variantGroup)

                let sourceFile = generateSourceFile(targetType: targetType,
                                                    targetSource: targetSource,
                                                    path: filePath,
                                                    fileReference: variantGroup,
                                                    buildPhases: buildPhases)
                allSourceFiles.append(sourceFile)
            }
        }

        // add references to localised resources into base localisation variant groups
        
        /*
         Base.lproj以外の`{language-id}.lproj`ディレクトリも含んで探索していく
         1. baseLocalisationVariantGroupsから予め追加されたvarientGroupと、for文で回しているnameが一緒のものを抽出
         2.
         */
        for localisedDirectory in localisedDirectories {
            let localisationName = localisedDirectory.lastComponentWithoutExtension
            let filePaths = try localisedDirectory.children()
                .filter { self.isIncludedPath($0, excludePaths: excludePaths, includePaths: includePaths) }
                .sorted { $0.lastComponent < $1.lastComponent }
            for filePath in filePaths {
                // find base localisation variant group
                // ex: Foo.strings will be added to Foo.strings or Foo.storyboard variant group
                let variantGroup = baseLocalisationVariantGroups
                    .first {
                        Path($0.name!).lastComponent == filePath.lastComponent
                    } ?? baseLocalisationVariantGroups.first {
                        Path($0.name!).lastComponentWithoutExtension == filePath.lastComponentWithoutExtension
                    }

                let fileReference = getFileReference(
                    path: filePath,
                    inPath: path,
                    name: variantGroup != nil ? localisationName : filePath.lastComponent
                )

                if let variantGroup = variantGroup {
                    if !variantGroup.children.contains(fileReference) {
                        variantGroup.children.append(fileReference)
                    }
                } else {
                    /*
                     base.lprojにないものだと、
                     とりあえず、ソースファイルを作成して、groupChildrenに突っ込んでおこう
                     というロジックになっている。
                     なので、AkerunDoorListLocalizable.stringsが、base.lprojに格納されていないので
                     結果ここのロジックを通る感じになっている。
                     */
                    let sourceFile = generateSourceFile(targetType: targetType,
                                                        targetSource: targetSource,
                                                        path: filePath,
                                                        fileReference: fileReference,
                                                        buildPhases: buildPhases)
                    allSourceFiles.append(sourceFile)
                    groupChildren.append(fileReference)
                }
            }
        }
        */
        
        // MARK: - group 作成
        
        let group = getGroup(
            path: path,
            mergingChildren: groupChildren,
            createIntermediateGroups: createIntermediateGroups,
            hasCustomParent: hasCustomParent,
            isBaseGroup: isBaseGroup
        )
        if createIntermediateGroups {
            createIntermediaGroups(for: group, at: path)
        }
        
        /*
         groupsの中には、groupが乱立していると思われるが
         0番目が受け取ったpathに等しいgroup
         
         例えば下記のようなFugaまでのpathを取った場合、
         /Akerun/Test/Hoge/Fuga
         
         Fugaがすぐ上のgroupにあたるもので、
         Fuga以下の下記のようなgroupは
         /Akerun/Test/Hoge/Fuga/HogeMaru/...
         /Akerun/Test/Hoge/Fuga/HogeMaru2/...
         /Akerun/Test/Hoge/Fuga/HogeMaru3/...
         
         もう少し上の方にある下記の処理がそれに相当すると思われる。
         for path in directories {

             let subGroups = try getGroupSources(
                 targetType: targetType,
                 targetSource: targetSource,
                 path: path,
                 isBaseGroup: false,
                 hasCustomParent: false,
                 excludePaths: excludePaths,
                 includePaths: includePaths,
                 buildPhases: buildPhases
             )
         
         
         */
        groups.insert(group, at: 0)
        return (allSourceFiles, groups)
    }

    /// creates source files
    private func getSourceFiles(targetType: PBXProductType, targetSource: TargetSource, buildPhases: [Path: BuildPhaseSpec]) throws -> [SourceFile] {

        // generate excluded paths
        let path = project.basePath + targetSource.path
        let excludePaths = getSourceMatches(targetSource: targetSource, patterns: targetSource.excludes)
        // generate included paths. Excluded paths will override this.
        let includePaths = getSourceMatches(targetSource: targetSource, patterns: targetSource.includes)

        let type = resolvedTargetSourceType(for: targetSource, at: path)

        let customParentGroups = (targetSource.group ?? "").split(separator: "/").map { String($0) }
        let hasCustomParent = !customParentGroups.isEmpty

        let createIntermediateGroups = targetSource.createIntermediateGroups ?? project.options.createIntermediateGroups

        var sourceFiles: [SourceFile] = []
        let sourceReference: PBXFileElement
        var sourcePath = path
        switch type {
        case .folder:
            let fileReference = getFileReference(
                path: path,
                inPath: project.basePath,
                name: targetSource.name ?? path.lastComponent,
                sourceTree: .sourceRoot,
                lastKnownFileType: "folder"
            )

            if !(createIntermediateGroups || hasCustomParent) || path.parent() == project.basePath {
                rootGroups.insert(fileReference)
            }

            let sourceFile = generateSourceFile(targetType: targetType, targetSource: targetSource, path: path, buildPhases: buildPhases)

            sourceFiles.append(sourceFile)
            sourceReference = fileReference
        case .file:
            
            let parentPath = path.parent()
            let fileReference = getFileReference(path: path, inPath: parentPath, name: targetSource.name)

            let sourceFile = generateSourceFile(targetType: targetType, targetSource: targetSource, path: path, buildPhases: buildPhases)

            if hasCustomParent {
                sourcePath = path
                sourceReference = fileReference
            } else if parentPath == project.basePath {
                sourcePath = path
                sourceReference = fileReference
                rootGroups.insert(fileReference)
            } else {
                let parentGroup = getGroup(
                    path: parentPath,
                    mergingChildren: [fileReference],
                    createIntermediateGroups: createIntermediateGroups,
                    hasCustomParent: hasCustomParent,
                    isBaseGroup: true
                )
                sourcePath = parentPath
                sourceReference = parentGroup
            }
            sourceFiles.append(sourceFile)

        case .group:
            if targetSource.optional && !Path(targetSource.path).exists {
                // This group is missing, so if's optional just return an empty array
                return []
            }

            let (groupSourceFiles, groups) = try getGroupSources(
                targetType: targetType,
                targetSource: targetSource,
                path: path,
                isBaseGroup: true,
                hasCustomParent: hasCustomParent,
                excludePaths: excludePaths,
                includePaths: SortedArray(includePaths),
                buildPhases: buildPhases
            )

            let group = groups.first!
            if let name = targetSource.name {
                group.name = name
            }

            sourceFiles += groupSourceFiles
            sourceReference = group
        }

        if hasCustomParent {
            createParentGroups(customParentGroups, for: sourceReference)
            try makePathRelative(for: sourceReference, at: path)
        } else if createIntermediateGroups {
            createIntermediaGroups(for: sourceReference, at: sourcePath)
        }

        return sourceFiles
    }

    /// Returns the resolved `SourceType` for a given `TargetSource`.
    ///
    /// While `TargetSource` declares `type`, its optional and in the event that the value is not defined then we must resolve a sensible default based on the path of the source.
    private func resolvedTargetSourceType(for targetSource: TargetSource, at path: Path) -> SourceType {
        return targetSource.type ?? (path.isFile || path.extension != nil ? .file : .group)
    }

    private func createParentGroups(_ parentGroups: [String], for fileElement: PBXFileElement) {
        guard let parentName = parentGroups.last else {
            return
        }

        let parentPath = project.basePath + Path(parentGroups.joined(separator: "/"))
        let parentPathExists = parentPath.exists
        let parentGroupAlreadyExists = groupsByPath[parentPath] != nil

        let parentGroup = getGroup(
            path: parentPath,
            mergingChildren: [fileElement],
            createIntermediateGroups: false,
            hasCustomParent: false,
            isBaseGroup: parentGroups.count == 1
        )

        // As this path is a custom group, remove the path reference
        if !parentPathExists {
            parentGroup.name = String(parentName)
            parentGroup.path = nil
        }

        if !parentGroupAlreadyExists {
            createParentGroups(parentGroups.dropLast(), for: parentGroup)
        }
    }

    // Add groups for all parents recursively
    private func createIntermediaGroups(for fileElement: PBXFileElement, at path: Path) {

        let parentPath = path.parent()
        guard parentPath != project.basePath else {
            // we've reached the top
            return
        }

        let hasParentGroup = groupsByPath[parentPath] != nil
        if !hasParentGroup {
            do {
                // if the path is a parent of the project base path (or if calculating that fails)
                // do not create a parent group
                // e.g. for project path foo/bar/baz
                //  - create foo/baz
                //  - create baz/
                //  - do not create foo
                let pathIsParentOfProject = try path.isParent(of: project.basePath)
                if pathIsParentOfProject { return }
            } catch {
                return
            }
        }
        let parentGroup = getGroup(
            path: parentPath,
            mergingChildren: [fileElement],
            createIntermediateGroups: true,
            hasCustomParent: false,
            isBaseGroup: false
        )

        if !hasParentGroup {
            createIntermediaGroups(for: parentGroup, at: parentPath)
        }
    }

    // Make the fileElement path and name relative to its parents aggregated paths
    private func makePathRelative(for fileElement: PBXFileElement, at path: Path) throws {
        // This makes the fileElement path relative to its parent and not to the project. Xcode then rebuilds the actual
        // path for the file based on the hierarchy this fileElement lives in.
        var paths: [String] = []
        var element: PBXFileElement = fileElement
        while true {
            guard let parent = element.parent else { break }

            if let path = parent.path {
                paths.insert(path, at: 0)
            }

            element = parent
        }

        let completePath = project.basePath + Path(paths.joined(separator: "/"))
        let relativePath = try path.relativePath(from: completePath)
        let relativePathString = relativePath.string

        if relativePathString != fileElement.path {
            fileElement.path = relativePathString
            fileElement.name = relativePath.lastComponent
        }
    }

    private func findCurrentCoreDataModelVersionPath(using versionedModels: [Path]) -> Path? {
        // Find and parse the current version model stored in the .xccurrentversion file
        guard
            let versionPath = versionedModels.first(where: { $0.lastComponent == ".xccurrentversion" }),
            let data = try? versionPath.read(),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
            let versionString = plist["_XCCurrentVersionName"] as? String else {
            return nil
        }
        return versionedModels.first(where: { $0.lastComponent == versionString })
    }
}
