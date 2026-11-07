import Foundation

/// 阻塞的磁盘读取和命令放到 GCD 线程上跑。Swift 并发的协作线程池只有 CPU 核数那么多线程，
/// 被阻塞读取占满后，别的扫描即使已经开始也会一直排队
func blocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { c in
        DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: work()) }
    }
}
