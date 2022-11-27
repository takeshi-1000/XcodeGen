//
//  PBXVarientGroupGenerator.swift
//  XcodeGenKit
//
//  Created by Takeshi Komori on 2022/11/24.
//

import XcodeProj
import ProjectSpec
import SwiftCLI
import PathKit
import XcodeGenCore

class PBXVarientGroupGenerator {
    let pbxProj: PBXProj
    let project: Project
    
    init(pbxProj: PBXProj, project: Project) {
        self.pbxProj = pbxProj
        self.project = project
    }
    
    func generate() -> [Path: PBXVariantGroup] {
        
        var tmpVarientGroupList: [Path: PBXVariantGroup] = [:]
        
        // pathを受け取る
        project.targets.forEach { target in
            target.sources.forEach { targetSource in
                let path = project.basePath + targetSource.path
                
                do {
                    generateVarientGroup(path: path)
                } catch {
                    
                }
                
            }
        }
        
        func generateVarientGroup(path: Path) {
            
            if path.exists && path.isDirectory  {
                do {
                    
                    let localizeDirs: [Path] = try path.children()
                        .filter ({ $0.extension == "lproj" })
                                        
                    if localizeDirs.count > 0 {
                        
                        try localizeDirs.forEach { localizedDir in
                            try localizedDir.children().forEach { localizedDirChildPath in
                                
                                
                                // PBXFileRefを作成
//                                Term.stdout.print("@@@ localizedDir.path :: \(localizedDir.path)")
                                // PBXVarientGroupを作成(orキャッシュから取得)
                                // sourceGeneratorの getFileReference(path: Path,.. 内のPBXFileReferenceを参考にする
                                let fileReferencePath = try localizedDirChildPath.relativePath(from: path)
                                let fileRef = PBXFileReference(
                                    sourceTree: .group,
                                    name: localizedDir.lastComponentWithoutExtension,
                                    lastKnownFileType: Xcode.fileType(path: path),
                                    path: fileReferencePath.string
                                )
                                
                                pbxProj.add(object: fileRef)

                                if let vg = tmpVarientGroupList.first(where: { ($0.key.lastComponentWithoutExtension == localizedDirChildPath.lastComponentWithoutExtension) })?.value {
                                    
                                    if localizedDirChildPath.lastComponentWithoutExtension == "Base" ||
                                        project.options.developmentLanguage == localizedDirChildPath.lastComponentWithoutExtension {
                                        vg.name = path.lastComponent
                                    }
                                    
                                    vg.children.append(fileRef)
                                } else {
                                    // fileRefをchildrenに追加(キャッシュから取得しようが、しまいが)
                                    // SourceGenerator内のgetVariantGroup(path: Path)を参考にPBXVarientGroupの生成処理を実装
                                    // そこまで複雑なことはやってなさそう
                                    // addObject忘れない
                                    let varientGroup = PBXVariantGroup(
                                        sourceTree: .group,
                                        name: localizedDirChildPath.lastComponent
                                    )
                                    varientGroup.children.append(fileRef)
                                    
                                    tmpVarientGroupList[localizedDirChildPath] = varientGroup
                                    
                                    pbxProj.add(object: varientGroup)
                                }
                            }
                        }
                    }
                    
                    try path.children().forEach { path in
                        generateVarientGroup(path: path)
                    }
                } catch {

                }
            }
        }
        
        return tmpVarientGroupList
    }
}
