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

class PBXVarientGroupGenerator {
    let pbxProj: PBXProj
//    let targets: [Target]
    let project: Project
    
//    private var tmpVarientGroups: [PBXVariantGroup] = []
    
    init(pbxProj: PBXProj, project: Project) {
        self.pbxProj = pbxProj
//        self.targets = targets
        self.project = project
    }
    
    func generate() -> [PBXVariantGroup] {
        var varientGroupList: [PBXVariantGroup] = []
        
        // pathを受け取る
        project.targets.forEach { target in
            target.sources.forEach { targetSource in
//                let path = project.basePath + targetSource.path
                let path = project.basePath + targetSource.path
//                Term.stdout.print("@@@ path :: \(path)")
                
                // include, excludeを考慮し
                
                do {
                    generateVarientGroup(path: path)
                } catch {
                    
                }
                
            }
        }
        
        // そのpathからPBXFileRefを作成
        // そのFileRefをchildrenにもったPBXVarientGroupを作成
        
        // addobject
        
        func generateVarientGroup(path: Path) {
            
            if path.exists && path.isDirectory  {
                do {
                    // path.children() ここのchilrenでincludeとexcludeを指定したほうが良さそう
                    
                    
                    
                    let localizeDirs: [Path] = try path.children().filter ({ $0.extension == "lproj" })
                    if localizeDirs.count > 0 {
//                        Term.stdout.print("@ lproj dir roo path :: \(path.path)")
                        
                        try localizeDirs.forEach { localizedDir in
//                            Term.stdout.print("@@ lproj dir path :: \(hoge.path)")
//                            Term.stdout.print("@@@ hoge.path :: \(hoge.path)")
                            
                            try localizedDir.children().forEach { localizedDirChildPath in
                                // PBXFileRefを作成
//                                Term.stdout.print("@@@ file path :: \(path.path)")
                                // PBXVarientGroupを作成(orキャッシュから取得)
                                // sourceGeneratorの getFileReference(path: Path,.. 内のPBXFileReferenceを参考にする
                                let fileReferencePath = try localizedDirChildPath.relativePath(from: path)
                                let fileRef = PBXFileReference(
                                    sourceTree: .group,
                                    name: fileReferencePath.lastComponent,
                                    lastKnownFileType: Xcode.fileType(path: path),
                                    path: fileReferencePath.string // let fileReferencePath = (try? path.relativePath(from: inPath)) ?? path, path:
                                )
                                
//                                pbxProj.add(object: fileRef)
                                
                                Term.stdout.print("@@@ localizedDirChildPath :: \(localizedDirChildPath.path)")
//                                Term.stdout.print("@@@ na,e :: \(fileReferencePath.lastComponent)")
                                
                                // 名前はBaseを参照する。

                                if let vg = varientGroupList.first(where: { ($0.name == localizedDirChildPath.lastComponent) }) {
                                    
//                                    if localizedDirChildPath.lastComponentWithoutExtension == "Base" {
//                                        vg.name = path.lastComponent
//                                    }
                                    
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
                                    
//                                    pbxProj.add(object: varientGroup)
                                    
                                    varientGroupList.append(varientGroup)
                                }
                            }
                        }
                    }
                    
    //                Term.stdout.print("\n")
                    
                    try path.children().forEach(generateVarientGroup(path:))
                } catch {
    //                if path.path.contains("lproj") {
    //                    Term.stdout.print("@@@ test1 :: \(path.path)")
    //                }
                }
            } else {
    //            if path.path.contains("lproj") {
    //                Term.stdout.print("@@@ test2 :: \(path.path)")
    //            }
            }
        }
        
        varientGroupList.forEach {
            Term.stdout.print("@@@ test :: \($0.name)")
        }

        Term.stdout.print("@@@ varientGroupList.count -> \(varientGroupList.count)")
        
        return varientGroupList
    }
}
