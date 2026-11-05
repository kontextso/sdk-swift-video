/// Which `ContentPlayback` tracks which player, across every `VideoAds`: a player belongs to one at a time. The
/// playback that claims a player takes it, and the one that tracked it before lets go
/// (`ContentPlayback.losePlayer()`): its overlay and pause ads can no longer be shown.
@MainActor
enum PlayerOwnership {
    /// One playback and the player it tracks, both weak.
    private struct Owner {
        weak var playback: ContentPlayback?
        weak var player: AnyObject?
    }

    private static var owners: [Owner] = []

    /// `player` is `playback`'s now: another one that tracks it lets go, as if it had never tracked one, except
    /// that its overlay and pause ads can no longer be shown (`ContentPlayback.playsAnotherEpisode`).
    static func claim(_ playback: ContentPlayback, player: AnyObject) {
        owners.removeAll { $0.playback == nil || $0.player == nil || $0.playback === playback }
        let others = owners.filter { $0.player === player }.compactMap(\.playback)
        owners.removeAll { $0.player === player }
        owners.append(Owner(playback: playback, player: player))
        for other in others { other.losePlayer() }
    }

    /// `playback` tracks nothing now (it stopped): it owns no player.
    static func release(_ playback: ContentPlayback) {
        owners.removeAll { $0.playback === playback || $0.playback == nil }
    }
}
