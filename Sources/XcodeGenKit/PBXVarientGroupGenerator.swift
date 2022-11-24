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
                    let localizeDirs: [Path] = try path.children().filter ({ $0.extension == "lproj" })
                    if localizeDirs.count > 0 {
                        Term.stdout.print("@ lproj dir roo path :: \(path.path)")
                        
                        try localizeDirs.forEach { hoge in
                            Term.stdout.print("@@ lproj dir path :: \(hoge.path)")
                            
                            try hoge.children().forEach { path in
                                // PBXFileRefを作成
                                Term.stdout.print("@@@ file path :: \(path.path)")
                                // PBXVarientGroupを作成(orキャッシュから取得)
                                let fileRef = PBXFileReference.init()
                                
                                if let vg = varientGroupList.first(where: { $0.name?.contains(path.lastComponentWithoutExtension) ?? false }) {
                                    vg.children.append(fileRef)
                                } else {
                                    // fileRefをchildrenに追加(キャッシュから取得しようが、しまいが)
                                    let varientGroup = PBXVariantGroup()
                                    varientGroup.children.append(fileRef)
                                    
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
        
        return varientGroupList
    }
    
    
}
