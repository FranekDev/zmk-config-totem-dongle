import Foundation
import IOKit.hid

/// Talks to the dongle's raw HID interface (usage page 0xFF60 / usage 0x61, zmk-raw-hid defaults).
/// All callbacks are delivered on the main run loop.
final class KeyboardHID {
    static let usagePage = 0xFF60
    static let usage = 0x61
    static let reportSize = 32

    var onReport: ((IOHIDDevice, [UInt8]) -> Void)?
    var onDeviceAdded: ((IOHIDDevice) -> Void)?
    var onDeviceRemoved: ((IOHIDDevice) -> Void)?

    private let manager: IOHIDManager
    private var buffers: [(device: IOHIDDevice, buffer: UnsafeMutablePointer<UInt8>)] = []

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey: Self.usagePage,
            kIOHIDDeviceUsageKey: Self.usage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            Unmanaged<KeyboardHID>.fromOpaque(ctx!).takeUnretainedValue().added(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            Unmanaged<KeyboardHID>.fromOpaque(ctx!).takeUnretainedValue().removed(device)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            NSLog("TotemStatus: IOHIDManagerOpen failed: 0x%08x", result)
        }
    }

    var devices: [IOHIDDevice] { buffers.map(\.device) }

    @discardableResult
    func send(_ bytes: [UInt8], to device: IOHIDDevice) -> Bool {
        var report = [UInt8](repeating: 0, count: Self.reportSize)
        for (i, b) in bytes.prefix(Self.reportSize).enumerated() { report[i] = b }
        let result = report.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, $0.count)
        }
        if result != kIOReturnSuccess {
            NSLog("TotemStatus: IOHIDDeviceSetReport failed: 0x%08x", result)
        }
        return result == kIOReturnSuccess
    }

    private func added(_ device: IOHIDDevice) {
        guard !buffers.contains(where: { $0.device == device }) else { return }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.reportSize)
        buffers.append((device, buffer))
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, Self.reportSize, { ctx, _, sender, _, _, report, length in
            let me = Unmanaged<KeyboardHID>.fromOpaque(ctx!).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            guard let sender else { return }
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            me.onReport?(device, bytes)
        }, ctx)
        onDeviceAdded?(device)
    }

    private func removed(_ device: IOHIDDevice) {
        if let idx = buffers.firstIndex(where: { $0.device == device }) {
            buffers[idx].buffer.deallocate()
            buffers.remove(at: idx)
        }
        onDeviceRemoved?(device)
    }
}
