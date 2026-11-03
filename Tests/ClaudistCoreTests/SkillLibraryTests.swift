import Foundation
import Testing
@testable import ClaudistCore

struct SkillLibraryTests {
    let root: URL
    let lib: SkillLibrary
    let src: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("skilllib-\(newID())")
        try AppPaths(root: root).ensure()
        lib = SkillLibrary(root: AppPaths(root: root).skills)
        src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    }

    private func write(_ text: String, _ rel: String) throws -> URL {
        let url = src.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func importsFolder() throws {
        _ = try write("---\nname: pdf\ndescription: PDF tools\n---\n", "pdf/SKILL.md")
        _ = try write("print(1)", "pdf/scripts/fill.py")
        let skill = try lib.importSkill(from: src.appendingPathComponent("pdf"))
        #expect(skill.name == "pdf")
        #expect(skill.description == "PDF tools")
        #expect(lib.files(of: skill).map(\.path) == ["scripts", "scripts/fill.py"])
        #expect(throws: ClaudistError.self) { try lib.importSkill(from: src.appendingPathComponent("pdf")) }
    }

    @Test func importsMarkdownFile() throws {
        let md = try write("---\nname: Release Notes\ndescription: x\n---\nbody", "notes.md")
        let skill = try lib.importSkill(from: md)
        #expect(skill.name == "release-notes")
        #expect(lib.readSkillMD(skill).hasSuffix("body"))
    }

    @Test func importsZipWithTopFolder() throws {
        _ = try write("---\nname: zipped\n---\n", "zipped/SKILL.md")
        let zip = root.appendingPathComponent("zipped.skill")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", src.appendingPathComponent("zipped").path, zip.path]
        try p.run()
        p.waitUntilExit()
        let skill = try lib.importSkill(from: zip)
        #expect(skill.name == "zipped")
    }

    @Test func rejectsFolderWithoutSkillMD() throws {
        _ = try write("x", "empty/readme.txt")
        #expect(throws: ClaudistError.self) { try lib.importSkill(from: src.appendingPathComponent("empty")) }
    }

    @Test func attachesFilesAndMakesScriptsExecutable() throws {
        let skill = try lib.create(name: "deploy", description: "d")
        let script = try write("#!/bin/sh\necho hi", "run")
        let doc = try write("ref", "guide.txt")
        try lib.attach([script], to: skill, subfolder: "scripts")
        try lib.attach([doc], to: skill)

        let files = lib.files(of: skill)
        #expect(files.map(\.path) == ["guide.txt", "scripts", "scripts/run"])
        #expect(files.first { $0.path == "scripts/run" }?.isExecutable == true)
        #expect(files.first { $0.path == "guide.txt" }?.isExecutable == false)

        // Re-attaching replaces the file.
        _ = try write("ref v2", "guide.txt")
        try lib.attach([doc], to: skill)
        #expect(try String(contentsOf: skill.url.appendingPathComponent("guide.txt"), encoding: .utf8) == "ref v2")

        try lib.removeFile("scripts/run", from: skill)
        #expect(lib.files(of: skill).map(\.path) == ["guide.txt", "scripts"])
    }

    @Test func refusesPathEscapesAndSkillMDReplacement() throws {
        let skill = try lib.create(name: "safe", description: "")
        #expect(throws: ClaudistError.self) { try lib.removeFile("../other", from: skill) }
        #expect(throws: ClaudistError.self) { try lib.attach([try write("x", "a.txt")], to: skill, subfolder: "../..") }
        #expect(throws: ClaudistError.self) { try lib.attach([try write("x", "SKILL.md")], to: skill) }
    }
}
