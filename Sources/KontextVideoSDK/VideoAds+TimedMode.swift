import AVFoundation
import Foundation

/// Timed mode, the part of `VideoAds` that runs on a clock: sampling the playhead while there is
/// something to watch, delivering windows, reporting `nextRequestAt`, and treating a jump as a seek.
/// Nothing here loads or shows an ad; it tells the app through `timingDelegate` and the ads' delegates.
extension VideoAds {
    /// Timed mode runs on a clock only while there is something to watch: a windowed ad not yet shown, a
    /// `nextRequestAt`, a windowed overlay on screen (a seek out of its window ends it).
    var needsMonitor: Bool {
        guard !isDestroyed else { return false }
        if !nextRequestAt.isEmpty || !deferredRequests.isEmpty { return true }
        if liveBids.contains(where: { $0.isPending && $0.isWindowed }) { return true }
        if liveAds.contains(where: { $0.isWindowed && $0.isPendingUnshown }) { return true }
        return showing.values.contains { $0.isWindowed && $0.format == .overlay }
    }

    func updateMonitor() {
        if needsMonitor {
            guard monitor == nil else { return }
            lastSample = nil
            let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = Self.sampleInterval / 5
            RunLoop.main.add(timer, forMode: .common)
            monitor = timer
            Logger.debug("\(content.id): watching the playhead")
        } else {
            stopMonitor()
        }
    }

    func stopMonitor() {
        guard let monitor else { return }
        monitor.invalidate()
        self.monitor = nil
        lastSample = nil
        Logger.debug("\(content.id): stopped watching the playhead")
    }

    /// One sample: a seek is a jump; otherwise windows and `nextRequestAt` are detected by crossing, the
    /// last sample before, this one at or past. Apple's advice for boundary observers applies: decide from
    /// the current time, never from a callback that a seek may skip.
    func tick() {
        let now = playhead
        defer {
            lastSample = now
            if !needsMonitor { stopMonitor() }
        }
        guard let last = lastSample else { return }
        if abs(now - last) > Self.seekThreshold {
            seeked(from: last, to: now)
            return
        }
        for (id, at) in nextRequestAt where now >= TimeInterval(at) / 1000 {
            nextRequestAt[id] = nil
            if isBusy(id) {
                // The placement still holds an unshown ad: a load now would be refused. Reported the
                // moment the placement is free (the next sample), never lost.
                Logger.info("\(id) for \(content.id): nextRequestAt \(at) ms reached while the placement is busy; deferred")
                deferredRequests.insert(id)
            } else {
                Logger.info("\(id) for \(content.id): nextRequestAt \(at) ms reached")
                timingDelegate?.videoAds(self, didRequestLoadOf: id, reason: .nextRequestReached)
            }
        }
        for id in deferredRequests.sorted() where !isBusy(id) {
            deferredRequests.remove(id)
            Logger.info("\(id) for \(content.id): placement free, the deferred nextRequestAt is due")
            timingDelegate?.videoAds(self, didRequestLoadOf: id, reason: .nextRequestReached)
        }
        for bid in liveBids where bid.isPending {
            guard case .window(_, let to) = bid.trigger, now >= to else { continue }
            bid.invalidate(.windowPassed)   // the invalidation reports the load request
        }
        for ad in liveAds where ad.isPendingUnshown {
            guard case .window(let from, let to) = ad.trigger else { continue }
            let fits = ad.format == .overlay ? now + (ad.duration ?? 0) <= to : now < to
            if !fits {
                Logger.info("ad \(ad.id.prefix(8)): window \(from)–\(to) s passed at \(now) s")
                ad.invalidate(.windowPassed)   // the invalidation reports the load request
            } else if now >= from {
                ad.deliverWindow()
            }
        }
    }

    /// The viewer seeked: the pending ads were chosen for the old content time and are stale, the
    /// server's plan is forgotten, and the app hears that a load makes sense for each placement that had
    /// something. An overlay on screen whose window the viewer left ends.
    func seeked(from: TimeInterval, to: TimeInterval) {
        Logger.info("\(content.id): seek from \(from) s to \(to) s")
        DebugReporter.shared.event("ads.seek", state: ["from": .number(from), "to": .number(to)])
        var placements: [String] = []
        for bid in liveBids where bid.isPending && bid.isWindowed {
            bid.invalidate(.seeked)
            placements.append(bid.placementId)
        }
        for ad in liveAds where ad.isPendingUnshown && ad.isWindowed {
            ad.invalidate(.seeked)
            placements.append(ad.placementId)
        }
        for ad in showing.values where ad.format == .overlay {
            if case .window(let windowFrom, let windowTo) = ad.trigger, !(windowFrom...windowTo).contains(to) {
                Logger.info("ad \(ad.id.prefix(8)): the viewer seeked out of its window")
                ad.end(.interrupted)
            }
        }
        placements.append(contentsOf: nextRequestAt.keys.sorted())
        placements.append(contentsOf: deferredRequests.sorted())
        nextRequestAt.removeAll()
        deferredRequests.removeAll()
        var notified: Set<String> = []
        for id in placements where notified.insert(id).inserted {
            timingDelegate?.videoAds(self, didRequestLoadOf: id, reason: .seeked)
        }
    }

    /// For a tracked `AVPlayer`, Apple's documented seek signal; the sample threshold is the fallback.
    func observeTimeJumps() {
        if let timeJumpObserver {
            NotificationCenter.default.removeObserver(timeJumpObserver)
            self.timeJumpObserver = nil
        }
        guard trackedPlayer != nil else { return }
        timeJumpObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.monitor != nil, let item = notification.object as? AVPlayerItem,
                      item === self.trackedPlayer?.currentItem, let last = self.lastSample else { return }
                let now = self.playhead
                guard abs(now - last) > 0.5 else { return }
                self.seeked(from: last, to: now)
                self.lastSample = now
            }
        }
    }

    func warnIfNoPlayheadSource() {
        guard !hasPlayheadSource, !noPlayheadSourceLogged else { return }
        noPlayheadSourceLogged = true
        Logger.warning("\(content.id): a timed ad arrived but no playhead source is set; call trackPlayhead(of:) or set playheadProvider, or its window can never be detected")
    }
}
