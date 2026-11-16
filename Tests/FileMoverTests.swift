import Foundation

// 命令行验证不编译 SwiftUI 窗口；导航值与 RootView 保持一致。
enum AppSection: String, Hashable, Sendable {
    case home, apps, leftovers, launch, installers, captures, bigFiles, stale, devTools
}

/// 搬家：同盘移动、跨盘复制核对再删原件、取消、重名、格式限制、改名、撤销。
/// 跨盘用两个临时磁盘映像（APFS 和 FAT32），测完卸掉
@main
struct FileMoverTests {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let base = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "scratch/mover-test-" + UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        MoveLog.override = base.appending(path: "moves.json")
        let apfs = try attach(base, name: "AdieuMoveTest", fs: "APFS")
        let fat = try attach(base, name: "ADIEUFAT", fs: "MS-DOS FAT32")
        defer {
            for v in [apfs, fat] { _ = run("/usr/bin/hdiutil", ["detach", v.path, "-force"]) }
            try? fm.removeItem(at: base)
        }
        // 测试映像挂成隐藏卷（不在访达里冒出来），位置列表本来就不列隐藏卷，所以手动补上
        let places = Places.list() + [apfs, fat].compactMap { Places.info($0, kind: .volume, name: $0.lastPathComponent) }
        try check(Places.list().first?.kind == .home, "第一个位置是这台 Mac")
        try check(Places.containing(fat, in: places)?.fsType == "msdos", "认出 FAT32")
        try check(Places.containing(fat, in: places)?.limitNote != nil, "FAT32 有限制说明")

        func write(_ url: URL, _ text: String) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let src = base.appending(path: "src")
        let here = base.appending(path: "here")
        try fm.createDirectory(at: here, withIntermediateDirectories: true)
        let project = src.appending(path: "项目 v1.2")
        try write(project.appending(path: "a.txt"), "hello")
        try write(project.appending(path: "sub/b.bin"), String(repeating: "x", count: 3_000_000))
        try write(project.appending(path: ".hidden"), "h")
        try fm.createSymbolicLink(atPath: project.appending(path: "link").path, withDestinationPath: "a.txt")
        let before = FileMover.summary(project)
        try check(before.files == 3 && before.links == 1 && before.folders == 2, "数到了隐藏文件和链接：\(before)")
        let noop: @Sendable (FileMover.Progress) -> Void = { _ in }

        // 1. 同盘移动：瞬间改位置
        try write(src.appending(path: "same.txt"), "same")
        var plan = try FileMover.plan([src.appending(path: "same.txt")], to: here, mode: .move, places: places, protected: [])
        try check(!plan.crossVolume, "同盘不算跨盘")
        var out = FileMover.run(plan, protected: [], progress: noop, cancelled: { false })
        try check(out.failed.isEmpty && FileMover.exists(here.appending(path: "same.txt")) && !FileMover.exists(src.appending(path: "same.txt")), "同盘移动")

        // 2. 不能放进自己里面、不能原地移动
        try expectRefusal { try FileMover.plan([project], to: project.appending(path: "sub"), mode: .move, places: places, protected: []) }
        try expectRefusal { try FileMover.plan([project], to: src, mode: .move, places: places, protected: []) }

        // 3. 取消：原件还在，目标盘上不留临时文件
        plan = try FileMover.plan([project], to: apfs, mode: .move, places: places, protected: [])
        try check(plan.crossVolume && plan.files == 3, "跨盘预检数了文件")
        out = FileMover.run(plan, protected: [], progress: noop, cancelled: { true })
        try check(out.cancelled && FileMover.summary(project) == before, "取消后原件不动")
        try check(try fm.contentsOfDirectory(atPath: apfs.path).allSatisfy { !$0.hasPrefix(".adieu-moving") }, "取消后不留临时文件")
        try check(Pending.leftovers().isEmpty, "取消后没有记成半成品")

        // 4. 跨盘移动：复制、核对、删原件
        out = FileMover.run(plan, protected: [], progress: noop, cancelled: { false })
        let moved = apfs.appending(path: "项目 v1.2")
        try check(out.failed.isEmpty, "跨盘移动没出错：\(out.failed)")
        try check(!FileMover.exists(project) && FileMover.summary(moved) == before, "跨盘移动后原件删除、内容一致")
        try check((try? fm.destinationOfSymbolicLink(atPath: moved.appending(path: "link").path)) == "a.txt", "链接原样复制")
        try check(out.done.first?.copied == false, "跨盘移动成功不算复制")

        // 5. 重名：两份都留，文件夹名不拆后缀
        plan = try FileMover.plan([moved], to: here, mode: .copy, places: places, protected: [])
        _ = FileMover.run(plan, protected: [], progress: noop, cancelled: { false })
        plan = try FileMover.plan([moved], to: here, mode: .copy, places: places, protected: [])
        try check(plan.conflicts == ["项目 v1.2"], "预检报出重名")
        out = FileMover.run(plan, protected: [], progress: noop, cancelled: { false })
        try check(FileMover.exists(here.appending(path: "项目 v1.2 2")) && out.done.first?.copied == true, "重名加编号：\(out)")
        try check(FileMover.uniqueName("a.txt", in: here.appending(path: "项目 v1.2"), isFolder: false) == "a 2.txt", "文件拆后缀加编号")

        // 6. FAT32：名字里有它不认的字符就整批不动
        try write(src.appending(path: "bad/a?b.txt"), "q")
        try expectRefusal { try FileMover.plan([src.appending(path: "bad")], to: fat, mode: .copy, places: places, protected: []) }
        try check(!FileMover.validName("x.", fsType: "msdos") && FileMover.validName("x.", fsType: "apfs"), "FAT 不认结尾的点")

        // 6b. 一批里只有部分放不进：放不进的列出来，其余照搬
        try write(src.appending(path: "good.txt"), "g")
        plan = try FileMover.plan([src.appending(path: "bad"), src.appending(path: "good.txt")], to: fat, mode: .copy, places: places, protected: [])
        try check(plan.items.map(\.lastPathComponent) == ["good.txt"] && plan.skipped.map(\.name) == ["bad"], "只跳过放不进的：\(plan.skipped)")

        // 6c. 同名：跳过、替换（同盘移动和跨盘复制各一次），逐字节核对
        try write(here.appending(path: "dup.txt"), "old")
        try write(src.appending(path: "dup.txt"), "new!")
        plan = try FileMover.plan([src.appending(path: "dup.txt")], to: here, mode: .move, places: places, protected: [])
        plan.conflict = .skip
        out = FileMover.run(plan, protected: [], progress: noop, cancelled: { false })
        try check(out.skipped == ["dup.txt"] && FileMover.exists(src.appending(path: "dup.txt")), "跳过同名")
        plan.conflict = .replace
        out = FileMover.run(plan, protected: [], progress: noop, cancelled: { false })
        try check(out.failed.isEmpty && (try String(contentsOf: here.appending(path: "dup.txt"), encoding: .utf8)) == "new!"
                  && !FileMover.exists(src.appending(path: "dup.txt")), "同盘替换：\(out.failed)")
        try check(try fm.contentsOfDirectory(atPath: here.path).allSatisfy { !$0.hasPrefix(".adieu-moving") }, "替换后不留临时文件")
        try write(apfs.appending(path: "dup.txt"), "older")
        plan = try FileMover.plan([here.appending(path: "dup.txt")], to: apfs, mode: .copy, places: places, protected: [])
        plan.conflict = .replace
        plan.verifyContents = true
        out = FileMover.run(plan, protected: [], progress: noop, cancelled: { false })
        try check(out.failed.isEmpty && (try String(contentsOf: apfs.appending(path: "dup.txt"), encoding: .utf8)) == "new!", "跨盘替换并逐字节核对")
        try check(try FileMover.sameContents(moved, here.appending(path: "项目 v1.2")), "内容一致")
        try write(here.appending(path: "x1.txt"), "aaaa")
        try write(here.appending(path: "x2.txt"), "aaab")
        try check(!(try FileMover.sameContents(here.appending(path: "x1.txt"), here.appending(path: "x2.txt"))), "同样大小内容不同能认出来")

        // 6d. 批量改名的名字；iCloud Drive 的保护名单只放开包住整个 iCloud Drive 的那条
        try check(FileMover.batchName("a.tar.gz", prefix: "1-", suffix: "-b", isFolder: false) == "1-a.tar-b.gz", "后缀放在扩展名前")
        try check(FileMover.batchName("v1.2", prefix: "", suffix: " 旧", isFolder: true) == "v1.2 旧", "文件夹不拆扩展名")
        let cloudInside = FileMover.cloudRoot + "/重要"
        try check(FileMover.cloudProtected(["~/Library/Mobile Documents", "~/.ssh", cloudInside]) == ["~/.ssh", cloudInside], "iCloud 保护名单")
        try check(FileMover.inCloud(cloudInside + "/a") && !FileMover.inCloud(FileMover.cloudRoot), "认出 iCloud 里面")

        // 7. 改名：只改大小写也行，重名拒绝
        try write(here.appending(path: "abc.txt"), "c")
        _ = try FileMover.rename(here.appending(path: "abc.txt"), to: "ABC.txt", fsType: "apfs", protected: [])
        try check(try fm.contentsOfDirectory(atPath: here.path).contains("ABC.txt"), "只改大小写")
        try expectRefusal { try FileMover.rename(here.appending(path: "ABC.txt"), to: "same.txt", fsType: "apfs", protected: []) }
        try expectRefusal { try FileMover.rename(here.appending(path: "ABC.txt"), to: ".x", fsType: "apfs", protected: []) }

        // 8. 范围：主目录第一层、资源库、保护名单都不让动
        let home = fm.homeDirectoryForCurrentUser
        try expectRefusal { try FileMover.checkSource(home.appending(path: "Documents"), protected: []) }
        try expectRefusal { try FileMover.checkSource(home.appending(path: "Library/Preferences"), protected: []) }
        try expectRefusal { try FileMover.checkDestination(home.appending(path: "Library"), protected: []) }
        try expectRefusal { try FileMover.checkSource(moved, protected: [apfs.path]) }

        // 9. 撤销：跨盘移动搬回去；同盘移动改回去
        let mover = MoverModel()
        try write(src.appending(path: "undo/u.txt"), "u")
        await mover.run(try FileMover.plan([src.appending(path: "undo")], to: apfs, mode: .move, places: places, protected: []))
        try check(FileMover.exists(apfs.appending(path: "undo/u.txt")) && !FileMover.exists(src.appending(path: "undo")), "撤销前已搬走")
        await mover.undo(mover.records[0])
        try check(FileMover.exists(src.appending(path: "undo/u.txt")) && !FileMover.exists(apfs.appending(path: "undo")), "跨盘撤销搬回原处：\(mover.notice ?? "")")
        await mover.run(try FileMover.plan([src.appending(path: "undo")], to: here, mode: .move, places: places, protected: []))
        let record = mover.records[0]
        await mover.undo(record)
        try check(FileMover.exists(src.appending(path: "undo/u.txt")), "同盘撤销改回去")
        try check(mover.records.first { $0.id == record.id }?.undone == true, "记成已撤销")
        print("FileMoverTests 通过")
    }

    private static func attach(_ base: URL, name: String, fs: String) throws -> URL {
        let image = base.appending(path: name + ".dmg").path
        guard run("/usr/bin/hdiutil", ["create", "-size", "40m", "-fs", fs, "-volname", name, image]).status == 0 else {
            throw NSError(domain: "hdiutil create \(name)", code: 1)
        }
        let out = run("/usr/bin/hdiutil", ["attach", image, "-nobrowse"])
        guard out.status == 0, let line = out.text.split(separator: "\n").last(where: { $0.contains("/Volumes/") }),
              let range = line.range(of: "/Volumes/") else { throw NSError(domain: "hdiutil attach \(name)", code: 1) }
        return URL(filePath: String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces))
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> (status: Int32, text: String) {
        let p = Process()
        p.executableURL = URL(filePath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NSError(domain: "FileMoverTests 失败：\(message)", code: 1) }
    }

    private static func expectRefusal<T>(_ work: () throws -> T, line: Int = #line) throws {
        do {
            _ = try work()
        } catch {
            return
        }
        throw NSError(domain: "FileMoverTests 失败：第 \(line) 行应该被拒绝", code: 1)
    }
}
