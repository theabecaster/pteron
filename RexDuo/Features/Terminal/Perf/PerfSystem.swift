import Darwin
import Foundation

/// What the kernel says about this process. Each call is a system call or two (about a
/// microsecond); the probe makes them at window edges and from a slow sampling timer.
enum PerfSystem {
    /// `phys_footprint`: the memory iOS charges the app with (what Xcode's gauge and jetsam use).
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(currentTask(), task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    /// CPU time (user + system) of every thread of the process so far, ended threads included.
    static func processCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// CPU time (user + system) of one thread so far.
    static func threadCPUSeconds(_ thread: thread_act_t) -> Double {
        var info = thread_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
            + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
    }

    /// The kernel's energy and wake-up counters for the process so far (`TASK_POWER_INFO_V2`).
    struct Power: Sendable {
        /// Energy the kernel charged to the process (CPU and what it attributes of the rest), in
        /// nanojoules. Zero where the kernel doesn't count it (the simulator).
        var energyNJ: UInt64 = 0
        /// GPU time charged to the process, in nanoseconds.
        var gpuNS: UInt64 = 0
        /// Times a thread of the process was woken by an interrupt (timers included), and those
        /// that took a core out of idle: what costs battery while the app looks idle.
        var interruptWakeups: UInt64 = 0
        var idleWakeups: UInt64 = 0
    }

    static func power() -> Power {
        var info = task_power_info_v2_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info_v2_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(currentTask(), task_flavor_t(TASK_POWER_INFO_V2), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return Power() }
        #if arch(arm64)
        let energy = info.task_energy
        #else
        let energy: UInt64 = 0
        #endif
        return Power(energyNJ: energy, gpuNS: info.gpu_energy.task_gpu_utilisation,
                     interruptWakeups: info.cpu_energy.task_interrupt_wakeups,
                     idleWakeups: info.cpu_energy.task_platform_idle_wakeups)
    }

    /// The calling thread's port, for `threadCPUSeconds`. No reference is taken.
    static func currentThread() -> thread_act_t { pthread_mach_thread_np(pthread_self()) }

    private static func currentTask() -> mach_port_t { mach_task_self_ }

    private static func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
}
