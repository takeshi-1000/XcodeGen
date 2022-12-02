import XcodeProj
import ProjectSpec
import PathKit
import XcodeGenCore

class PBXVariantGroupInfo {
    let targetName: String
    let variantGroup: PBXVariantGroup
    var path: Path
    
    init(targetName: String, variantGroup: PBXVariantGroup, path: Path) {
        self.targetName = targetName
        self.variantGroup = variantGroup
        self.path = path
    }
}

class PBXVariantGroupGenerator: Hoge {
    let pbxProj: PBXProj
    let project: Project
    
    var defaultExcludedFiles = [
        ".DS_Store",
    ]
    let defaultExcludedExtensions = [
        "orig",
    ]
    
    init(pbxProj: PBXProj, project: Project) {
        self.pbxProj = pbxProj
        self.project = project
    }
    
    func generate() throws -> [PBXVariantGroupInfo] {
        var variantGroupInfoList: [PBXVariantGroupInfo] = []
        
        try project.targets.forEach { target in
            try target.sources.forEach { targetSource in
                let excludePaths = getSourceMatches(targetSource: targetSource,
                                                    patterns: targetSource.excludes)
                let includePaths = getSourceMatches(targetSource: targetSource,
                                                    patterns: targetSource.includes)
                
                let path = project.basePath + targetSource.path
                
                try generateVarientGroup(targetName: target.name,
                                         targetSource: targetSource,
                                         path: path,
                                         excludePaths: excludePaths,
                                         includePaths: SortedArray(includePaths))
            }
        }
        
        func generateVarientGroup(targetName: String,
                                  targetSource: TargetSource,
                                  path: Path,
                                  excludePaths: Set<Path>,
                                  includePaths: SortedArray<Path>) throws {
            guard path.exists && path.isDirectory && !Xcode.isDirectoryFileWrapper(path: path) else {
                return
            }
            
            let children = try getSourceChildren(targetSource: targetSource,
                                                 dirPath: path,
                                                 excludePaths: excludePaths,
                                                 includePaths: includePaths)
            
            try children.forEach {
                let excludePaths = getSourceMatches(targetSource: targetSource,
                                                    patterns: targetSource.excludes)
                let includePaths = getSourceMatches(targetSource: targetSource,
                                                    patterns: targetSource.includes)
                
                try generateVarientGroup(targetName: targetName,
                                         targetSource: targetSource,
                                         path: $0,
                                         excludePaths: excludePaths,
                                         includePaths: SortedArray(includePaths))
            }
            
            let localizeDirs: [Path] = children
                .filter ({ $0.extension == "lproj" })
            
            guard localizeDirs.count > 0 else {
                return
            }
            
            try localizeDirs.forEach { localizedDir in
                try localizedDir.children()
                    .filter { self.isIncludedPath($0, excludePaths: excludePaths, includePaths: includePaths) }
                    .sorted()
                    .forEach { localizedDirChildPath in
                        let fileReferencePath = try localizedDirChildPath.relativePath(from: path)
                        let fileRef = PBXFileReference(
                            sourceTree: .group,
                            name: localizedDir.lastComponentWithoutExtension,
                            lastKnownFileType: Xcode.fileType(path: localizedDirChildPath),
                            path: fileReferencePath.string
                        )
                        pbxProj.add(object: fileRef)
                        
                        let variantGroupInfo = getVariantGroupInfo(targetName: targetName, localizedChildPath: localizedDirChildPath)
                        
                        if localizedDir.lastComponentWithoutExtension == "Base" || project.options.developmentLanguage == localizedDir.lastComponentWithoutExtension {
                            
                            variantGroupInfo.path = localizedDirChildPath
                            variantGroupInfo.variantGroup.name = localizedDirChildPath.lastComponent
                        }
                        
                        variantGroupInfo.variantGroup.children.append(fileRef)
                    }
            }
        }
        
        func getVariantGroupInfo(targetName: String, localizedChildPath: Path) -> PBXVariantGroupInfo {
            let pbxVariantGroupInfo = variantGroupInfoList
                .filter { $0.targetName == targetName }
                .first {
                    if localizedChildPath.lastComponent.contains(".intentdefinition") || localizedChildPath.lastComponent.contains(".storyboard") {
                        return $0.path.lastComponentWithoutExtension == localizedChildPath.lastComponentWithoutExtension
                    } else {
                        return $0.path.lastComponent == localizedChildPath.lastComponent
                    }
                }
            
            if let pbxVariantGroupInfo = pbxVariantGroupInfo {
                return pbxVariantGroupInfo
            } else {
                let variantGroup = PBXVariantGroup(
                    sourceTree: .group,
                    name: localizedChildPath.lastComponent
                )
                pbxProj.add(object: variantGroup)
                
                let pbxVariantGroupInfo = PBXVariantGroupInfo(targetName: targetName,
                                                              variantGroup: variantGroup,
                                                              path: localizedChildPath)
                variantGroupInfoList.append(pbxVariantGroupInfo)
                
                return pbxVariantGroupInfo
            }
        }
        
        return variantGroupInfoList
    }
}
