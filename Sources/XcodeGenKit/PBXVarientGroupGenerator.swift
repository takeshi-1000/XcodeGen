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
    
    func generate() -> [PBXVariantGroup] {
        //
        /*
         pathを格納しておき、
         同じディレクトリ配下にあるlocalizeディレクトリを抽出する。
         （PBXFileRefを、該当するPBXVariantGroupに追加するのに伴って）
         
         */
        var tmpVarientGroupList: [Path: PBXVariantGroup] = [:]
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
                                    
                                    varientGroupList.append(varientGroup)
                                }
                            }
                        }
                    }
                    
    //                Term.stdout.print("\n")
                    try path.children().forEach { path in
                        generateVarientGroup(path: path)
                    }
//                    try path.children().forEach(generateVarientGroup(path:includes:excludes:))
                } catch {
                    Term.stdout.print("@@@ 通過する????")
    //                if path.path.contains("lproj") {
    //                    Term.stdout.print("@@@ test1 :: \(path.path)")
    //                }
                }
            } else {
                if path.path.contains("lproj") {
                    Term.stdout.print("@@@ test2 :: \(path.path)")
                }
            }
        }
        
        
        
//        varientGroupList.forEach {
//            Term.stdout.print("@@@ test :: \($0.name)")
//        }
        
        /*
         (1)/Users/takeshikomori/me/iOS/akerun-ios/AkerunWidget/ja.lproj/AkerunWidget.strings を受け取る
         ・AkerunWidget.stringsのvariantGroupを作成
         
         
         (2)/Users/takeshikomori/me/iOS/akerun-ios/AkerunWidget/Base.lproj/AkerunWidget.intentdefinition を受け取る
         ・/Users/takeshikomori/me/iOS/akerun-ios/AkerunWidget/"ja".lproj のようなpathをfilterする。
         ・そこでfilterされたlastComponentWithoutExtensionで生成された名前のものがあればchildrenにappend
         ・chilren append時に Base or deploymentLanguageであればそれによせる。
         
         @@@ test :: /Users/takeshikomori/me/iOS/akerun-ios/Akerun/en.lproj/Main.strings, Optional("Main.strings")
         @@@ test :: /Users/takeshikomori/me/iOS/akerun-ios/Akerun/ja.lproj/ja.Main.strings, Optional("ja.Main.strings")
         @@@ test :: /Users/takeshikomori/me/iOS/akerun-ios/AkerunWidget/ja.lproj/AkerunWidget.strings, Optional("AkerunWidget.strings")
         @@@ test :: /Users/takeshikomori/me/iOS/akerun-ios/TodayExtension/Base.lproj/MainInterface.storyboard, Optional("MainInterface.storyboard")
         @@@ test :: /Users/takeshikomori/me/iOS/akerun-ios/AkerunWidget/Base.lproj/AkerunWidget.intentdefinition, Optional("AkerunWidget.intentdefinition")
         @@@ test :: /Users/takeshikomori/me/iOS/akerun-ios/Akerun/Supporting Files/ja.lproj/AkerunLocalizable.strings, Optional("AkerunLocalizable.strings")
         @@@ test :: /Users/takeshikomori/me/iOS/akerun-ios/Akerun/Supporting Files/ja.lproj/Localizable.strings, Optional("Localizable.strings")
         @@@ test :: /Users/takeshikomori/me/iOS/akerun-ios/Akerun/Supporting Files/ja.lproj/InfoPlist.strings, Optional("InfoPlist.strings")
         @@@ test :: /Users/takeshikomori/me/iOS/akerun-ios/Akerun/Supporting Files/ja.lproj/AkerunDoorListLocalizable.strings, Optional("AkerunDoorListLocalizable.strings")
         
         
         @@@ test :: /Users/takeshikomori/me/iOS/akerun-ios/AkerunWidget/ja.lproj/AkerunWidget.strings, Optional("AkerunWidget.strings")
         @@@ test :: /Users/takeshikomori/me/iOS/akerun-ios/Akerun/Supporting Files/ja.lproj/InfoPlist.strings, Optional("InfoPlist.strings")
         @@@ test :: /Users/takeshikomori/me/iOS/akerun-ios/AkerunWidget/Base.lproj/AkerunWidget.intentdefinition, Optional("AkerunWidget.intentdefinition")
         @@@ test :: /Users/takeshikomori/me/iOS/akerun-ios/Akerun/ja.lproj/ja.Main.strings, Optional("ja.Main.strings")
         @@@ test :: /Users/takeshikomori/me/iOS/akerun-ios/TodayExtension/Base.lproj/MainInterface.storyboard, Optional("MainInterface.storyboard")
         @@@ test :: /Users/takeshikomori/me/iOS/akerun-ios/Akerun/en.lproj/Main.strings, Optional("Main.strings")
         @@@ test :: /Users/takeshikomori/me/iOS/akerun-ios/Akerun/Supporting Files/ja.lproj/Localizable.strings, Optional("Localizable.strings")
         @@@ test :: /Users/takeshikomori/me/iOS/akerun-ios/Akerun/Supporting Files/ja.lproj/AkerunLocalizable.strings, Optional("AkerunLocalizable.strings")
         @@@ test :: /Users/takeshikomori/me/iOS/akerun-ios/Akerun/Supporting Files/ja.lproj/AkerunDoorListLocalizable.strings, Optional("AkerunDoorListLocalizable.strings")
         */
        tmpVarientGroupList.forEach { test in
            Term.stdout.print("@@@ test :: \(test.key.path), \(test.value.name)")
        }

        Term.stdout.print("@@@ varientGroupList.count -> \(varientGroupList.count)")
        
        return tmpVarientGroupList.map { $0.value }
    }
}
