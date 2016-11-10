//
//  AudioHardware.swift
//  AMCoreAudio
//
//  Created by Ruben on 7/9/15.
//  Copyright © 2015 9Labs. All rights reserved.
//

import Foundation
import AudioToolbox.AudioServices

/// :nodoc:
@available(*, deprecated, message: "Marked for removal in 3.2. Use AudioHardwareEvent instead") public typealias AMAudioHardwareEvent = AudioHardwareEvent

/// :nodoc:
@available(*, deprecated, message: "Marked for removal in 3.2. Use AudioHardware instead") public typealias AMAudioHardware = AudioHardware


/**
    Represents an `AudioHardware` event.
 */
public enum AudioHardwareEvent: Event {
    /**
        Called whenever the list of hardware devices and device subdevices changes.
        (i.e., devices that are part of *Aggregate* or *Multi-Output* devices.)
     */
    case deviceListChanged(addedDevices: [AudioDevice], removedDevices: [AudioDevice])

    /**
        Called whenever the default input device changes.
     */
    case defaultInputDeviceChanged(audioDevice: AudioDevice)

    /**
        Called whenever the default output device changes.
     */
    case defaultOutputDeviceChanged(audioDevice: AudioDevice)

    /**
        Called whenever the default system output device changes.
     */
    case defaultSystemOutputDeviceChanged(audioDevice: AudioDevice)
}

/**
    This class allows subscribing to hardware-related audio notifications.

    For a comprehensive list of supported notifications, see `AudioHardwareEvent`.
 */
final public class AudioHardware {

    /**
        Returns a singleton `AudioHardware` instance.
    */
    public static let sharedInstance = AudioHardware()

    /**
        An auto-maintained array of all the audio devices currently available in the system.

        - Note: This list may also include *Aggregate* and *Multi-Output* devices.

        - Returns: An array of `AudioDevice` objects.
     */
    private var allKnownDevices = [AudioDevice]()

    private var isRegisteredForNotifications = false

    private lazy var notificationsQueue: DispatchQueue = {
        return DispatchQueue(label: "io.9labs.AMCoreAudio.hardwareNotifications", attributes: .concurrent)
    }()

    private lazy var propertyListenerBlock: AudioObjectPropertyListenerBlock = { [weak self] (inNumberAddresses, inAddresses) -> Void in
        let address = inAddresses.pointee
        let notificationCenter = NotificationCenter.defaultCenter

        switch address.mSelector {
        case kAudioObjectPropertyOwnedObjects:
            // Get the latest device list
            let latestDeviceList = AudioDevice.allDevices()

            let addedDevices = latestDeviceList.filter { (audioDevice) -> Bool in
                let isContained = (self?.allKnownDevices.filter({ (oldAudioDevice) -> Bool in
                    return oldAudioDevice == audioDevice
                }) ?? []).count > 0

                return !isContained
            }

            let removedDevices = self?.allKnownDevices.filter { (audioDevice) -> Bool in
                let isContained = latestDeviceList.filter({ (oldAudioDevice) -> Bool in
                    return oldAudioDevice == audioDevice
                }).count > 0

                return !isContained
            }

            // Add new devices
            addedDevices.forEach { (device) in
                self?.addDevice(device)
            }
            
            // Remove old devices
            removedDevices?.forEach { (device) in
                self?.removeDevice(device)
            }

            notificationCenter.publish(AudioHardwareEvent.deviceListChanged(
                addedDevices: addedDevices,
                removedDevices: removedDevices ?? []
            ))
        case kAudioHardwarePropertyDefaultInputDevice:
            if let audioDevice = AudioDevice.defaultInputDevice() {
                notificationCenter.publish(AudioHardwareEvent.defaultInputDeviceChanged(audioDevice: audioDevice))
            }
        case kAudioHardwarePropertyDefaultOutputDevice:
            if let audioDevice = AudioDevice.defaultOutputDevice() {
                notificationCenter.publish(AudioHardwareEvent.defaultOutputDeviceChanged(audioDevice: audioDevice))
            }
        case kAudioHardwarePropertyDefaultSystemOutputDevice:
            if let audioDevice = AudioDevice.defaultSystemOutputDevice() {
                notificationCenter.publish(AudioHardwareEvent.defaultSystemOutputDeviceChanged(audioDevice: audioDevice))
            }
        default:
            break
        }
    }

    // MARK: - Public Functions

    deinit {
        disableDeviceMonitoring()
    }

    /**
        Enables device monitoring so events like the ones below are generated:
     
        - added or removed device
        - new default input device
        - new default output device
        - new default system output device

        - SeeAlso: disableDeviceMonitoring()
     */
    internal func enableDeviceMonitoring() {
        registerForNotifications()

        let allDevices = AudioDevice.allDevices()

        allDevices.forEach { (device) in
            addDevice(device)
        }
    }

    /**
        Disables device monitoring.
     
        - SeeAlso: enableDeviceMonitoring()
     */
    internal func disableDeviceMonitoring() {
        allKnownDevices.forEach { (device) in
            removeDevice(device)
        }

        unregisterForNotifications()
    }

    // MARK: - Private Functions

    private func addDevice(_ device: AudioDevice) {
        allKnownDevices.append(device)
    }

    private func removeDevice(_ device: AudioDevice) {
        if let idx = allKnownDevices.index(of: device) {
            allKnownDevices.remove(at: idx)
        }
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

        let err = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, notificationsQueue, propertyListenerBlock)

        if noErr != err {
            log("Error on AudioObjectAddPropertyListenerBlock: \(err)")
        }

        isRegisteredForNotifications = noErr == err
    }

    private func unregisterForNotifications() {
        if isRegisteredForNotifications {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertySelectorWildcard,
                mScope: kAudioObjectPropertyScopeWildcard,
                mElement: kAudioObjectPropertyElementWildcard
            )

            let err = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, notificationsQueue, propertyListenerBlock)

            if noErr != err {
                log("Error on AudioObjectRemovePropertyListenerBlock: \(err)")
            }

            isRegisteredForNotifications = noErr != err
        }
    }
}
