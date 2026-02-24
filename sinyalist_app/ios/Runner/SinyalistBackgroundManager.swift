// =============================================================================
// SINYALIST — iOS Background Manager
// =============================================================================
// Keeps the app process alive in the background using:
//   1. CLLocationManager significant-location-change monitoring
//      (App Store compliant, ~negligible battery impact)
//   2. BLE background modes (bluetooth-central/peripheral in Info.plist)
//      keep the process alive when BLE events fire
//   3. BGTaskScheduler for periodic supplementary processing (≥15 min)
//   4. UNUserNotificationCenter for survival-mode critical alerts
//      (equivalent to Android foreground service notification)
// =============================================================================

import Foundation
import CoreLocation
import BackgroundTasks
import UserNotifications
import UIKit

class SinyalistBackgroundManager: NSObject, CLLocationManagerDelegate {

    private static let seismicTaskId = "com.sinyalist.seismic"
    private static let notifChannelId = "sinyalist_emergency"

    private let locationManager = CLLocationManager()
    private var isSurvivalMode = false
    private var monitoringActive = false

    // Called from AppDelegate after channel registration
    func startMonitoring() {
        setupLocationManager()
        registerBackgroundTask()
        requestNotificationPermission()
    }

    func stopMonitoring() {
        locationManager.stopMonitoringSignificantLocationChanges()
        monitoringActive = false
    }

    func activateSurvivalMode() {
        guard !isSurvivalMode else { return }
        isSurvivalMode = true
        postSurvivalNotification()
    }

    // -------------------------------------------------------------------------
    // Location Manager — keeps process alive in background
    // -------------------------------------------------------------------------

    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false

        let status = locationManager.authorizationStatus
        switch status {
        case .notDetermined:
            locationManager.requestAlwaysAuthorization()
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        case .authorizedAlways:
            startLocationMonitoring()
        default:
            // Permission denied — log and continue without location keep-alive.
            // BLE background modes will still keep the app alive for BLE events.
            print("[BackgroundMgr] Location permission denied — BLE-only background")
        }
    }

    private func startLocationMonitoring() {
        locationManager.startMonitoringSignificantLocationChanges()
        monitoringActive = true
        print("[BackgroundMgr] Significant location change monitoring started")
    }

    // CLLocationManagerDelegate
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways {
            startLocationMonitoring()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[BackgroundMgr] Location error: \(error.localizedDescription)")
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Significant location change — opportunity to do work.
        // Seismic engine runs continuously so no explicit restart needed here.
        print("[BackgroundMgr] Significant location change — app still alive")
    }

    // -------------------------------------------------------------------------
    // BGTaskScheduler — periodic supplementary work
    // -------------------------------------------------------------------------

    private func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.seismicTaskId,
            using: nil
        ) { [weak self] task in
            self?.handleBackgroundTask(task: task as! BGProcessingTask)
        }
        scheduleNextBackgroundTask()
    }

    private func scheduleNextBackgroundTask() {
        let request = BGProcessingTaskRequest(identifier: Self.seismicTaskId)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 min

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[BackgroundMgr] BGTask schedule error: \(error)")
        }
    }

    private func handleBackgroundTask(task: BGProcessingTask) {
        scheduleNextBackgroundTask() // reschedule immediately

        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        // Seismic engine runs continuously via CMMotionManager —
        // this task mainly renews our time budget with iOS.
        print("[BackgroundMgr] BGProcessingTask fired — seismic monitoring continues")
        task.setTaskCompleted(success: true)
    }

    // -------------------------------------------------------------------------
    // Notifications — survival mode alert (foreground service equivalent)
    // -------------------------------------------------------------------------

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge, .criticalAlert]
        ) { granted, error in
            if granted {
                print("[BackgroundMgr] Notification permission granted")
            } else {
                print("[BackgroundMgr] Notification permission denied: \(error?.localizedDescription ?? "unknown")")
            }
        }

        // Register monitoring notification category
        let monitorAction = UNNotificationAction(
            identifier: "OPEN_APP",
            title: "Aç",
            options: .foreground
        )
        let category = UNNotificationCategory(
            identifier: Self.notifChannelId,
            actions: [monitorAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    private func postSurvivalNotification() {
        let content = UNMutableNotificationContent()
        content.title = "DEPREM ALGILANDI"
        content.body = "Hayatta kalma modu aktif. Konum paylaşıldı."
        content.sound = .defaultCritical
        content.categoryIdentifier = Self.notifChannelId
        content.interruptionLevel = .critical

        let request = UNNotificationRequest(
            identifier: "sinyalist_survival_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil // immediate
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[BackgroundMgr] Survival notification error: \(error)")
            } else {
                print("[BackgroundMgr] SURVIVAL notification posted")
            }
        }
    }

    func postMonitoringNotification(status: String) {
        let content = UNMutableNotificationContent()
        content.title = "Sinyalist Aktif"
        content.body = status
        content.sound = nil
        content.categoryIdentifier = Self.notifChannelId
        content.interruptionLevel = .passive

        let request = UNNotificationRequest(
            identifier: "sinyalist_status",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
