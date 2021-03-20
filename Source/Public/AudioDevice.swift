//
//  AudioDevice.swift
//  AMCoreAudio
//
//  Created by Ruben on 7/7/15.
//  Copyright © 2015 9Labs. All rights reserved.
//

import AudioToolbox.AudioServices
import Foundation
import os.log

/// Represents a pair of stereo channel numbers.
public typealias StereoPair = (left: UInt32, right: UInt32)

/// This class represents an audio device in the system and allows subscribing to audio device notifications.
///
/// Devices may be physical or virtual. For a comprehensive list of supported types, please refer to `TransportType`.
public final class AudioDevice: AudioObject {
    /// The cached device name. This may be useful in some situations where the class instance
    /// is pointing to a device that is no longer available, so we can still access its name.
    ///
    /// - Returns: The cached device name.
    private(set) var cachedDeviceName: String!

    private var isRegisteredForNotifications = false

    private lazy var propertyListenerBlock: AudioObjectPropertyListenerBlock = { [weak self] (_, inAddresses) -> Void in
        guard let strongSelf = self else { return }

        let address = inAddresses.pointee
        let notificationCenter = NotificationCenter.default

        switch address.mSelector {
        case kAudioDevicePropertyNominalSampleRate:
            notificationCenter.post(name: Notifications.deviceNominalSampleRateDidChange.name, object: strongSelf)
        case kAudioDevicePropertyAvailableNominalSampleRates:
            notificationCenter.post(name: Notifications.deviceAvailableNominalSampleRatesDidChange.name, object: strongSelf)
        case kAudioDevicePropertyClockSource:
            notificationCenter.post(name: Notifications.deviceClockSourceDidChange.name, object: strongSelf)
        case kAudioObjectPropertyName:
            notificationCenter.post(name: Notifications.deviceNameDidChange.name, object: strongSelf)
        case kAudioObjectPropertyOwnedObjects:
            notificationCenter.post(name: Notifications.deviceOwnedObjectsDidChange.name, object: strongSelf)
        case kAudioDevicePropertyVolumeScalar:
            let userInfo: [AnyHashable: Any] = [
                "channel": address.mElement,
                "direction": direction
            ]

            notificationCenter.post(name: Notifications.deviceVolumeDidChange.name, object: strongSelf, userInfo: userInfo)
        case kAudioDevicePropertyMute:
            let userInfo: [AnyHashable: Any] = [
                "channel": address.mElement,
                "direction": direction
            ]

            notificationCenter.post(name: Notifications.deviceMuteDidChange.name, object: strongSelf, userInfo: userInfo)
        case kAudioDevicePropertyDeviceIsAlive:
            notificationCenter.post(name: Notifications.deviceIsAliveDidChange.name, object: strongSelf)
        case kAudioDevicePropertyDeviceIsRunning:
            notificationCenter.post(name: Notifications.deviceIsRunningDidChange.name, object: strongSelf)
        case kAudioDevicePropertyDeviceIsRunningSomewhere:
            notificationCenter.post(name: Notifications.deviceIsRunningSomewhereDidChange.name, object: strongSelf)
        case kAudioDevicePropertyJackIsConnected:
            notificationCenter.post(name: Notifications.deviceIsJackConnectedDidChange.name, object: strongSelf)
        case kAudioDevicePropertyPreferredChannelsForStereo:
            notificationCenter.post(name: Notifications.devicePreferredChannelsForStereoDidChange.name, object: strongSelf)
        case kAudioDevicePropertyHogMode:
            notificationCenter.post(name: Notifications.deviceHogModeDidChange.name, object: strongSelf)
        // Unhandled cases beyond this point
        case kAudioDevicePropertyBufferFrameSize:
            fallthrough
        case kAudioDevicePropertyPlayThru:
            fallthrough
        case kAudioDevicePropertyDataSource:
            fallthrough
        default:
            break
        }
    }

    // MARK: - Lifecycle Functions

    /// Initializes an `AudioDevice` by providing a valid audio device identifier that is present in the system.
    ///
    /// - Parameter id: An audio device identifier.
    private init?(id: AudioObjectID) {
        super.init(objectID: id)

        guard owningObject != nil else { return nil }

        cachedDeviceName = getDeviceName()
        registerForNotifications()
        AudioObjectPool.instancePool.setObject(self, forKey: NSNumber(value: UInt(objectID)))
    }

    deinit {
        unregisterForNotifications()
        AudioObjectPool.instancePool.removeObject(forKey: NSNumber(value: UInt(objectID)))
    }

    // MARK: - Class Functions

    /// Returns an `AudioDevice` by providing a valid audio device identifier.
    ///
    /// - Parameter id: An audio device identifier.
    ///
    /// - Note: If identifier is not valid, `nil` will be returned.
    public static func lookup(by id: AudioObjectID) -> AudioDevice? {
        var instance = AudioObjectPool.instancePool.object(forKey: NSNumber(value: UInt(id))) as? AudioDevice

        if instance == nil {
            instance = AudioDevice(id: id)
        }

        return instance
    }

    /// Returns an `AudioDevice` by providing a valid audio device unique identifier.
    ///
    /// - Parameter uid: An audio device unique identifier.
    ///
    /// - Note: If unique identifier is not valid, `nil` will be returned.
    public static func lookup(by uid: String) -> AudioDevice? {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )

        var deviceID = kAudioObjectUnknown
        var cfUID = (uid as CFString)

        let status: OSStatus = withUnsafeMutablePointer(to: &cfUID) { cfUIDPtr in
            withUnsafeMutablePointer(to: &deviceID) { deviceIDPtr in
                var translation = AudioValueTranslation(
                    mInputData: cfUIDPtr,
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: deviceIDPtr,
                    mOutputDataSize: UInt32(MemoryLayout<AudioObjectID>.size)
                )

                return getPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                       address: address,
                                       andValue: &translation)
            }
        }

        if noErr != status || deviceID == kAudioObjectUnknown {
            return nil
        }

        return lookup(by: deviceID)
    }

    /// All the audio device identifiers currently available in the system.
    ///
    /// - Note: This list may also include *Aggregate* and *Multi-Output* devices.
    ///
    /// - Returns: An array of `AudioObjectID` values.
    public class func allDeviceIDs() -> [AudioObjectID] {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )

        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        var allIDs = [AudioObjectID]()
        let status = getPropertyDataArray(systemObjectID, address: address, value: &allIDs, andDefaultValue: 0)

        return noErr == status ? allIDs : []
    }

    /// All the audio devices currently available in the system.
    ///
    /// - Note: This list may also include *Aggregate* and *Multi-Output* devices.
    ///
    /// - Returns: An array of `AudioDevice` objects.
    public class func allDevices() -> [AudioDevice] {
        return allDeviceIDs().compactMap { AudioDevice.lookup(by: $0) }
    }

    /// All the devices in the system that have at least one input.
    ///
    /// - Note: This list may also include *Aggregate* devices.
    ///
    /// - Returns: An array of `AudioDevice` objects.
    public class func allInputDevices() -> [AudioDevice] {
        return allDevices().filter { $0.channels(direction: .recording) > 0 }
    }

    /// All the devices in the system that have at least one output.
    ///
    /// - Note: The list may also include *Aggregate* and *Multi-Output* devices.
    ///
    /// - Returns: An array of `AudioDevice` objects.
    public class func allOutputDevices() -> [AudioDevice] {
        return allDevices().filter { $0.channels(direction: .playback) > 0 }
    }

    /// All the devices in the system that support input and output.
    ///
    /// - Note: The list may also include *Aggregate* and *Multi-Output* devices.
    ///
    /// - Returns: An array of `AudioDevice` objects.
    public static func allIODevices() -> [AudioDevice] {
        return AudioDevice.allDevices().filter {
            $0.channels(direction: .recording) > 0 && $0.channels(direction: .playback) > 0
        }
    }

    /// All the devices in the system that are real devices - not aggregate ones.
    ///
    /// - Returns: An array of `AudioDevice` objects.
    public static func allNonAggregateDevices() -> [AudioDevice] {
        return AudioDevice.allDevices().filter {
            !$0.isAggregateDevice()
        }
    }

    /// All the devices in the system that are aggregate devices.
    ///
    /// - Returns: An array of `AudioDevice` objects.
    public static func allAggregateDevices() -> [AudioDevice] {
        return AudioDevice.allDevices().filter {
            $0.isAggregateDevice()
        }
    }

    /// The default input device.
    ///
    /// - Returns: *(optional)* An `AudioDevice`.
    public class func defaultInputDevice() -> AudioDevice? {
        return defaultDevice(of: kAudioHardwarePropertyDefaultInputDevice)
    }

    /// The default output device.
    ///
    /// - Returns: *(optional)* An `AudioDevice`.
    public class func defaultOutputDevice() -> AudioDevice? {
        return defaultDevice(of: kAudioHardwarePropertyDefaultOutputDevice)
    }

    /// The default system output device.
    ///
    /// - Returns: *(optional)* An `AudioDevice`.
    public class func defaultSystemOutputDevice() -> AudioDevice? {
        return defaultDevice(of: kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    // MARK: - Default Device Functions

    /// Promotes this device to become the default input device.
    ///
    /// - Returns: `true` on success, `false` otherwise.
    @discardableResult public func setAsDefaultInputDevice() -> Bool {
        return setDefaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    /// Promotes this device to become the default output device.
    ///
    /// - Returns: `true` on success, `false` otherwise.
    @discardableResult public func setAsDefaultOutputDevice() -> Bool {
        return setDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    /// Promotes this device to become the default system output device.
    ///
    /// - Returns: `true` on success, `false` otherwise.
    @discardableResult public func setAsDefaultSystemDevice() -> Bool {
        return setDefaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    // MARK: - ✪ General Device Information Functions

    /// The audio device's identifier (ID).
    ///
    /// - Note: This identifier will change with system restarts.
    /// If you need an unique identifier that persists between restarts, use `uid` instead.
    ///
    /// - SeeAlso: `uid`
    ///
    /// - Returns: An audio device identifier.
    public var id: AudioObjectID {
        return objectID
    }

    /// The audio device's name as reported by the system.
    ///
    /// - Returns: An audio device's name.
    override public var name: String {
        return getDeviceName()
    }

    /// The audio device's unique identifier (UID).
    ///
    /// - Note: This identifier is guaranted to uniquely identify a device in the system
    /// and will not change even after restarts. Two (or more) identical audio devices
    /// are also guaranteed to have unique identifiers.
    ///
    /// - SeeAlso: `id`
    ///
    /// - Returns: *(optional)* A `String` with the audio device `UID`.
    public var uid: String? {
        if let address = validAddress(selector: kAudioDevicePropertyDeviceUID) {
            return getProperty(address: address)
        } else {
            return nil
        }
    }

    /// The audio device's model unique identifier.
    ///
    /// - Returns: *(optional)* A `String` with the audio device's model unique identifier.
    public var modelUID: String? {
        if let address = validAddress(selector: kAudioDevicePropertyModelUID) {
            return getProperty(address: address)
        } else {
            return nil
        }
    }

    /// The audio device's manufacturer.
    ///
    /// - Returns: *(optional)* A `String` with the audio device's manufacturer name.
    public var manufacturer: String? {
        if let address = validAddress(selector: kAudioObjectPropertyManufacturer) {
            return getProperty(address: address)
        } else {
            return nil
        }
    }

    /// The bundle identifier for an application that provides a GUI for configuring the AudioDevice.
    /// By default, the value of this property is the bundle ID for *Audio MIDI Setup*.
    ///
    /// - Returns: *(optional)* A `String` pointing to the bundle identifier
    public var configurationApplication: String? {
        if let address = validAddress(selector: kAudioDevicePropertyConfigurationApplication) {
            return getProperty(address: address)
        } else {
            return nil
        }
    }

    /// A transport type that indicates how the audio device is connected to the CPU.
    ///
    /// - Returns: *(optional)* A `TransportType`.
    public var transportType: TransportType? {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )

        var transportType = UInt32(0)

        guard noErr == getPropertyData(address, andValue: &transportType) else { return nil }

        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        case kAudioDeviceTransportTypeAggregate:
            return .aggregate
        case kAudioDeviceTransportTypeVirtual:
            return .virtual
        case kAudioDeviceTransportTypePCI:
            return .pci
        case kAudioDeviceTransportTypeUSB:
            return .usb
        case kAudioDeviceTransportTypeFireWire:
            return .fireWire
        case kAudioDeviceTransportTypeBluetooth:
            return .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE:
            return .bluetoothLE
        case kAudioDeviceTransportTypeHDMI:
            return .hdmi
        case kAudioDeviceTransportTypeDisplayPort:
            return .displayPort
        case kAudioDeviceTransportTypeAirPlay:
            return .airPlay
        case kAudioDeviceTransportTypeAVB:
            return .avb
        case kAudioDeviceTransportTypeThunderbolt:
            return .thunderbolt
        case kAudioDeviceTransportTypeUnknown:
            fallthrough
        default:
            return .unknown
        }
    }

    /// Whether the audio device is included in the normal list of devices.
    ///
    /// - Note: Hidden devices can only be discovered by knowing their `UID` and
    /// using `kAudioHardwarePropertyDeviceForUID`.
    ///
    /// - Returns: `true` when device is hidden, `false` otherwise.
    public func isHidden() -> Bool {
        if let address = validAddress(selector: kAudioDevicePropertyIsHidden) {
            return getProperty(address: address) ?? false
        } else {
            return false
        }
    }

    /// Whether the audio device's jack is connected for a given direction.
    ///
    /// - Parameter direction: A direction.
    ///
    /// - Returns: `true` when jack is connected, `false` otherwise.
    public func isJackConnected(direction: Direction) -> Bool? {
        if let address = validAddress(selector: kAudioDevicePropertyJackIsConnected,
                                      scope: scope(direction: direction))
        {
            return getProperty(address: address)
        } else {
            return nil
        }
    }

    /// Whether the device is alive.
    ///
    /// - Returns: `true` when the device is alive, `false` otherwise.
    public func isAlive() -> Bool {
        if let address = validAddress(selector: kAudioDevicePropertyDeviceIsAlive) {
            return getProperty(address: address) ?? false
        } else {
            return false
        }
    }

    /// Whether the device is running.
    ///
    /// - Returns: `true` when the device is running, `false` otherwise.
    public func isRunning() -> Bool {
        if let address = validAddress(selector: kAudioDevicePropertyDeviceIsRunning) {
            return getProperty(address: address) ?? false
        } else {
            return false
        }
    }

    /// Whether the device is running somewhere.
    ///
    /// - Returns: `true` when the device is running somewhere, `false` otherwise.
    public func isRunningSomewhere() -> Bool {
        if let address = validAddress(selector: kAudioDevicePropertyDeviceIsRunningSomewhere) {
            return getProperty(address: address) ?? false
        } else {
            return false
        }
    }

    /// A human readable name for the channel number and direction specified.
    ///
    /// - Parameter channel: A channel.
    /// - Parameter direction: A direction.
    ///
    /// - Returns: *(optional)* A `String` with the name of the channel.
    public func name(channel: UInt32, direction: Direction) -> String? {
        guard let address = validAddress(selector: kAudioObjectPropertyElementName,
                                         scope: scope(direction: direction),
                                         element: channel) else { return nil }

        guard let name: String = getProperty(address: address) else { return nil }

        return name.isEmpty ? nil : name
    }

    /// All the audio object identifiers that are owned by this audio device.
    ///
    /// - Returns: *(optional)* An array of `AudioObjectID` values.
    public func ownedObjectIDs() -> [AudioObjectID]? {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyOwnedObjects,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )

        var qualifierData = [kAudioObjectClassID]
        let qualifierDataSize = UInt32(MemoryLayout<AudioClassID>.size * qualifierData.count)
        var ownedObjects = [AudioObjectID]()

        let status = getPropertyDataArray(address,
                                          qualifierDataSize: qualifierDataSize,
                                          qualifierData: &qualifierData,
                                          value: &ownedObjects,
                                          andDefaultValue: AudioObjectID())

        return noErr == status ? ownedObjects : nil
    }

    /// All the audio object identifiers representing the audio controls of this audio device.
    ///
    /// - Returns: *(optional)* An array of `AudioObjectID` values.
    public func controlList() -> [AudioObjectID]? {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyControlList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )

        var controlList = [AudioObjectID]()
        let status = getPropertyDataArray(address, value: &controlList, andDefaultValue: AudioObjectID())

        return noErr == status ? controlList : nil
    }

    /// All the audio devices related to this audio device.
    ///
    /// - Returns: *(optional)* An array of `AudioDevice` objects.
    public func relatedDevices() -> [AudioDevice]? {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyRelatedDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )

        var relatedDevices = [AudioDeviceID]()
        let status = getPropertyDataArray(address, value: &relatedDevices, andDefaultValue: AudioDeviceID())

        if noErr == status {
            return relatedDevices.compactMap { AudioDevice.lookup(by: $0) }
        }

        return nil
    }

    // MARK: - 💣 LFE (Low Frequency Effects) Functions

    /// Whether the audio device should claim ownership of any attached iSub or not.
    ///
    /// - Return: *(optional)* `true` when device should claim ownership, `false` otherwise.
    public var shouldOwniSub: Bool? {
        get {
            guard let address = validAddress(selector: kAudioDevicePropertyDriverShouldOwniSub) else { return nil }
            return getProperty(address: address)
        }

        set {
            if let value = newValue, let address = validAddress(selector: kAudioDevicePropertyDriverShouldOwniSub) {
                _ = setProperty(address: address, value: value)
            }
        }
    }

    /// Whether the audio device's LFE (Low Frequency Effects) output is muted or not.
    ///
    /// - Return: *(optional)* `true` when LFE output is muted, `false` otherwise.
    public var lfeMute: Bool? {
        get {
            guard let address = validAddress(selector: kAudioDevicePropertySubMute) else { return nil }
            return getProperty(address: address)
        }

        set {
            if let value = newValue, let address = validAddress(selector: kAudioDevicePropertySubMute) {
                _ = setProperty(address: address, value: value)
            }
        }
    }

    /// The audio device's LFE (Low Frequency Effects) scalar output volume.
    ///
    /// - Return: *(optional)* A `Float32` with the volume.
    public var lfeVolume: Float32? {
        get {
            guard let address = validAddress(selector: kAudioDevicePropertySubVolumeScalar) else { return nil }
            return getProperty(address: address)
        }

        set {
            if let value = newValue, let address = validAddress(selector: kAudioDevicePropertySubVolumeScalar) {
                _ = setProperty(address: address, value: value)
            }
        }
    }

    /// The audio device's LFE (Low Frequency Effects) output volume in decibels.
    ///
    /// - Return: *(optional)* A `Float32` with the volume.
    public var lfeVolumeDecibels: Float32? {
        get {
            guard let address = validAddress(selector: kAudioDevicePropertySubVolumeDecibels) else { return nil }
            return getProperty(address: address)
        }

        set {
            if let value = newValue, let address = validAddress(selector: kAudioDevicePropertySubVolumeDecibels) {
                _ = setProperty(address: address, value: value)
            }
        }
    }

    // MARK: - ⇄ Input/Output Layout Functions

    /// The number of layout channels for a given direction.
    ///
    /// - Parameter direction: A direction.
    ///
    /// - Returns: *(optional)* A `UInt32` with the number of layout channels.
    public func layoutChannels(direction: Direction) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelLayout,
            mScope: scope(direction: direction),
            mElement: kAudioObjectPropertyElementMaster
        )

        if AudioObjectHasProperty(id, &address) {
            var result = AudioChannelLayout()
            let status = getPropertyData(address, andValue: &result)

            return noErr == status ? result.mNumberChannelDescriptions : nil
        }

        return nil
    }

    /// The number of channels for a given direction.
    ///
    /// - Parameter direction: A direction.
    ///
    /// - Returns: A `UInt32` with the number of channels.
    public func channels(direction: Direction) -> UInt32 {
        guard let streams = streams(direction: direction) else { return 0 }

        return streams.map { $0.physicalFormat?.mChannelsPerFrame ?? 0 }.reduce(0, +)
    }

    /// Whether the device has only inputs but no outputs.
    ///
    /// - Returns: `true` when the device is input only, `false` otherwise.
    public func isInputOnlyDevice() -> Bool {
        return channels(direction: .playback) == 0 && channels(direction: .recording) > 0
    }

    /// Whether the device has only outputs but no inputs.
    ///
    /// - Returns: `true` when the device is output only, `false` otherwise.
    public func isOutputOnlyDevice() -> Bool {
        return channels(direction: .recording) == 0 && channels(direction: .playback) > 0
    }

    // MARK: - ⇉ Individual Channel Functions

    /// A `VolumeInfo` struct containing information about a particular channel and direction combination.
    ///
    /// - Parameter channel: A channel.
    /// - Parameter direction: A direction.
    ///
    /// - Returns: *(optional)* A `VolumeInfo` struct.
    public func volumeInfo(channel: UInt32, direction: Direction) -> VolumeInfo? {
        // Obtain volume info
        var address: AudioObjectPropertyAddress
        var hasAnyProperty = false

        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: scope(direction: direction),
            mElement: channel
        )

        var volumeInfo = VolumeInfo()

        if AudioObjectHasProperty(id, &address) {
            var canSetVolumeBoolean = DarwinBoolean(false)
            var status = AudioObjectIsPropertySettable(id, &address, &canSetVolumeBoolean)

            if noErr == status {
                volumeInfo.canSetVolume = canSetVolumeBoolean.boolValue
                volumeInfo.hasVolume = true

                var volume = Float32(0)
                status = getPropertyData(address, andValue: &volume)

                if noErr == status {
                    volumeInfo.volume = volume
                    hasAnyProperty = true
                }
            }
        }

        // Obtain mute info
        address.mSelector = kAudioDevicePropertyMute

        if AudioObjectHasProperty(id, &address) {
            var canMuteBoolean = DarwinBoolean(false)
            var status = AudioObjectIsPropertySettable(id, &address, &canMuteBoolean)

            if noErr == status {
                volumeInfo.canMute = canMuteBoolean.boolValue

                var isMutedValue = UInt32(0)
                status = getPropertyData(address, andValue: &isMutedValue)

                if noErr == status {
                    volumeInfo.isMuted = Bool(isMutedValue)
                    hasAnyProperty = true
                }
            }
        }

        // Obtain play thru info
        address.mSelector = kAudioDevicePropertyPlayThru

        if AudioObjectHasProperty(id, &address) {
            var canPlayThruBoolean = DarwinBoolean(false)
            var status = AudioObjectIsPropertySettable(id, &address, &canPlayThruBoolean)

            if noErr == status {
                volumeInfo.canPlayThru = canPlayThruBoolean.boolValue

                var isPlayThruSetValue = UInt32(0)
                status = getPropertyData(address, andValue: &isPlayThruSetValue)

                if noErr == status {
                    volumeInfo.isPlayThruSet = Bool(isPlayThruSetValue)
                    hasAnyProperty = true
                }
            }
        }

        return hasAnyProperty ? volumeInfo : nil
    }

    /// The scalar volume for a given channel and direction.
    ///
    /// - Parameter channel: A channel.
    /// - Parameter direction: A direction.
    ///
    /// - Returns: *(optional)* A `Float32` value with the scalar volume.
    public func volume(channel: UInt32, direction: Direction) -> Float32? {
        guard let address = validAddress(selector: kAudioDevicePropertyVolumeScalar,
                                         scope: scope(direction: direction),
                                         element: channel) else { return nil }

        return getProperty(address: address)
    }

    /// The volume in decibels *(dbFS)* for a given channel and direction.
    ///
    /// - Parameter channel: A channel.
    /// - Parameter direction: A direction.
    ///
    /// - Returns: *(optional)* A `Float32` value with the volume in decibels.
    public func volumeInDecibels(channel: UInt32, direction: Direction) -> Float32? {
        guard let address = validAddress(selector: kAudioDevicePropertyVolumeDecibels,
                                         scope: scope(direction: direction),
                                         element: channel) else { return nil }

        return getProperty(address: address)
    }

    /// Sets the channel's volume for a given direction.
    ///
    /// - Parameter volume: The new volume as a scalar value ranging from 0 to 1.
    /// - Parameter channel: A channel.
    /// - Parameter direction: A direction.
    ///
    /// - Returns: `true` on success, `false` otherwise.
    @discardableResult public func setVolume(_ volume: Float32, channel: UInt32, direction: Direction) -> Bool {
        guard let address = validAddress(selector: kAudioDevicePropertyVolumeScalar,
                                         scope: scope(direction: direction),
                                         element: channel) else { return false }

        return setProperty(address: address, value: volume)
    }

    /// Mutes a channel for a given direction.
    ///
    /// - Parameter shouldMute: Whether channel should be muted or not.
    /// - Parameter channel: A channel.
    /// - Parameter direction: A direction.
    ///
    /// - Returns: `true` on success, `false` otherwise.
    @discardableResult public func setMute(_ shouldMute: Bool, channel: UInt32, direction: Direction) -> Bool {
        guard let address = validAddress(selector: kAudioDevicePropertyMute,
                                         scope: scope(direction: direction),
                                         element: channel) else { return false }

        return setProperty(address: address, value: shouldMute)
    }

    /// Whether a channel is muted for a given direction.
    ///
    /// - Parameter channel: A channel.
    /// - Parameter direction: A direction.
    ///
    /// - Returns: *(optional)* `true` if channel is muted, false otherwise.
    public func isMuted(channel: UInt32, direction: Direction) -> Bool? {
        guard let address = validAddress(selector: kAudioDevicePropertyMute,
                                         scope: scope(direction: direction),
                                         element: channel) else { return nil }

        return getProperty(address: address)
    }

    /// Whether the master channel is muted for a given direction.
    ///
    /// - Parameter direction: A direction.
    ///
    /// - Returns: `true` when muted, `false` otherwise.
    public func isMasterChannelMuted(direction: Direction) -> Bool? {
        return isMuted(channel: kAudioObjectPropertyElementMaster, direction: direction)
    }

    /// Whether a channel can be muted for a given direction.
    ///
    /// - Parameter channel: A channel.
    /// - Parameter direction: A direction.
    ///
    /// - Returns: `true` if channel can be muted, `false` otherwise.
    public func canMute(channel: UInt32, direction: Direction) -> Bool {
        return volumeInfo(channel: channel, direction: direction)?.canMute ?? false
    }

    /// Whether the master volume can be muted for a given direction.
    ///
    /// - Parameter direction: A direction.
    ///
    /// - Returns: `true` when the volume can be muted, `false` otherwise.
    public func canMuteMasterChannel(direction: Direction) -> Bool {
        if canMute(channel: kAudioObjectPropertyElementMaster, direction: direction) == true {
            return true
        }

        guard let preferredChannelsForStereo = preferredChannelsForStereo(direction: direction) else { return false }
        guard canMute(channel: preferredChannelsForStereo.0, direction: direction) else { return false }
        guard canMute(channel: preferredChannelsForStereo.1, direction: direction) else { return false }

        return true
    }

    /// Whether a channel's volume can be set for a given direction.
    ///
    /// - Parameter channel: A channel.
    /// - Parameter direction: A direction.
    ///
    /// - Returns: `true` if the channel's volume can be set, `false` otherwise.
    public func canSetVolume(channel: UInt32, direction: Direction) -> Bool {
        return volumeInfo(channel: channel, direction: direction)?.canSetVolume ?? false
    }

    /// A list of channel numbers that best represent the preferred stereo channels
    /// used by this device. In most occasions this will be channels 1 and 2.
    ///
    /// - Parameter direction: A direction.
    ///
    /// - Returns: A `StereoPair` tuple containing the channel numbers.
    public func preferredChannelsForStereo(direction: Direction) -> StereoPair? {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: scope(direction: direction),
            mElement: kAudioObjectPropertyElementMaster
        )

        var preferredChannels = [UInt32]()
        let status = getPropertyDataArray(address, value: &preferredChannels, andDefaultValue: 0)

        guard noErr == status, preferredChannels.count == 2 else { return nil }

        return (left: preferredChannels[0], right: preferredChannels[1])
    }

    /// Attempts to set the new preferred channels for stereo for a given direction.
    ///
    /// - Parameter channels: A `StereoPair` representing the preferred channels.
    /// - Parameter direction: A direction.
    ///
    /// - Returns: `true` on success, `false` otherwise.
    @discardableResult public func setPreferredChannelsForStereo(channels: StereoPair, direction: Direction) -> Bool {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: scope(direction: direction),
            mElement: kAudioObjectPropertyElementMaster
        )

        var preferredChannels = [channels.left, channels.right]
        let status = setPropertyData(address, andValue: &preferredChannels)

        return noErr == status
    }

    // MARK: - 🔊 Virtual Master Volume / Balance Functions

    /// :nodoc:
    @available(*, renamed: "canMuteMasterChannel", message: "Marked for removal in version 4.0")
    public func canMuteVirtualMasterChannel(direction: Direction) -> Bool {
        return canMuteMasterChannel(direction: direction)
    }

    /// Whether the master volume can be set for a given direction.
    ///
    /// - Parameter direction: A direction.
    ///
    /// - Returns: `true` when the volume can be set, `false` otherwise.
    public func canSetVirtualMasterVolume(direction: Direction) -> Bool {
        guard validAddress(selector: kAudioHardwareServiceDeviceProperty_VirtualMasterVolume,
                           scope: scope(direction: direction)) != nil else { return false }

        return true
    }

    /// Sets the virtual master volume for a given direction.
    ///
    /// - Parameter volume: The new volume as a scalar value ranging from 0 to 1.
    /// - Parameter direction: A direction.
    ///
    /// - Returns: `true` on success, `false` otherwise.
    @discardableResult public func setVirtualMasterVolume(_ volume: Float32, direction: Direction) -> Bool {
        guard let address = validAddress(selector: kAudioHardwareServiceDeviceProperty_VirtualMasterVolume,
                                         scope: scope(direction: direction)) else { return false }

        return setProperty(address: address, value: volume)
    }

    /// The virtual master scalar volume for a given direction.
    ///
    /// - Parameter direction: A direction.
    ///
    /// - Returns: *(optional)* A `Float32` value with the scalar volume.
    public func virtualMasterVolume(direction: Direction) -> Float32? {
        guard let address = validAddress(selector: kAudioHardwareServiceDeviceProperty_VirtualMasterVolume,
                                         scope: scope(direction: direction)) else { return nil }

        return getProperty(address: address)
    }

    /// The virtual master volume in decibels for a given direction.
    ///
    /// - Parameter direction: A direction.
    ///
    /// - Returns: *(optional)* A `Float32` value with the volume in decibels.
    public func virtualMasterVolumeInDecibels(direction: Direction) -> Float32? {
        var referenceChannel: UInt32

        if canSetVolume(channel: kAudioObjectPropertyElementMaster, direction: direction) {
            referenceChannel = kAudioObjectPropertyElementMaster
        } else {
            guard let channels = preferredChannelsForStereo(direction: direction) else { return nil }
            referenceChannel = channels.0
        }

        guard let masterVolume = virtualMasterVolume(direction: direction) else { return nil }

        return scalarToDecibels(volume: masterVolume, channel: referenceChannel, direction: direction)
    }

    /// The virtual master balance for a given direction.
    ///
    /// The range is from 0 (all power to the left) to 1 (all power to the right) with the value of 0.5 signifying
    /// that the channels have equal power.
    ///
    /// - Parameter direction: A direction.
    ///
    /// - Returns: *(optional)* A `Float32` value with the stereo balance.
    public func virtualMasterBalance(direction: Direction) -> Float32? {
        guard let address = validAddress(selector: kAudioHardwareServiceDeviceProperty_VirtualMasterBalance,
                                         scope: scope(direction: direction)) else { return nil }

        return getProperty(address: address)
    }

    /// Sets the new virtual master balance for a given direction.
    ///
    /// The range is from 0 (all power to the left) to 1 (all power to the right) with the value of 0.5 signifying
    /// that the channels have equal power.
    ///
    /// - Parameter value: The new balance.
    /// - Parameter direction: A direction.
    ///
    /// - Returns: `true` on success, `false` otherwise.
    @discardableResult public func setVirtualMasterBalance(_ value: Float32, direction: Direction) -> Bool {
        guard let address = validAddress(selector: kAudioHardwareServiceDeviceProperty_VirtualMasterBalance,
                                         scope: scope(direction: direction)) else { return false }

        return setProperty(address: address, value: value)
    }

    // MARK: - 〰 Sample Rate Functions

    /// The actual audio device's sample rate.
    ///
    /// - Returns: *(optional)* A `Float64` value with the actual sample rate.
    public func actualSampleRate() -> Float64? {
        guard let address = validAddress(selector: kAudioDevicePropertyActualSampleRate) else { return nil }

        return getProperty(address: address)
    }

    /// The nominal audio device's sample rate.
    ///
    /// - Returns: *(optional)* A `Float64` value with the nominal sample rate.
    public func nominalSampleRate() -> Float64? {
        guard let address = validAddress(selector: kAudioDevicePropertyNominalSampleRate) else { return nil }

        return getProperty(address: address)
    }

    /// Sets the nominal sample rate.
    ///
    /// - Parameter sampleRate: The new nominal sample rate.
    ///
    /// - Returns: `true` on success, `false` otherwise.
    @discardableResult public func setNominalSampleRate(_ sampleRate: Float64) -> Bool {
        guard let address = validAddress(selector: kAudioDevicePropertyNominalSampleRate) else { return false }

        return setProperty(address: address, value: sampleRate)
    }

    /// A list of all the nominal sample rates supported by this audio device.
    ///
    /// - Returns: *(optional)* A `Float64` array containing the nominal sample rates.
    public func nominalSampleRates() -> [Float64]? {
        guard let address = validAddress(selector: kAudioDevicePropertyAvailableNominalSampleRates,
                                         scope: kAudioObjectPropertyScopeWildcard) else { return nil }

        var sampleRates = [Float64]()
        var valueRanges = [AudioValueRange]()
        let status = getPropertyDataArray(address, value: &valueRanges, andDefaultValue: AudioValueRange())

        guard noErr == status else { return nil }

        // A list of all the possible sample rates up to 192kHz
        // to be used in the case we receive a range (see below)
        let possibleRates: [Float64] = [
            6400, 8000, 11025, 12000,
            16000, 22050, 24000, 32000,
            44100, 48000, 64000, 88200,
            96000, 128_000, 176_400, 192_000
        ]

        for valueRange in valueRanges {
            if valueRange.mMinimum < valueRange.mMaximum {
                // We got a range.
                //
                // This could be a headset audio device (i.e., CS50/CS60-USB Headset)
                // or a virtual audio driver (i.e., "System Audio Recorder" by WonderShare AllMyMusic)
                if let startIndex = possibleRates.firstIndex(of: valueRange.mMinimum),
                   let endIndex = possibleRates.firstIndex(of: valueRange.mMaximum)
                {
                    sampleRates += possibleRates[startIndex..<endIndex + 1]
                } else {
                    os_log("Failed to obtain list of supported sample rates ranging from %f to %f. This is an error in AMCoreAudio and should be reported to the project maintainers.", log: .default, type: .debug, valueRange.mMinimum, valueRange.mMaximum)
                }
            } else {
                // We did not get a range (this should be the most common case)
                sampleRates.append(valueRange.mMinimum)
            }
        }

        return sampleRates
    }

    // MARK: - ⚄ Data Source Functions

    /// A list of item IDs for the currently selected data sources.
    ///
    /// - Returns: *(optional)* A `UInt32` array containing all the item IDs.
    public func dataSource(direction: Direction) -> [UInt32]? {
        guard let address = validAddress(selector: kAudioDevicePropertyDataSource,
                                         scope: scope(direction: direction)) else { return nil }

        var dataSourceIDs = [UInt32]()
        let status = getPropertyDataArray(address, value: &dataSourceIDs, andDefaultValue: 0)

        guard noErr == status else { return nil }

        return dataSourceIDs
    }

    /// A list of all the IDs of all the data sources currently available.
    ///
    /// - Returns: *(optional)* A `UInt32` array containing all the item IDs.
    public func dataSources(direction: Direction) -> [UInt32]? {
        guard let address = validAddress(selector: kAudioDevicePropertyDataSources,
                                         scope: scope(direction: direction)) else { return nil }

        var dataSourceIDs = [UInt32]()
        let status = getPropertyDataArray(address, value: &dataSourceIDs, andDefaultValue: 0)

        guard noErr == status else { return nil }

        return dataSourceIDs
    }

    /// Returns the data source name for a given data source ID.
    ///
    /// - Parameter dataSourceID: A data source ID.
    ///
    /// - Returns: *(optional)* A `String` with the data source name.
    public func dataSourceName(dataSourceID: UInt32, direction: Direction) -> String? {
        var name: CFString = "" as CFString
        var mDataSourceID = dataSourceID

        let status: OSStatus = withUnsafeMutablePointer(to: &mDataSourceID) { mDataSourceIDPtr in
            withUnsafeMutablePointer(to: &name) { namePtr in
                var translation = AudioValueTranslation(
                    mInputData: mDataSourceIDPtr,
                    mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: namePtr,
                    mOutputDataSize: UInt32(MemoryLayout<CFString>.size)
                )

                let address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDataSourceNameForIDCFString,
                    mScope: scope(direction: direction),
                    mElement: kAudioObjectPropertyElementMaster
                )

                return getPropertyData(address, andValue: &translation)
            }
        }

        return noErr == status ? (name as String) : nil
    }

    // MARK: - 𝍄 Clock Source Functions

    /// The current clock source identifier for this audio device.
    ///
    /// - Returns: *(optional)* A `UInt32` containing the clock source identifier.
    public func clockSourceID() -> UInt32? {
        guard let address = validAddress(selector: kAudioDevicePropertyClockSource,
                                         scope: kAudioObjectPropertyScopeGlobal) else { return nil }

        return getProperty(address: address)
    }

    /// The current clock source name for this audio device.
    ///
    /// - Returns: *(optional)* A `String` containing the clock source name.
    public func clockSourceName() -> String? {
        guard let sourceID = clockSourceID() else { return nil }

        return clockSourceName(clockSourceID: sourceID)
    }

    /// A list of all the clock source identifiers available for this audio device.
    ///
    /// - Returns: *(optional)* A `UInt32` array containing all the clock source identifiers.
    public func clockSourceIDs() -> [UInt32]? {
        guard let address = validAddress(selector: kAudioDevicePropertyClockSources,
                                         scope: kAudioObjectPropertyScopeGlobal,
                                         element: kAudioObjectPropertyElementMaster) else { return nil }

        var clockSourceIDs = [UInt32]()
        let status = getPropertyDataArray(address, value: &clockSourceIDs, andDefaultValue: 0)

        guard noErr == status else { return nil }

        return clockSourceIDs
    }

    /// A list of all the clock source names available for this audio device.
    ///
    /// - Returns: *(optional)* A `String` array containing all the clock source names.
    public func clockSourceNames() -> [String]? {
        guard let clockSourceIDs = clockSourceIDs() else { return nil }

        return clockSourceIDs.map {
            // We expect clockSourceNameForClockSourceID to never fail in this case,
            // but in the unlikely case it does, we provide a default value.
            clockSourceName(clockSourceID: $0) ?? "Clock source \(String(describing: clockSourceID))"
        }
    }

    /// Returns the clock source name for a given clock source ID.
    ///
    /// - Parameter clockSourceID: A clock source ID.
    ///
    /// - Returns: *(optional)* A `String` with the source clock name.
    public func clockSourceName(clockSourceID: UInt32) -> String? {
        var name: CFString = "" as CFString
        var mClockSourceID = clockSourceID

        let status: OSStatus = withUnsafeMutablePointer(to: &mClockSourceID) { mClockSourceIDPtr in
            withUnsafeMutablePointer(to: &name) { namePtr in
                var translation = AudioValueTranslation(
                    mInputData: mClockSourceIDPtr,
                    mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: namePtr,
                    mOutputDataSize: UInt32(MemoryLayout<CFString>.size)
                )

                let address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyClockSourceNameForIDCFString,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMaster
                )

                return getPropertyData(address, andValue: &translation)
            }
        }

        return noErr == status ? (name as String) : nil
    }

    /// Sets the clock source for this audio device.
    ///
    /// - Parameter clockSourceID: A clock source ID.
    ///
    /// - Returns: `true` on success, `false` otherwise.
    @discardableResult public func setClockSourceID(_ clockSourceID: UInt32) -> Bool {
        guard let address = validAddress(selector: kAudioDevicePropertyClockSource,
                                         scope: kAudioObjectPropertyScopeGlobal) else { return false }

        return setProperty(address: address, value: clockSourceID)
    }

    // MARK: - ↹ Latency Functions

    /// The latency in frames for the specified direction.
    ///
    /// - Parameter direction: A direction.
    ///
    /// - Returns: *(optional)* A `UInt32` value with the latency in frames.
    public func latency(direction: Direction) -> UInt32? {
        guard let address = validAddress(selector: kAudioDevicePropertyLatency,
                                         scope: scope(direction: direction)) else { return nil }

        return getProperty(address: address)
    }

    /// The safety offset frames for the specified direction.
    ///
    /// - Parameter direction: A direction.
    ///
    /// - Returns: *(optional)* A `UInt32` value with the safety offset in frames.
    public func safetyOffset(direction: Direction) -> UInt32? {
        guard let address = validAddress(selector: kAudioDevicePropertySafetyOffset,
                                         scope: scope(direction: direction)) else { return nil }

        return getProperty(address: address)
    }

    // MARK: - 🐗 Hog Mode Functions

    /// Indicates the `pid` that currently owns exclusive access to the audio device or
    /// a value of `-1` indicating that the device is currently available to all processes.
    ///
    /// - Returns: *(optional)* A `pid_t` value.
    public func hogModePID() -> pid_t? {
        guard let address = validAddress(selector: kAudioDevicePropertyHogMode,
                                         scope: kAudioObjectPropertyScopeWildcard) else { return nil }

        var pid = pid_t()
        let status = getPropertyData(address, andValue: &pid)

        return noErr == status ? pid : nil
    }

    /// Toggles hog mode on/off
    ///
    /// - Returns: `true` on success, `false` otherwise.
    private func toggleHogMode() -> Bool {
        guard let address = validAddress(selector: kAudioDevicePropertyHogMode,
                                         scope: kAudioObjectPropertyScopeWildcard) else { return false }

        return setProperty(address: address, value: 0)
    }

    /// Attempts to set the `pid` that currently owns exclusive access to the
    /// audio device.
    ///
    /// - Returns: `true` on success, `false` otherwise.
    @discardableResult
    public func setHogMode() -> Bool {
        guard hogModePID() != pid_t(ProcessInfo.processInfo.processIdentifier) else { return false }

        return toggleHogMode()
    }

    /// Attempts to make the audio device available to all processes by setting
    /// the hog mode to `-1`.
    ///
    /// - Returns: `true` on success, `false` otherwise.
    @discardableResult
    public func unsetHogMode() -> Bool {
        guard hogModePID() == pid_t(ProcessInfo.processInfo.processIdentifier) else { return false }

        return toggleHogMode()
    }

    // MARK: - ♺ Volume Conversion Functions

    /// Converts a scalar volume to a decibel *(dbFS)* volume for the given channel and direction.
    ///
    /// - Parameter volume: A scalar volume.
    /// - Parameter channel: A channel number.
    /// - Parameter direction: A direction.
    ///
    /// - Returns: *(optional)* A `Float32` value with the scalar volume converted in decibels.
    public func scalarToDecibels(volume: Float32, channel: UInt32, direction: Direction) -> Float32? {
        guard let address = validAddress(selector: kAudioDevicePropertyVolumeScalarToDecibels,
                                         scope: scope(direction: direction),
                                         element: channel) else { return nil }

        var inOutVolume = volume
        let status = getPropertyData(address, andValue: &inOutVolume)

        return noErr == status ? inOutVolume : nil
    }

    /// Converts a relative decibel *(dbFS)* volume to a scalar volume for the given channel and direction.
    ///
    /// - Parameter volume: A volume in relative decibels (dbFS).
    /// - Parameter channel: A channel number.
    /// - Parameter direction: A direction.
    ///
    /// - Returns: *(optional)* A `Float32` value with the decibels volume converted to scalar.
    public func decibelsToScalar(volume: Float32, channel: UInt32, direction: Direction) -> Float32? {
        guard let address = validAddress(selector: kAudioDevicePropertyVolumeDecibelsToScalar,
                                         scope: scope(direction: direction),
                                         element: channel) else { return nil }

        var inOutVolume = volume
        let status = getPropertyData(address, andValue: &inOutVolume)

        return noErr == status ? inOutVolume : nil
    }

    // MARK: - ♨︎ Stream Functions

    /// Returns a list of streams for a given direction.
    ///
    /// - Parameter direction: A direction.
    ///
    /// - Returns: *(optional)* An array of `AudioStream` objects.
    public func streams(direction: Direction) -> [AudioStream]? {
        guard let address = validAddress(selector: kAudioDevicePropertyStreams,
                                         scope: scope(direction: direction)) else { return nil }

        var streamIDs = [AudioStreamID]()
        let status = getPropertyDataArray(address, value: &streamIDs, andDefaultValue: 0)

        if noErr != status {
            return nil
        }

        return streamIDs.compactMap { AudioStream.lookup(by: $0) }
    }

    // MARK: - Private Functions

    private func setDefaultDevice(_ type: AudioObjectPropertySelector) -> Bool {
        let address = self.address(selector: type)
        var deviceID = UInt32(id)
        let status = setPropertyData(AudioObjectID(kAudioObjectSystemObject), address: address, andValue: &deviceID)

        return noErr == status
    }

    private func getDeviceName() -> String {
        return super.name ?? (cachedDeviceName ?? "<Unknown Device Name>")
    }

    private class func defaultDevice(of type: AudioObjectPropertySelector) -> AudioDevice? {
        let address = self.address(selector: type)
        var deviceID = AudioDeviceID()
        let status = getPropertyData(AudioObjectID(kAudioObjectSystemObject), address: address, andValue: &deviceID)

        return noErr == status ? AudioDevice.lookup(by: deviceID) : nil
    }

    // MARK: - Notification Book-keeping

    private func registerForNotifications() {
        if isRegisteredForNotifications {
            unregisterForNotifications()
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertySelectorWildcard,
            mScope: kAudioObjectPropertyScopeWildcard,
            mElement: kAudioObjectPropertyElementWildcard
        )

        let err = AudioObjectAddPropertyListenerBlock(id, &address, propertyListenerQueue, propertyListenerBlock)

        if noErr != err {
            os_log("Error on AudioObjectAddPropertyListenerBlock: %@.", log: .default, type: .debug, err)
        }

        isRegisteredForNotifications = noErr == err
    }

    private func unregisterForNotifications() {
        guard isAlive(), isRegisteredForNotifications else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertySelectorWildcard,
            mScope: kAudioObjectPropertyScopeWildcard,
            mElement: kAudioObjectPropertyElementWildcard
        )

        let err = AudioObjectRemovePropertyListenerBlock(id, &address, propertyListenerQueue, propertyListenerBlock)

        if noErr != err {
            os_log("Error on AudioObjectRemovePropertyListenerBlock: %@.", log: .default, type: .debug, err)
        }

        isRegisteredForNotifications = noErr != err
    }
}

extension AudioDevice: CustomStringConvertible {
    // MARK: - CustomStringConvertible Protocol

    /// Returns a `String` representation of self.
    public var description: String {
        return "\(name) (\(id))"
    }
}
