import AppKit
import Foundation
import Observation
import OpenIslandCore
import SwiftUI

@MainActor
@Observable
final class OverlayUICoordinator {

    private static let notificationSurfaceAutoCollapseDelay: TimeInterval = 10

    // MARK: - Transition animations
    //
    // Owned here, not by the view, because the Liquid Glass morph
    // (`IslandPanelView.islandMorphSurface`) needs the `notchStatus`
    // mutation itself wrapped in an explicit `withAnimation` to animate
    // reliably — a passive `.animation(value:)` modifier elsewhere in the
    // view tree isn't shown to reliably drive glass insert/remove
    // transitions the way it drives ordinary opacity/scale. `withAnimation`
    // is a plain SwiftUI function, not view-only, so it's fine to call from
    // here; this does not reintroduce AppKit-level animation — the actual
    // `NSPanel` frame is still set synchronously in `OverlayPanelController`.
    private static let openAnimation = Animation.spring(response: 0.55, dampingFraction: 0.6)
    // Underdamped (dampingFraction < 1) springs overshoot their target
    // before settling — fine when *opening* (springs past the opened size,
    // a nice pop), but when *closing* it meant the pill shrank smaller than
    // its final size and bounced back up to it, which reads as wrong rather
    // than playful since the pill has one exact correct size to land on.
    // `.smooth` is SwiftUI's no-overshoot preset, so it settles into the
    // pill's size directly.
    private static let closeAnimation = Animation.smooth(duration: 0.4)
    private static let popAnimation = Animation.spring(response: 0.3, dampingFraction: 0.5)

    private static func transitionAnimation(for status: NotchStatus) -> Animation {
        switch status {
        case .opened:  return openAnimation
        case .closed:  return closeAnimation
        case .popping: return popAnimation
        }
    }

    var notchStatus: NotchStatus = .closed
    var notchOpenReason: NotchOpenReason?
    var islandSurface: IslandSurface = .sessionList()
    var isOverlayVisible: Bool { notchStatus != .closed }

    var overlayDisplayOptions: [OverlayDisplayOption] = []
    var overlayPlacementDiagnostics: OverlayPlacementDiagnostics?

    var overlayDisplaySelectionID = OverlayDisplayOption.automaticID {
        didSet {
            guard overlayDisplaySelectionID != oldValue else {
                return
            }
            persistOverlayDisplayPreference()
            refreshOverlayPlacement()
        }
    }

    @ObservationIgnored
    weak var appModel: AppModel?

    @ObservationIgnored
    var onStatusMessage: ((String) -> Void)?

    @ObservationIgnored
    var activeIslandCardSessionAccessor: (() -> AgentSession?)?

    @ObservationIgnored
    var isSoundMutedAccessor: (() -> Bool)?

    @ObservationIgnored
    var ignoresPointerExitAccessor: (() -> Bool)?

    @ObservationIgnored
    var harnessRuntimeMonitor: HarnessRuntimeMonitor?

    @ObservationIgnored
    let overlayPanelController = OverlayPanelController()

    @ObservationIgnored
    private var screenParametersObserver: NSObjectProtocol?

    @ObservationIgnored
    private var overlayTransitionGeneration: UInt64 = 0

    @ObservationIgnored
    private var notificationAutoCollapseTask: Task<Void, Never>?

    var hasPendingNotificationAutoCollapse: Bool {
        notificationAutoCollapseTask != nil
    }

    @ObservationIgnored
    private var autoCollapseSurfaceHasBeenEntered = false

    @ObservationIgnored
    private var isPointerInsideIslandSurface = false

    /// Kept for API compatibility; always false now that the window never
    /// resizes and close transitions are pure SwiftUI.
    var isCloseTransitionPending: Bool { false }

    private var activeIslandCardSession: AgentSession? {
        activeIslandCardSessionAccessor?()
    }

    private var isSoundMuted: Bool {
        isSoundMutedAccessor?() ?? false
    }

    private var ignoresPointerExitDuringHarness: Bool {
        ignoresPointerExitAccessor?() ?? false
    }

    private var preferredOverlayScreenID: String? {
        overlayDisplaySelectionID == OverlayDisplayOption.automaticID
            ? nil
            : overlayDisplaySelectionID
    }

    // MARK: - Initialization

    func restoreDisplayPreference() {
        overlayDisplaySelectionID = UserDefaults.standard.string(
            forKey: "overlay.display.preference"
        ) ?? OverlayDisplayOption.automaticID
    }

    /// Re-syncs the cached display options and the target panel placement
    /// whenever macOS reports a screen configuration change (hotplug,
    /// arrangement change, sleep/wake). Without this, the picker list keeps
    /// stale entries after disconnect, and a saved preference whose
    /// `CGDirectDisplayID` gets reused for a different physical display can
    /// silently route the island to the wrong screen.
    func startObservingDisplayChanges() {
        guard screenParametersObserver == nil else { return }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshOverlayDisplayConfiguration()
            }
        }
    }

    isolated deinit {
        if let observer = screenParametersObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Overlay transitions

    func toggleOverlay() {
        if notchStatus == .closed {
            notchOpen(reason: .click)
        } else {
            notchClose()
        }
    }

    func notchOpen(reason: NotchOpenReason, surface: IslandSurface = .sessionList()) {
        transitionOverlay(
            to: .opened,
            reason: reason,
            surface: surface,
            interactive: true,
            beforeTransition: nil,
            afterStateChange: { [weak self] in
                guard let self else { return }
                self.autoCollapseSurfaceHasBeenEntered = false
                self.isPointerInsideIslandSurface = false
                self.updateNotificationAutoCollapse()
            },
            onPlacementResolved: { [weak self] in
                guard let self, let overlayPlacementDiagnostics else { return }
                self.onStatusMessage?("Overlay showing on \(overlayPlacementDiagnostics.targetScreenName) as \(overlayPlacementDiagnostics.modeDescription.lowercased()).")
            }
        )
    }

    func notchClose() {
        transitionOverlay(
            to: .closed,
            reason: nil,
            surface: .sessionList(),
            interactive: false,
            beforeTransition: { [weak self] in
                self?.notificationAutoCollapseTask?.cancel()
                self?.notificationAutoCollapseTask = nil
            },
            afterStateChange: { [weak self] in
                self?.autoCollapseSurfaceHasBeenEntered = false
                self?.isPointerInsideIslandSurface = false
                self?.appModel?.measuredNotificationContentHeight = 0
            }
        )
    }

    /// Coordinates overlay transitions.
    ///
    /// The window stays at a fixed (opened) size at all times — no AppKit
    /// animation, no window resize; `overlayPanelController.setInteractive`/
    /// `.show` below are synchronous AppKit calls, deliberately left outside
    /// the `withAnimation` closure. All visual transitions (shape morph,
    /// content fade) are SwiftUI-side only, driven by wrapping the
    /// `notchStatus` mutation itself in an explicit `withAnimation` — see
    /// the note on `transitionAnimation(for:)` above for why a passive
    /// `.animation(value:)` modifier isn't used instead.
    private func transitionOverlay(
        to status: NotchStatus,
        reason: NotchOpenReason?,
        surface: IslandSurface,
        interactive: Bool,
        beforeTransition: (() -> Void)?,
        afterStateChange: (() -> Void)? = nil,
        onPlacementResolved: (() -> Void)? = nil
    ) {
        beforeTransition?()

        overlayTransitionGeneration &+= 1

        // Reset measured notification height when the surface changes so stale
        // measurements from a previous notification don't mis-size the new one.
        if surface != islandSurface {
            appModel?.measuredNotificationContentHeight = 0
        }

        withAnimation(Self.transitionAnimation(for: status)) {
            islandSurface = surface
            notchOpenReason = reason
            notchStatus = status
        }
        overlayPanelController.setInteractive(interactive)

        if status == .opened, let appModel {
            overlayPlacementDiagnostics = overlayPanelController.show(
                model: appModel,
                preferredScreenID: preferredOverlayScreenID
            )
        }

        afterStateChange?()
        onPlacementResolved?()
    }

    func notchPop() {
        guard notchStatus == .closed else { return }
        withAnimation(Self.popAnimation) {
            islandSurface = .sessionList()
            notchStatus = .popping
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.notchStatus == .popping else { return }
            withAnimation(Self.closeAnimation) {
                self.notchStatus = .closed
            }
        }
    }

    func performBootAnimation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.notchOpen(reason: .boot, surface: .sessionList())
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard self?.notchOpenReason == .boot else { return }
                self?.notchClose()
            }
        }
    }

    func ensureOverlayPanel() {
        guard let appModel else { return }
        overlayPanelController.ensurePanel(model: appModel, preferredScreenID: preferredOverlayScreenID)
    }

    // Legacy compatibility
    func showOverlay() { notchOpen(reason: .click, surface: .sessionList()) }
    func hideOverlay() { notchClose() }

    /// Transition from notification mode (single session) to full session list.
    /// - Parameter clearExpansion: If true, clears the actionable session's expansion
    ///   (used for completion notifications which are informational only).
    func expandNotificationToSessionList(clearExpansion: Bool = false) {
        if clearExpansion {
            islandSurface = .sessionList()
        }
        // When not clearing, keep actionableSessionID so approval/question expansion persists
        notchOpenReason = .click
        notificationAutoCollapseTask?.cancel()
        notificationAutoCollapseTask = nil
        refreshOverlayPlacementIfVisible()
    }

    // MARK: - Display configuration

    func refreshOverlayDisplayConfiguration() {
        overlayDisplayOptions = overlayPanelController.availableDisplayOptions()

        let validSelectionIDs = Set(overlayDisplayOptions.map(\.id))
        if !validSelectionIDs.contains(overlayDisplaySelectionID) {
            overlayDisplaySelectionID = OverlayDisplayOption.automaticID
            return
        }

        refreshOverlayPlacement()
    }

    func refreshOverlayPlacement() {
        overlayPlacementDiagnostics = overlayPanelController.reposition(
            preferredScreenID: preferredOverlayScreenID
        )
    }

    func refreshOverlayPlacementIfVisible() {
        refreshOverlayPlacement()
    }

    // MARK: - Pointer tracking

    var shouldAutoCollapseOnMouseLeave: Bool {
        if ignoresPointerExitDuringHarness {
            return false
        }

        guard notchStatus == .opened else {
            return false
        }

        if notchOpenReason == .hover && !islandSurface.isNotificationCard {
            return true
        }

        return notchOpenReason == .notification
            && islandSurface.autoDismissesWhenPresentedAsNotification(session: activeIslandCardSession)
    }

    var autoCollapseOnMouseLeaveRequiresPriorSurfaceEntry: Bool {
        guard notchOpenReason == .notification else { return false }
        // If the session was removed from state (e.g. by process monitoring),
        // default to requiring prior surface entry — prevents the notification
        // from closing immediately on pointer exit before the user sees it.
        guard let session = activeIslandCardSession else { return true }
        return islandSurface.autoDismissesWhenPresentedAsNotification(session: session)
    }

    var showsNotificationCard: Bool {
        islandSurface.isNotificationCard
    }

    func notePointerInsideIslandSurface() {
        guard shouldTrackPointerInsideIslandSurface else {
            return
        }

        isPointerInsideIslandSurface = true
        autoCollapseSurfaceHasBeenEntered = true

        if notchOpenReason == .notification {
            notificationAutoCollapseTask?.cancel()
            notificationAutoCollapseTask = nil
        }
    }

    func handlePointerExitedIslandSurface() {
        guard shouldTrackPointerInsideIslandSurface else {
            return
        }

        isPointerInsideIslandSurface = false

        guard shouldAutoCollapseOnMouseLeave else {
            return
        }

        guard !autoCollapseOnMouseLeaveRequiresPriorSurfaceEntry
                || autoCollapseSurfaceHasBeenEntered else {
            return
        }

        notchClose()
    }

    // MARK: - Notification surfaces

    func presentNotificationSurface(_ surface: IslandSurface) {
        guard surface.isNotificationCard else {
            return
        }

        guard !shouldPreserveCurrentNotificationSurface(against: surface) else {
            return
        }

        appModel?.measuredNotificationContentHeight = 0
        NotificationSoundService.playNotification(isMuted: isSoundMuted)
        notchOpen(reason: .notification, surface: surface)
    }

    func shouldPreserveCurrentNotificationSurface(against candidate: IslandSurface) -> Bool {
        guard candidate.isNotificationCard,
              notchStatus == .opened,
              notchOpenReason == .notification,
              islandSurface.isNotificationCard,
              islandSurface != candidate else {
            return false
        }

        return isPointerInsideCurrentNotificationCard
    }

    func reconcileIslandSurfaceAfterStateChange() {
        guard islandSurface.isNotificationCard else {
            return
        }

        let session = activeIslandCardSession
        guard islandSurface.matchesCurrentState(of: session) else {
            if notchOpenReason == .notification {
                notchClose()
            } else {
                islandSurface = .sessionList()
            }
            return
        }

        updateNotificationAutoCollapse()
    }

    func dismissNotificationSurfaceIfPresent(for sessionID: String) {
        guard islandSurface.sessionID == sessionID,
              notchOpenReason == .notification else {
            return
        }

        notchClose()
    }

    func dismissOverlayForJump() {
        guard isOverlayVisible else {
            return
        }

        notchClose()
    }

    private func updateNotificationAutoCollapse() {
        notificationAutoCollapseTask?.cancel()
        notificationAutoCollapseTask = nil

        guard notchStatus == .opened,
              notchOpenReason == .notification,
              islandSurface.autoDismissesWhenPresentedAsNotification(session: activeIslandCardSession) else {
            return
        }

        if overlayPanelController.isPointInExpandedArea(NSEvent.mouseLocation) {
            notePointerInsideIslandSurface()
            return
        }

        notificationAutoCollapseTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.notificationSurfaceAutoCollapseDelay))
            } catch {
                // Task was cancelled (e.g. a new event reset the timer).
                // Do NOT proceed — the replacement task owns the new timer.
                return
            }

            guard let self,
                  self.notchStatus == .opened,
                  self.notchOpenReason == .notification,
                  self.islandSurface.autoDismissesWhenPresentedAsNotification(session: self.activeIslandCardSession) else {
                return
            }

            guard !self.shouldDeferTimedNotificationAutoCollapse else {
                return
            }

            self.notchClose()
        }
    }

    var shouldDeferTimedNotificationAutoCollapse: Bool {
        isPointerInsideIslandSurface
            || overlayPanelController.isPointInExpandedArea(NSEvent.mouseLocation)
    }

    private var shouldTrackPointerInsideIslandSurface: Bool {
        shouldAutoCollapseOnMouseLeave
            || (notchStatus == .opened && notchOpenReason == .notification && islandSurface.isNotificationCard)
    }

    private var isPointerInsideCurrentNotificationCard: Bool {
        isPointerInsideIslandSurface
            || overlayPanelController.isPointInExpandedArea(NSEvent.mouseLocation)
    }

    // MARK: - Debug snapshots (overlay portion)

    func applyOverlayState(from snapshot: IslandDebugSnapshot, presentOverlay: Bool, autoCollapseNotificationCards: Bool) {
        notificationAutoCollapseTask?.cancel()
        notificationAutoCollapseTask = nil
        autoCollapseSurfaceHasBeenEntered = false
        isPointerInsideIslandSurface = false

        islandSurface = snapshot.islandSurface
        notchStatus = snapshot.notchStatus
        notchOpenReason = snapshot.notchOpenReason

        if autoCollapseNotificationCards {
            updateNotificationAutoCollapse()
        }

        guard presentOverlay, let appModel else {
            return
        }

        // Immediate interactivity update.
        let interactive = snapshot.notchStatus == .opened
        overlayPanelController.setInteractive(interactive)

        // Defer AppKit panel animation to the next run-loop iteration.
        overlayTransitionGeneration &+= 1
        let capturedGeneration = overlayTransitionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.overlayTransitionGeneration == capturedGeneration else { return }
            switch snapshot.notchStatus {
            case .opened:
                self.overlayPlacementDiagnostics = self.overlayPanelController.show(
                    model: appModel,
                    preferredScreenID: self.preferredOverlayScreenID
                )
            case .closed, .popping:
                self.overlayPanelController.ensurePanel(
                    model: appModel,
                    preferredScreenID: self.preferredOverlayScreenID
                )
                self.refreshOverlayPlacement()
            }
            self.harnessRuntimeMonitor?.recordMilestone("overlayPresented", message: snapshot.title)
        }
    }

    // MARK: - Persistence

    private func persistOverlayDisplayPreference() {
        let defaults = UserDefaults.standard
        if overlayDisplaySelectionID == OverlayDisplayOption.automaticID {
            defaults.removeObject(forKey: "overlay.display.preference")
        } else {
            defaults.set(overlayDisplaySelectionID, forKey: "overlay.display.preference")
        }
    }
}
