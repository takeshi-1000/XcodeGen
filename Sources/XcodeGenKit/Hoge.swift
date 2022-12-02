//
//  Hoge.swift
//  XcodeGenKit
//
//  Created by Takeshi Komori on 2022/12/02.
//

import XcodeProj
import ProjectSpec
import PathKit
import XcodeGenCore

protocol Hoge {
    var project: Project { get }
    var defaultExcludedFiles: [String] { get set }
    var defaultExcludedExtensions: [String] { get }
}

extension Hoge {
    
    
    /// Gets all the children paths that aren't excluded
    func getSourceChildren(targetSource: TargetSource, dirPath: Path, excludePaths: Set<Path>, includePaths: SortedArray<Path>) throws -> [Path] {
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
    
    /// Checks whether the path is not in any default or TargetSource excludes
    func isIncludedPath(_ path: Path, excludePaths: Set<Path>, includePaths: SortedArray<Path>) -> Bool {
        return !defaultExcludedFiles.contains(where: { path.lastComponent == $0 })
        && !(path.extension.map(defaultExcludedExtensions.contains) ?? false)
        && !excludePaths.contains(path)
        // If includes is empty, it's included. If it's not empty, the path either needs to match exactly, or it needs to be a direct parent of an included path.
        && (includePaths.value.isEmpty || _isIncludedPathSorted(path, sortedPaths: includePaths))
        
        func _isIncludedPathSorted(_ path: Path, sortedPaths: SortedArray<Path>) -> Bool {
            guard let idx = sortedPaths.firstIndex(where: { $0 >= path }) else { return false }
            let foundPath = sortedPaths.value[idx]
            return foundPath.description.hasPrefix(path.description)
        }
    }
    
    func getSourceMatches(targetSource: TargetSource, patterns: [String]) -> Set<Path> {
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
}
