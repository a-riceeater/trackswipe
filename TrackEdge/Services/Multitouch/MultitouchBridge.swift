import Foundation

/// Runtime binding to Apple's PRIVATE `MultitouchSupport.framework`.
///
/// Why private: public AppKit/SwiftUI APIs only deliver touches to the frontmost window. Reading raw
/// per-finger positions globally (regardless of the foreground app) is only possible through this
/// framework, which every trackpad utility in this space relies on.
///
/// Safety: nothing is linked at build time. Every symbol is resolved with `dlsym`; if the framework or
/// any required symbol is missing, `MultitouchBridge.shared` is `nil` and the app reports
/// "Unavailable" rather than crashing. Optional symbols (actuator, family ID) degrade individually.
final class MultitouchBridge {
    typealias DeviceRef = UnsafeMutableRawPointer
    typealias ContactCallback = @convention(c) (DeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

    typealias CreateListFn = @convention(c) () -> Unmanaged<CFArray>?
    typealias RegisterFn = @convention(c) (DeviceRef, ContactCallback) -> Void
    typealias StartFn = @convention(c) (DeviceRef, Int32) -> Int32
    typealias StopFn = @convention(c) (DeviceRef) -> Int32
    typealias BoolFn = @convention(c) (DeviceRef) -> Bool
    typealias DimensionsFn = @convention(c) (DeviceRef, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
    typealias FamilyFn = @convention(c) (DeviceRef, UnsafeMutablePointer<Int32>) -> Int32
    typealias DeviceIDFn = @convention(c) (DeviceRef, UnsafeMutablePointer<UInt64>) -> Int32
    typealias ActuatorCreateFn = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    typealias ActuatorOpenFn = @convention(c) (CFTypeRef) -> Int32
    typealias ActuatorCloseFn = @convention(c) (CFTypeRef) -> Int32
    typealias ActuatorActuateFn = @convention(c) (CFTypeRef, Int32, UInt32, Float, Float) -> Int32

    static let frameworkPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
    /// Expected `MemoryLayout<TEMTTouch>.stride`; a mismatch means the C layout is wrong for this toolchain.
    static let expectedTouchStride = 96

    static let shared: MultitouchBridge? = MultitouchBridge()

    let createList: CreateListFn
    let registerCallback: RegisterFn
    let unregisterCallback: RegisterFn
    let start: StartFn
    let stop: StopFn
    let isBuiltIn: BoolFn
    let surfaceDimensions: DimensionsFn
    let familyID: FamilyFn?
    let deviceID: DeviceIDFn?
    let isAlive: BoolFn?
    let actuatorCreate: ActuatorCreateFn?
    let actuatorOpen: ActuatorOpenFn?
    let actuatorClose: ActuatorCloseFn?
    let actuatorActuate: ActuatorActuateFn?

    private init?() {
        guard MemoryLayout<TEMTTouch>.stride == Self.expectedTouchStride,
              let handle = dlopen(Self.frameworkPath, RTLD_NOW) else { return nil }

        func load<T>(_ name: String, as _: T.Type) -> T? {
            guard let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: T.self)
        }

        guard let createList = load("MTDeviceCreateList", as: CreateListFn.self),
              let register = load("MTRegisterContactFrameCallback", as: RegisterFn.self),
              let unregister = load("MTUnregisterContactFrameCallback", as: RegisterFn.self),
              let start = load("MTDeviceStart", as: StartFn.self),
              let stop = load("MTDeviceStop", as: StopFn.self),
              let isBuiltIn = load("MTDeviceIsBuiltIn", as: BoolFn.self),
              let dims = load("MTDeviceGetSensorSurfaceDimensions", as: DimensionsFn.self)
        else { return nil }

        self.createList = createList
        registerCallback = register
        unregisterCallback = unregister
        self.start = start
        self.stop = stop
        self.isBuiltIn = isBuiltIn
        surfaceDimensions = dims
        familyID = load("MTDeviceGetFamilyID", as: FamilyFn.self)
        deviceID = load("MTDeviceGetDeviceID", as: DeviceIDFn.self)
        isAlive = load("MTDeviceIsAlive", as: BoolFn.self)
        actuatorCreate = load("MTActuatorCreateFromDeviceID", as: ActuatorCreateFn.self)
        actuatorOpen = load("MTActuatorOpen", as: ActuatorOpenFn.self)
        actuatorClose = load("MTActuatorClose", as: ActuatorCloseFn.self)
        actuatorActuate = load("MTActuatorActuate", as: ActuatorActuateFn.self)
    }

    var supportsActuator: Bool {
        actuatorCreate != nil && actuatorOpen != nil && actuatorActuate != nil
    }
}
