import Foundation
import Darwin

/// Bound native probes independently of their UI/main-thread responsiveness.
/// Each process exits after its assertions; this watchdog only handles runaway
/// work and reads the same physical-footprint metric used for pressure triage.
func startArtworkSmokeBudget() {
    DispatchQueue.global(qos: .utility).async {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while true {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            if ProcessInfo.processInfo.systemUptime > deadline
                || (result == KERN_SUCCESS && info.phys_footprint > 512 * 1024 * 1024) {
                print("FAIL: native probe exceeded its 30-second / 512-MiB budget")
                exit(2)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}
